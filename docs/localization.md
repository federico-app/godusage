# Localization

GodUsage ships in English (the base language) and Italian. The app follows the Mac's language: with Italian first in System Settings > General > Language & Region, or per app under Applications, it shows Italian; with any other language it shows English.

## Where the strings live

- `Sources/GodUsage/Resources/Localizable.xcstrings` is the single String Catalog. The key is the English text; each entry holds the Italian translation, and counts carry plural variations ("1 account" / "%lld accounts").
- `swift build` compiles the catalog into `en.lproj` and `it.lproj` inside `GodUsage_GodUsage.bundle`.
- `script/release.sh` and `script/build_and_run.sh` copy those `.lproj` folders into the app's `Contents/Resources` (`script/lib/stage_localizations.sh`) and declare `CFBundleDevelopmentRegion` en and `CFBundleLocalizations` en, it in the Info.plist. SwiftUI and `String(localized:)` look strings up in the main app bundle, so the copy is what makes the translations show. The build fails if either `.lproj` is missing.
- `swift run` and `swift test` have no app bundle around them, so they always show English.

## Adding or changing a string

1. Write the English in code:
   - SwiftUI literals (`Text("Done")`, `Button("Cancel")`, `Toggle`, `Label`, `.help("…")`) are localizable already.
   - Text typed as `String` (helpers, notifications, alerts, menu items, tooltips, error messages) uses `String(localized: "…")`. Put values in the literal with interpolation (`String(localized: "Delete \(name)?")`), never concatenate pieces of a sentence. Add a `comment:` when a short word is ambiguous.
   - For a count, write one key (`String(localized: "\(count) accounts")`) and add the plural variations in the catalog.
2. Run `script/sync_localizations.sh`. It builds and merges the strings the compiler found into the catalog; removed strings are marked stale.
3. Add the Italian translation (and plural variations) for every new key, in Xcode's catalog editor or in the JSON.
4. Run `swift test`. `LocalizationCatalogTests` fails on any key without Italian, on Italian whose format arguments differ from the key, and on a provider metric title missing from the catalog.

Do not localize log messages, identifiers, provider, model or plan names, or anything the local HTTP API or the CLI outputs.

## Provider metric titles

Metric titles ("Session", "Weekly", "Extra Usage") stay English in the model, because they double as match keys, go out through the local API and are saved in layouts. Views translate them when they draw them with `LocalizedMetricTitle.string(_:)`. Their catalog entries are added by hand (extraction state "manual"); model names such as "Sonnet" or "Spark" are marked "don't translate".

## Italian style

Concise, in the tone of macOS System Settings. Titles capitalize only the first word ("Mostra sempre il ritmo"), not English title case. Brand and product names stay as they are (Claude, Codex, GodUsage, Max 20x).

To check a build in Italian without changing the Mac's language, launch it with `open "dist/GodUsage DEV.app" --args -AppleLanguages '(it)'` (or `'(en)'` on an Italian Mac).

The CLI and the local HTTP API keep their field names and values in English. Error messages in the API's `errors` list are the dashboard's text, so they follow the app's language.
