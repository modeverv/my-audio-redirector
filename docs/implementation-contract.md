# Implementation interface contract

Initial native app implementation, 2026-09-28. Public C headers are authoritative.

Native start/probe_start return 0 on success and nonzero on failure, with error text. Channel setters use source 0 for RME and 1 for PC. Source 2 is the fixed stereo D4 return controlled by the return master.

## Configuration JSON

All channel numbers in persisted configuration are **1-based**, C gain setters use **0-based** channel indexes.

```
{
  "schemaVersion": 1,
  "rmeUID": "...", "d4UID": "...", "pcUID": "...", "pcStreamIndex": 0,
  "bufferFrames": 64, "rmeFifoFrames": 64, "pcFifoFrames": 64, "returnFifoFrames": 64,
  "srcQuality": "fastest",
  "rmeReturnLeft": 11, "rmeReturnRight": 12,
  "d4ReturnLeft": 1, "d4ReturnRight": 2,
  "forwardGainDB": 0, "returnGainDB": 0, "returnMuted": true,
  "tapMuteOriginal": false,
  "rmeChannels": [{"channel": 1, "gainDB": 0, "pan": -1, "muted": true}],
  "pcChannels": [{"channel": 1, "gainDB": 0, "pan": -1, "muted": true}]
}
```

Absent source channel settings remain muted. UI initializes adjacent stereo pairs with hard L/R pan, gain 0, muted; explicit stereo link in UI copies gain/mute to the paired channel while preserving L/R pans. No source is silently unmuted. Return muted default. UID selections are explicit; suggested device names can preselect on first run only, without starting audio. Start requests device buffer sizes, requires all relevant stream rates 48 kHz, never changes system default output or hardware clock source/TotalMix/D4 routing. Device shared property changes are tracked and conditionally restored when still owned. Structural changes only OFF.

## Inventory JSON

```
{"devices":[{"id":42,"uid":"...","name":"...","sampleRate":48000,"bufferFrames":64,
 "inputChannels":20,"outputChannels":20,"alive":true,"transport":"...",
 "inputNames":["Mic 1"],"outputNames":["Analog 1"],
 "outputStreams":[{"index":0,"id":43,"startingChannel":1,"channels":20,"sampleRate":48000,"format":"Float32"}]}],
 "defaultOutputUID":"...", "systemOutputUID":"...", "error":null}
```

Missing optional properties use null/absence, never fake zero. Capture starts only on explicit GUI action or CLI probe. No tap created during inventory.

## Engine status JSON

```
{"state":"off|starting|priming|running|probe|fault","error":null,
 "rmeBufferFrames":64,"d4BufferFrames":64,"pcBufferFrames":64,
 "pcChannels":20,"tapUID":"...","aggregateUID":"...",
 "sources":[{"name":"RME|PC|Return","callbacks":0,"frames":0,"fifoFrames":0,"fifoMin":0,"fifoMax":0,"underruns":0,"overflows":0,"ppm":0,"peaks":[]}],
 "outputPeaks":[0,0],"clipped":0,"nonFinite":0,"fault":0,
 "probeCallbacks":0,"probeFrames":0,"probePeaks":[],"probeFormat":null}
```

UI status parser should tolerate additional/missing fields. State must not claim running before all required paths primed. Probe is capture-only, not routing. Poll serial queue every 200ms, no API calls from callbacks except DSP core/atomic stats. Bridge owns safe start/stop and tracks device disappearance, format/rate/buffer changes, callback heartbeat. Core handles bounded SPSC/stereo ASRC/gain ramps; any hard fault silences every output immediately and is stopped by control poll. No auto fallback.

Status also includes `tapActive`, `aggregateActive` (owned HAL resource IDs remain nonzero), `unsafeTeardown`, and `teardownDiagnostic`. UID strings remain as diagnostic history after stop and do not indicate resource liveness. Stop is successful only when state is off, active resources are false, and unsafeTeardown is false.

