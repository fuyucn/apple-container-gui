#!/usr/bin/env bash
# Canonical test command for this repository.
#
# This machine has only the Command Line Tools (no full Xcode). Under CLT,
# SwiftPM cannot resolve the SDK platform framework path
# (`xcrun --show-sdk-platform-path` fails), so a bare `swift test` builds the
# test bundle but runs no tests. The swift-testing framework + its interop dylib
# ship inside the CLT Frameworks dir; point the compiler and the runtime loader
# at them explicitly. On a machine with full Xcode a plain `swift test` works.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
INTEROP_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

exec swift test \
	-Xswiftc -F -Xswiftc "$FRAMEWORKS" \
	-Xlinker -rpath -Xlinker "$FRAMEWORKS" \
	-Xlinker -rpath -Xlinker "$INTEROP_LIB" \
	"$@"
