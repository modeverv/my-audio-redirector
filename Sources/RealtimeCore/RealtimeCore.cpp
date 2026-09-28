#include "RealtimeCore.h"
#include "samplerate.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <new>

namespace {
// These faults latch until the control thread destroys/recreates the stopped core.
enum Fault { badArgument = 1, converterError = 2, starvation = 3,
             overflow = 4, nonFiniteAudio = 5, discontinuity = 6 };
constexpr double kMaximumPPM = 1000.0;
constexpr double kSlewPPMPerSecond = 100.0;
constexpr unsigned kMaximumProcessCalls = 8;
static_assert(std::atomic<uint64_t>::is_always_lock_free, "RT atomics must be lock free");
static_assert(std::atomic<double>::is_always_lock_free, "RT atomics must be lock free");
static_assert(std::atomic<float>::is_always_lock_free, "RT atomics must be lock free");
static_assert(std::atomic<int>::is_always_lock_free && std::atomic<bool>::is_always_lock_free, "RT diagnostic publication must be lock free");

uint64_t pairBits(float l, float r) {
    uint32_t a, b; std::memcpy(&a, &l, 4); std::memcpy(&b, &r, 4);
    return uint64_t(a) | (uint64_t(b) << 32);
}
void pairValues(uint64_t bits, float &l, float &r) {
    uint32_t a = uint32_t(bits), b = uint32_t(bits >> 32);
    std::memcpy(&l, &a, 4); std::memcpy(&r, &b, 4);
}
float amplitude(float db) { return std::pow(10.0f, std::clamp(db, -144.0f, 24.0f) / 20.0f); }

constexpr MRGateSettings kDefaultGate {1, -60, .2f, 50, 30, 6};
bool validGate(const MRGateSettings &g) {
    return (g.enabled == 0 || g.enabled == 1) &&
        std::isfinite(g.thresholdDB) && g.thresholdDB >= -96 && g.thresholdDB <= 0 &&
        std::isfinite(g.attackMS) && g.attackMS >= .1f && g.attackMS <= 50 &&
        std::isfinite(g.holdMS) && g.holdMS >= 0 && g.holdMS <= 1000 &&
        std::isfinite(g.releaseMS) && g.releaseMS >= 1 && g.releaseMS <= 2000 &&
        std::isfinite(g.hysteresisDB) && g.hysteresisDB >= 0 && g.hysteresisDB <= 24;
}
// 10 threshold + 9 attack + 10 hold + 11 release + 8 hysteresis + 1 enabled
// bits. Quantization is part of the C API contract, not a torn-field snapshot.
uint64_t gateBits(const MRGateSettings &g) {
    return uint64_t(std::lround((g.thresholdDB + 96) * 10)) |
        (uint64_t(std::lround(g.attackMS * 10)) << 10) |
        (uint64_t(std::lround(g.holdMS)) << 19) |
        (uint64_t(std::lround(g.releaseMS)) << 29) |
        (uint64_t(std::lround(g.hysteresisDB * 10)) << 40) |
        (uint64_t(g.enabled != 0) << 48);
}

// Producer-owned detector/envelope. No buffering, allocation, locks, RMS
// window, or transcendental work per sample. Input is checked finite first.
struct Gate {
    uint64_t applied = UINT64_MAX;
    bool enabled = true, opened = false, hasSamples = false;
    float opening = 0, closing = 0, gain = 0, target = 0, step = 0, rampStart = 0;
    uint32_t attack = 0, hold = 0, release = 0, held = 0, remaining = 0, rampLength = 0;

