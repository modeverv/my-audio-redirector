#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The harness includes Bridge.mm to exercise its internal aggregation without
# opening any audio device. Link the same Core/Samplerate objects as the app.
swift build -c release --target RealtimeCore
event_log_bin_dir="$(swift build -c release --show-bin-path)"
event_log_test_dir=".build/pc-fifo-recovery"
mkdir -p "$event_log_test_dir"
xcrun clang++ -std=c++17 -fobjc-arc -O1 \
  -I Sources/RedirectorBridge/include -I Sources/RealtimeCore/include \
  Tests/EventLogTests/main.mm \
  "$event_log_bin_dir/RealtimeCore.build/RealtimeCore.cpp.o" \
  "$event_log_bin_dir/CSamplerate.build/samplerate.c.o" \
  "$event_log_bin_dir/CSamplerate.build/src_linear.c.o" \
  "$event_log_bin_dir/CSamplerate.build/src_sinc.c.o" \
  "$event_log_bin_dir/CSamplerate.build/src_zoh.c.o" \
  -framework Foundation -framework CoreAudio \
  -o "$event_log_test_dir/EventLogTests"
"$event_log_test_dir/EventLogTests" | tee "$event_log_test_dir/event-log-tests.txt"
