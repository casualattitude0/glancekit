import SwiftUI

@main
struct GlancekitApp: App {
    @State private var registry: PluginRegistry
    @State private var coordinator: RefreshCoordinator
    @State private var updater = UpdateChecker()
    @State private var hotkeys: HotkeyCenter
    @State private var quickSwitch: QuickSwitchStore
    @State private var tutorial: TutorialController
    @State private var panelSettings = MenuPanelSettings()
    @State private var panelHistory = SmartPanelHistory()

    init() {
        let registry = PluginRegistry()
        // Built up front (not at line ~60) because AIPlugin needs it at
        // registration time to drive its enable/disable tools.
        let coordinator = RefreshCoordinator(registry: registry)

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
        registry.register(ClipboardPlugin())
        registry.register(CurrencyPlugin())
        registry.register(FeedsPlugin())
        registry.register(TimersPlugin())
        registry.register(HabitsPlugin())
        registry.register(PowerPlugin())
        registry.register(NetworkPlugin())
        registry.register(WorldClockPlugin())
        registry.register(NextMeetingPlugin())
        registry.register(AIPlugin(registry: registry, coordinator: coordinator))
        // ──────────────────────────────────────────────────────────────────

        // Seed after registration so the ring knows every glance that exists.
        let quickSwitch = QuickSwitchStore()
        quickSwitch.seed(with: registry.plugins.map(\.id))

        // ── Global shortcuts ──────────────────────────────────────────────
        // Every glance gets an action that toggles its tool window open at the
        // mouse (Colors on ⌥1, Notes on ⌥2 by default; the rest start unbound);
        // Quick Switch steps through the ring (⌥⇥); Open Settings fronts the
        // Settings window (⌥`). All are rebindable on the Shortcuts settings
        // page. The glance actions are derived from the registry, so registering
        // a new plugin makes it assignable with no wiring change here.
        let hotkeys = HotkeyCenter(glancePluginIDs: registry.plugins.map(\.id))
        for action in hotkeys.allActions {
            hotkeys.setHandler(for: action) {
                switch action {
                case .quickSwitch:
                    ToolWindowManager.shared.quickSwitch(
                        among: quickSwitch.ring(in: registry),
                        // The Assistant is pinned independently of the ring, so it
                        // stays reachable even when the user hasn't included it —
                        // the "get AI help, jump back" affordance.
                        assistant: registry.plugin(id: "ai"),
                        shortcut: hotkeys.shortcut(for: .quickSwitch)?.displayString
                    )
                case .settings:
                    SettingsWindowPresenter.toggle()
                case .openMenubar:
                    MenuBarPresenter.toggle()
                case .glance(let pluginID):
                    guard let plugin = registry.plugin(id: pluginID) else { return }
                    ToolWindowManager.shared.toggle(plugin: plugin)
                }
            }
        }
        // ──────────────────────────────────────────────────────────────────

        _registry = State(initialValue: registry)
        _coordinator = State(initialValue: coordinator)
        _hotkeys = State(initialValue: hotkeys)
        _quickSwitch = State(initialValue: quickSwitch)
        _tutorial = State(initialValue: TutorialController(registry: registry))
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environment(registry)
                .environment(coordinator)
                .environment(panelSettings)
                .environment(panelHistory)
                .frame(width: 340)
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
                .environment(tutorial)
                .environment(panelSettings)
        }

        // Standalone first-run window. Opened once on launch by MenuBarLabelView;
        // presenting onboarding inside the MenuBarExtra popover would hide the
        // glances window, so it lives in its own window instead.
        Window("Welcome to Glancekit", id: OnboardingState.windowID) {
            OnboardingView()
                .environment(registry)
                .environment(coordinator)
                .environment(tutorial)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
