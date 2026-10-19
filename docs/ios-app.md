# iOS Companion App

GodUsageMobile (in `ios/`) is a read-only iPhone and iPad viewer for your Teams usage. It holds no provider credentials and reads everything from the GodUsage teams server.

Link the phone once by QR code: on a Mac signed in to Teams, open **Settings → Teams → iPhone and iPad → Link iPhone or iPad…**, then tap **Scan Code** in the app (or scan the code with the Camera app, which opens GodUsage). See [Teams](teams.md#iphone-and-ipad).

Once linked, the app shows:

- **Your Usage**: Today and Last 30 Days spend and tokens, a 30-day chart, and the spend per provider, summed across your Macs. Macs share usage with the server only while you are in at least one team.
- **Your Teams**: each team's spend leaderboard for Today, 7 Days, or 30 Days.

The session is kept in the Keychain on this device. **Sign Out** (account menu) ends it; unlinking the phone from the Mac does too, and the app then asks for a new code. The app refreshes on opening, on returning to the foreground, and with pull-to-refresh.

**GodUsage DEV** (Debug and Dev builds) talks to the dev server (`api-dev.godusage.com`) and **GodUsage** (Release builds) to production (`api.godusage.com`), matching the Mac's DEV and production channels. A code from the other server is refused with a message naming the right app.

## Building

Open `ios/GodUsageMobile.xcodeproj` in Xcode and run, or:

```bash
xcodebuild -project ios/GodUsageMobile.xcodeproj -target GodUsageMobile \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

That unsigned simulator build is for compile verification. Run the app from Xcode to sign simulator and device builds.

There are two apps, like on the Mac, and they install side by side:

| Configuration | App | Bundle id | Teams server |
| --- | --- | --- | --- |
| Debug | GodUsage DEV | `com.montinovo.godusage.mobile.dev` | `api-dev.godusage.com` |
| Dev | GodUsage DEV (TestFlight) | same as Debug | `api-dev.godusage.com` |
| Release | GodUsage | `com.montinovo.godusage.mobile` | `api.godusage.com` |

Pick the app with the scheme: **GodUsage DEV** runs Debug and archives Dev, **GodUsage** runs and archives Release. Product → Archive then builds the app the scheme names. The `DEV_CHANNEL` compilation condition (set for Debug and Dev) picks the dev server. The app needs no capabilities beyond the defaults. Signing is automatic with the development team.

## Releasing (TestFlight)

**GodUsage DEV** ships from `develop`: every push that changes `ios/` uploads a Dev build to TestFlight for internal testers (see [Releasing](releasing.md#ios-dev-channel)). Production ships as below.

The iOS app ships from the same `v*` tag as the Mac app, when the release touches it. The release workflow calls `.github/workflows/release-ios.yml`. Its "iOS Gate" job (`script/testflight_gate.mjs`) checks what changed since the last build the external TestFlight testers received. Until the app has an App Store Connect record, every release skips the iOS jobs and the gate logs a warning. A Mac-only release skips the iOS jobs, because every upload is a new version that goes through a fresh Beta App Review and pushes an update at testers. When the gate says ship, the "iOS TestFlight" job archives the app, signs it, and uploads it to App Store Connect, which serves it to internal testers once Apple finishes processing. The "TestFlight External" job then waits for that processing, adds the build to the external tester group(s), and submits it for Beta App Review (`script/testflight_distribute.mjs`). External testers receive it when Apple approves. Testers install and update through the TestFlight app. There is no Sparkle feed on iOS and no notarization.

The gate ships when anything under `ios/`, the iOS release workflow, or a TestFlight pipeline script changed since the baseline build. Changes to the macOS release job do not count. The baseline is the newest processed build present in every external TestFlight group. Its version names the tag it was built from, so a failed upload or failed external distribution never advances the baseline. The gate also ships when the baseline build is older than 60 days, because TestFlight builds expire 90 days after upload. Beta App Review approval is not part of the baseline: it stays pending for up to a day after every ship, and waiting for it would re-submit identical builds. TestFlight can therefore lag the Mac version (say, 0.8.9 on the Mac while TestFlight shows 0.8.5). That is expected. A teams API change that matters to the phone must update the decoders in `ios/`, which trips the gate. To ship iOS regardless, run the Release workflow manually with the `force_ios` input checked.

- The version is the tag (`v0.7.1` → `0.7.1`) and the build number is the git commit count, both injected at build time. `MARKETING_VERSION` in the Xcode project is never bumped by hand. TestFlight rejects a reused build number for the same version, so rerunning a tag that already uploaded fails at the upload step. Tag a new patch version instead.
- Signing is manual: an Apple Distribution certificate and one App Store provisioning profile for the app, stored as repository secrets, the same pattern as the Mac release's Developer ID cert. The App Store Connect API key (App Manager role) only authenticates the upload and the TestFlight distribution calls. Cloud signing does not work with API keys below Admin.
- `script/release_ios.sh` is the whole build. Run it locally with `SKIP_TESTFLIGHT_UPLOAD=1` to get a signed `.ipa` in `dist/ios/` without uploading.
- The upload can never be repeated, but the external-distribution job is idempotent. If it fails (say, before the one-time Test Information is filled in), rerun just that job with `gh run rerun <run-id> --failed`. The uploaded build is untouched.

The one-time App Store Connect setup (app record, tester group, key role) is in [Releasing](releasing.md).
