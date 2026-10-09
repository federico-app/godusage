# Updates

GodUsage updates itself with [Sparkle](https://sparkle-project.org), the standard update framework for Mac apps. The app downloads updates from GodUsage's own release feed and verifies them before they install.

## How it works

- **Automatic checks.** The app checks for a new version in the background about once an hour. When one is found, an **Update Available** banner appears at the top of the popover. Click **Install Update** to open the update window (release notes, download, install). The banner's close button snoozes it until the next time the app finds the update.
- **Manual check.** Press **⌘U** in the popover, choose **Check for Updates…** in the gear menu, or open **Settings → Advanced → Updates** and click **Check for Updates…**. For manual checks and banner installs, GodUsage closes the popover and brings itself to the foreground before opening Sparkle so the update window is not buried behind another app. Because GodUsage normally lives only in the menu bar, it briefly shows a Dock icon for the update session, then hides it again.
- **Homebrew installs.** An app installed with `brew install --cask federico-app/tap/godusage` updates itself the same way. `brew upgrade` skips it because the cask is marked as auto-updating. See [Releasing](releasing.md#homebrew).
- **Turn it off.** The **Update Automatically** switch in **Settings → Advanced → Updates** stops the background checks. You can still check manually.

![Stable-only update settings](assets/updates-stable-only.png)

## Where updates come from

**GodUsage DEV**, the development build from the `develop` branch, reads its own feed (`appcast-dev.xml`) and only ever updates to newer DEV builds. The release app reads `appcast.xml` and only updates to stable releases. See [Releasing](releasing.md#dev-channel).


GodUsage publishes update builds on its GitHub releases and serves the list of versions (the appcast) from `https://federico-app.github.io/godusage/appcast.xml`. That address is baked into every shipped app, and it is the same GitHub Pages site as the [landing page](https://federico-app.github.io/godusage/). Keep it working: a release that moves the feed must ship before the old address goes away.

Each download is signed two ways, Apple notarization plus GodUsage's own Sparkle signature, and the app refuses anything that does not match. Updates are only available in the official signed release build, not in local developer builds.