    void rampTo(float value, uint32_t frames) {
        target = value;
        if (gain == target) { remaining = 0; step = 0; return; }
        rampStart = gain; remaining = rampLength = frames;
        step = (target - gain) / float(frames);
    }
    void configure(uint64_t bits, double rate) {
        if (bits == applied) return;
        const bool wasEnabled = enabled;
        enabled = (bits >> 48) & 1;
        const float threshold = float(bits & 1023) / 10 - 96;
        const float hysteresis = float((bits >> 40) & 255) / 10;
        opening = amplitude(threshold); closing = amplitude(threshold - hysteresis);
        attack = std::max(1u, uint32_t(std::lround(double((bits >> 10) & 511) * rate / 10000)));
        hold = uint32_t(std::lround(double((bits >> 19) & 1023) * rate / 1000));
        release = std::max(1u, uint32_t(std::lround(double((bits >> 29) & 2047) * rate / 1000)));
        if (!hasSamples) {
            opened = !enabled; gain = target = enabled ? 0 : 1; remaining = held = 0; step = 0;
        } else if (!enabled) {
            opened = true; held = 0; rampTo(1, attack);
        } else {
            if (!wasEnabled) { opened = true; held = hold; }
            else held = std::min(held, hold);
            if (remaining) rampTo(target, target > gain ? attack : release);
        }
        applied = bits;
    }
    float next(float level) {
        hasSamples = true;
        if (enabled) {
            if (opened) {
                if (level >= closing) held = hold;
                else if (held) --held;
                else { opened = false; rampTo(0, release); }
            } else if (level >= opening) {
                opened = true; held = hold; rampTo(1, attack);
            }
        }
        if (remaining) {
            --remaining;
            gain = remaining ? std::clamp(rampStart + step * float(rampLength - remaining), 0.0f, 1.0f) : target;
        }
        // Exact endpoints avoid denormal tails after closing.
        return gain;
    }
};

struct Ramp {
    float current = 0, target = 0, step = 0;
    uint32_t remaining = 0;
    void set(float value, uint32_t length) {
        if (value == target) return;
        target = value; remaining = length;
        step = (target - current) / float(length);
    }
    float next() {
        if (remaining && --remaining == 0) current = target;
        else if (remaining) current += step;
        return current;
    }
};

// A tracker belongs to exactly one callback. Device input and output have
// different trackers even when they belong to the same physical interface.
struct ClockTracker {
    bool previousValid = false;
    double previousSample = 0, previousHost = 0, anchorSample = 0, anchorHost = 0;
    uint32_t previousFrames = 0;
    double rate = 48000;
    uint32_t observe(MRTime t, uint32_t frames, double nominal) {
        if (!t.valid) { previousValid = false; return 0; }
        if (!std::isfinite(t.sampleTime) || !std::isfinite(t.hostSeconds)) return MR_CLOCK_NONFINITE_TIMESTAMP;
        if (previousValid) {
            if (std::abs(t.sampleTime - previousSample - previousFrames) > 0.5) return MR_CLOCK_SAMPLE_TIME_GAP;
            if (t.hostSeconds <= previousHost) return MR_CLOCK_HOST_TIME_NONINCREASING;
            const double elapsed = t.hostSeconds - anchorHost;
            if (elapsed >= 0.25) {
                const double measured = (t.sampleTime - anchorSample) / elapsed;
                // Reject jitter-corrupted rate observations, not otherwise
                // continuous audio. Occupancy feedback remains available.
                if (std::isfinite(measured) && std::abs(measured / nominal - 1) < 0.01)
                    rate += 0.125 * (measured - rate);
                anchorSample = t.sampleTime; anchorHost = t.hostSeconds;
            }
        } else { anchorSample = t.sampleTime; anchorHost = t.hostSeconds; }
        previousSample = t.sampleTime; previousHost = t.hostSeconds;
        previousFrames = frames; previousValid = true;
        return 0;
    }
};

struct Channel {
    std::atomic<uint64_t> coefficients { pairBits(0, 0) };
    std::atomic<uint64_t> gateCommand { gateBits(kDefaultGate) };
    Ramp left, right;
    Gate gate;
    std::atomic<float> peak { 0 };
    std::atomic<float> gateGain { 0 };
};

struct Source {
    uint32_t channels = 0, target = 0, capacity = 0, mask = 0;
    uint32_t gateLinks = 0; // immutable after the first producer callback
    std::unique_ptr<float[]> ring, mix;
    alignas(64) std::atomic<uint64_t> written { 0 };
    alignas(64) std::atomic<uint64_t> read { 0 };
    std::array<Channel, MR_MAX_CHANNELS> channel;
    SRC_STATE *src = nullptr;
    ClockTracker inputClock;
    std::atomic<double> inputRate { 48000 };
    // Consumer-only state, never touched by the producer or snapshot thread.
    bool primed = false, converterStarted = false, recovering = false;
    std::array<float,2> lastOutput{}, recoveryTail{};
    uint32_t fadeOutRemaining = 0, fadeInRemaining = 0;
    double ratio = 1, filteredError = 0, integral = 0;
    std::atomic<double> ppm { 0 };
    std::atomic<uint64_t> pushes { 0 }, frames { 0 }, underruns { 0 }, overflows { 0 };
    std::atomic<uint64_t> startupDiscarded { 0 };
    std::atomic<uint64_t> recoveryCount { 0 }, recoveryCompleted { 0 }, recoveryDiscarded { 0 }, recoveryOutput { 0 };
    std::atomic<uint32_t> recoveryActive { 0 }, lastRecoveryMissing { 0 };
    // Max has one writer (producer), min has one writer (consumer).
    std::atomic<uint32_t> minimum { UINT32_MAX }, maximum { 0 };
    ~Source() { if (src) src_delete(src); }
    uint32_t available() const {
        const uint64_t r = read.load(std::memory_order_relaxed);
        return uint32_t(written.load(std::memory_order_acquire) - r);
    }
};

struct Destination {
    std::unique_ptr<float[]> scratch;
    ClockTracker outputClock;
    Ramp master;
    std::atomic<uint64_t> renders { 0 }, frames { 0 };
    std::atomic<float> peak { 0 };
};
}

