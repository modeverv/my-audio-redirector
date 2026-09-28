# libsamplerate 0.2.2 offline availability and CPU measurement

No audio device was opened. No audio setting was changed. Temporary static build only; nothing installed system-wide.

## Reproduce

Keep `bench.c` and `reproduce.py` together. Run `python3 reproduce.py`. This downloads official libsamplerate tag 0.2.2 to a fresh temporary directory, builds with existing CMake/clang, and runs the offline benchmark. No pip/Homebrew/system installation. `results.csv` contains a version line and separately headed `delay`, `required`, and `cpu` record families. `results.json` is this recorded run with metadata. A repeat run will have different CPU times.

## Method

- Float32 interleaved stereo; `end_of_input=0` for every call, preserving SRC state throughout each stream. No flushing or future data masquerading as EOF.
- Delay sweep: fresh state per quality/ratio/block case; feed 8192 input frames in blocks of 1, 32 or 64; output capacity 2048 frames so all currently available output is drained. Assert every input block was consumed.
- Ratios: output/input = 0.9999, 1.0000, 1.0001. Use 48000 Hz only to convert source-frame counts to ms.
- Impulse at zero-based source index 1024. Record both output-array peak index and cumulative input arrival when that peak became available. Available source sample index is cumulative input count minus one.
- `steady_input_minus_output_over_ratio` records the input-equivalent production deficit after input frame 2048. It includes the SRC's intrinsic future-input requirement; it is not an app ring buffer.
- `required` sweep independently feeds one input frame at a time until the first target 32 or 64 output frames exist. This determines startup demand without arrival-block rounding.
- CPU: ordinary thread, 3000 warmup calls then 20000 measured calls. Each call permits input B+2 and requests B output; ratio = 1 + 0.0001*sin(k*0.003). Preallocated input/output. Timer = mach_absolute_time/mach_timebase_info around src_process and error checking. No short calls occurred in measured iterations. CPU phase deliberately keeps enough input available and does not model hardware input pacing.

## Recorded conclusions at ratio 1

| Mode | First output after cumulative input | Steady deficit / online impulse availability delay | At 48 kHz | Input required for first 64 output frames |
|---|---:|---:|---:|---:|
| Fastest | 21 frames | 20 frames | 0.416667 ms | 84 frames |
| Medium | 48 frames | 47 frames | 0.979167 ms | 111 frames |
| Best | 145 frames | 144 frames | 3.000000 ms | 208 frames |

The first output index is zero. Thus requiring 21 supplied frames means waiting until input index 20, i.e. 20 sample intervals of future input, not 21 intervals. At +/-100 ppm the exact sub-frame phase changes by about one input frame; use the CSV rather than claiming an exact constant integer delay at every phase.

The impulse output-array peak index remains 1024 at unity ratio. This does NOT mean zero online latency: libsamplerate aligns its output indices, but cannot produce those values before enough future input arrives. The online availability metric is the relevant measurement here. Avoid calling the unchanged peak-array index the real-time group delay.

With 64-frame input chunks, the first call emits only 44 frames Fastest or 17 Medium at unity. A full first 64-frame output block requires a second input callback in this simplified start-at-zero block-arrival experiment. With 32-frame input chunks, the first 32 outputs require 64 cumulative input frames Fastest or 96 Medium. These startup/block-rounding numbers are not steady end-to-end delay. Output callback phase, pre-roll, driver safety offsets, app FIFO target, and device DSP remain separate.

A 64-frame HAL buffer at 48 kHz is 1.333333 ms. It can coexist with either Fastest or Medium SRC. An all-inclusive 64-frame round-trip target is different: two unity-rate Medium SRC passes already require 94 frames (1.958333 ms) of future input in this serial path. Two Fastest passes require 40 frames (0.833333 ms) before all other terms.

If a design budgets `Q + L_SRC`, define Q as app queue delay EXCLUDING SRC-internal lookahead. If Q already means total pipeline stored audio, adding lookahead again double counts it.

## Limits

This is an offline implementation measurement, not an actual RME/Discrete4 driver, DSP, Core Audio callback, ASRC-controller, or end-to-end benchmark. It does not prove a realtime maximum execution time, lack of all heap allocations, immunity from overload, or eight-hour stability. Runtime timing is one short observation under ordinary OS scheduling. End-to-end latency needs actual independent-device callbacks and a measured physical/host signal route.

## Primary source

- [Official tag 0.2.2](https://github.com/libsndfile/libsamplerate/tree/0.2.2)
- [Sinc implementation](https://github.com/libsndfile/libsamplerate/blob/0.2.2/src/src_sinc.c)
- [Full API](https://libsndfile.github.io/libsamplerate/api_full.html)
