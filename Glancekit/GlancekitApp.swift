import SwiftUI

@main
struct GlancekitApp: App {
    @State private var registry: PluginRegistry
    @State private var coordinator: RefreshCoordinator
    @State private var updater = UpdateChecker()
    @State private var hotkeys: HotkeyCenter
    @State private var quickSwitch: QuickSwitchStore

    init() {
        let registry = PluginRegistry()

        // ── Plugin registration ───────────────────────────────────────────
        // Registration order is the default popover order for a new install;
        // the user's own order, once set, overrides it.
        registry.register(StocksPlugin())
        registry.register(SystemStatsPlugin())
        registry.register(TimeProductivityPlugin())
        registry.register(PomodoroPlugin())
        registry.register(PhotosPlugin())
        registry.register(GitHubPlugin())
        registry.register(CustomAPIPlugin())
        registry.register(ColorsPlugin())
        registry.register(WeatherPlugin())
        registry.register(NotesPlugin())
        // ──────────────────────────────────────────────────────────────────

        // Seed after registration so the ring knows every glance that exists.
        let quickSwitch = QuickSwitchStore()
        quickSwitch.seed(with: registry.plugins.map(\.id))

        // ── Global shortcuts ──────────────────────────────────────────────
        // A glance action toggles its tool window open at the mouse (Colors on
        // ⌥1, Notes on ⌥2 by default); Quick Switch steps through the ring
        // (⌥⇥); Open Settings
        // fronts the Settings window (⌥`). All are rebindable on the Shortcuts
        // settings page.
        let hotkeys = HotkeyCenter()
        for action in ShortcutAction.allCases {
            hotkeys.setHandler(for: action) {
                switch action {
                case .quickSwitch:
                    ToolWindowManager.shared.quickSwitch(among: quickSwitch.ring(in: registry))
                case .colors, .notes:
                    guard let plugin = action.pluginID.flatMap(registry.plugin(id:)) else { return }
                    ToolWindowManager.shared.toggle(plugin: plugin)
                case .settings:
                    SettingsWindowPresenter.toggle()
                }
            }
        }
        // ──────────────────────────────────────────────────────────────────

        _registry = State(initialValue: registry)
        _coordinator = State(initialValue: RefreshCoordinator(registry: registry))
        _hotkeys = State(initialValue: hotkeys)
        _quickSwitch = State(initialValue: quickSwitch)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environment(registry)
                .environment(coordinator)
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
                .environment(quickSwitch)
                .environment(updater)
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