struct MRCore {
    MRCoreConfig config {};
    std::array<Source, 3> source;
    std::array<Destination, 2> destination;
    std::atomic<int> fault { 0 };
    std::atomic<int> clockFailureOwner { -1 };
    std::atomic<bool> clockFailureReady { false };
    MRClockFailure clockFailure {};
    std::atomic<uint32_t> primedMask { 0 };
    std::atomic<uint64_t> nonFinite { 0 }, clipped { 0 };
    std::atomic<uint64_t> masters { pairBits(1, 0) };
    uint32_t rampFrames = 240, recoveryRampFrames = 48, lookahead = 20;

    void fail(int code) {
        int expected = 0;
        fault.compare_exchange_strong(expected, code, std::memory_order_relaxed);
    }

    void failClock(uint32_t tracker, uint32_t reason, const ClockTracker &clock, MRTime current) {
        int expected = -1;
        if (clockFailureOwner.compare_exchange_strong(expected, int(tracker), std::memory_order_relaxed)) {
            // Exactly one callback writes this record. Snapshot cannot read
            // it until the release/acquire publication, and it never changes
            // afterward. No snapshot retry loop, allocation, or RT wait.
            clockFailure.valid = 1;
            clockFailure.previousValid = clock.previousValid ? 1 : 0;
            clockFailure.tracker = tracker; clockFailure.reason = reason;
            clockFailure.previousSampleTime = clock.previousSample;
            clockFailure.expectedSampleTime = clock.previousSample + clock.previousFrames;
            clockFailure.currentSampleTime = current.sampleTime;
            clockFailure.previousHostSeconds = clock.previousHost;
            clockFailure.currentHostSeconds = current.hostSeconds;
            clockFailure.previousFrames = clock.previousFrames;
            clockFailureReady.store(true, std::memory_order_release);
        }
        fail(discontinuity);
    }

    void concealPC(Source &s, float *out, uint32_t frames) {
        // A single-sample tail avoids an abrupt edge. It is not replaying the
        // failed/old PCM block, and reaches exact silence within one millisecond.
        for(uint32_t f=0;f<frames;++f) {
            const float gain=s.fadeOutRemaining ? float(--s.fadeOutRemaining)/float(recoveryRampFrames) : 0;
            out[2*f]=s.recoveryTail[0]*gain;
            out[2*f+1]=s.recoveryTail[1]*gain;
        }
        s.lastOutput={out[2*(frames-1)],out[2*(frames-1)+1]};
        s.recoveryOutput.fetch_add(frames,std::memory_order_relaxed);
    }

