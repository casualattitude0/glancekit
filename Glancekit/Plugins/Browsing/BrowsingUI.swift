import SwiftUI
import AppKit

// MARK: - Popover UI

struct BrowsingPopover: View {
    let plugin: BrowsingPlugin
    @State private var search: String = ""
    /// `nil` = all browsers. Only meaningful when more than one is enabled.
    @State private var browserFilter: Browser?

    private func matches(_ entry: BrowsingPlugin.Entry) -> Bool {
        if let browserFilter, entry.browser != browserFilter { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return entry.title.localizedCaseInsensitiveContains(q)
            || entry.url.localizedCaseInsensitiveContains(q)
    }

    private var pinnedFiltered: [BrowsingPlugin.Entry] {
        plugin.sortedEntries.filter { $0.pinned && matches($0) }
    }

    private var unpinnedFiltered: [BrowsingPlugin.Entry] {
        plugin.sortedEntries.filter { !$0.pinned && matches($0) }
    }

    private var todayFiltered: [BrowsingPlugin.Entry] {
        unpinnedFiltered.filter { Calendar.current.isDateInToday($0.timestamp) }
    }

    private var earlierFiltered: [BrowsingPlugin.Entry] {
        unpinnedFiltered.filter { !Calendar.current.isDateInToday($0.timestamp) }
    }

    /// Reorder is only coherent when the Pinned section shows the full pinned set
    /// in its stored order — i.e. no search and no browser narrowing.
    private var canReorder: Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty && browserFilter == nil
    }

    private var nothingToShow: Bool {
        pinnedFiltered.isEmpty && unpinnedFiltered.isEmpty
    }

