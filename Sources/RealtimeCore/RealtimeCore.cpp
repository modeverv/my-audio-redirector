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

uint64_t pairBits(float l, float r) {
    uint32_t a, b; std::memcpy(&a, &l, 4); std::memcpy(&b, &r, 4);
    return uint64_t(a) | (uint64_t(b) << 32);
}
void pairValues(uint64_t bits, float &l, float &r) {
    uint32_t a = uint32_t(bits), b = uint32_t(bits >> 32);
    std::memcpy(&l, &a, 4); std::memcpy(&r, &b, 4);
}
float amplitude(float db) { return std::pow(10.0f, std::clamp(db, -144.0f, 24.0f) / 20.0f); }

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
    bool observe(MRTime t, uint32_t frames, double nominal) {
        if (!t.valid) { previousValid = false; return true; }
        if (!std::isfinite(t.sampleTime) || !std::isfinite(t.hostSeconds)) return false;
        if (previousValid) {
            if (std::abs(t.sampleTime - previousSample - previousFrames) > 0.5 ||
                t.hostSeconds <= previousHost) return false;
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
        return true;
    }
};

struct Channel {
    std::atomic<uint64_t> coefficients { pairBits(0, 0) };
    Ramp left, right;
    std::atomic<float> peak { 0 };
};

struct Source {
    uint32_t channels = 0, target = 0, capacity = 0, mask = 0;
    std::unique_ptr<float[]> ring, mix;
    alignas(64) std::atomic<uint64_t> written { 0 };
    alignas(64) std::atomic<uint64_t> read { 0 };
    std::array<Channel, MR_MAX_CHANNELS> channel;
    SRC_STATE *src = nullptr;
    ClockTracker inputClock;
    std::atomic<double> inputRate { 48000 };
    // Consumer-only state, never touched by the producer or snapshot thread.
    bool primed = false, converterStarted = false;
    double ratio = 1, filteredError = 0, integral = 0;
    std::atomic<double> ppm { 0 };
    std::atomic<uint64_t> pushes { 0 }, frames { 0 }, underruns { 0 }, overflows { 0 };
    std::atomic<uint64_t> startupDiscarded { 0 };
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
    std::atomic<uint32_t> primedMask { 0 };
    std::atomic<uint64_t> nonFinite { 0 }, clipped { 0 };
    std::atomic<uint64_t> masters { pairBits(1, 0) };
    uint32_t rampFrames = 240, lookahead = 20;

    void fail(int code) {
        int expected = 0;
        fault.compare_exchange_strong(expected, code, std::memory_order_relaxed);
    }

    bool convert(unsigned index, float *out, uint32_t frames, double outputRate) {
        auto &s = source[index];
        std::fill_n(out, size_t(frames) * 2, 0.0f);
        if (!s.channels) return true;
        if (!s.primed) {
            // Q is the unread application FIFO reserve, EXCLUDING the
            // converter's lookahead. No target is silently increased.
            const uint32_t required = s.target + uint32_t(std::ceil(frames / 0.999)) + lookahead + 2;
            const uint32_t available = s.available();
            if (available < required) return false;
            // Different device start calls can take different amounts of time.
            // Before the FIRST output only, retain the most recent priming
            // window. Never play an old startup backlog and slowly chase it.
            if (available > required) {
                const uint32_t discarded = available - required;
                const uint64_t r = s.read.load(std::memory_order_relaxed);
                s.read.store(r + discarded, std::memory_order_release);
                s.startupDiscarded.store(discarded, std::memory_order_relaxed);
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
            fail(starvation); return false;
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
            // Capacity tolerates asynchronous device startup. It is NOT the
            // target latency; the consumer trims excess once when priming.
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

extern "C" void mr_core_push(MRCore *core, uint32_t index, const MRChannelView *views, uint32_t channels, uint32_t frames, MRTime time) {
    if (!core || core->fault.load(std::memory_order_relaxed)) return;
    if (index >= 3 || !frames || frames > core->config.maxFrames || channels != core->source[index].channels || (channels && !views)) {
        core->fail(badArgument); return;
    }
    auto &s = core->source[index];
    s.pushes.fetch_add(1, std::memory_order_relaxed); s.frames.fetch_add(frames, std::memory_order_relaxed);
    if (!s.inputClock.observe(time, frames, core->config.sampleRate)) { core->fail(discontinuity); return; }
    s.inputRate.store(s.inputClock.rate, std::memory_order_relaxed);
    if (!channels) return;
    for (uint32_t c = 0; c < channels; ++c) {
        if (!views[c].data || !views[c].stride || views[c].stride > MR_MAX_CHANNELS) { core->fail(badArgument); return; }
    }
    const uint64_t w = s.written.load(std::memory_order_relaxed);
    const uint64_t r = s.read.load(std::memory_order_acquire);
    if (w - r + frames > s.capacity) { s.overflows.fetch_add(1, std::memory_order_relaxed); core->fail(overflow); return; }
    std::fill_n(s.mix.get(), size_t(frames) * 2, 0.0f);
    for (uint32_t c = 0; c < channels; ++c) {
        auto &channel = s.channel[c]; float peak = 0;
        float l, rr; pairValues(channel.coefficients.load(std::memory_order_relaxed), l, rr);
        channel.left.set(l, core->rampFrames); channel.right.set(rr, core->rampFrames);
        for (uint32_t f = 0; f < frames; ++f) {
            const float sample = views[c].data[size_t(f) * views[c].stride];
            if (!std::isfinite(sample)) { core->nonFinite.fetch_add(1, std::memory_order_relaxed); core->fail(nonFiniteAudio); return; }
            peak = std::max(peak, std::abs(sample));
            if (index == 2) s.mix[f * 2 + c] = sample;
            else {
                s.mix[f * 2] += sample * channel.left.next();
                s.mix[f * 2 + 1] += sample * channel.right.next();
            }
        }
        channel.peak.store(peak, std::memory_order_relaxed);
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
    if (!d.outputClock.observe(time, frames, core->config.sampleRate)) { core->fail(discontinuity); return; }
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
        for (unsigned c = 0; c < s.channels; ++c) out->inputPeak[i][c] = s.channel[c].peak.load(std::memory_order_relaxed);
    }
    for (unsigned i = 0; i < 2; ++i) {
        auto &d = core->destination[i]; out->renders[i] = d.renders.load(std::memory_order_relaxed);
        out->outputFrames[i] = d.frames.load(std::memory_order_relaxed); out->outputPeak[i] = d.peak.load(std::memory_order_relaxed);
    }
    out->primedMask = core->primedMask.load(std::memory_order_acquire); out->fault = core->fault.load(std::memory_order_relaxed);
    out->nonFinite = core->nonFinite.load(std::memory_order_relaxed); out->clipped = core->clipped.load(std::memory_order_relaxed);
}
