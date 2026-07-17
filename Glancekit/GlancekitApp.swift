import SwiftUI

@main
struct GlancekitApp: App {
    @State private var registry: PluginRegistry
    @State private var coordinator: RefreshCoordinator
    @State private var updater = UpdateChecker()
    @State private var hotkeys: HotkeyCenter

    init() {
        let registry = PluginRegistry()

        // ── Plugin registration ───────────────────────────────────────────
        // Stage 1 registers the flagship. Stage 3 appends one line per plugin
        // that the Stage 2 sub-agents produce, e.g.:
        //   registry.register(SystemStatsPlugin())
        //   registry.register(PhotosPlugin())
        //   registry.register(GitHubPlugin())
        //   registry.register(CustomAPIPlugin())
        //   registry.register(ColorsPlugin())
        registry.register(StocksPlugin())
        registry.register(SystemStatsPlugin())
        registry.register(TimeProductivityPlugin())
        registry.register(PhotosPlugin())
        registry.register(GitHubPlugin())
        registry.register(CustomAPIPlugin())
        registry.register(ColorsPlugin())
        registry.register(WeatherPlugin())
        // ──────────────────────────────────────────────────────────────────

        // ── Global shortcuts ──────────────────────────────────────────────
        // Each action toggles its glance's tool window open at the mouse (⇧⌘1
        // by default; rebindable on the Shortcuts settings page).
        let hotkeys = HotkeyCenter()
        for action in ShortcutAction.allCases {
            hotkeys.setHandler(for: action) {
                guard let plugin = registry.plugin(id: action.pluginID) else { return }
                ToolWindowManager.shared.toggle(plugin: plugin)
            }
        }
        // ──────────────────────────────────────────────────────────────────

        _registry = State(initialValue: registry)
        _coordinator = State(initialValue: RefreshCoordinator(registry: registry))
        _hotkeys = State(initialValue: hotkeys)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environment(registry)
                .environment(coordinator)
                .environment(updater)
                .frame(width: 340)
                .onAppear { coordinator.start() }
        } label: {
            MenuBarLabelView()
                .environment(registry)
                .environment(coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(registry)
                .environment(coordinator)
                .environment(hotkeys)
        }

        // Standalone first-run window. Opened once on launch by MenuBarLabelView;
        // presenting onboarding inside the MenuBarExtra popover would hide the
        // glances window, so it lives in its own window instead.
        Window("Welcome to Glancekit", id: OnboardingState.windowID) {
            OnboardingView()
                .environment(registry)
                .environment(coordinator)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
