#!/usr/bin/env bash
set -euo pipefail

# Prints the SHA-1 of the first certificate in <profile> that is a valid code-signing identity in the
# keychain (looked up in-process by find_codesigning_identity.swift). A profile only works with the
# certificates it lists, so signing with any other identity (even one from the same team) produces
# an app that macOS refuses to launch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:?usage: profile_signing_identity.sh <profile>}"

decoded=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/godusage-profile.XXXXXX")
certificate=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/godusage-cert.XXXXXX")
trap '/bin/rm -f "$decoded" "$certificate"' EXIT
"$SCRIPT_DIR/decode_provisioning_profile.sh" "$PROFILE" "$decoded" 2>/dev/null \
  || { echo "could not decode provisioning profile: $PROFILE" >&2; exit 1; }

hashes=()
index=0
while /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:$index" "$decoded" >"$certificate" 2>/dev/null; do
  # PlistBuddy appends a newline to the raw DER bytes; strip it before hashing.
  /usr/bin/perl -0pi -e 's/\n\z//' "$certificate"
  sha1=$(/usr/bin/openssl x509 -inform der -in "$certificate" -noout -fingerprint -sha1 2>/dev/null \
    | /usr/bin/sed 's/.*=//; s/://g')
  [ -n "$sha1" ] && hashes+=("$sha1")
  index=$((index + 1))
done
[ "${#hashes[@]}" -gt 0 ] || exit 1
exec /usr/bin/xcrun swift "$SCRIPT_DIR/find_codesigning_identity.swift" --sha1 "${hashes[@]}"
