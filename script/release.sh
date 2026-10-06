#!/usr/bin/env bash
set -euo pipefail

# Builds a distributable, Developer ID-signed, notarized GodUsage.app and wraps it in a DMG. The app
# is a universal binary (arm64 + x86_64) so it runs on both Apple Silicon and Intel Macs; the DMG is the
# only output. The appcast is produced separately by Sparkle's generate_appcast (in release.yml), which
# signs the DMG with the EdDSA key and writes/updates appcast.xml. Runs in CI (release.yml) and locally
# on a Mac with the same env. This script does NOT push anything to GitHub.
#
# Required env:
#   CODESIGN_IDENTITY     Developer ID Application identity display name
#   ICLOUD_PROVISIONING_PROFILE  Developer ID provisioning profile with the production iCloud container
#   SPARKLE_PUBLIC_KEY    base64 EdDSA public key -> baked into Info.plist (SUPublicEDKey). generate_appcast
#                         only signs the DMG if this matches the private key it signs with.
#   GODUSAGE_VERSION     human version, e.g. 0.7.0 (CFBundleShortVersionString)
# Optional env:
#   CHANNEL               "prod" (default) or "dev". dev builds "GodUsage DEV" (com.montinovo.godusage.dev,
#                         its own iCloud container, appcast-dev.xml feed, GodUsage-DEV-<version>.dmg) so
#                         it installs and updates beside the release app. GODUSAGE_VERSION may then
#                         carry a suffix (0.8.16-dev.642); prod accepts only a stable version.
#   GODUSAGE_BUILD       CFBundleVersion (monotonic). Default: git commit count.
#   FEED_URL              appcast URL baked into the app. Default: GitHub Pages project URL.
#   APPLE_NOTARY_KEY_PATH / APPLE_NOTARY_KEY_ID / APPLE_NOTARY_ISSUER_ID
#                         App Store Connect API private key path, key ID, and issuer ID for notarytool.
#                         When all three are set, the app and DMG are notarized + stapled.
#   ALLOW_UNNOTARIZED=1   Skip notarization for a LOCAL dry run. Without it, missing notary creds is a
#                         hard error so CI never publishes an un-notarized build.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to your Developer ID Application identity}"
: "${ICLOUD_PROVISIONING_PROFILE:?set ICLOUD_PROVISIONING_PROFILE to the iCloud provisioning profile path}"
: "${SPARKLE_PUBLIC_KEY:?set SPARKLE_PUBLIC_KEY to your base64 EdDSA public key}"
: "${GODUSAGE_VERSION:?set GODUSAGE_VERSION, e.g. 0.7.0}"

CHANNEL="${CHANNEL:-prod}"
APP_NAME="GodUsage"   # executable and SwiftPM product; the same for both channels
case "$CHANNEL" in
  prod)
    APP_DISPLAY_NAME="GodUsage"
    BUNDLE_ID="com.montinovo.godusage"
    ICLOUD_CONTAINER_ID="iCloud.com.montinovo.godusage"
    FEED_FILE="appcast.xml"
    DMG_PREFIX="GodUsage"
    ;;
  dev)
    APP_DISPLAY_NAME="GodUsage DEV"
    BUNDLE_ID="com.montinovo.godusage.dev"
    ICLOUD_CONTAINER_ID="iCloud.com.montinovo.godusage.dev"
    FEED_FILE="appcast-dev.xml"
    DMG_PREFIX="GodUsage-DEV"
    ;;
  *)
    echo "CHANNEL must be prod or dev, got: $CHANNEL" >&2
    exit 1
    ;;
esac
EXPECTED_TEAM_ID="${APPLE_TEAM_ID:-S6X72K86R8}"
APPLE_TEAM_ID="$EXPECTED_TEAM_ID"
export APPLE_TEAM_ID
MIN_SYSTEM_VERSION="15.0"
VERSION="$GODUSAGE_VERSION"
if [ "$CHANNEL" = "prod" ]; then
  "$ROOT_DIR/script/validate_release_tag.sh" "v$VERSION" >/dev/null
elif [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$ ]]; then
  echo "Dev versions must look like 1.2.3-dev.45, got: $VERSION" >&2
  exit 1
