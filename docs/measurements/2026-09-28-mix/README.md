# Offline RME-side mixing cost, Apple M4 Max

Measured 2026-09-28, Apple M4 Max / arm64, Apple clang -O3, standard floating point (no fast-math). No audio device was opened; no device settings changed; no installation. All sources are synthetic Float32 arrays.

## Reproduce

Keep `mix_bench.c` and `reproduce.py` together and run `python3 reproduce.py`. It uses installed clang, builds in a fresh temporary directory, executes the benchmark and prints its output location. `results.json` is the recorded run with metadata; `results.csv` is its complete raw numerical output. No system/library downloads are needed.

## Cases and fairness

- `premixed`: already mixed stereo gain/copy, linked gain ramp on L/R.
- `mono_to_stereo`: 2/8/16/20 mono sources, independent L/R gains per source (pan/matrix contribution), one linear gain ramp on each coefficient. Output zeroing, reading, gain, accumulation and gain-ramp arithmetic included.
- `stereo_routes`: 8/16 synthetic stereo routes, linked L/R gain ramp per route. The 16-route case uses 32 scalar synthetic source channels; this is NOT a claim about the RME's exposed channel count.
- `planar`: fixed 64-frame stride between source channels; process first B frames of each.
- `interleaved20`: frame-major 20-channel source, directly extract selected channels in the mixing loop. Premixed uses channel 0/1; mono case uses first N channels. Planar and interleaved data are identical; matching case checksums verify equivalence.
- Every case includes ramps. Premixed has one linked stereo gain; mono inputs have two independent destination coefficients; stereo routes have one linked gain per pair. This compares actual work for those features, not identical DSP semantics for all cases.
- Input buffers are filled with deterministic pseudo-random audio once, not inside timed loops. Array sizes fit a small working set and stay cache-hot. The benchmark is not a driver/cold-cache test.

## Timing and anti-optimization

4096 warmup calls, then 200 batches of 256 calls. mach_absolute_time and mach_timebase_info. Reported per-block times divide each batch time by 256. p50/p99 are percentiles of those BATCH AVERAGES, not a single real-time callback's p50/p99 or maximum. A volatile compiler memory clobber follows each call, noinline prevents body merging into the caller, a per-call varying gain bump prevents constant input/gain assumptions, and each batch's output contributes to a published checksum. Input/output arrays are preallocated; no heap work occurs in measured source routines.

Correctness check is outside the timed region: compare the output against double-precision analytical gain ramps and sums, with 2e-6 absolute tolerance. Observed maximum errors are recorded and below 5e-8. This also allows rounding from iterative Float32 ramp increments versus analytical ramp values.

## Recorded mean cost per block, microseconds

| Case | 32 frames | 64 frames |
| --- | ---: | ---: |
| Premixed stereo, planar | 0.0351 | 0.0467 |
| Premixed stereo, interleaved20 | 0.0327 | 0.0460 |
| 2 mono to stereo, planar | 0.1051 | 0.1279 |
| 8 mono to stereo, planar | 0.2303 | 0.4362 |
| 16 mono to stereo, planar | 0.3799 | 0.8475 |
| 20 mono to stereo, planar | 0.4709 | 1.0539 |
| 20 mono to stereo, interleaved20 | 0.4717 | 1.0567 |
| 8 stereo routes, planar | 0.1993 | 0.4266 |
| 16 stereo routes, planar | 0.3850 | 0.8288 |

64 frames at 48 kHz means 750 callbacks/s and 1333.333 microseconds per callback period. The 20-mono planar mean minus premixed-planar mean is 1.007222493 microseconds/block: about 0.07554% of one core's time at that callback frequency. This is a rough ordinary offline CPU demand comparison, not a real-time scheduling reservation/guarantee. These low numbers are plausible for small hot arrays; exact ordering of close cases should not be overinterpreted.

The 20-mono planar batch-amortized p50/p99 are 1.0498/1.1769 microseconds/block. Premixed planar are 0.0467/0.0470. Values are not single-block tail statistics.

## Operation and bandwidth scale

Counting a multiply and an add as separate FLOPs (even if compiled as an FMA): each mono-to-stereo sample performs 2 multiplies + 2 accumulation adds + 2 ramp increments = approximately 6 operations/source/frame. At N=20 and 48 kHz this is 5.76 million scalar FLOPs/s, plus small per-block setup/zeroing. 8 and 16 stereo routes use about 5 operations/route/frame = 1.92 and 3.84 million FLOPs/s respectively. Premixed linked-stereo gain is about 0.144 million FLOPs/s. Source read scale for 20 Float32 channels at 48 kHz is 3.84 MB/s, not counting repeated output accumulation traffic or driver behavior.

## Interpretation and limits

If all inputs and playback loopbacks come from the SAME RME clock, they can be mixed inside its existing callback into stereo BEFORE the existing stereo ASRC. This adds no algorithmic lookahead and need not add another block queue. It adds computation inside the callback; full execution still must fit the real deadline. There is no need to run one ASRC per source in that topology. The independent RME-to-Discrete4 clock crossing and its ASRC/FIFO requirements remain.

Do not call these numbers real RME/Discrete4 latency or stability measurements. They omit Core Audio driver/channel acquisition, FIFO operations, ASRC, UI, device DSP, device transport and hostile background load. Input-channel availability and preservation of physical inputs when TotalMix loopback occupies corresponding host recording channels must be validated separately. Software gain/mix is comparable as linear mixing only; it does not automatically reproduce any TotalMix EQ/dynamics/FX or different routing/monitor settings.
