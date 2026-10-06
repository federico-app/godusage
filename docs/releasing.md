# Releasing

Releases are automated and come in two channels:

- **Production.** When you push a stable tag such as `v0.7.1` on `main`, the pipeline tests, builds, signs, notarizes, and publishes a new version with its SHA-256 checksum. Prerelease suffixes are rejected.
- **Dev.** Every push to `develop` publishes **GodUsage DEV** as a GitHub prerelease. See [Dev channel](#dev-channel). The macOS pipeline is [.github/workflows/release.yml](../.github/workflows/release.yml), which calls the [iOS TestFlight pipeline](../.github/workflows/release-ios.yml) in parallel. The step-by-step is in the `release-swift` skill.

**The DMG.** `script/build_dmg.sh` (called by `script/release.sh`) makes a drag-to-install window: the app on the left, an Applications link on the right, and an arrow between them on a background from `assets/dmg/`. Finder lays the window out through AppleScript, so the build needs a GUI session (GitHub's macOS runners have one); if Finder does not save the layout, the build fails. To change the background, edit and run `swift script/render_dmg_background.swift`, and keep the icon positions in `build_dmg.sh` in step with it.

Release tags are owner-managed. See [CONTRIBUTING.md](../CONTRIBUTING.md). Everything below is one-time setup for the maintainer's fork, not something contributors need.

## Release setup (one-time)

The release workflow needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | base64 of the GodUsage Developer ID Application `.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12` |
| `APPLE_NOTARY_PRIVATE_KEY_BASE64` | base64 of an App Store Connect API private key (`.p8`) |
| `APPLE_NOTARY_KEY_ID` | the App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | the App Store Connect API issuer ID |
| `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` | base64 Developer ID provisioning profile for `com.montinovo.godusage` (production iCloud container, Sign in with Apple) |
| `APPLE_DEVELOPER_ID_DEV_PROFILE` | base64 Developer ID provisioning profile for `com.montinovo.godusage.dev` (dev iCloud container, Sign in with Apple) |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token that can edit Workers and D1 in the account in `backend/wrangler.jsonc` |
| `SPARKLE_PUBLIC_KEY` | base64 EdDSA public key, baked into the build as `SUPublicEDKey` |
| `SPARKLE_PRIVATE_KEY` | base64 EdDSA private key used to sign the DMG |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | base64 of the Apple Distribution `.p12` that signs the iOS app |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12` |
| `APPLE_IOS_APP_STORE_PROFILE` | base64 App Store provisioning profile for the iOS app |
| `APPLE_IOS_WIDGET_APP_STORE_PROFILE` | base64 App Store provisioning profile for the iOS widget extension |
| `HOMEBREW_TAP_DEPLOY_KEY` | private half of an SSH deploy key with write access to `federico-app/homebrew-tap` (see [Homebrew](#homebrew)) |

### macOS signing and notarization

Export the Developer ID Application cert (with its private key) from Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 | pbcopy`. Create an App Store Connect API key with the **App Manager** role (it notarizes the Mac app and uploads the iOS app), download its `.p8` once, and base64-encode it the same way. The certificate, API key, and iCloud profile must all belong to the same team (`S6X72K86R8`). Generate the Sparkle EdDSA key pair once with Sparkle's `generate_keys` tool. The public and private values must be a matching pair, or signing is silently skipped.

## Dev channel

[.github/workflows/release-dev.yml](../.github/workflows/release-dev.yml) runs on every push to `develop` that changes the app: pushes that only touch `docs/`, `backend/`, `website/`, or Markdown files are skipped (run it by hand from Actions if needed). It builds `script/release.sh` with `CHANNEL=dev`:

- the app is **GodUsage DEV** (`com.montinovo.godusage.dev`, iCloud container `iCloud.com.montinovo.godusage.dev`), so it installs beside the release app and keeps its own settings, iCloud data, and teams backend; its dashboard shows an orange **DEV** badge next to the Total Spend title (or in its own row when that card is hidden);
- the version is the newest stable tag plus the build number, for example `0.8.16-dev.642`;
- it is Developer ID-signed and notarized like production, published as the prerelease `dev-<build>` with `GodUsage-DEV-<version>.dmg`, and never becomes the GitHub "Latest" release;
- it updates `appcast-dev.xml` on `update-feed` (last 10 builds) and deploys `update-feed` to GitHub Pages itself, so it does not depend on workflows on `main`. Installed DEV apps update from that feed and never see production releases, and production apps never see DEV builds. The production pipeline ignores `dev-*` prereleases when it checks the feed's release history.
- it runs in its own queue, so a push to `develop` never cancels a production release that is waiting to start. If a DEV build and a production release publish `update-feed` at the same moment, one push fails; rerun it.

Merge `develop` into `main` and tag it to ship production.

The dev container needs its CloudKit schema deployed to **Production** too, because a Developer ID build uses the Production environment (see [iCloud Sync](icloud-sync.md#development-and-release-setup)).

## Homebrew

`brew install --cask federico-app/tap/godusage` installs the latest production DMG. The cask lives in the public tap repo [`federico-app/homebrew-tap`](https://github.com/federico-app/homebrew-tap) as `Casks/godusage.rb`.

After each production release, the **Update Homebrew Cask** job in [.github/workflows/release.yml](../.github/workflows/release.yml) renders the cask from [script/homebrew/godusage.rb.template](../script/homebrew/godusage.rb.template) with the new version and the DMG's SHA-256 (`script/render_homebrew_cask.sh`) and pushes it to the tap. It skips the push when the tag is not the latest release, so rerunning an old tag never rolls the cask back. It fails loudly when `HOMEBREW_TAP_DEPLOY_KEY` is missing, without blocking the update feed or the iOS jobs. The DEV channel has no cask.

The cask declares `auto_updates true`: Sparkle updates the installed app, and `brew upgrade` leaves it alone.

One-time setup:

1. Create the public repo `federico-app/homebrew-tap` with a first commit (an empty repo cannot be checked out).
2. Generate a key pair: `ssh-keygen -t ed25519 -N "" -C "godusage release" -f homebrew_tap_key`.
3. Add `homebrew_tap_key.pub` to the tap repo as a deploy key with **Allow write access**.
4. Store `homebrew_tap_key` (the private half) as the `HOMEBREW_TAP_DEPLOY_KEY` secret on this repo, then delete both files.

To check the cask locally: `brew style --cask federico-app/tap/godusage && brew audit --cask --online federico-app/tap/godusage`.

The tap name means the command is not just `brew install godusage`. That needs the cask in the official `homebrew/cask` repo, which only accepts apps that are notable enough on GitHub.

## Teams backend

[.github/workflows/backend-deploy.yml](../.github/workflows/backend-deploy.yml) deploys the [teams backend](teams-backend.md) on the same channels. A push to `develop` that changes `backend/` migrates and deploys the dev Worker. A stable tag migrates and deploys production. It can also be run by hand for either environment. It needs `CLOUDFLARE_API_TOKEN`.

### iOS signing

The iOS TestFlight jobs sign manually with the `APPLE_DISTRIBUTION_*` cert and the two `APPLE_IOS_*_PROFILE` secrets (one App Store profile per bundle ID: the app `com.montinovo.godusage.mobile` and the widget extension `com.montinovo.godusage.mobile.widgets`), and reuse the three `APPLE_NOTARY_*` secrets for the upload and TestFlight API calls. Xcode cloud signing is not used, because an App Manager API key cannot access cloud-managed distribution certificates ("Cloud signing permission error").

You can create the Apple Distribution certificate and App Store profiles through the App Store Connect API with the App Manager key: generate an RSA-2048 CSR, `POST /v1/certificates` with type `DISTRIBUTION`, then `POST /v1/profiles` with type `IOS_APP_STORE` referencing the bundle ID and certificate, once per bundle ID. Package the cert and private key as a `.p12` **with OpenSSL 3's `-legacy` flag** (the modern defaults produce a `.p12` that macOS `security import` rejects with "MAC verification failed") and include the WWDR G3 intermediate. Store the `.p12`, its password, and the profiles in 1Password with the other signing material.

### App Store Connect

Create the app record (My Apps → New App, iOS, bundle ID `com.montinovo.godusage.mobile`, any unique SKU), and add an internal TestFlight tester group with **automatic distribution** so every uploaded build reaches internal testers without a manual step. The App ID must already have the CloudKit capability with both GodUsage containers (see [iOS app](ios-app.md)).

The iOS jobs only run when the release needs them. Until the app record exists, the iOS Gate job skips every release with a warning instead of failing. The iOS Gate job skips Mac-only releases (no iOS-relevant changes since the last build the external testers received) unless that build is nearing its 90-day expiry. See [iOS app](ios-app.md#releasing-testflight). For external testers, the TestFlight External job submits each shipped release for Beta App Review, and testers receive it when Apple approves. The job runs in the **iOS TestFlight** GitHub environment, so the repository's Deployments panel shows the public join link (https://testflight.apple.com/join/uA4aHUEx) next to the Update Feed deployment. Its one-time setup has two steps. First, create an external group named `External` under TestFlight → External Testing, and add testers by email or enable a public link (the workflow's `TESTFLIGHT_EXTERNAL_GROUPS` env lists the group names it ships to). Second, fill in the app's TestFlight **Test Information**: the beta app description, the feedback email, and the review contact and sign-in details the first submission asks for. The app needs no demo account because it reads the tester's own iCloud data. Mark it as not requiring sign-in and say so in the review notes.

### iCloud Sync

Teams sign in through Apple's web flow, so the profiles do not need Sign in with Apple (Developer ID profiles never grant it). It needs the Services ID described in [Teams backend](teams-backend.md#sign-in-with-apple). The entitlements scripts still add Sign in with Apple when a profile grants it, and never otherwise, because an entitlement the profile does not authorize stops the app from launching. The dev build signs with a certificate the embedded profile lists, so include an installed **Apple Development** certificate when generating development profiles.

Store the original development and Developer ID provisioning profiles in 1Password as secure documents. Install the development profile on each registered Mac. Base64-encode the Developer ID profile and store it only in the `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` Actions secret. See [iCloud Sync](icloud-sync.md#development-and-release-setup) for the container identifiers, build command, and inspection command.

### GitHub Pages

The repository must be public (Sparkle fetches the DMG and appcast anonymously), and the update feed is served through GitHub Pages. Set Settings → Pages → Build and deployment → Source to **GitHub Actions**. The publishing workflows create and maintain the `update-feed` branch and deploy through the **Update Feed** environment. The landing page ships the same way: `website/` on `main` is published to `update-feed` by `.github/workflows/landing-page.yml` on merge, alongside the appcast and pricing supplement.

The Pages site has no custom domain. It serves the landing page, appcast, and pricing supplement from `federico-app.github.io/godusage/`. That feed URL is baked into every shipped app as `SUFeedURL`, so if you ever add a custom domain, keep the GitHub Pages address working (GitHub redirects it) and never let the domain lapse. See [Updates](updates.md#where-updates-come-from).
