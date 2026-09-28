#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product CoreTests
binary_dir="$(swift build -c release --show-bin-path)"
"$binary_dir/CoreTests"
