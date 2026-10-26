#!/bin/zsh
# Builds EchoEngine and runs its Swift Testing suite with swiftc directly, because SwiftPM is broken in the
# installed Command Line Tools and Xcode's toolchain needs its license accepted. Once `swift test` works,
# Package.swift does the same job.
#
#   ./test.sh                      run all tests
#   ./test.sh --filter Watch       run matching tests
#   ECHO_BENCH_TEXT=novel.txt ./test.sh --filter Performance
set -e
cd "${0:A:h}"
CLT=/Library/Developer/CommandLineTools
FW=$CLT/Library/Developer/Frameworks
LIB=$CLT/Library/Developer/usr/lib
PLUGINS=$CLT/usr/lib/swift/host/plugins/testing
mkdir -p .build/swiftc

swiftc -O -enable-testing -swift-version 6 -target arm64-apple-macosx14.0 -parse-as-library \
    -module-name EchoEngine -emit-module -emit-module-path .build/swiftc/EchoEngine.swiftmodule \
    -emit-library -static -o .build/swiftc/libEchoEngine.a Sources/EchoEngine/*.swift

print 'import Testing\nawait Testing.__swiftPMEntryPoint() as Never' > .build/swiftc/main.swift
swiftc -O -swift-version 6 -target arm64-apple-macosx14.0 -module-name EchoEngineTests \
    -plugin-path $PLUGINS -I .build/swiftc -L .build/swiftc -lEchoEngine \
    -F $FW -Xlinker -rpath -Xlinker $FW -L $LIB -Xlinker -rpath -Xlinker $LIB \
    Tests/EchoEngineTests/*.swift .build/swiftc/main.swift -o .build/swiftc/EchoEngineTests

.build/swiftc/EchoEngineTests "$@"
