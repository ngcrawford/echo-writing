#!/bin/zsh
# Builds axprobe with swiftc (SwiftPM manifest linking is broken in the installed Command Line Tools).
set -e
cd "${0:A:h}"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/axprobe/main.swift -o axprobe
echo "Built $(pwd)/axprobe"