    bool recoverPC(Source &s, float *out, uint32_t frames, uint32_t missing, double outputRate) {
        // Only this source's consumer may change read or the SRC state. Never
        // reset written/the producer clock, nor reset the startup barrier.
        const uint64_t r=s.read.load(std::memory_order_relaxed);
        const uint64_t w=s.written.load(std::memory_order_acquire);
        s.read.store(w,std::memory_order_release);
        s.recoveryDiscarded.fetch_add(w-r,std::memory_order_relaxed);
        // Vendored Sinc reset only clears its already-allocated buffer/state.
        if(src_reset(s.src)) { fail(converterError);return false; }
        s.primed=false;s.converterStarted=false;s.recovering=true;
        s.filteredError=s.integral=0;
        s.ratio=std::clamp(outputRate/s.inputRate.load(std::memory_order_relaxed),
                          1-kMaximumPPM*1e-6,1+kMaximumPPM*1e-6);
        s.ppm.store((s.ratio-1)*1e6,std::memory_order_relaxed);
        s.recoveryTail=s.lastOutput;s.fadeOutRemaining=recoveryRampFrames;s.fadeInRemaining=0;
        s.lastRecoveryMissing.store(missing,std::memory_order_relaxed);
        s.recoveryActive.store(1,std::memory_order_relaxed);
        s.recoveryCount.fetch_add(1,std::memory_order_release);
        concealPC(s,out,frames);
        return true; // Valid PC contribution; RME input and return keep running.
    }

    bool convert(unsigned index, float *out, uint32_t frames, double outputRate) {
        auto &s = source[index];
        std::fill_n(out, size_t(frames) * 2, 0.0f);
        if (!s.channels) return true;
        // A fast producer burst must not interrupt a multi-block fade-out
        // (notably B16/B32) by jumping straight into the new signal's fade-in.
        if(s.recovering && s.fadeOutRemaining) { concealPC(s,out,frames);return true; }
        if (!s.primed) {
            // Q is the unread application FIFO reserve, EXCLUDING the
            // converter's lookahead. No target is silently increased.
            const uint32_t required = s.target + uint32_t(std::ceil(frames / 0.999)) + lookahead + 2;
            const uint32_t available = s.available();
            if (available < required) {
                if(s.recovering) { concealPC(s,out,frames);return true; }
                return false;
            }
            // Different device start calls can take different amounts of time.
            // Retain the newest priming window at startup and PC recovery.
            // Never play an old backlog and slowly chase it after a dropout.
            if (available > required) {
                const uint32_t discarded = available - required;
                const uint64_t r = s.read.load(std::memory_order_relaxed);
                s.read.store(r + discarded, std::memory_order_release);
                if(s.recovering)s.recoveryDiscarded.fetch_add(discarded,std::memory_order_relaxed);
                else s.startupDiscarded.store(discarded, std::memory_order_relaxed);
            }
            s.primed = true;
        }

        long produced = 0;
        for (unsigned call = 0; call < kMaximumProcessCalls && produced < frames; ++call) {
            SRC_DATA d {};
            d.data_out = out + produced * 2;
            d.output_frames = frames - produced;
            d.src_ratio = s.ratio;
            // Always drain converter-held future input first. Passing the
            // entire FIFO to libsamplerate would hide arbitrary queue latency
            // inside its private buffer and invalidate occupancy feedback.
            uint64_t r = s.read.load(std::memory_order_relaxed);
            if (call != 0 || !s.converterStarted) {
                uint32_t wanted = uint32_t(std::ceil(d.output_frames / s.ratio));
                if (!s.converterStarted) wanted += lookahead + 2;
                const uint32_t available = s.available();
                const uint32_t contiguous = s.capacity - (uint32_t(r) & s.mask);
                d.input_frames = std::min({wanted, available, contiguous});
                d.data_in = s.ring.get() + (uint32_t(r) & s.mask) * 2;
            }
            int error = src_process(s.src, &d);
            s.converterStarted = true;
            if (error) { fail(converterError); return false; }
            if (d.input_frames_used) s.read.store(r + uint64_t(d.input_frames_used), std::memory_order_release);
            produced += d.output_frames_gen;
            if (call && !d.input_frames_used && !d.output_frames_gen) break;
        }
        if (produced != frames) {
            s.underruns.fetch_add(1, std::memory_order_relaxed);
            s.minimum.store(0, std::memory_order_relaxed);
            if(index==1)return recoverPC(s,out,frames,uint32_t(frames-produced),outputRate);
            fail(starvation); return false;
        }
        if(s.recovering) {
            s.recovering=false;s.fadeOutRemaining=0;s.fadeInRemaining=recoveryRampFrames;
            s.recoveryActive.store(0,std::memory_order_relaxed);
            s.recoveryCompleted.fetch_add(1,std::memory_order_release);
        }
        if(index==1) {
            for(uint32_t f=0;f<frames && s.fadeInRemaining;++f) {
                const float gain=1-float(--s.fadeInRemaining)/float(recoveryRampFrames);
                out[2*f]*=gain;out[2*f+1]*=gain;
            }
            s.lastOutput={out[2*(frames-1)],out[2*(frames-1)+1]};
        }
        const uint32_t level = s.available();
        s.minimum.store(std::min(level, s.minimum.load(std::memory_order_relaxed)), std::memory_order_relaxed);
        primedMask.fetch_or(1u << index, std::memory_order_release);

        const double dt = frames / config.sampleRate;
        const double error = double(level) - s.target;
        const double alpha = dt / (0.1 + dt);
        s.filteredError += alpha * (error - s.filteredError);
        const double feedForward = (outputRate / s.inputRate.load(std::memory_order_relaxed) - 1.0) * 1e6;
        const double nextIntegral = std::clamp(s.integral + s.filteredError * dt * 0.2, -500.0, 500.0);
        const double requested = feedForward - 4.0 * s.filteredError - nextIntegral;
        // Anti-windup: integrate only if unsaturated or driving out of saturation.
        if (std::abs(requested) <= kMaximumPPM ||
            (requested > kMaximumPPM && s.filteredError > 0) ||
            (requested < -kMaximumPPM && s.filteredError < 0)) s.integral = nextIntegral;
        const double oldPPM = (s.ratio - 1.0) * 1e6;
        const double bounded = std::clamp(requested, -kMaximumPPM, kMaximumPPM);
        const double step = kSlewPPMPerSecond * dt;
        const double newPPM = std::clamp(bounded, oldPPM - step, oldPPM + step);
        s.ratio = 1.0 + newPPM * 1e-6;
        s.ppm.store(newPPM, std::memory_order_relaxed);
        return true;
    }
};

