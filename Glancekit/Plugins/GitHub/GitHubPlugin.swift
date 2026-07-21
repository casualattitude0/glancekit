import SwiftUI
import Observation

/// GitHub glance: unread notifications, open PRs authored by the signed-in
/// user, and a best-effort CI status dot per PR — for one or more accounts.
///
/// - Auth: one fine-grained Personal Access Token per account, pasted in
///   Settings and stored in `CredentialStore` under `"github.pat.<uuid>"` via
///   `CredentialStore`. Account metadata (id + label) lives in `UserDefaults`
///   via `GitHubAccountStore`; tokens never reach app preferences.
/// - Popover: per-account Contributions + Notifications + My PRs sections, or a
///   friendly prompt to add an account when none are configured.
@MainActor
@Observable
final class GitHubPlugin: GlancePlugin {
    nonisolated var id: String { "github" }
    nonisolated var title: String { "GitHub" }
    nonisolated var iconSystemName: String { "chevron.left.forwardslash.chevron.right" }
    var refreshInterval: TimeInterval { 120 }

    /// Live fetched state, one entry per configured account.
    private(set) var accountData: [GitHubAccountData] = []

    private let client = NetworkClient()

    init() {
        reloadAccounts()
    }

    /// The configured accounts (metadata), derived from live state.
    var accounts: [GitHubAccount] { accountData.map(\.account) }

