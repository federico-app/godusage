#!/usr/bin/env bash
set -euo pipefail

# Finds the newest installed, unexpired provisioning profile for <bundle-id> that authorizes Sign in
# with Apple. The fallback when no profile also carries the iCloud container: the build then gets
# Teams sign-in without iCloud Sync, instead of no profile at all.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

profile_matches_bundle() {
  local application_identifier="$1"
  local bundle_id="$2"
  case "$application_identifier" in
    *."$bundle_id") [ "${application_identifier%."$bundle_id"}" != "" ] ;;
    *) return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

BUNDLE_ID="${1:?usage: find_signin_provisioning_profile.sh <bundle-id>}"

best_profile=""
best_expiration=0
now=$(/bin/date -u +%s)

for directory in \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [ -d "$directory" ] || continue
  while IFS= read -r -d '' candidate; do
    decoded=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/godusage-profile.XXXXXX")
    if ! "$SCRIPT_DIR/decode_provisioning_profile.sh" "$candidate" "$decoded" 2>/dev/null; then
      /bin/rm -f "$decoded"
      continue
    fi
    application_identifier=$(/usr/libexec/PlistBuddy \
      -c "Print :Entitlements:com.apple.application-identifier" "$decoded" 2>/dev/null || true)
    has_signin=0
    /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.applesignin" "$decoded" >/dev/null 2>&1 \
      && has_signin=1
    expiration=$(/usr/bin/plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null || true)
    /bin/rm -f "$decoded"

    profile_matches_bundle "$application_identifier" "$BUNDLE_ID" || continue
    [ "$has_signin" = 1 ] || continue
    expiration_epoch=$(/bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expiration" +%s 2>/dev/null || true)
    [ -n "$expiration_epoch" ] && [ "$expiration_epoch" -gt "$now" ] || continue
    if [ "$expiration_epoch" -gt "$best_expiration" ]; then
      best_profile="$candidate"
      best_expiration="$expiration_epoch"
    fi
  done < <(/usr/bin/find "$directory" -type f \
    \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print0)
done

[ -n "$best_profile" ] || exit 1
printf '%s\n' "$best_profile"