extern "C" MRCore *mr_core_create(const MRCoreConfig *config, char *error, size_t errorSize) {
    auto message = [&](const char *text) { if (error && errorSize) std::snprintf(error, errorSize, "%s", text); };
    if (!config || !std::isfinite(config->sampleRate) || config->sampleRate != 48000.0 ||
        !config->maxFrames || config->maxFrames > MR_MAX_FRAMES || config->quality < 0 || config->quality > 1 ||
        config->channels[2] != 2) {
        message("Core requires 48 kHz, maxFrames 1..4096, quality 0/1, and a two-channel return"); return nullptr;
    }
    for (unsigned i = 0; i < 3; ++i) {
        if (config->channels[i] > MR_MAX_CHANNELS || !config->fifoTarget[i] || config->fifoTarget[i] > 32768) {
            message("Channel count must be at most 64 and FIFO target 1..32768 frames"); return nullptr;
        }
    }
    try {
        std::unique_ptr<MRCore> core(new MRCore);
        core->config = *config;
        core->lookahead = config->quality == 0 ? 20 : 47;
        core->rampFrames = uint32_t(config->sampleRate * .005);
        for (unsigned i = 0; i < 3; ++i) {
            auto &s = core->source[i];
            s.channels = config->channels[i]; s.target = config->fifoTarget[i];
            s.gateLinks = i == 2 ? 1u : 0u;
            for (uint32_t c = 0; c < s.channels; ++c)
                s.channel[c].gate.configure(s.channel[c].gateCommand.load(std::memory_order_relaxed), config->sampleRate);
            // Capacity tolerates asynchronous device startup. It is NOT the
            // target latency; the consumer trims excess when priming/recovering.
            uint32_t capacity = 32768;
            while (capacity < s.target + config->maxFrames * 4 + 128) capacity *= 2;
            s.capacity = capacity; s.mask = capacity - 1;
            s.ring.reset(new float[size_t(capacity) * 2]());
            s.mix.reset(new float[size_t(config->maxFrames) * 2]());
            s.inputClock.rate = config->sampleRate;
            s.inputRate.store(config->sampleRate, std::memory_order_relaxed);
            int status = 0;
            s.src = src_new(config->quality == 0 ? SRC_SINC_FASTEST : SRC_SINC_MEDIUM_QUALITY, 2, &status);
            if (!s.src) { message(src_strerror(status)); return nullptr; }
            if (!s.channels) core->primedMask.fetch_or(1u << i, std::memory_order_relaxed);
        }
        for (auto &d : core->destination) {
            d.scratch.reset(new float[size_t(config->maxFrames) * 2]());
            d.outputClock.rate = config->sampleRate;
        }
        message(""); return core.release();
    } catch (const std::bad_alloc &) { message("Unable to allocate realtime buffers"); return nullptr; }
    catch (...) { message("Unable to initialize realtime core"); return nullptr; }
}

