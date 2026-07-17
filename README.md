# Glancekit

A modular macOS menu bar suite for glancing at everything that matters — all in one place. Fully extensible, with no limit on what gets added next.

Glancekit lives in your menu bar and surfaces compact, at-a-glance information from a growing set of independent **glances** (plugins) — weather, stocks, GitHub activity, system stats, photos, and more. Click the menu bar item for a rich popover; each glance renders its own section and refreshes on its own schedule.

> **Requirements:** macOS 14.0+ and Xcode 15+ (Swift, SwiftUI, WidgetKit).

## Features

- **Menu bar first** — a compact summary in the status bar, a detailed popover on click.
- **Modular glances** — each glance is a self-contained plugin that touches only its own folder.
- **Home Screen / Notification Center widgets** — via the bundled WidgetKit extension.
- **Secure by default** — secrets go through a dedicated `CredentialStore` (Keychain), never `UserDefaults`.
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
| Time & Productivity | Time-of-day and productivity glance |
| Color Picker / Color Palette | Quick color tools |
| Custom API | Point a glance at any JSON endpoint |

## Install

### Build & install from source

```bash
git clone https://github.com/casualattitude0/glancekit.git
cd glancekit
./install.sh            # build in Release, install to /Applications, and launch
```

Options:

```bash
./install.sh --login       # also add Glancekit as a login item (auto-start)
./install.sh --no-launch   # install but don't launch afterwards
```

The script builds with `xcodebuild`, installs to `/Applications`, clears the Gatekeeper quarantine flag, and (optionally) registers a login item.

### Open in Xcode

Open `Glancekit.xcodeproj`, select the **Glancekit** scheme, and run.

## Writing your own glance

Glances are plugins that conform to the `GlancePlugin` protocol. Each is a `@MainActor @Observable final class` that lives entirely in its own `Glancekit/Plugins/<YourName>/` folder — it never touches core, UI, or other plugins.

```swift
@MainActor
protocol GlancePlugin: AnyObject {
    var id: String { get }                     // stable, unique, lowercase
    var title: String { get }                  // shown in Settings + popover
    var iconSystemName: String { get }         // SF Symbol
    var refreshInterval: TimeInterval { get }  // seconds; 0 = refresh once on start
    var menuBarSummary: String? { get }        // compact status-bar text; nil = popover-only
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
install.sh          Build & install helper
```

## License

[MIT](LICENSE) © 2026 Aaron Xue
