# BrewWatcher

A macOS menu bar app that monitors Homebrew packages and reminds the user to upgrade them. Inspired by the lowtechguys family of single-purpose menu bar utilities (Rectangle, Lunar, Clop).

## What it does

Lives in the menu bar. Polls `brew outdated` every 6 hours and shows a count badge when packages can be upgraded. Clicking the menu bar icon reveals a list of outdated packages with versions, plus an "Upgrade all" button. During upgrade, parses `brew upgrade --verbose` output in real time to show per-package progress (X/Y count, current package name, download percentage, install status).

If Homebrew isn't installed when the app launches, shows a welcome view that opens Terminal.app with the official install script and polls in the background until brew becomes available.

## Architecture

Single-file SwiftUI app (`BrewWatcherApp.swift`). Deliberately not split into modules — the whole app is small enough that one file is easier to navigate than a folder tree.

Key types:
- **`BrewWatcherApp`** — `@main` entry, declares the `MenuBarExtra` scene. Icon name varies by `brewState`.
- **`BrewMonitor`** (`@MainActor`, `ObservableObject`) — owns all state and side effects. Holds the periodic check timer and the install-polling timer. All `@Published` properties; views observe.
- **`BrewState`** enum (`notInstalled` / `installing` / `ready`) — drives which top-level view renders.
- **`OutdatedPackage`** / **`OutdatedResponse`** — Decodable models for `brew outdated --json=v2`.
- **`UpgradeProgress`** — value type tracking total, completed, current package, status string, and per-package percent. `overallFraction` blends completed count with in-progress percent so the bar moves continuously.
- **`LineBuffer`** — thread-safe accumulator that splits on both `\n` and `\r`. The `\r` handling matters because brew uses carriage returns to rewrite progress lines in place.
- **`MenuView`** — top-level view that switches on `brewState`. Subviews: `notInstalledView`, `installingView`, `readyView` (with header / progress / content / actions / footer).

## Subprocess handling

Two helpers on `BrewMonitor`:

- **`runBrew(_:)`** — runs brew to completion and returns all stdout as Data. Used for `update`, `outdated`, `cleanup`.
- **`runBrewStreaming(_:onLine:)`** — uses `readabilityHandler` on the pipes to feed lines to a callback as they arrive. Used for `upgrade` so the UI can show progress.

Both use `makeProcess(args:)` which:
- Resolves brew binary from `/opt/homebrew/bin/brew` (Apple Silicon) or `/usr/local/bin/brew` (Intel)
- Sets a sane PATH so brew can find its own helpers
- Sets `HOMEBREW_NO_AUTO_UPDATE`, `HOMEBREW_NO_ANALYTICS`, `HOMEBREW_NO_ENV_HINTS`, `HOMEBREW_NO_COLOR`

## Parsing brew output

`parseUpgradeLine(_:)` watches for these markers in `brew upgrade --verbose` output:

| Pattern | Meaning |
|---|---|
| `==> Fetching X` | Sets current package, status = "Hämtar" |
| `==> Downloading` | status = "Laddar ner" |
| `==> Upgrading X 1.2 -> 1.3` | Sets current package, status = "Förbereder" |
| `==> Pouring` / `==> Installing` | status = "Installerar" |
| `🍺` (in any line) | Increments `completed` |
| `XX.X%` anywhere in line | Sets `packagePercent` |

The text format is **not a stable API** — brew can change these strings between versions. Parsing is defensive: unknown lines are ignored. Worst case after a brew update is that some status text becomes stale; the `🍺` counter is the most stable signal and should keep working.

## The JSON API is stable

`brew outdated --json=v2` is versioned and stable. The "check" flow is safe across brew updates. The "upgrade progress" flow is the fragile part.

## Homebrew install flow

When `brewPath` is nil at launch, the app shows a welcome view. Clicking "Install Homebrew" calls `installBrew()`, which uses AppleScript to open Terminal.app with the official curl install command pre-typed. The user sees and authorizes everything in Terminal — we never handle sudo ourselves.

After Terminal opens, `startPollingForBrew()` runs a 3-second timer (10-minute timeout) checking whether brew has appeared on disk. When found, transitions to `.ready`, kicks off a first check, and starts the regular 6-hour timer.

## Notifications

