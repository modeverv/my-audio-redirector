#ifndef MR_REALTIME_CORE_H
#define MR_REALTIME_CORE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define MR_MAX_CHANNELS 64
#define MR_MAX_FRAMES 4096
// Sources: 0 RME physical inputs, 1 PC tap, 2 D4 processed stereo.
// Destinations: 0 Discrete4 Computer1/2 (sources 0+1), 1 RME return (source 2).
typedef struct MRCore MRCore;
typedef struct { const float *data; uint32_t stride; } MRChannelView;
typedef struct { double sampleTime; double hostSeconds; int valid; } MRTime;
typedef struct {
    int enabled;
    float thresholdDB;  // -96..0 dBFS, 0.1 dB resolution; opening threshold
    float attackMS;     // 0.1..50 ms, 0.1 ms resolution
    float holdMS;       // 0..1000 ms, 1 ms resolution
    float releaseMS;    // 1..2000 ms, 1 ms resolution
    float hysteresisDB; // 0..24 dB, 0.1 dB resolution; closing threshold = thresholdDB - hysteresisDB
} MRGateSettings;
typedef struct {
    uint32_t channels[3];
    uint32_t fifoTarget[3];
    uint32_t maxFrames;
    double sampleRate;
    int quality; // 0 SINC_FASTEST, 1 SINC_MEDIUM_QUALITY
} MRCoreConfig;
// Tracker identities are stable across diagnostic exports.
enum {
    MR_CLOCK_RME_INPUT = 0, MR_CLOCK_PC_INPUT = 1, MR_CLOCK_RETURN_INPUT = 2,
    MR_CLOCK_DISCRETE4_OUTPUT = 3, MR_CLOCK_RME_OUTPUT = 4
};
enum {
    MR_CLOCK_NONFINITE_TIMESTAMP = 1, MR_CLOCK_SAMPLE_TIME_GAP = 2,
    MR_CLOCK_HOST_TIME_NONINCREASING = 3
};
typedef struct {
    int valid, previousValid;
    uint32_t tracker, reason;
    double previousSampleTime, expectedSampleTime, currentSampleTime;
    double previousHostSeconds, currentHostSeconds;
    uint32_t previousFrames;
} MRClockFailure;
typedef struct {
    uint64_t pushes[3], renders[2], inputFrames[3], outputFrames[2];
    uint64_t underruns[3], overflows[3], nonFinite, clipped;
    uint64_t startupDiscardedFrames[3]; // consumer-only trim before first prime
    uint32_t fifoFrames[3], fifoMin[3], fifoMax[3];
    double correctionPPM[3];
    float inputPeak[3][MR_MAX_CHANNELS], outputPeak[2];
    float gateGain[3][MR_MAX_CHANNELS]; // latest producer block end: 0 closed, 1 open, intermediate attack/release
    uint32_t primedMask;
    int fault; // 0 none, otherwise fail silent and stop on control thread
    // First failing tracker wins; immutable until core destruction. valid=0
    // until the complete record is published. Current values can be NaN/Inf
    // for NONFINITE_TIMESTAMP; consumers must encode them safely.
    MRClockFailure clockFailure;
    // PC-only underrun recovery. Other faults still latch. These counters are
    // monotonic per core, and snapshots may span an in-flight recovery change.
    uint64_t pcRecoveryCount, pcRecoveryCompleted;
    // Explicit unread FIFO discards, excluding discarded private SRC history.
    uint64_t pcRecoveryDiscardedFrames;
    // PC output frames replaced by declick/silence, excluding the recovery fade-in.
    uint64_t pcRecoveryOutputFrames;
    uint32_t pcRecovering, pcLastRecoveryMissingFrames;
} MRCoreStats;
MRCore *mr_core_create(const MRCoreConfig *, char *error, size_t errorSize);
void mr_core_destroy(MRCore *); // only after ALL callbacks stopped
void mr_core_set_channel(MRCore *, uint32_t source, uint32_t channel, float gainDB, float pan, int muted);
void mr_core_set_master(MRCore *, float forwardDB, float returnDB, int returnMuted);
// All channels default to enabled, -60 dBFS, attack .2 ms, hold 50 ms,
// release 30 ms, hysteresis 6 dB. Gate precedes gain/pan and adds no lookahead.
// Runtime settings are one coherent lock-free command per channel. Disabling
// an already-running gate fades to unity using attack; initial bypass is exact.
void mr_core_set_gate(MRCore *, uint32_t source, uint32_t channel, const MRGateSettings *);
// Configure links BEFORE the first push for that source. pairStart is 0,2,4,...
// Linked pairs use max(abs(L),abs(R)), the first channel's settings, and a
// common gain. Sources 0/1 default unlinked; source 2 defaults linked.
void mr_core_set_gate_link(MRCore *, uint32_t source, uint32_t pairStart, int linked);
void mr_core_push(MRCore *, uint32_t source, const MRChannelView *, uint32_t channels, uint32_t frames, MRTime);
void mr_core_render(MRCore *, uint32_t destination, float *stereo, uint32_t frames, MRTime);
void mr_core_snapshot(MRCore *, MRCoreStats *);
#ifdef __cplusplus
}
#endif
#endif
