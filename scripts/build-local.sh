#!/bin/sh
# Build `tml` with plain swiftc (Command Line Tools only). With Xcode: swift build.
# The Info.plist is embedded so macOS can show the speech-recognition permission dialog for a CLI.
set -e
cd "$(dirname "$0")/.."
B=${BUILD_DIR:-.build/local}
mkdir -p "$B"
swiftc -O -parse-as-library -emit-library -static -module-name TimelineML -emit-module-path "$B/TimelineML.swiftmodule" \
  -o "$B/libTimelineML.a" Sources/TimelineML/*.swift
swiftc -O -I "$B" -L "$B" -lTimelineML -o "$B/tml" Sources/tml/main.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/tml/Info.plist