Uses `osascript display notification` rather than `UserNotifications`. Tradeoff: no permission prompt, no rich notifications with actions, but it just works for a single-purpose utility like this.

## Icon

Squircle background with a warm amber gradient (`#FFC062` → `#D9760F`). A beer mug with golden beer, foam top, and two large cartoon eyes positioned mid-glass to convey the "watcher" theme without being literal (no magnifying glass, no surveillance imagery). Source is `BrewWatcherIcon.svg`; rendered to all required sizes in `AppIcon.appiconset/`.

If you regenerate the icon set from the SVG, use `rsvg-convert` or `cairosvg` at sizes 16, 32, 64, 128, 256, 512, 1024 and map to the filenames in `AppIcon.appiconset/Contents.json` (1x and 2x variants share the same rendered pixel size — e.g. `icon_16x16@2x.png` is the 32px render).

## Build / release / distribute

- **macOS deployment target**: 14.0 (Sonoma). `MenuBarExtra` only needs 13.0, but the menu bar icon uses `mug` / `mug.fill` SF Symbols which were introduced in macOS 14. If you need to support Ventura, swap those for an older symbol (e.g. `cup.and.saucer.fill`) and drop the target back to 13.0.
- **App Sandbox must be OFF**. Sandboxed apps can't spawn `/opt/homebrew/bin/brew` as a subprocess. This rules out App Store distribution.
- **Info.plist**: `LSUIElement = YES` (no Dock icon, menu bar only).
- **Signing**: Developer ID Application certificate, hardened runtime enabled.
- **Release pipeline**: `release.sh` does xcodebuild → codesign → DMG → notarytool submit → stapler staple. Requires a keychain profile created via `xcrun notarytool store-credentials` (see `release.sh` and `README.md` for the one-time setup).
- **Distribution**: GitHub Releases for the DMG, plus a Homebrew Cask formula with `livecheck` strategy `:github_latest`. The cask bot auto-detects new releases and opens PRs to `homebrew/homebrew-cask`. Updates reach users via `brew upgrade` — fitting for an app whose entire purpose is reminding people to run `brew upgrade`.

## Common pitfalls

- **`ObservableObject` doesn't compile**: add `import Combine`. SwiftUI usually re-exports it but sometimes the synthesis breaks with `@MainActor`.
- **Same outdated packages stick around after upgrade**: don't use `--greedy` on `brew outdated` — it lists self-updating casks (Chrome, Slack) that `brew upgrade` won't touch without the same flag. Asymmetric flags create permanent "outdated" entries.
- **Brew can't be found from a GUI app even though it works in Terminal**: GUI apps inherit a minimal PATH. Always resolve the full binary path in code and set PATH explicitly in the subprocess environment.
- **Stuck progress bar after a brew version bump**: the verbose-output strings may have changed. Check `parseUpgradeLine` first.
- **Sandbox sneaks back in**: Xcode adds it by default for new macOS app templates. Verify in Signing & Capabilities before each release.

## Things explicitly not in scope

- **App Store distribution** — incompatible with how the app works (see sandbox note above).
- **Custom UserNotifications** — `osascript` is sufficient.
- **Sparkle auto-updates** — Homebrew Cask handles updates. Don't double up; the two can race on sha256 checks.
- **Selective upgrades** ("upgrade only these packages") — keep the UI single-purpose. If a user wants surgical control, they'll use the terminal.
- **Settings UI for check interval** — wire to `@AppStorage` if/when actually needed. YAGNI for now.

## Project context for AI assistants

The user (Rickard) is a Swedish full-stack developer comfortable with Swift, web stacks, infrastructure, and hardware projects. The app's UI is localized: source strings are in English (the default), with Swedish translations in `BrewWatcher/Localizable.xcstrings`. Use `Text("...")` / `Button("...")` / `Label("...", systemImage:)` with English literals in views (SwiftUI auto-localizes via `LocalizedStringKey`), and `String(localized: "...")` or `LocalizedStringResource` for strings stored outside views (errors, notification bodies, `UpgradeProgress.status`). When you add a new user-facing string, add it to `Localizable.xcstrings` with a Swedish translation. Code, comments, and identifiers remain in English. The user prefers concrete, opinionated technical answers over hedged ones, and appreciates being told when an approach has a hidden gotcha rather than discovering it later.