fi
# CFBundleShortVersionString is the stable human-readable version Sparkle shows in its update prompt
# and the app shows in its footer/About. Sparkle compares builds by the monotonic CFBundleVersion.
BUILD="${GODUSAGE_BUILD:-$(git rev-list --count HEAD)}"
FEED_URL="${FEED_URL:-https://federico-app.github.io/godusage/$FEED_FILE}"
DMG_NAME="$DMG_PREFIX-$VERSION.dmg"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_BINARY="$APP_HELPERS/godusage"
DMG_PATH="$DIST_DIR/$DMG_NAME"
DMG_CHECKSUM_PATH="$DMG_PATH.sha256"
ENTITLEMENTS_TEMPLATE="$ROOT_DIR/script/GodUsage.release.entitlements.plist"
if [ "$CHANNEL" = "dev" ]; then
  # Same entitlements, pointed at the dev container.
  mkdir -p "$DIST_DIR"
  sed "s/iCloud\.com\.montinovo\.godusage</$ICLOUD_CONTAINER_ID</" "$ENTITLEMENTS_TEMPLATE" \
    > "$DIST_DIR/GodUsage.release-dev.entitlements.plist"
  ENTITLEMENTS_TEMPLATE="$DIST_DIR/GodUsage.release-dev.entitlements.plist"
  grep -q "$ICLOUD_CONTAINER_ID<" "$ENTITLEMENTS_TEMPLATE" \
    || { echo "could not point the entitlements at $ICLOUD_CONTAINER_ID" >&2; exit 1; }
fi
ENTITLEMENTS="$DIST_DIR/GodUsage.release.resolved.entitlements.plist"

[[ "$CODESIGN_IDENTITY" == Developer\ ID\ Application:*"($EXPECTED_TEAM_ID)" ]] \
  || { echo "CODESIGN_IDENTITY must belong to team $EXPECTED_TEAM_ID" >&2; exit 1; }

# Decide notarization up front. CI always supplies the App Store Connect API key; a local dry run can
# opt out with ALLOW_UNNOTARIZED=1 (the build will then be Gatekeeper-blocked on other Macs). Missing
# creds without that opt-out is a hard error so CI never publishes an un-notarized DMG.
NOTARIZE=0
if [ -n "${APPLE_NOTARY_KEY_PATH:-}" ] \
  && [ -f "${APPLE_NOTARY_KEY_PATH:-}" ] \
  && [ -n "${APPLE_NOTARY_KEY_ID:-}" ] \
  && [ -n "${APPLE_NOTARY_ISSUER_ID:-}" ]; then
  NOTARIZE=1
elif [ "${ALLOW_UNNOTARIZED:-}" = "1" ]; then
  echo "WARNING: ALLOW_UNNOTARIZED=1 — build will NOT be notarized (other Macs will block it)." >&2
else
  echo "Notarization credentials missing or invalid." >&2
  echo "Set APPLE_NOTARY_KEY_PATH, APPLE_NOTARY_KEY_ID, and APPLE_NOTARY_ISSUER_ID," >&2
  echo "or set ALLOW_UNNOTARIZED=1 for a local dry run." >&2
  exit 1
fi

notarize() {  # $1: artifact to submit (.zip or .dmg)
  xcrun notarytool submit "$1" \
    --key "$APPLE_NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait
}

echo "==> building $APP_DISPLAY_NAME $VERSION ($BUILD) — universal (arm64 + x86_64)"
# Build both arch slices and let SwiftPM lipo-merge them into one universal binary. With multiple
# --arch, --show-bin-path resolves to the merged products dir (.build/apple/Products/Release), which
# also holds the *.bundle resources, so the staging loop below is unchanged.
swift build -c release --arch arm64 --arch x86_64 --product GodUsage
swift build -c release --arch arm64 --arch x86_64 --product godusage-cli
BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_CLI_BINARY="$BUILD_DIR/godusage-cli"
[ -x "$BUILD_BINARY" ] || { echo "missing built binary: $BUILD_BINARY" >&2; exit 1; }
[ -x "$BUILD_CLI_BINARY" ] || { echo "missing built CLI: $BUILD_CLI_BINARY" >&2; exit 1; }

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$CLI_BINARY"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CLI_BINARY"
# Fail loudly if the build ever silently regresses to a single arch (e.g. a dropped --arch flag): a
# fat binary is the whole point, and generate_appcast derives Sparkle's hardwareRequirements from it.
lipo -archs "$APP_BINARY" | grep -q "x86_64" && lipo -archs "$APP_BINARY" | grep -q "arm64" \
  || { echo "Expected a universal (arm64 + x86_64) binary, got: $(lipo -archs "$APP_BINARY")" >&2; exit 1; }
lipo -archs "$CLI_BINARY" | grep -q "x86_64" && lipo -archs "$CLI_BINARY" | grep -q "arm64" \
  || { echo "Expected a universal CLI, got: $(lipo -archs "$CLI_BINARY")" >&2; exit 1; }

