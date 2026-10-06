#!/usr/bin/env bash
# Renders the Homebrew cask for a production release from script/homebrew/godusage.rb.template.
#
# The release workflow writes the result to Casks/godusage.rb in the federico-app/homebrew-tap
# repo, so `brew install --cask federico-app/tap/godusage` always installs the newest DMG.
#
# Usage: render_homebrew_cask.sh <MAJOR.MINOR.PATCH> <dmg sha256> <output path>
set -euo pipefail

version="$1"
sha256="$2"
out="$3"
template="$(dirname "$0")/homebrew/godusage.rb.template"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "render_homebrew_cask: '$version' is not a plain MAJOR.MINOR.PATCH version" >&2
  exit 1
}
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "render_homebrew_cask: '$sha256' is not a SHA-256 hex digest" >&2
  exit 1
}

mkdir -p "$(dirname "$out")"
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha256/" "$template" > "$out"

if grep -q '@[A-Z0-9]*@' "$out"; then
  echo "render_homebrew_cask: unreplaced placeholder left in $out" >&2
  exit 1
fi
echo "Rendered $out for GodUsage $version"
