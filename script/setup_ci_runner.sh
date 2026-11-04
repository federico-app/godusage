#!/usr/bin/env bash
# Registers this Mac as the self-hosted GitHub Actions runners that run GodUsage's macOS jobs (CI,
# DEV and production releases, TestFlight) and installs each as a launchd agent in the logged-in
# session, so they start at login and have the GUI session the DMG build needs. See docs/ci-runner.md.
#
#   script/setup_ci_runner.sh <registration-token> [count]
#
# The token comes from a repo admin: Settings → Actions → Runners → New self-hosted runner, or
# `gh api -X POST repos/federico-app/godusage/actions/runners/registration-token --jq .token`.
# It expires after an hour. `count` (default 2) runners let two jobs run at once.
set -euo pipefail

TOKEN="${1:?usage: script/setup_ci_runner.sh <registration-token> [count]}"
COUNT="${2:-2}"
REPO_URL="https://github.com/federico-app/godusage"
ROOT="${GODUSAGE_RUNNER_ROOT:-$HOME/actions-runners/godusage}"
# The Xcode the jobs build with (DEVELOPER_DIR), matching what the GitHub-hosted runners used.
XCODE="${GODUSAGE_XCODE:-/Applications/Xcode 26.6.app}"

[[ "$(uname -m)" == "arm64" ]] || { echo "This script sets up Apple silicon runners only." >&2; exit 1; }
[[ -d "$XCODE/Contents/Developer" ]] || { echo "No Xcode at $XCODE. Set GODUSAGE_XCODE to the Xcode to build with." >&2; exit 1; }
for tool in gh jq node; do
  command -v "$tool" >/dev/null || { echo "$tool is required on the runner (the workflows call it)." >&2; exit 1; }
done

release="$(gh api repos/actions/runner/releases/latest)"
version="$(jq -r '.tag_name | ltrimstr("v")' <<<"$release")"
archive="actions-runner-osx-arm64-$version.tar.gz"
digest="$(jq -r --arg name "$archive" '.assets[] | select(.name == $name) | .digest // empty' <<<"$release")"

mkdir -p "$ROOT"
if [[ ! -f "$ROOT/$archive" ]]; then
  echo "Downloading runner $version…"
  curl -fsSL -o "$ROOT/$archive.part" "https://github.com/actions/runner/releases/download/v$version/$archive"
  if [[ -n "$digest" ]]; then
    actual="sha256:$(shasum -a 256 "$ROOT/$archive.part" | cut -d' ' -f1)"
    [[ "$actual" == "$digest" ]] || { rm -f "$ROOT/$archive.part"; echo "Checksum mismatch for $archive." >&2; exit 1; }
  fi
  mv "$ROOT/$archive.part" "$ROOT/$archive"
fi

host="$(scutil --get LocalHostName)"
for n in $(seq 1 "$COUNT"); do
  dir="$ROOT/runner-$n"
  if [[ -f "$dir/.runner" ]]; then
    echo "runner-$n is already configured; skipping."
    continue
  fi
  mkdir -p "$dir"
  tar -xzf "$ROOT/$archive" -C "$dir"
  (
    cd "$dir"
    # Labels: self-hosted, macOS, ARM64 come by default; `godusage` is what the workflows ask for.
    ./config.sh --unattended --url "$REPO_URL" --token "$TOKEN" --name "$host-$n" --labels godusage --work _work --replace
    printf 'GODUSAGE_XCODE=%s\nLANG=en_US.UTF-8\n' "$XCODE" >> .env
    ./svc.sh install
    ./svc.sh start
  )
  echo "runner-$n is running as $host-$n."
done

echo "Done. The first DMG build asks to let the runner control Finder: allow it once."