extern "C" void mr_core_destroy(MRCore *core) { delete core; }

extern "C" void mr_core_set_channel(MRCore *core, uint32_t source, uint32_t channel, float gainDB, float pan, int muted) {
    if (!core) return;
    if (source >= 2 || channel >= core->source[source].channels || !std::isfinite(gainDB) || !std::isfinite(pan)) {
        core->fail(badArgument); return;
    }
    pan = std::clamp(pan, -1.0f, 1.0f);
    const float gain = muted ? 0.0f : amplitude(gainDB);
    const double angle = (double(pan) + 1.0) * 0.78539816339744830962;
    const float l = pan == 1 ? 0 : gain * float(std::cos(angle));
    const float r = pan == -1 ? 0 : gain * float(std::sin(angle));
    core->source[source].channel[channel].coefficients.store(pairBits(l, r), std::memory_order_relaxed);
}

extern "C" void mr_core_set_master(MRCore *core, float forwardDB, float returnDB, int returnMuted) {
    if (!core) return;
    if (!std::isfinite(forwardDB) || !std::isfinite(returnDB)) { core->fail(badArgument); return; }
    core->masters.store(pairBits(amplitude(forwardDB), returnMuted ? 0 : amplitude(returnDB)), std::memory_order_relaxed);
}

extern "C" void mr_core_set_gate(MRCore *core, uint32_t source, uint32_t channel, const MRGateSettings *settings) {
    if (!core) return;
    if (source >= 3 || channel >= core->source[source].channels || !settings || !validGate(*settings)) {
        core->fail(badArgument); return;
    }
    core->source[source].channel[channel].gateCommand.store(gateBits(*settings), std::memory_order_relaxed);
}

extern "C" void mr_core_set_gate_link(MRCore *core, uint32_t source, uint32_t pairStart, int linked) {
    if (!core) return;
    if (source >= 3 || (pairStart & 1) || pairStart >= MR_MAX_CHANNELS - 1 ||
        pairStart + 1 >= core->source[source].channels ||
        core->source[source].pushes.load(std::memory_order_relaxed) != 0 || (linked != 0 && linked != 1)) {
        core->fail(badArgument); return;
    }
    const uint32_t mask = 1u << (pairStart / 2);
    auto &links = core->source[source].gateLinks;
    if (linked) links |= mask; else links &= ~mask;
}

