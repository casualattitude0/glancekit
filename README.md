# Glancekit

A modular macOS menu bar suite for glancing at everything that matters — all in one place. Fully extensible, with no limit on what gets added next.

Glancekit lives in your menu bar and surfaces at-a-glance information from a growing set of independent **glances** (plugins) — weather, stocks, GitHub activity, system stats, photos, and more. Click the menu bar item for a rich popover; each glance renders its own section and refreshes on its own schedule.

> **Requirements:** macOS 14.0+ and Xcode 15+ (Swift, SwiftUI, WidgetKit).

## Features

- **Menu bar first** — an unobtrusive status-bar icon, a detailed popover on click.
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
| Colors | Eyedrop any pixel, dial in a shade, keep favorites |
| Custom API | Point a glance at any JSON endpoint |

## Install

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
make-dmg.sh         Build & package a distributable .dmg
install.sh          Build & install straight to /Applications (dev helper)
```

## License

[MIT](LICENSE) © 2026 Aaron Xue
