#!/usr/bin/env bash
# Developer-ID signing + Apple notarization + stapling for AppleContainerGUI.app.
#
# !!! NOT RUNNABLE IN THIS ENVIRONMENT !!!
# This script REQUIRES a paid Apple Developer Program account ($99/yr):
#   * a "Developer ID Application" code-signing certificate in the login keychain
#   * an Apple ID + an app-specific password (or a notarytool keychain profile)
#   * a Team ID
# At the time of writing this repo's machine has 0 codesigning identities
# (`security find-identity -v -p codesigning` => "0 valid identities found"),
# so this script has been WRITTEN and reviewed but NOT executed. Run it on a
# machine with a real Developer ID to produce a Gatekeeper-approved, distributable
# .app.
#
# Distribution model: unsandboxed Developer-ID + notarized (NOT Mac App Store).
# The app shells out to the `container` CLI, which the App Sandbox forbids; see
# scripts/bundle.sh for the full rationale.
#
# --- REQUIRED ENVIRONMENT VARIABLES -------------------------------------------
#   DEV_ID        Full Developer ID Application identity string, e.g.
#                 "Developer ID Application: Firsthand Inc (ABCDE12345)"
#   APPLE_ID      Apple ID email used for notarization (the developer account).
#   TEAM_ID       10-char Apple Developer Team ID, e.g. "ABCDE12345".
#   APP_PASSWORD  App-specific password for APPLE_ID (appleid.apple.com -> Sign-In
#                 & Security -> App-Specific Passwords). NOT your account password.
#
# Optional:
#   SHORT_VERSION / BUILD_VERSION  Forwarded to bundle.sh for Info.plist stamping.
#
# Usage:
#   export DEV_ID="Developer ID Application: Firsthand Inc (ABCDE12345)"
#   export APPLE_ID="dev@firsthand.ai"
#   export TEAM_ID="ABCDE12345"
#   export APP_PASSWORD="abcd-efgh-ijkl-mnop"
#   bash scripts/notarize.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="AppleContainerGUI"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
ZIP_PATH="$ROOT_DIR/$APP_NAME.zip"

# --- 0. Validate prerequisites ------------------------------------------------
: "${DEV_ID:?Set DEV_ID to your 'Developer ID Application: …' identity}"
: "${APPLE_ID:?Set APPLE_ID to your Apple Developer account email}"
: "${TEAM_ID:?Set TEAM_ID to your 10-char Apple Team ID}"
: "${APP_PASSWORD:?Set APP_PASSWORD to an app-specific password}"

# Fail fast if the identity is not actually present in a keychain.
if ! security find-identity -v -p codesigning | grep -q "$DEV_ID"; then
	echo "error: Developer ID identity '$DEV_ID' not found in any keychain." >&2
	echo "       Install your 'Developer ID Application' certificate first." >&2
	exit 1
fi

# notarytool ships with full Xcode, not the Command Line Tools. Notarization
# additionally needs xcode-select pointed at Xcode.app, not CommandLineTools.
if ! xcrun --find notarytool >/dev/null 2>&1; then
	echo "error: notarytool not found. Run:" >&2
	echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
	exit 1
fi

# --- 1. Build + Developer-ID sign (hardened runtime + timestamp) --------------
# Hand SIGN_IDENTITY to bundle.sh so it signs with the real cert + hardened
# runtime instead of ad-hoc. bundle.sh attaches NO entitlements (unsandboxed).
echo "==> Building and Developer-ID signing via bundle.sh"
SIGN_IDENTITY="$DEV_ID" bash "$SCRIPT_DIR/bundle.sh"

# Confirm the signature is Developer-ID (not ad-hoc) and satisfies Gatekeeper's
# notarization policy preconditions.
echo "==> Verifying Developer-ID signature"
codesign --verify --strict --verbose=2 "$APP_DIR"
codesign --display --verbose=4 "$APP_DIR" 2>&1 | grep -i "Authority=Developer ID Application" \
	|| { echo "error: bundle is not Developer-ID signed" >&2; exit 1; }

# --- 2. Zip for submission ----------------------------------------------------
# notarytool accepts .zip (ditto preserves the bundle's symlinks/metadata),
# .pkg, or .dmg. We use a zip of the .app.
echo "==> Zipping $APP_NAME.app for notarization"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

# --- 3. Submit to Apple notary service and wait -------------------------------
# --wait blocks until Apple finishes (typically <5 min). On failure, fetch the
# log with: xcrun notarytool log <submission-id> --apple-id … --team-id … --password …
echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP_PATH" \
	--apple-id "$APPLE_ID" \
	--team-id "$TEAM_ID" \
	--password "$APP_PASSWORD" \
	--wait

# --- 4. Staple the notarization ticket to the .app ----------------------------
# Stapling embeds the ticket so Gatekeeper passes offline. Staple the .app
# (not the zip); re-zip afterward for distribution if desired.
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_DIR"

# --- 5. Final Gatekeeper assessment -------------------------------------------
echo "==> Verifying with spctl (Gatekeeper)"
spctl --assess --type execute --verbose=4 "$APP_DIR"

# Re-zip the stapled app for distribution.
echo "==> Re-zipping stapled app for distribution"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "==> Done: notarized + stapled $APP_DIR (distributable: $ZIP_PATH)"