    private var filterableBrowsers: [Browser] {
        plugin.enabledBrowsers.sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField

            if filterableBrowsers.count > 1 {
                Picker("Browser", selection: $browserFilter) {
                    Text("All").tag(Browser?.none)
                    ForEach(filterableBrowsers) { browser in
                        Text(browser.displayName).tag(Browser?.some(browser))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if plugin.isCapturingSuspended {
                pauseBanner
            } else if !plugin.browsersAwaitingAccess.isEmpty {
                accessBanner
            }

            if nothingToShow {
                emptyState
            } else {
                List {
                    if !pinnedFiltered.isEmpty {
                        Section("Pinned") {
                            ForEach(pinnedFiltered) { entry in
                                BrowsingRow(plugin: plugin, entry: entry)
                            }
                            .onMove(perform: canReorder ? { plugin.movePins(fromOffsets: $0, toOffset: $1) } : nil)
                        }
                    }
                    if !todayFiltered.isEmpty {
                        Section("Today") {
                            ForEach(todayFiltered) { entry in
                                BrowsingRow(plugin: plugin, entry: entry)
                            }
                        }
                    }
                    if !earlierFiltered.isEmpty {
                        Section("Earlier") {
                            ForEach(earlierFiltered) { entry in
                                BrowsingRow(plugin: plugin, entry: entry)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            footer
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search history…", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: emptyIcon)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if plugin.enabledBrowsers.isEmpty {
                Button("Open Settings…") { SettingsWindowPresenter.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private var emptyIcon: String {
        if plugin.enabledBrowsers.isEmpty { return "gearshape" }
        return plugin.entries.isEmpty ? "safari" : "line.3.horizontal.decrease.circle"
    }

    private var emptyMessage: String {
        if plugin.enabledBrowsers.isEmpty { return "Choose which browsers to record in Settings." }
        if plugin.entries.isEmpty { return "Nothing browsed yet." }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return "No matches for your search." }
        if let browserFilter { return "Nothing from \(browserFilter.displayName)." }
        return "Nothing to show."
    }

    private var pauseBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill").foregroundStyle(GlanceStyle.warning)
            Text(pauseText).font(.caption)
            Spacer(minLength: 4)
            Button("Resume") {
                plugin.isPaused = false
                plugin.resumeTimedPause()
            }
            .buttonStyle(.plain)
            .font(.caption.bold())
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var pauseText: String {
        if plugin.isPaused { return "Recording paused" }
        if let until = plugin.pausedUntil {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return "Paused \(fmt.localizedString(for: until, relativeTo: Date()))"
        }
        return "Recording paused"
    }

    /// Shown when a watched browser is open but hasn't granted Automation. Not a
    /// full gate — other browsers may well be working, and the history already
    /// recorded stays visible.
    private var accessBanner: some View {
        let waiting = plugin.browsersAwaitingAccess
        return HStack(spacing: 6) {
            Image(systemName: "lock.fill").foregroundStyle(GlanceStyle.warning)
            Text("Can't read \(waiting.map(\.displayName).joined(separator: ", "))")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Allow…") {
                Task {
                    for browser in waiting {
                        await AutomationPermission.request(for: browser.bundleID)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.caption.bold())
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var footer: some View {
        if !plugin.entries.isEmpty {
            Divider()
            HStack {
                Button {
                    plugin.clearHistory()
                } label: {
                    Label("Clear history", systemImage: "trash").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Menu {
                    Button("Pause 15 minutes") { plugin.pause(for: 15 * 60) }
                    Button("Pause 1 hour") { plugin.pause(for: 60 * 60) }
                    Button("Pause until resumed") { plugin.isPaused = true }
                } label: {
                    Label("Recording", systemImage: "pause.circle").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BrowsingRow: View {
    let plugin: BrowsingPlugin
    let entry: BrowsingPlugin.Entry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.browser.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if hovering {
                Button {
                    plugin.togglePin(entry)
                } label: {
                    Image(systemName: entry.pinned ? "star.fill" : "star")
                        .foregroundStyle(entry.pinned ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(entry.pinned ? "Unpin" : "Pin")

                Button {
                    plugin.delete(entry)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
            } else {
                if entry.pinned {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(GlanceStyle.highlight)
                }
                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { plugin.open(entry) }
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .help(entry.url)
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            plugin.open(entry)
        } label: {
            Label("Open in \(entry.browser.displayName)", systemImage: "arrow.up.forward.app")
        }

        Button {
            plugin.copyURL(entry)
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }

        Button {
            plugin.togglePin(entry)
        } label: {
            Label(entry.pinned ? "Unpin" : "Pin", systemImage: entry.pinned ? "star.slash" : "star")
        }

        Divider()

        Button {
            plugin.blockDomain(of: entry)
        } label: {
            Label("Never record \(entry.host)", systemImage: "hand.raised")
        }
        .disabled(entry.host.isEmpty)

        Button(role: .destructive) {
            plugin.delete(entry)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Host, plus a visit count once the page has been seen more than once.
    private var subtitle: String {
        let host = entry.host.isEmpty ? entry.url : entry.host
        guard entry.visits > 1 else { return host }
        return "\(host) · \(entry.visits) visits"
    }

    private var relativeTime: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: entry.timestamp, relativeTo: Date())
    }
}

// MARK: - Settings UI

struct BrowsingSettings: View {
    @Bindable var plugin: BrowsingPlugin
    @State private var newDomain: String = ""
    /// Live automation status per browser bundle id. `AutomationPermission.status`
    /// isn't observable, and a grant can land from anywhere — the in-app button,
    /// a prompt raised by background polling, or System Settings — so the rows
    /// can't rely on their own button to know when to re-read. This snapshot is
    /// refreshed on appear and on a slow timer while the pane is open; because
    /// `Status` is Equatable, an unchanged re-read is a no-op for SwiftUI.
    @State private var statuses: [String: GlancePermission.Status] = [:]

    /// Fires while the settings pane is visible so `statuses` tracks grants that
    /// happen outside this view.
    private let statusPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Only offer browsers the user actually has installed, plus any already
    /// enabled (so a browser that was uninstalled can still be switched off).
    private var availableBrowsers: [Browser] {
        Browser.allCases.filter { $0.isInstalled || plugin.enabledBrowsers.contains($0) }
    }

    var body: some View {
        SettingsPage("Browsing") {
            SettingsSectionHeader("Browsers")

            if availableBrowsers.isEmpty {
                SettingsHelp("No supported browsers found.")
            } else {
                ForEach(availableBrowsers) { browser in
                    browserRow(browser)
                }
            }

            SettingsHelp("Only the browser you're currently looking at is read, and only while it's already running. Firefox is read from its own history file instead of by automation, so it needs no permission.")

            Divider()

            Stepper(value: $plugin.maxEntries, in: 25...500, step: 25) {
                Text("Max history: \(plugin.maxEntries) pages")
            }
            SettingsHelp("Pinned pages are always kept and don't count toward this limit.")

            Divider()

            SettingsToggleRow("Skip private and incognito windows", detail: "Reliable for Chrome and other Chromium browsers. Safari does not tell apps which of its windows are private, so private Safari tabs are still recorded — block the domain or pause recording instead.", isOn: $plugin.skipsPrivateWindows)

            SettingsToggleRow("Ignore query strings", detail: "Drops everything after “?”, collapsing tracking-parameter variants into one entry. Leave off if you want search results and app URLs kept intact.", isOn: $plugin.stripsQueryStrings)

            SettingsToggleRow("Pause recording", isOn: $plugin.isPaused)
            if let until = plugin.pausedUntil, until > Date() {
                SettingsHelp("Timed pause active until \(until.formatted(date: .omitted, time: .shortened)).")
            }

            SettingsToggleRow("Clear history when quitting", detail: "On quit, removes unpinned pages. Pinned pages are kept.", isOn: $plugin.clearOnQuit)

            Divider()

            SettingsSectionHeader("Never record")

            HStack(spacing: 6) {
                TextField("example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if plugin.blockedDomains.isEmpty {
                SettingsHelp("No blocked domains. Adding one also deletes anything already recorded from it, including its subdomains.")
            } else {
                ForEach(plugin.blockedDomains, id: \.self) { domain in
                    HStack {
                        Image(systemName: "hand.raised").foregroundStyle(.secondary)
                        Text(domain).font(.callout)
                        Spacer()
                        Button {
                            plugin.unblock(domain)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                }
                SettingsHelp("Subdomains are blocked too, so example.com also covers mail.example.com.")
            }

            Divider()

            Button(role: .destructive) {
                plugin.clearAll()
            } label: {
                Label("Clear all history", systemImage: "trash")
            }
            SettingsHelp("Removes every page, including pinned ones.")
        }
        .onAppear(perform: refreshStatuses)
        .onReceive(statusPoll) { _ in refreshStatuses() }
    }

    /// Re-read TCC for every scriptable browser and publish the snapshot. Cheap,
    /// synchronous, and a no-op for SwiftUI when nothing changed.
    private func refreshStatuses() {
        var next: [String: GlancePermission.Status] = [:]
        for browser in availableBrowsers where browser.family != .firefox {
            next[browser.bundleID] = AutomationPermission.status(for: browser.bundleID)
        }
        statuses = next
    }

    @ViewBuilder
    private func browserRow(_ browser: Browser) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: binding(for: browser)) {
                Label(browser.displayName, systemImage: browser.systemImage)
            }
            .toggleStyle(.switch)
            Spacer()
            if plugin.enabledBrowsers.contains(browser), browser.family != .firefox {
                permissionStatus(for: browser)
            }
        }
    }

    @ViewBuilder
    private func permissionStatus(for browser: Browser) -> some View {
        switch statuses[browser.bundleID] ?? AutomationPermission.status(for: browser.bundleID) {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(GlanceStyle.positive).labelStyle(.titleAndIcon)
        case .denied:
            Button("Open System Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        case .notDetermined:
            // Also the answer when the browser isn't running — TCC can't be asked
            // about a process that doesn't exist, so prompting has to wait.
            Button(browser.isRunning ? "Allow…" : "Not running") {
                Task {
                    await AutomationPermission.request(for: browser.bundleID)
                    refreshStatuses()
                }
            }
            .controlSize(.small)
            .disabled(!browser.isRunning)
        }
    }

    private func binding(for browser: Browser) -> Binding<Bool> {
        Binding(
            get: { plugin.enabledBrowsers.contains(browser) },
            set: { isOn in
                if isOn {
                    plugin.enabledBrowsers.insert(browser)
                } else {
                    plugin.enabledBrowsers.remove(browser)
                }
            }
        )
    }

    private func addDomain() {
        plugin.block(newDomain)
        newDomain = ""
    }
}
