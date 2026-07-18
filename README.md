# Glancekit

A modular macOS menu bar suite for glancing at everything that matters — all in one place. Fully extensible, with no limit on what gets added next.

Glancekit lives in your menu bar and surfaces at-a-glance information from a growing set of independent **glances** (plugins) — weather, stocks, GitHub activity, system stats, photos, and more. Click the menu bar item for a rich popover; each glance renders its own section and refreshes on its own schedule.

> **Requirements:** macOS 14.0+ and Xcode 15+ (Swift, SwiftUI, WidgetKit).

## Features

- **Menu bar first** — an unobtrusive status-bar icon, a detailed popover on click.
- **Modular glances** — each glance is a self-contained plugin that touches only its own folder.
- **Home Screen / Notification Center widgets** — via the bundled WidgetKit extension.
- **Secrets kept out of preferences** — secrets go through a dedicated `CredentialStore`, which keeps them in a `0600` file in Application Support, never `UserDefaults`. This guards against other users on the machine, not against code running as you; `CredentialStore.swift` documents the trade-off.
- **Independent refresh** — every glance sets its own refresh interval; a shared coordinator handles the rest.
- **Per-glance settings** — configure each glance from a unified Settings window.

## Built-in glances

| Glance | What it shows |
| --- | --- |
| Weather | Current conditions for your location |
| Stocks | Live quotes for tickers you follow |
| GitHub | Your recent GitHub activity |
| Photos | A rotating look at your library |
| System | CPU, memory, and other system stats |
| Time & Productivity | World clocks, your next event, reminders, a countdown |
| Pomodoro | Focus/break cycles with long breaks and a session tally |
| Colors | Eyedrop any pixel, dial in a shade, keep favorites |
| Custom API | Point a glance at any JSON endpoint |

## Install

### One-line install (recommended)

Download and install the latest release straight to `/Applications` — no clone,
no Xcode, no build:

```bash
curl -fsSL https://raw.githubusercontent.com/casualattitude0/glancekit/main/scripts/install-release.sh | bash
```

Pin a specific version with `GLANCEKIT_VERSION`:

```bash
curl -fsSL https://raw.githubusercontent.com/casualattitude0/glancekit/main/scripts/install-release.sh | GLANCEKIT_VERSION=v1.0.2 bash
```

The script downloads the latest release `.zip`, installs it **in place** (so
widgets you have already placed keep their settings), strips the download
quarantine so Gatekeeper won't block the ad-hoc-signed app, refreshes the widget
daemon, and launches Glancekit. macOS only.

### From the `.dmg`

1. Download `Glancekit.dmg` and open it.
2. Drag **Glancekit** onto the **Applications** folder.
3. Launch Glancekit from Applications — it appears in your menu bar.

> Because the app is ad-hoc signed (not notarized), the first launch may show a
> Gatekeeper warning. Right-click the app and choose **Open**, or allow it under
> System Settings ▸ Privacy & Security.

### Build the `.dmg` yourself

```bash
git clone https://github.com/casualattitude0/glancekit.git
cd glancekit
./make-dmg.sh            # build in Release, package -> dist/Glancekit.dmg
```

The script builds with `xcodebuild` and packages the app into a disk image with a
drag-to-install Applications shortcut. Use `-o <path>` to change the output location.

### Build and install for development

```bash
scripts/install.sh       # build, install to /Applications, refresh the widget daemon
```

This is the only sanctioned way to get a smoke-testable install into
`/Applications`. It updates `/Applications/Glancekit.app` in place, so widgets you
have already placed keep their saved settings. Smoke-test
`/Applications/Glancekit.app` and nothing else: any other copy of the app
re-registers the same widget extension bundle id and can shadow the installed one,
which makes the widget gallery serve a stale widget that ignores its saved config.

Two things to know before you run it:

- **It builds `-configuration Debug`**, not Release. If you need a Release build,
  use `./make-dmg.sh`.
- **It deletes competing copies, it does not just unregister them.** The script
  lists every `*/Glancekit.app` in the `lsregister` dump, and for each path that is
  not `/Applications/Glancekit.app` or its own fresh build it runs
  `lsregister -u` **and `rm -rf`**. That reaches any Glancekit.app anywhere on
  disk, including `~/Downloads/Glancekit.app` unpacked from a `.dmg` and a mounted
  `/Volumes/Glancekit/Glancekit.app`. It prints each path as it removes it. Move
  copies you want to keep out of the way, or rename them, before running it.

### Open in Xcode

Open `Glancekit.xcodeproj`, select the **Glancekit** scheme, and run.

Use this for editing, debugging, and previews. Know what a Run costs you:

- It builds into `~/Library/Developer/Xcode/DerivedData`, which is Spotlight
  indexed, so a second **Glancekit** icon appears in Launchpad next to the one
  from `/Applications`.
- The DerivedData copy registers the same widget extension bundle id and can win
  over `/Applications/Glancekit.app`. The widget then renders from the stale
  DerivedData build and ignores its saved config.

So do not treat an Xcode Run as an install, and do not smoke-test its build
product. Check for extra copies with:

```bash
mdfind "kMDItemFSName == 'Glancekit.app'"
```

The purge loop in `scripts/install.sh` removes the DerivedData copy on your next
install, which puts `/Applications/Glancekit.app` back in charge. Deleting the
DerivedData bundle by hand only lasts until the next Run.

See [`CLAUDE.md`](CLAUDE.md) for the full rules on build locations and what does
not fix this.

## Writing your own glance

Glances are plugins that conform to the `GlancePlugin` protocol. Each is a `@MainActor @Observable final class` that lives entirely in its own `Glancekit/Plugins/<YourName>/` folder — it never touches core, UI, or other plugins.

```swift
@MainActor
protocol GlancePlugin: AnyObject {
    var id: String { get }                     // stable, unique, lowercase
    var title: String { get }                  // shown in Settings + popover
    var iconSystemName: String { get }         // SF Symbol
    var refreshInterval: TimeInterval { get }  // seconds; 0 = refresh once on start
    func refresh() async                       // fetch/recompute; never throws
    func popoverSection() -> AnyView           // rich popover content
    func settingsSection() -> AnyView          // per-glance settings (optional)
}
```

The **Stocks** plugin is the worked reference. See [`Glancekit/Core/PLUGIN_CONTRACT.md`](Glancekit/Core/PLUGIN_CONTRACT.md) for the full contract and rules.

## Project layout

```
Glancekit/
  Core/        Plugin framework, registry, networking, credential store
  Plugins/     Built-in glances (one folder each)
  UI/          Menu bar, popover, onboarding
  Settings/    Settings window
GlancekitWidgets/   WidgetKit extension
scripts/
  install-release.sh  Download the latest release & install to /Applications (curl | bash)
  install.sh          Build & install straight to /Applications (dev helper)
make-dmg.sh         Build & package a distributable .dmg
```

## License

[MIT](LICENSE) © 2026 Aaron Xue
