# CI runner

Every macOS job (CI's Build and Test and Build iOS App, the DEV release, the production release, and TestFlight) runs on self-hosted runners on a maintainer's Apple silicon Mac, not on GitHub's macOS runners, which were slow and unreliable. Linux jobs (the backend, the feed, the landing page) stay on GitHub's `ubuntu-latest`.

The macOS jobs ask for `[self-hosted, macOS, ARM64, godusage]`, so they wait in the queue while no runner is online: the Mac must be on and logged in for checks and releases to run.

## Setup

1. A repo admin creates a registration token: Settings → Actions → Runners → **New self-hosted runner**, or `gh api -X POST repos/federico-app/godusage/actions/runners/registration-token --jq .token`. It expires after an hour.
2. On the Mac, run `script/setup_ci_runner.sh <token>`. It downloads the latest runner (checking its checksum), registers two runners (`<host>-1`, `<host>-2`, so two jobs can run at once) under `~/actions-runners/godusage`, and installs each as a launchd agent that starts at login. `gh`, `jq`, and `node` must be installed.
3. The first DMG build asks to let the runner control Finder (it lays out the DMG window). Allow it once.

The jobs build with the newest stable Xcode in `/Applications` (betas are skipped), or the one `GODUSAGE_XCODE` names when you run the script. The script writes it into each runner's `.env`, and each job sets `DEVELOPER_DIR` from it, since a runner can't `sudo xcode-select`. After installing a newer Xcode, edit `GODUSAGE_XCODE` in `~/actions-runners/godusage/runner-*/.env` and restart the runners (`./svc.sh stop && ./svc.sh start` in each folder).

## Safety

The repo is public, so CI's macOS jobs skip pull requests from forks: a stranger's PR never runs code on the Mac. Only branches of this repo run there. Also keep **Require approval for all external contributors** on in Settings → Actions.

Signing jobs import their certificate into a temporary keychain named after the run and job, and remove it when the job ends, so two jobs at once never clash. The certificates, notary key, and Sparkle key come from the repo secrets for each run and are not kept on the Mac.

## Removing a runner

In the runner's folder: `./svc.sh stop && ./svc.sh uninstall`, then `./config.sh remove --token <removal token>` (an admin creates it from the runner's page in Settings → Actions → Runners).