Property notifications use a dedicated serial dispatch queue and listener blocks retaining only run-specific atomic signals, never the engine pointer. RT callbacks read the fault signal directly without waiting for that queue or UI polling. Each start gets fresh signals, so delayed notifications cannot access a destroyed engine or fault a later run. Failed listener removal retains the registration and reports unsafe teardown; successful removal does not need to drain queued blocks to preserve engine lifetime.

Startup registers and configures all resources first, then starts RME, Discrete4, and Tap in that order. Callbacks remain unarmed until all starts return success; unarmed callbacks zero output and record heartbeat/trace without feeding or rendering the core. This avoids startup Tap sample-time resets observed when the underlying RME starts. Normal stop fades before disarming; fault stop disarms immediately. Runtime timestamp discontinuities remain fatal. The first 512 callback timestamps per I/O are captured in fixed storage and emitted only in fault diagnostics as `timestampTrace`.

Inventory includes `bufferFrameMin`/`bufferFrameMax` (null when unavailable). Runtime `ioTiming` holds per-I/O armed callback counts, maximum callback interval and processing time in microseconds, and actual input/output frame minima/maxima. The first armed callback is excluded from interval estimation. Values persist through stop for inspection.

FIFO targets are post-render mean occupancy targets, not guaranteed minimum reserves. Initial drift estimation uses sampleTime/hostTime intervals of at least 0.25 s with exponential smoothing plus bounded occupancy PI correction. This fixed-cost calculation runs in its owning C++ callback; it is an initial implementation, rather than the longer-window non-RT estimator proposed in the design. Ratios are bounded and slew-limited; no steady frame skipping is used.

## PC FIFO underrun recovery

PC source 1 underrun is recoverable. The destination consumer discards the incomplete PC output block, drops the currently published unread PC FIFO, resets only its Sinc converter and occupancy controller, then primes again at the configured FIFO target. Excess queued input at re-prime is trimmed to the newest required window. The producer's write index, channel/Gate state and clock tracker are not reset. An in-flight unpublished producer block may arrive after the discard boundary.

The PC contribution fades from its last output sample to exact zero in 48 frames (1 ms), remains silent during re-prime, and fades in over 48 frames after successful full-block conversion. The other forward input and the return continue rendering. The startup `primedMask` remains sticky after successful initial priming, while a separate PC recovery state reports re-prime progress. Initial startup still waits for all paths. No FIFO target is increased or persisted automatically.

`MRCoreStats` records one `pcRecoveryCount`/PC `underruns` increment per shortage episode, `pcRecoveryCompleted` on successful re-prime, `pcRecoveryDiscardedFrames` for explicitly discarded unread FIFO input (not private SRC history), and `pcRecoveryOutputFrames` for output replaced by fade-out/silence (not the fade-in). `pcRecovering` is the current state; `pcLastRecoveryMissingFrames` records the output deficit that triggered the latest episode. These are atomic counters rather than a transactional snapshot. Recovery does not set `fault` or stop the engine.

The same six fields are exported at the top level of the engine status. `eventLog` reports `path`, `error`, `pendingRecords`, `writtenRecords`, `droppedRecords`, `writeFailures` and `lastRecordReadbackVerified`. Logging is dispatched from the control thread to a bounded utility queue, never from the audio callback. PC recovery summaries aggregate counter deltas at most once per second, with a final summary at stop. `~/Library/Logs/My Redirector/events.jsonl` holds one JSON event per line, with three rotated files `events.1.jsonl` through `events.3.jsonl`, each capped at 2 MiB. Log failures remain visible in status but do not fault the audio engine; readback verification is not a power-loss durability guarantee.

Non-finite audio, converter errors, overflow, timestamp discontinuity, device/format changes and callback timeouts retain their existing fault behavior. RME-input/Return starvation also remains fatal. Runtime diagnostics and validation must distinguish continuing after concealed audio loss from a run with no lost audio.
