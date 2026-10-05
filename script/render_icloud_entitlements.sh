#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="${1:?entitlements template path required}"
PROFILE="${2:?provisioning profile path required}"
OUTPUT="${3:?resolved entitlements output path required}"
# Optional: without a container the profile only has to match the app, and no iCloud keys are added
# (a Teams-only development profile).
CONTAINER_ID="${4:-}"

PROFILE_PLIST="$(mktemp)"
trap 'rm -f "$PROFILE_PLIST"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/decode_provisioning_profile.sh" "$PROFILE" "$PROFILE_PLIST"

TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
[ -n "$TEAM_ID" ] || { echo "provisioning profile has no team identifier" >&2; exit 1; }
if [ -n "${APPLE_TEAM_ID:-}" ] && [ "$TEAM_ID" != "$APPLE_TEAM_ID" ]; then
  echo "provisioning profile belongs to team $TEAM_ID, expected $APPLE_TEAM_ID" >&2
  exit 1
fi

APP_ID="$(/usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
[ -n "$APP_ID" ] || { echo "provisioning profile has no application identifier" >&2; exit 1; }

if [ -n "$CONTAINER_ID" ]; then
  /usr/libexec/PlistBuddy \
    -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$PROFILE_PLIST" \
    | /usr/bin/grep -Fq "$CONTAINER_ID" \
    || { echo "provisioning profile does not allow $CONTAINER_ID" >&2; exit 1; }

  # shellcheck source=find_icloud_provisioning_profile.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/find_icloud_provisioning_profile.sh"
  ICLOUD_SERVICES="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.icloud-services' "$PROFILE_PLIST" 2>/dev/null || true)"
  profile_authorizes_cloudkit "$ICLOUD_SERVICES" \
    || { echo "provisioning profile does not authorize CloudKit (regenerate it with the CloudKit capability)" >&2; exit 1; }
fi

/bin/cp "$TEMPLATE" "$OUTPUT"

# Xcode normally injects these identity entitlements while signing. This repository signs the
# SwiftPM-built bundle directly with codesign, so derive them from the provisioning profile instead.
# Without them taskgated rejects an otherwise valid signature before the app can launch.
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.application-identifier string $APP_ID" \
  -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
  -c "Add :keychain-access-groups array" \
  -c "Add :keychain-access-groups:0 string $APP_ID" \
  "$OUTPUT"

# Sign in with Apple (Teams) is requested only when the profile grants it: an entitlement the
# profile does not authorize makes macOS refuse to launch the app.
if /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.applesignin' "$PROFILE_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.developer.applesignin array' \
    -c 'Add :com.apple.developer.applesignin:0 string Default' \
    "$OUTPUT"
fi

if [ -z "$CONTAINER_ID" ]; then
  :
elif /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices:0' "$PROFILE_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.developer.icloud-container-environment string Development' \
    -c 'Add :com.apple.developer.icloud-container-development-container-identifiers array' \
    -c "Add :com.apple.developer.icloud-container-development-container-identifiers:0 string $CONTAINER_ID" \
    "$OUTPUT"
else
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.developer.icloud-container-environment string Production' \
    "$OUTPUT"
fi
/usr/bin/plutil -lint "$OUTPUT" >/dev/null