# SwiftPM stamps LC_BUILD_VERSION's `sdk` field with the deployment target (macOS 15), not the real
# SDK it compiled against. macOS gates the modern Liquid Glass control appearance (pop-up buttons,
# pickers, etc.) on the linked SDK — a "15.0" stamp makes AppKit fall back to legacy Aqua controls.
# Restamp the sdk to 26.0 (Tahoe) while keeping minos at MIN_SYSTEM_VERSION so the app still runs on
# macOS 15 but gets the modern controls. Stamps every slice of the universal binary; re-signed below.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"
# Fail loudly if any slice still reports the old SDK (a silent vtool no-op would ship legacy controls).
if vtool -show-build "$APP_BINARY" | grep -q "sdk 15.0"; then
  echo "SDK restamp failed: $APP_BINARY still reports sdk 15.0" >&2
  exit 1
fi

shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Install the app icon. Prefer the prebuilt compiled catalog: actool on GitHub's runners (Xcode 26.4.1
# and 26.5) crashes on the Icon Composer `.icon` refractivity feature (Apple regression FB20183399), so
# CI can't compile it. The committed Assets.car is produced by a working actool via script/compile_icon.sh;
# regenerate it there whenever assets/AppIcon.icon changes. Fall back to actool where it works (e.g. local).
if [ -f "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" ]; then
  echo "==> installing prebuilt app icon"
  cp "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" "$APP_RESOURCES/Assets.car"
  [ -f "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" ] \
    && cp "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
  echo "==> compiling app icon"
  xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
    --app-icon AppIcon --enable-on-demand-resources NO --development-region en \
    --target-device mac --platform macosx --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --output-partial-info-plist /dev/null --output-format human-readable-text --errors --warnings
fi

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID.invite</string>
      <key>CFBundleURLSchemes</key><array><string>godusage</string></array>
    </dict>
  </array>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
  <key>NSUbiquitousContainers</key>
  <dict>
    <key>$ICLOUD_CONTAINER_ID</key>
    <dict>
      <key>NSUbiquitousContainerIsDocumentScopePublic</key><false/>
      <key>NSUbiquitousContainerName</key><string>GodUsage</string>
      <key>NSUbiquitousContainerSupportedFolderLevels</key><string>None</string>
    </dict>
  </dict>
</dict>
</plist>
PLIST

cp "$ICLOUD_PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
"$ROOT_DIR/script/render_icloud_entitlements.sh" \
  "$ENTITLEMENTS_TEMPLATE" "$ICLOUD_PROVISIONING_PROFILE" "$ENTITLEMENTS" \
  "$ICLOUD_CONTAINER_ID"

# Embed + sign Sparkle (Developer ID, hardened runtime, secure timestamp).
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "$CODESIGN_IDENTITY" "--options runtime --timestamp"
codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$CLI_BINARY"

echo "==> signing app (Developer ID, hardened runtime)"
# Not --deep: the Sparkle framework is signed above and must keep that signature.
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
  --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -d --entitlements :- "$APP_BUNDLE" 2>&1 | grep -q "$ICLOUD_CONTAINER_ID<" \
  || { echo "signed app is missing the $ICLOUD_CONTAINER_ID iCloud entitlement" >&2; exit 1; }

# Notarize + staple the app itself (not just the DMG) so it launches cleanly even offline after a
# Sparkle update extracts it from the disk image.
if [ "$NOTARIZE" = "1" ]; then
  echo "==> notarizing app (this can take a few minutes)"
  APP_ZIP="$DIST_DIR/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
  notarize "$APP_ZIP"
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$APP_ZIP"
fi

echo "==> building $DMG_PATH"
# Drag-to-install window: background, app on the left, Applications on the right.
STAGED_APP="$(mktemp -d)/$APP_DISPLAY_NAME.app"
cp -R "$APP_BUNDLE" "$STAGED_APP"
"$ROOT_DIR/script/build_dmg.sh" "$STAGED_APP" "$APP_DISPLAY_NAME" "$DMG_PATH"
rm -rf "$(dirname "$STAGED_APP")"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"

# Notarize + staple the DMG too, so the first manual download isn't Gatekeeper-blocked.
if [ "$NOTARIZE" = "1" ]; then
  echo "==> notarizing dmg"
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "==> notarized + stapled"
fi

(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" > "$(basename "$DMG_CHECKSUM_PATH")"
)

echo "==> done"
echo "    DMG:  $DMG_PATH"
echo "    SHA-256: $DMG_CHECKSUM_PATH"
echo "    The appcast is generated from this DMG by generate_appcast (see release.yml)."
