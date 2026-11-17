# shellcheck shell=bash
# Sourced by release.sh and build_and_run.sh.
#
# SwiftPM compiles Localizable.xcstrings into en.lproj / it.lproj inside the GodUsage resource bundle.
# SwiftUI's Text("…") and String(localized:) look strings up in Bundle.main, and macOS picks the app's
# language from the localizations the main bundle carries, so the .lproj folders also go into the
# app's own Contents/Resources. Fails loudly when the build produced none.

# $1: SwiftPM products dir (holds GodUsage_GodUsage.bundle), $2: the app's Contents/Resources
stage_localizations() {
  local resource_bundle="$1/GodUsage_GodUsage.bundle"
  local app_resources="$2"
  local staged=0
  local lproj
  for lproj in "$resource_bundle"/*.lproj "$resource_bundle"/Contents/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    rm -rf "$app_resources/$(basename "$lproj")"
    cp -R "$lproj" "$app_resources/"
    staged=$((staged + 1))
  done
  for required in en it; do
    if [ ! -f "$app_resources/$required.lproj/Localizable.strings" ] \
      && [ ! -f "$app_resources/$required.lproj/Localizable.stringsdict" ]; then
      echo "error: $required.lproj/Localizable.* missing from $resource_bundle (staged $staged .lproj)" >&2
      return 1
    fi
  done
  echo "==> staged $staged localizations into $app_resources"
}
