# BrewWatcher

A macOS menu bar app that watches your Homebrew packages and reminds you to upgrade them.

Lives in the menu bar, checks `brew outdated` every 6 hours, and shows a badge when packages can be upgraded. Click it for the list, hit **Upgrade all**, and watch per-package progress as brew works.

## Install

```sh
brew tap orangelabweb/tap
brew install --cask brewwatcher
```

Updates arrive the same way everything else does:

```sh
brew upgrade
```

Or grab the DMG from [Releases](https://github.com/orangelabweb/brew-watcher/releases).

Requires **macOS 14 (Sonoma)** or later, and Homebrew — though if Homebrew is missing, the app walks you through installing it.

## What it does

- Badges the menu bar icon with the number of outdated packages
- Lists them with installed → available versions
- **Upgrade all** with live progress: X/Y packages, current package, download percentage
- Checks every 6 hours, notifies when something's upgradeable
- Optional launch at login
- Offers to install Homebrew if it isn't there

It skips pinned packages, because `brew upgrade` skips them too — counting something you can't act on just leaves a badge that never clears.

Some casks need administrator rights. Rather than ask for your password, BrewWatcher hands off to Terminal so you can see exactly what runs and type it there. The app never brokers credentials.

## Building from source

Open `BrewWatcher.xcodeproj` and build (⌘R). No dependencies.

Two settings matter:

- **App Sandbox must be off.** A sandboxed app can't run `/opt/homebrew/bin/brew` as a subprocess. Xcode re-adds the sandbox to new macOS targets by default, so check Signing & Capabilities if brew suddenly can't be found.
- **`LSUIElement = YES`** keeps it out of the Dock.

Notifications only work in a properly signed build. An ad-hoc signed build fails with `UNErrorDomain Code=1 "Notifications are not allowed for this application"` regardless of where it lives; a Developer ID build is authorized immediately.

Architecture notes and the reasoning behind the trickier parts live in [`CLAUDE.md`](CLAUDE.md).

## Releasing

`release.sh` builds, signs, packages a DMG, notarizes it with Apple, and staples the ticket.

One-time setup:

1. An Apple Developer Program membership and a Developer ID Application certificate
2. An [app-specific password](https://appleid.apple.com)
3. Store the notarization credentials in your keychain:

   ```sh
   xcrun notarytool store-credentials "brewwatcher-notary" \
     --apple-id "you@example.com" \
     --team-id "YOUR_TEAM_ID" \
     --password "app-specific-password"
   ```

Then `./release.sh`. Bump `MARKETING_VERSION` first — the cask's `livecheck` watches GitHub Releases, and the DMG is named after the version.

After the release is published, update `version` and `sha256` in the [tap](https://github.com/orangelabweb/homebrew-tap).

## Why a tap and not homebrew/homebrew-cask

The official cask repository rejects apps whose upstream repository isn't notable enough. For self-submitted casks — where the PR author owns the repository — the thresholds are 90 forks, 90 watchers, or 225 stars ([Acceptable Casks](https://docs.brew.sh/Acceptable-Casks#rejected-casks)). That check is automated. Until BrewWatcher clears it, the tap is the way in.

## License

[MIT](LICENSE)
