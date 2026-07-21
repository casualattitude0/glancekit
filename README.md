# Glancekit

A modular macOS menu bar suite for glancing at everything that matters — all in one place. Fully extensible, with no limit on what gets added next.

Glancekit lives in your menu bar and surfaces at-a-glance information from a growing set of independent **glances** (plugins) — weather, stocks, GitHub activity, Mac health, world clocks, your next meeting, and many more. Click the menu bar item for a rich popover; each glance renders its own section and refreshes on its own schedule. Pop any glance out into its own standalone window, and let the **Smart Panel** surface only the glances that need attention right now.

> **Requirements:** macOS 14.0+ and Xcode 15+ (Swift, SwiftUI, WidgetKit).

## Features

- **Menu bar first** — an unobtrusive status-bar icon, a detailed popover on click.
- **Modular glances** — each glance is a self-contained plugin that touches only its own folder. Twenty ship built in.
- **Smart Panel** — a dynamic menu-bar layout that promotes only the glances signalling something worth your attention, and stays out of the way otherwise.
- **Standalone tool windows** — pop any glance out of the popover into its own resizable window, sized to fit its content.
- **Home Screen / Notification Center widgets** — via the bundled WidgetKit extension.
- **AI Assistant glance** — a chat that can call your other glances as tools and trigger a refresh on demand.
- **Secrets kept out of preferences** — secrets go through a dedicated `CredentialStore`, which keeps them in a `0600` file in Application Support, never `UserDefaults`. This guards against other users on the machine, not against code running as you; `CredentialStore.swift` documents the trade-off.
- **Independent refresh** — every glance sets its own refresh interval; a shared coordinator handles the rest.
- **Per-glance settings** — configure each glance from a unified Settings window, organized by category.

## Built-in glances

Glances are grouped into categories in Settings.

### System

| Glance | What it shows |
| --- | --- |
| Mac Health | CPU, memory, disk, throughput, and other system stats |
| Power | Battery health %, cycle count, temperature, adapter wattage, and a charge-history sparkline |
| Network | Reachability/latency probes against your own list of hosts, plus VPN and throughput |

### Productivity

| Glance | What it shows |
| --- | --- |
| Notes | A quick-capture field and a list of everything you've saved — local and private |
| Habits | Daily habits with completion streaks |
| Pomodoro | Focus/break cycles with long breaks and a session tally |
| Reminders | Your open reminders grouped by overdue, today and upcoming — tick them off in place |
| Countdowns | Any number of named countdowns to a date, ticking live and sorted soonest-first |
| Timers | Multiple concurrent countdown timers plus a stopwatch |
| Next Meeting | A live countdown ring, one-click Join, and today's remaining agenda |

### Finance

| Glance | What it shows |
| --- | --- |
| Stocks | Live quotes for tickers you follow, across Taiwan, the US and Japan |
| Currency | A base currency tracked against a list of targets |

### Developer

| Glance | What it shows |
| --- | --- |
| GitHub | Your recent GitHub activity |
| Colors | Eyedrop any pixel, dial in a shade, keep favorites |
| Custom API | Point a glance at any JSON endpoint |

### Utilities

| Glance | What it shows |
| --- | --- |
| Assistant | A chat that can call your other glances as tools |
| Weather | Current conditions for your location |
| Photos | A rotating look at your library |
| World Clock | Live-ticking clocks with day/night and GMT offsets |
| Feeds | RSS/Atom feeds merged with the Hacker News front page into one reading list |
| Clipboard | A searchable history of recent clipboard entries |

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
    var id: String { get }                        // stable, unique, lowercase — the persistence key
    var title: String { get }                     // shown in Settings + popover
    var iconSystemName: String { get }            // SF Symbol
    var category: GlanceCategory { get }           // Settings grouping (has a default)
    var refreshInterval: TimeInterval { get }     // seconds; 0 = opt out of the shared refresh loop
    func refresh() async                          // fetch/recompute; never throws
    var requiredPermissions: [GlancePermission] { get }  // shown as a grant prompt (default: none)
    func currentSignal() -> GlanceSignal?         // relevance for the Smart Panel (default: nil)
    func popoverSection() -> AnyView              // rich popover content
    func settingsSection() -> AnyView             // per-glance settings (default: empty)
    var preferredToolWindowSize: CGSize? { get }  // standalone-window size (default: automatic)
    var fillsToolWindow: Bool { get }             // manage own layout in the tool window (default: false)
}
```

Most requirements have defaults, so a minimal glance implements only `id`, `title`, `iconSystemName`, `refresh()`, and `popoverSection()`. The **Stocks** plugin is the worked reference. See [`docs/PLUGIN_CONTRACT.md`](docs/PLUGIN_CONTRACT.md) for the full contract and rules.

## Project layout

```
Glancekit/
  Core/        Plugin framework, registry, refresh coordinator, Smart Panel signals,
               networking, credential store, hotkeys, update checker
  Plugins/     Built-in glances (one folder each)
  UI/          Menu bar, popover, Smart Panel, tool windows, onboarding, tutorial
  Settings/    Settings window
GlancekitWidgets/   WidgetKit extension
scripts/
  install-release.sh  Download the latest release & install to /Applications (curl | bash)
  install.sh          Build & install straight to /Applications (dev helper)
make-dmg.sh         Build & package a distributable .dmg
```

## License

[MIT](LICENSE) © 2026 Aaron Xue
