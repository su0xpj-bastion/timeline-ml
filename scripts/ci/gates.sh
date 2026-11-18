#!/bin/bash
# XCTest (one test per gate; speech gates skip without recognition permission), tml, fault matrix.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/reports
swift build -c release --product tml
.build/release/tml run --json > build/reports/gates.json || true
.build/release/tml run
swift test -c release -Xswiftc -enable-testing 2>&1 | tee build/reports/swift-test.log
python3 tools/fault_matrix.py .build/release/tml