extern "C" void mr_core_push(MRCore *core, uint32_t index, const MRChannelView *views, uint32_t channels, uint32_t frames, MRTime time) {
    if (!core || core->fault.load(std::memory_order_relaxed)) return;
    if (index >= 3 || !frames || frames > core->config.maxFrames || channels != core->source[index].channels || (channels && !views)) {
        core->fail(badArgument); return;
    }
    auto &s = core->source[index];
    s.pushes.fetch_add(1, std::memory_order_relaxed); s.frames.fetch_add(frames, std::memory_order_relaxed);
    if (uint32_t reason = s.inputClock.observe(time, frames, core->config.sampleRate)) { core->failClock(index, reason, s.inputClock, time); return; }
    s.inputRate.store(s.inputClock.rate, std::memory_order_relaxed);
    if (!channels) return;
    for (uint32_t c = 0; c < channels; ++c) {
        if (!views[c].data || !views[c].stride || views[c].stride > MR_MAX_CHANNELS) { core->fail(badArgument); return; }
    }
    const uint64_t w = s.written.load(std::memory_order_relaxed);
    const uint64_t r = s.read.load(std::memory_order_acquire);
    if (w - r + frames > s.capacity) { s.overflows.fetch_add(1, std::memory_order_relaxed); core->fail(overflow); return; }
    std::fill_n(s.mix.get(), size_t(frames) * 2, 0.0f);
    for (uint32_t c = 0; c < channels;) {
        const bool linked = !(c & 1) && c + 1 < channels && (s.gateLinks & (1u << (c / 2)));
        const uint32_t count = linked ? 2 : 1;
        auto &gate = s.channel[c].gate;
        gate.configure(s.channel[c].gateCommand.load(std::memory_order_relaxed), core->config.sampleRate);
        float peak[2] = {0, 0};
        for (uint32_t n = 0; n < count; ++n) {
            auto &channel = s.channel[c + n];
            float l, rr; pairValues(channel.coefficients.load(std::memory_order_relaxed), l, rr);
            channel.left.set(l, core->rampFrames); channel.right.set(rr, core->rampFrames);
        }
        for (uint32_t f = 0; f < frames; ++f) {
            float samples[2], detector = 0;
            for (uint32_t n = 0; n < count; ++n) {
                samples[n] = views[c + n].data[size_t(f) * views[c + n].stride];
                if (!std::isfinite(samples[n])) { core->nonFinite.fetch_add(1, std::memory_order_relaxed); core->fail(nonFiniteAudio); return; }
                const float magnitude = std::abs(samples[n]);
                peak[n] = std::max(peak[n], magnitude); detector = std::max(detector, magnitude);
            }
            const float gain = gate.next(detector);
            for (uint32_t n = 0; n < count; ++n) {
                auto &channel = s.channel[c + n];
                const float sample = gain == 0 ? 0 : samples[n] * gain;
                if (index == 2) s.mix[f * 2 + c + n] = sample;
                else {
                    s.mix[f * 2] += sample * channel.left.next();
                    s.mix[f * 2 + 1] += sample * channel.right.next();
                }
            }
        }
        for (uint32_t n = 0; n < count; ++n) {
            s.channel[c + n].peak.store(peak[n], std::memory_order_relaxed);
            s.channel[c + n].gateGain.store(gate.gain, std::memory_order_relaxed);
        }
        c += count;
    }
    for (uint32_t f = 0; f < frames; ++f) {
        if (!std::isfinite(s.mix[f * 2]) || !std::isfinite(s.mix[f * 2 + 1])) {
            core->nonFinite.fetch_add(1, std::memory_order_relaxed); core->fail(nonFiniteAudio); return;
        }
        const uint32_t slot = (uint32_t(w + f) & s.mask) * 2;
        s.ring[slot] = s.mix[f * 2]; s.ring[slot + 1] = s.mix[f * 2 + 1];
    }
    if (core->fault.load(std::memory_order_relaxed)) return;
    s.written.store(w + frames, std::memory_order_release);
    const uint32_t level = uint32_t(w + frames - r);
    s.maximum.store(std::max(level, s.maximum.load(std::memory_order_relaxed)), std::memory_order_relaxed);
}

