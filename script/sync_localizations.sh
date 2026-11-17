#!/usr/bin/env bash
# Syncs Sources/GodUsage/Resources/Localizable.xcstrings with the strings the code uses.
#
# `swift build` (Swift Build backend) emits a *.stringsdata file per source file listing every
# localizable string: SwiftUI literals (Text("…"), Button("…"), …), String(localized:) and
# LocalizedStringResource. `xcstringstool sync` merges them into the catalog: new keys are added
# without translations, keys no longer in the code are marked stale. Then fill in the Italian
# translations (see docs/localization.md) and run `swift test` (LocalizationCatalogTests fails on
# any key without one).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT_DIR/Sources/GodUsage/Resources/Localizable.xcstrings"
cd "$ROOT_DIR"

swift build --product GodUsage

# The app target (GodUsageApp, e.g. the Settings… menu command) resolves strings against the same
# main-bundle catalog, so its strings are synced too. The CLI stays English.
# GodUsage.build holds both the library (GodUsage-t.build) and the app product (GodUsage-p.build).
INTERMEDIATES="$ROOT_DIR/.build/out/Intermediates.noindex/GodUsage.build/Debug"
if [ ! -d "$INTERMEDIATES" ]; then
  echo "error: $INTERMEDIATES not found; this script expects the Swift Build backend" >&2
  exit 1
fi
args=()
while IFS= read -r -d '' file; do
  args+=(--stringsdata "$file")
done < <(find "$INTERMEDIATES" -name '*.stringsdata' -print0)

if [ ${#args[@]} -eq 0 ]; then
  echo "error: no .stringsdata files found" >&2
  exit 1
fi

xcrun xcstringstool sync "$CATALOG" "${args[@]}"
echo "==> synced $CATALOG"
