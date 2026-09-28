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
    uint32_t channels[3];
    uint32_t fifoTarget[3];
    uint32_t maxFrames;
    double sampleRate;
    int quality; // 0 SINC_FASTEST, 1 SINC_MEDIUM_QUALITY
} MRCoreConfig;
typedef struct {
    uint64_t pushes[3], renders[2], inputFrames[3], outputFrames[2];
    uint64_t underruns[3], overflows[3], nonFinite, clipped;
    uint64_t startupDiscardedFrames[3]; // consumer-only trim before first prime, never during running
    uint32_t fifoFrames[3], fifoMin[3], fifoMax[3];
    double correctionPPM[3];
    float inputPeak[3][MR_MAX_CHANNELS], outputPeak[2];
    uint32_t primedMask;
    int fault; // 0 none, otherwise fail silent and stop on control thread
} MRCoreStats;
MRCore *mr_core_create(const MRCoreConfig *, char *error, size_t errorSize);
void mr_core_destroy(MRCore *); // only after ALL callbacks stopped
void mr_core_set_channel(MRCore *, uint32_t source, uint32_t channel, float gainDB, float pan, int muted);
void mr_core_set_master(MRCore *, float forwardDB, float returnDB, int returnMuted);
void mr_core_push(MRCore *, uint32_t source, const MRChannelView *, uint32_t channels, uint32_t frames, MRTime);
void mr_core_render(MRCore *, uint32_t destination, float *stereo, uint32_t frames, MRTime);
void mr_core_snapshot(MRCore *, MRCoreStats *);
#ifdef __cplusplus
}
#endif
#endif