extern "C" void mr_core_render(MRCore *core, uint32_t index, float *out, uint32_t frames, MRTime time) {
    if (out) std::fill_n(out, size_t(std::min(frames, uint32_t(MR_MAX_FRAMES))) * 2, 0.0f);
    if (!core) return;
    if (index >= 2 || !out || !frames || frames > core->config.maxFrames) { core->fail(badArgument); return; }
    auto &d = core->destination[index];
    d.renders.fetch_add(1, std::memory_order_relaxed); d.frames.fetch_add(frames, std::memory_order_relaxed);
    if (core->fault.load(std::memory_order_relaxed)) { d.peak.store(0, std::memory_order_relaxed); return; }
    if (uint32_t reason = d.outputClock.observe(time, frames, core->config.sampleRate)) { core->failClock(3 + index, reason, d.outputClock, time); return; }
    bool ready;
    if (index == 0) {
        ready = core->convert(0, out, frames, d.outputClock.rate);
        ready = core->convert(1, d.scratch.get(), frames, d.outputClock.rate) && ready;
        if (ready) for (size_t i = 0; i < size_t(frames) * 2; ++i) out[i] += d.scratch[i];
    } else ready = core->convert(2, out, frames, d.outputClock.rate);
    if (!ready || core->fault.load(std::memory_order_relaxed) || core->primedMask.load(std::memory_order_acquire) != 7) {
        std::fill_n(out, size_t(frames) * 2, 0.0f); d.peak.store(0, std::memory_order_relaxed); return;
    }
    float forward, backward; pairValues(core->masters.load(std::memory_order_relaxed), forward, backward);
    d.master.set(index == 0 ? forward : backward, core->rampFrames);
    uint64_t clipped = 0; float peak = 0;
    for (uint32_t f = 0; f < frames; ++f) {
        const float gain = d.master.next();
        for (unsigned c = 0; c < 2; ++c) {
            float value = out[f * 2 + c] * gain;
            if (!std::isfinite(value)) { core->nonFinite.fetch_add(1, std::memory_order_relaxed); core->fail(nonFiniteAudio); value = 0; }
            if (std::abs(value) > 1) { ++clipped; value = std::clamp(value, -1.0f, 1.0f); }
            out[f * 2 + c] = value; peak = std::max(peak, std::abs(value));
        }
    }
    core->clipped.fetch_add(clipped, std::memory_order_relaxed);
    if (core->fault.load(std::memory_order_relaxed)) { std::fill_n(out, size_t(frames) * 2, 0.0f); peak = 0; }
    d.peak.store(peak, std::memory_order_relaxed);
}

extern "C" void mr_core_snapshot(MRCore *core, MRCoreStats *out) {
    if (!out) return;
    std::memset(out, 0, sizeof(*out)); if (!core) return;
    for (unsigned i = 0; i < 3; ++i) {
        auto &s = core->source[i];
        out->pushes[i] = s.pushes.load(std::memory_order_relaxed); out->inputFrames[i] = s.frames.load(std::memory_order_relaxed);
        out->underruns[i] = s.underruns.load(std::memory_order_relaxed); out->overflows[i] = s.overflows.load(std::memory_order_relaxed);
        out->startupDiscardedFrames[i] = s.startupDiscarded.load(std::memory_order_relaxed);
        const uint64_t r = s.read.load(std::memory_order_acquire), w = s.written.load(std::memory_order_acquire);
        out->fifoFrames[i] = uint32_t(std::min(w - r, uint64_t(s.capacity)));
        uint32_t low = s.minimum.load(std::memory_order_relaxed); out->fifoMin[i] = low == UINT32_MAX ? 0 : low;
        out->fifoMax[i] = s.maximum.load(std::memory_order_relaxed); out->correctionPPM[i] = s.ppm.load(std::memory_order_relaxed);
        for (unsigned c = 0; c < s.channels; ++c) {
            out->inputPeak[i][c] = s.channel[c].peak.load(std::memory_order_relaxed);
            out->gateGain[i][c] = s.channel[c].gateGain.load(std::memory_order_relaxed);
        }
    }
    for (unsigned i = 0; i < 2; ++i) {
        auto &d = core->destination[i]; out->renders[i] = d.renders.load(std::memory_order_relaxed);
        out->outputFrames[i] = d.frames.load(std::memory_order_relaxed); out->outputPeak[i] = d.peak.load(std::memory_order_relaxed);
    }
    out->primedMask = core->primedMask.load(std::memory_order_acquire); out->fault = core->fault.load(std::memory_order_relaxed);
    out->nonFinite = core->nonFinite.load(std::memory_order_relaxed); out->clipped = core->clipped.load(std::memory_order_relaxed);
    if (core->clockFailureReady.load(std::memory_order_acquire)) out->clockFailure = core->clockFailure;
    auto &pc=core->source[1];
    out->pcRecoveryCount=pc.recoveryCount.load(std::memory_order_acquire);
    out->pcRecoveryCompleted=pc.recoveryCompleted.load(std::memory_order_acquire);
    out->pcRecoveryDiscardedFrames=pc.recoveryDiscarded.load(std::memory_order_relaxed);
    out->pcRecoveryOutputFrames=pc.recoveryOutput.load(std::memory_order_relaxed);
    out->pcRecovering=pc.recoveryActive.load(std::memory_order_relaxed);
    out->pcLastRecoveryMissingFrames=pc.lastRecoveryMissing.load(std::memory_order_relaxed);
}
