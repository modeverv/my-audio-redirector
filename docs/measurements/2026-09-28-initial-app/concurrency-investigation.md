# Concurrent fixture correction — 2026-09-28

The unmodified audio core was built independently with clang/clang++ `-O0 -g -fsanitize=address -fno-omit-frame-pointer`, C11/C++17, and the vendored libsamplerate sources. Shared SwiftPM `.build`, audio devices, and audio settings were not used.

## Reproduction

[concurrency-before-fix.txt](concurrency-before-fix.txt): focused execution failed on repetition 2/20, at consumer iteration 11962, fault 3 (starvation), source 0 underrun. There was no AddressSanitizer memory diagnostic. The old test used common producer/render callback counts as a proxy for all three FIFO occupancies. Concurrent first conversion discarded 41, 105, and 105 startup frames, respectively; those callback-count leads no longer described the actual independent unread FIFO levels. Subsequent scheduler phase variation plus occupancy correction could exhaust the small real reserve.

The corrected fixture is in `Tests/RealtimeCoreTests/main.cpp`. Production core code was unchanged.

## Correction and validation

The concurrent fixture now primes deterministically before starting its threads. Its simulated producer is independently paced by each source's actual unread FIFO occupancy, pushing a 64-frame block only at <=128 frames. Its simulated consumer waits until all three FIFOs contain >=128 frames before consuming one 64-frame output block. Producer, consumer, and gain/master/snapshot control execute concurrently; these waits and snapshots occur outside the realtime API. The control thread runs until the consumer completes. This explicitly tests concurrent ownership/publication, not hardware driver deadlines or arbitrary jitter tolerance. The separate deterministic clock simulations retain responsibility for rate/phase behavior.

[concurrency-debug-asan.txt](concurrency-debug-asan.txt): 20/20 focused repetitions passed, each with 12,000 render cycles (each cycle renders both destinations), no core fault, no C++ realtime allocation observed, and no AddressSanitizer diagnostic. This is not ThreadSanitizer evidence, a 24-hour run, an actual hardware/audio test, or an end-to-end latency result. The full deterministic suite was not rerun in this isolated build; root already ran the unchanged production core's full release/ASan suite and handles final integration verification.

Reproduce using `swift build --scratch-path /tmp/redirector-asan --sanitize=address --product CoreTests`, then `/tmp/redirector-asan/debug/CoreTests --concurrency-only 20`. Failure diagnostics include first-fault iteration, per-source FIFO min/max/current, underruns, overflows, startup discarded frames, and correction ppm.