    /// Reconcile `accountData` with the persisted account list, preserving
    /// already-fetched data for accounts that still exist.
    func reloadAccounts() {
        let accounts = GitHubAccountStore.load()
        let existing = Dictionary(accountData.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        accountData = accounts.map { account in
            if let data = existing[account.id] {
                data.update(account: account)
                return data
            }
            return GitHubAccountData(account: account)
        }
    }

    // MARK: GlancePlugin

    func refresh() async {
        reloadAccounts()
        guard !accountData.isEmpty else { return }
        // Refresh accounts concurrently; each writes only its own state.
        await withTaskGroup(of: Void.self) { group in
            for data in accountData {
                group.addTask { await self.refresh(data) }
            }
        }
    }

    private func refresh(_ data: GitHubAccountData) async {
        guard let token = CredentialStore.get(data.account.tokenKey), !token.isEmpty else {
            data.error = "Add a token for this account in Settings"
            data.notifications = []
            data.pullRequests = []
            data.ciStatus = [:]
            data.contributions = nil
            return
        }

        do {
            // Resolve + cache the login once.
            let login: String
            if let cached = data.login {
                login = cached
            } else {
                login = try await GitHubAPI.fetchUser(client: client, token: token).login
                data.login = login
            }

            async let notificationsTask = GitHubAPI.fetchNotifications(client: client, token: token)
            async let prsTask = GitHubAPI.fetchOpenPRs(client: client, token: token, login: login)

            let fetchedNotifications = try await notificationsTask
            let fetchedPRs = try await prsTask

            data.notifications = Array(fetchedNotifications.prefix(10))
            data.pullRequests = Array(fetchedPRs.prefix(5))
            data.error = nil

            // Best-effort contribution heatmap; a failure here (e.g. a
            // fine-grained token without profile access) must not clear the
            // rest of the glance.
            data.contributions = try? await GitHubAPI.fetchContributions(client: client, token: token)

            // Best-effort CI dots, capped at 5 PRs.
            var newStatus: [Int: String] = [:]
            for pr in data.pullRequests {
                if let state = await GitHubAPI.fetchCombinedStatus(
                    client: client, token: token, repoFullName: pr.repoFullName, prNumber: pr.number
                ) {
                    newStatus[pr.id] = state
                }
            }
            data.ciStatus = newStatus
        } catch NetworkClient.NetworkError.http(401, _) {
            data.error = "Token is invalid or expired"
            data.login = nil
            data.notifications = []
            data.pullRequests = []
            data.ciStatus = [:]
            data.contributions = nil
        } catch NetworkClient.NetworkError.http(403, let message) {
            // 403 with a valid token is usually a fine-grained PAT missing a
            // required permission (Notifications, Pull requests, Metadata…) or a
            // hit rate limit. Surface GitHub's own explanation when present.
            data.error = message.map { "403: \($0)" }
                ?? "Token is missing a required permission (check Notifications, Pull requests, Metadata)"
            data.login = nil
        } catch {
            data.error = error.localizedDescription
        }
    }

    /// Surfaces unread notifications and failing PR checks across all accounts.
    /// A red CI dot is urgent; unread notifications alone are elevated.
    func currentSignal() -> GlanceSignal? {
        let unread = accountData.reduce(0) { $0 + $1.notifications.filter(\.unread).count }
        let failing = accountData.reduce(0) { sum, data in
            sum + data.ciStatus.values.filter { $0 == "failure" || $0 == "error" }.count
        }
        guard unread > 0 || failing > 0 else {
            // Nothing pressing — but if accounts are configured and healthy, a
            // quiet "all caught up" card keeps GitHub on the feed.
            let openPRs = accountData.reduce(0) { $0 + $1.pullRequests.count }
            guard !accountData.isEmpty, accountData.allSatisfy({ $0.error == nil }) else { return nil }
            return GlanceSignal(priority: .ambient, score: 0,
                                headline: openPRs > 0 ? "Inbox clear · \(openPRs) open PR\(openPRs == 1 ? "" : "s")" : "All caught up",
                                systemImage: iconSystemName, tint: .secondary)
        }

        var parts: [String] = []
        if unread > 0 { parts.append("\(unread) unread") }
        if failing > 0 { parts.append("\(failing) CI failing") }

        // Name the most recent unread thread, so the card says *what* is waiting
        // rather than just how much — the API returns them newest-first.
        let topUnread = accountData
            .flatMap { $0.notifications }
            .first { $0.unread }
        let detail = topUnread.map { "\($0.subject.title) · \($0.repository.full_name)" }

        let priority: GlanceSignal.Priority = failing > 0 ? .urgent : .elevated
        let tint: Color = failing > 0 ? .red : .blue
        // Rank by attention weight: a failing check counts for more than an
        // unread thread, so a broken build outranks a big inbox.
        let score = Double(failing * 10 + unread)
        return GlanceSignal(priority: priority, score: score,
                            headline: parts.joined(separator: " · "),
                            detail: detail,
                            systemImage: iconSystemName, tint: tint)
    }

    func popoverSection() -> AnyView {
        AnyView(GitHubPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(GitHubSettings(plugin: self))
    }
}

// MARK: - Popover UI

private struct GitHubPopover: View {
    let plugin: GitHubPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plugin.accountData.isEmpty {
                Label("Add a GitHub account in Settings", systemImage: "person.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                let showLabels = plugin.accountData.count > 1
                ForEach(Array(plugin.accountData.enumerated()), id: \.element.id) { index, data in
                    if index > 0 {
                        Divider().padding(.vertical, 2)
                    }
                    GitHubAccountSection(data: data, showAccountLabel: showLabels)
                }
            }
        }
    }
}

/// One account's block within the popover: an optional account label header,
/// then Contributions, Notifications, and My PRs.
private struct GitHubAccountSection: View {
    let data: GitHubAccountData
    let showAccountLabel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showAccountLabel {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption2)
                    Text(data.login.map { "\(data.account.label) · @\($0)" } ?? data.account.label)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.secondary)
            }

            if let err = data.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let calendar = data.contributions {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(calendar.totalContributions) contributions in the last year")
                        .font(.subheadline.weight(.semibold))
                    ContributionHeatmap(calendar: calendar)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications")
                    .font(.subheadline.weight(.semibold))
                if data.notifications.isEmpty {
                    Text("No unread notifications")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(data.notifications.prefix(5)) { note in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(note.unread ? Color.blue : Color.clear)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(note.subject.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(note.repository.full_name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("My PRs")
                    .font(.subheadline.weight(.semibold))
                if data.pullRequests.isEmpty {
                    Text("No open pull requests")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(data.pullRequests) { pr in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ciColor(for: data.ciStatus[pr.id]))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(pr.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(pr.repoFullName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func ciColor(for state: String?) -> Color {
        switch state {
        case "success": return .green
        case "pending": return .yellow
        case "failure", "error": return .red
        default: return .gray
        }
    }
}

/// GitHub-style contribution heatmap: one column per week, one cell per day,
/// shaded by contribution count. Sized to fit the 240pt popover column.
private struct ContributionHeatmap: View {
    let calendar: GitHubAPI.ContributionCalendar

    private let cell: CGFloat = 3
    private let gap: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(calendar.weeks) { week in
                VStack(spacing: gap) {
                    // Pad to 7 rows so weekdays line up even on partial weeks.
                    ForEach(0..<7, id: \.self) { weekday in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color(for: day(in: week, weekday: weekday)))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }

    private func day(in week: GitHubAPI.ContributionCalendar.Week, weekday: Int) -> GitHubAPI.ContributionCalendar.Day? {
        week.contributionDays.first { $0.weekday == weekday }
    }

    /// Empty/absent days are a faint fill; present days ramp through green.
    private func color(for day: GitHubAPI.ContributionCalendar.Day?) -> Color {
        guard let count = day?.contributionCount else { return .gray.opacity(0.15) }
        switch count {
        case 0: return .gray.opacity(0.15)
        case 1...2: return .green.opacity(0.4)
        case 3...5: return .green.opacity(0.6)
        case 6...9: return .green.opacity(0.8)
        default: return .green
        }
    }
}

// MARK: - Settings UI

private struct GitHubSettings: View {
    @Bindable var plugin: GitHubPlugin

    // New-account entry fields.
    @State private var newLabel: String = ""
    @State private var newToken: String = ""
    @State private var addNote: String?
    @State private var addFailed: Bool = false

    var body: some View {
        SettingsPage("GitHub Accounts", intro: "Add one or more accounts. Create a fine-grained token at github.com/settings/tokens with read-only access to: Notifications, Pull requests, Checks (or Commit statuses), and Metadata. Tokens are stored in Glancekit's credentials file (readable only by your macOS account), never in app preferences.") {
            if plugin.accounts.isEmpty {
                SettingsHelp("No accounts yet.")
            } else {
                ForEach(plugin.accounts) { account in
                    GitHubAccountRow(plugin: plugin, account: account)
                    Divider()
                }
            }

            // Add-account form.
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader("Add account")
                TextField("Label (e.g. Work, Personal)", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                SecureField("ghp_… or github_pat_…", text: $newToken)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Add") {
                        let account = GitHubAccountStore.add(label: newLabel, token: newToken)
                        addFailed = !newToken.isEmpty && !GitHubAccountStore.hasToken(account)
                        if addFailed {
                            // The credential write failed — roll the account back.
                            GitHubAccountStore.remove(account)
                            addNote = "Couldn't save credentials (\(CredentialStore.lastStatus))."
                        } else {
                            addNote = "Added."
                            newLabel = ""
                            newToken = ""
                            plugin.reloadAccounts()
                            Task { await plugin.refresh() }
                        }
                    }
                    .disabled(newToken.isEmpty)
                    if let note = addNote {
                        Text(note).font(.caption).foregroundStyle(addFailed ? .red : .green)
                    }
                }
            }
        }
    }
}

/// A single configured account: rename, replace token, or remove.
private struct GitHubAccountRow: View {
    let plugin: GitHubPlugin
    let account: GitHubAccount

    @State private var label: String
    @State private var replacementToken: String = ""
    @State private var note: String?
    @State private var noteIsError: Bool = false

    init(plugin: GitHubPlugin, account: GitHubAccount) {
        self.plugin = plugin
        self.account = account
        _label = State(initialValue: account.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Label", text: $label, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                if GitHubAccountStore.hasToken(account) {
                    Label("Token set", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("No token", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button(role: .destructive) {
                    GitHubAccountStore.remove(account)
                    plugin.reloadAccounts()
                    Task { await plugin.refresh() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove account")
            }

            HStack {
                SecureField("Replace token…", text: $replacementToken)
                    .textFieldStyle(.roundedBorder)
                Button("Update") {
                    let ok = GitHubAccountStore.setToken(replacementToken, for: account)
                    noteIsError = !ok
                    note = ok ? "Updated." : "Couldn't save credentials (\(CredentialStore.lastStatus))."
                    if ok {
                        replacementToken = ""
                        Task { await plugin.refresh() }
                    }
                }
                .disabled(replacementToken.isEmpty)
                if let note {
                    Text(note).font(.caption).foregroundStyle(noteIsError ? .red : .green)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func commitRename() {
        GitHubAccountStore.rename(account, to: label)
        plugin.reloadAccounts()
    }
}
