#!/usr/bin/env bash
# Build the AppMain executable in release configuration and assemble it into a
# macOS .app bundle, then ad-hoc codesign it.
#
# A SwiftUI @main executable will not reliably show its window without a real
# bundle (Info.plist with CFBundlePackageType=APPL, NSPrincipalClass=NSApplication)
# plus the .regular activation policy set at launch (see
# Sources/AppMain/AppMainApp.swift).
#
# --- WHY NO APP SANDBOX -------------------------------------------------------
# This app is INTENTIONALLY unsandboxed. It is a GUI front-end that shells out to
# Apple's `container` CLI (/opt/homebrew/opt/container/bin/container) via Process
# in Core/CLI, streams logs/builds, and can run an interactive PTY terminal. The
# App Sandbox (com.apple.security.app-sandbox) forbids arbitrary Process exec of
# binaries outside the bundle and would break every Core operation. Per the
# project's Global Constraints, distribution is unsandboxed Developer-ID +
# notarized (see scripts/notarize.sh) -- NOT Mac App Store. We therefore attach
# NO entitlements file here and never add the app-sandbox entitlement.
#
# --- SIGNING ------------------------------------------------------------------
# This environment has 0 Developer ID identities (security find-identity -p
# codesigning => "0 valid identities found"). We therefore AD-HOC sign ("-")
# which is enough for local launch. For real distribution use scripts/notarize.sh
# on a machine with a paid Apple Developer account.
set -euo pipefail

# Resolve the repository root from this script's location so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="AppleContainerGUI"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
EXECUTABLE="AppMain"

# Version metadata: overridable from the environment (e.g. CI) but defaults to
# the values baked into Resources/Info.plist when unset.
SHORT_VERSION="${SHORT_VERSION:-}"   # CFBundleShortVersionString (marketing, e.g. 0.1.0)
BUILD_VERSION="${BUILD_VERSION:-}"   # CFBundleVersion (monotonic build number)

# Signing identity: defaults to ad-hoc ("-"). Override with a Developer ID
# Application identity to produce a distributable build (still needs notarize.sh).
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

PLIST_BUDDY="/usr/libexec/PlistBuddy"

echo "==> Building release binary"
swift build -c release --product "$EXECUTABLE"

BIN_DIR="$(swift build -c release --product "$EXECUTABLE" --show-bin-path)"
BIN_PATH="$BIN_DIR/$EXECUTABLE"
if [[ ! -x "$BIN_PATH" ]]; then
	echo "error: built binary not found at $BIN_PATH" >&2
	exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy SwiftPM-generated resource bundles into the standard, codesign-able
# location Contents/Resources/.
#
# The only such bundle today is SwiftTerm_SwiftTerm.bundle, a FLAT bundle that
# carries just Shaders.metal for SwiftTerm's *Metal* renderer (MetalTerminalView).
# Our terminal UI uses LocalProcessTerminalView (the AppKit/CoreText renderer),
# which never touches Metal or Bundle.module -- so this resource is not accessed
# at runtime. We still ship it for completeness/future-proofing.
#
# Placement caveat (intentional): SwiftPM's generated Bundle.module accessor looks
# for the bundle at Bundle.main.bundleURL/SwiftTerm_SwiftTerm.bundle, i.e. the .app
# ROOT. We cannot put it there: unsigned/loose files at the .app root make codesign
# fail with "unsealed contents present in the bundle root", and putting the flat
# .bundle under Contents/MacOS makes codesign reject it as a malformed nested
# bundle. Contents/Resources/ is the only location that signs + verifies cleanly,
# and since Bundle.module is never accessed in our usage, the app-root lookup miss
# is harmless. If a future feature uses SwiftTerm's Metal renderer, revisit this.
shopt -s nullglob
RESOURCE_BUNDLES=("$BIN_DIR"/*.bundle)
shopt -u nullglob
if [[ ${#RESOURCE_BUNDLES[@]} -gt 0 ]]; then
	for b in "${RESOURCE_BUNDLES[@]}"; do
		echo "==> Copying resource bundle $(basename "$b") -> Contents/Resources/"
		cp -R "$b" "$APP_DIR/Contents/Resources/"
	done
else
	echo "==> No SwiftPM resource bundles to copy"
fi

# If a non-system dynamic library is linked (none today; SwiftTerm links
# statically), copy it next to the executable so the bundle is self-contained.
shopt -s nullglob
DYLIBS=("$BIN_DIR"/*.dylib)
shopt -u nullglob
if [[ ${#DYLIBS[@]} -gt 0 ]]; then
	for d in "${DYLIBS[@]}"; do
		echo "==> Copying dylib $(basename "$d")"
		cp "$d" "$APP_DIR/Contents/MacOS/"
	done
fi

# Optional app icon: if Resources/AppIcon.icns exists, install it and register it
# in Info.plist. Otherwise the app uses the default executable icon.
# TODO(icon): ship a designed AppIcon.icns. Generate a placeholder with
#   scripts/make-icon.sh (produces Resources/AppIcon.icns).
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
	echo "==> Installing app icon"
	cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
	"$PLIST_BUDDY" -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
		|| "$PLIST_BUDDY" -c "Set :CFBundleIconFile AppIcon" "$APP_DIR/Contents/Info.plist"
else
	echo "==> No Resources/AppIcon.icns (using default icon) -- run scripts/make-icon.sh to add one"
fi

# Apply optional version overrides to the bundled Info.plist.
if [[ -n "$SHORT_VERSION" ]]; then
	echo "==> Setting CFBundleShortVersionString=$SHORT_VERSION"
	"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "$BUILD_VERSION" ]]; then
	echo "==> Setting CFBundleVersion=$BUILD_VERSION"
	"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_DIR/Contents/Info.plist"
fi

# --- Codesign -----------------------------------------------------------------
# Ad-hoc by default. No --entitlements: this app is intentionally unsandboxed
# (see header). codesign --deep signs nested code (the resource bundle) too.
echo "==> Codesigning ($([[ "$SIGN_IDENTITY" == "-" ]] && echo ad-hoc || echo "$SIGN_IDENTITY"))"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
	codesign --force --deep --sign - "$APP_DIR"
else
	# Developer ID path: hardened runtime + secure timestamp are required for
	# notarization (see scripts/notarize.sh).
	codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi

echo "==> Verifying signature"
codesign --verify --verbose "$APP_DIR"

echo "==> Built and signed $APP_DIR"
