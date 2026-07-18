# Glancekit Plugin Contract

Read this before writing a glance. The **Stocks** plugin
(`Plugins/Stocks/StocksPlugin.swift` + `QuoteProvider.swift`) is the worked
reference — mirror its structure.

## The protocol (`Core/GlancePlugin.swift`)

```swift
@MainActor
protocol GlancePlugin: AnyObject {
    var id: String { get }                 // stable, unique, lowercase — persistence key
    var title: String { get }              // shown in Settings + popover header
    var iconSystemName: String { get }     // SF Symbol
    var refreshInterval: TimeInterval { get }  // seconds; 0 = refresh once on start only
    func refresh() async                   // fetch/recompute; never throws — store errors internally
    func popoverSection() -> AnyView       // rich popover content
    func settingsSection() -> AnyView      // per-glance settings (defaults to empty)
}
```

Defaults exist for `refreshInterval` (0), `settingsSection()` (empty), and
`currentSignal()` (nil) — override only what you need.

### The Smart Panel signal (optional)

The menu-bar panel has a dynamic layout — the **Smart Panel** — that surfaces
only the glances that need attention right now, ranked by urgency. To take part,
override:

```swift
func currentSignal() -> GlanceSignal?   // Core/GlanceSignal.swift; default nil
```

Compute it from the state you already hold after `refresh()` and return `nil`
when there's nothing worth surfacing. Pick a `priority` (`ambient` < `normal` <
`elevated` < `urgent`), a `score` (tiebreak within a priority), and a compact
`headline`. Optional `detail`, `systemImage`, and `tint` refine the card. See
`SystemStatsPlugin`/`StocksPlugin` for worked examples. Glances with nothing
time-sensitive to say (e.g. Colors) just keep the `nil` default.

## Rules (non-negotiable)

1. **Your plugin is a `@MainActor @Observable final class` conforming to `GlancePlugin`.**
   Being `@Observable` is what makes SwiftUI re-render after `refresh()`.
2. **Touch ONLY your own `Plugins/<YourName>/` folder.** Create every file there.
   Do NOT modify any file under `Core/`, `UI/`, `Settings/`, or another plugin.
   Do NOT edit `GlancekitApp.swift` — registration is done in Stage 3.
3. **Consume core types, don't redefine them.** Use `NetworkClient` for HTTP,
   `CredentialStore` for any secret (API key / token / headers). Never put a
   secret in `UserDefaults`. Use `UserDefaults` only for non-secret prefs, with
   keys namespaced `glancekit.<id>.<name>`.
4. **`refresh()` must not throw and must not crash on missing input.** No
   credentials / empty config → set a friendly error string for the popover and
   return. The verdict checklist tests this.
5. **No cross-plugin imports.** Plugins are independent.
6. **Language mode is Swift 5** (`SWIFT_VERSION = 5.0`), macOS 14+ deployment.
   Views returned from `popoverSection()`/`settingsSection()` must be wrapped in
   `AnyView`. Keep private view structs `private` to avoid name collisions.
7. **Naming:** main type `‹Name›Plugin`, `id` a short lowercase string. Prefix
   any type that could collide (e.g. a `Settings` view) — Stocks uses
   `private struct StocksSettings`.

## Skeleton to copy

```swift
import SwiftUI
import Observation

@MainActor
@Observable
final class ExamplePlugin: GlancePlugin {
    nonisolated var id: String { "example" }
    nonisolated var title: String { "Example" }
    nonisolated var iconSystemName: String { "star" }
    var refreshInterval: TimeInterval { 60 }

    private(set) var lastError: String?
    // ... your @Observable state ...

    func refresh() async {
        do { /* fetch via NetworkClient; update state */ }
        catch { lastError = error.localizedDescription }
    }

    func popoverSection() -> AnyView { AnyView(ExamplePopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(ExampleSettings(plugin: self)) }
}

private struct ExamplePopover: View {
    let plugin: ExamplePlugin
    var body: some View { /* ... */ Text("hi") }
}

private struct ExampleSettings: View {
    @Bindable var plugin: ExamplePlugin
    var body: some View { /* ... */ EmptyView() }
}
```

Note: `id`/`title`/`iconSystemName` are marked `nonisolated` so they can be read
off the main actor cheaply (see Stocks). `refreshInterval` and mutable state
stay main-actor.

## Permissions (system-gated glances)

If your feature needs a system permission (Calendar, Reminders, Photos, etc.),
DO NOT render the feature until it's granted. Implement `requiredPermissions`
(default `[]`) to return the permissions that are *currently relevant and not yet
granted*. The popover automatically shows a grant prompt for them and reveals
`popoverSection()` only once all are granted — you don't render the gate yourself.

- Return `[]` when the permission isn't needed right now (e.g. Photos only needs
  it in `.photosLibrary` mode; Time & Productivity only for enabled EventKit
  features). See `PhotosPlugin`/`TimeProductivityPlugin` for worked examples.
- Each `GlancePermission` supplies live `status`, an async `request`, and a
  System Settings deep link for the denied case.
- Network APIs (Stocks/GitHub/Custom API) are NOT system permissions — no gate.

## Deliverable

- A self-contained `Plugins/<Name>/` folder that compiles.
- The **one registration line** to add in Stage 3, reported back verbatim, e.g.
  `registry.register(SystemStatsPlugin())`.
- If your plugin needs an Info.plist usage string or entitlement, state it — do
  NOT edit project settings yourself (Stage 3 handles it). Calendar/Reminders/
  Photos usage strings are already present in the project.

## Verdict checklist (Stage 3 will verify)

- [ ] Compiles as part of `xcodebuild -scheme Glancekit build` with zero errors.
- [ ] Appears in Settings' Glances list and can be toggled/reordered.
- [ ] `popoverSection()` renders non-empty content when enabled.
- [ ] `refresh()` with empty/missing credentials does not crash — shows a message.
