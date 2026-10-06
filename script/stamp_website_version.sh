#!/usr/bin/env bash
# Stamps the landing page's dashboard mock with a release version.
#
# The mock's footer and the Download buttons show "GodUsage X.Y.Z". The source file carries whatever version was current
# when it was last edited; the site is only ever published by the update-feed workflows, so each
# of them stamps the real version at assemble time and the page never drifts.
#
# Usage: stamp_website_version.sh <index.html path> <MAJOR.MINOR.PATCH>
set -euo pipefail

html="$1"
version="$2"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "stamp_website_version: '$version' is not a plain MAJOR.MINOR.PATCH version" >&2
  exit 1
}
grep -qE 'GodUsage [0-9]+\.[0-9]+\.[0-9]+' "$html" || {
  echo "stamp_website_version: no 'GodUsage X.Y.Z' text found in $html — did the mock's footer change?" >&2
  exit 1
}

tmp="$html.tmp"
sed -E "s/GodUsage [0-9]+\.[0-9]+\.[0-9]+/GodUsage $version/g" "$html" > "$tmp"
mv "$tmp" "$html"

grep -q "GodUsage $version" "$html" || {
  echo "stamp_website_version: stamping $html with $version failed" >&2
  exit 1
}
echo "Stamped $html with GodUsage $version"
