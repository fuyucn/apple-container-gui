#!/bin/bash
# Run the swift-testing test suite under Command Line Tools (no Xcode).
#
# Why this exists: under a plain Command Line Tools install (no full Xcode),
# `swift test` builds and links the test bundle but the bundled
# swiftpm-testing-helper does NOT execute swift-testing (`import Testing`)
# tests — it only knows the legacy XCTest path. `swift test` therefore exits 0
# without running a single `@Test`, which silently hides failures.
#
# This script builds the test bundle, then drives the swift-testing ABI
# directly: a tiny generated runner dlopen()s the freshly built test bundle so
# its @Test records register in-process, then calls the public-but-underscored
# `Testing.__swiftPMEntryPoint(passing:)`, which discovers and runs every test
# and returns a nonzero exit code on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SWIFT=/Library/Developer/CommandLineTools/usr/bin/swift
SWIFTC=/Library/Developer/CommandLineTools/usr/bin/swiftc
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
ILIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

ARCH="$(uname -m)"
DEBUG_DIR=".build/${ARCH}-apple-macosx/debug"
BUNDLE="${REPO_ROOT}/${DEBUG_DIR}/AppleContainerGUIPackageTests.xctest/Contents/MacOS/AppleContainerGUIPackageTests"

echo "==> Building test bundle"
"$SWIFT" build --build-tests

RUNNER_SRC="$(mktemp -t swttest_runner.XXXXXX).swift"
RUNNER_BIN="$(mktemp -t swttest_runner.XXXXXX)"
trap 'rm -f "$RUNNER_SRC" "$RUNNER_BIN"' EXIT

cat > "$RUNNER_SRC" <<SWIFT
import Testing
import Foundation

@main struct Runner {
    static func main() async {
        let bundle = "${BUNDLE}"
        guard dlopen(bundle, RTLD_NOW | RTLD_GLOBAL) != nil else {
            FileHandle.standardError.write("dlopen failed: \(String(cString: dlerror()))\n".data(using: .utf8)!)
            exit(2)
        }
        let code: Int32 = await __swiftPMEntryPoint(passing: nil as __CommandLineArguments_v0?)
        exit(code)
    }
}
SWIFT

echo "==> Compiling swift-testing runner"
"$SWIFTC" "$RUNNER_SRC" -o "$RUNNER_BIN" \
    -parse-as-library -sdk "$SDK" -F "$FW" -framework Testing \
    -Xlinker -rpath -Xlinker "$FW"

echo "==> Running tests"
DYLD_FRAMEWORK_PATH="$FW" DYLD_LIBRARY_PATH="$ILIB" "$RUNNER_BIN" "$@"
