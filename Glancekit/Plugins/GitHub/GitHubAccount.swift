import Foundation
import Observation

/// One configured GitHub account.
///
/// Only non-secret metadata (a stable `id` and a user-facing `label`) is
/// persisted — to `UserDefaults` via `GitHubAccountStore`. The account's token
/// lives in the Keychain under `tokenKey`, never in preferences.
struct GitHubAccount: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String

    init(id: UUID = UUID(), label: String) {
        self.id = id
        self.label = label
    }

    /// Per-account Keychain key, e.g. "github.pat.<uuid>".
    var tokenKey: String { "github.pat.\(id.uuidString)" }
}

/// Persistence for the account list (metadata in `UserDefaults`, tokens in the
/// Keychain), plus a one-time migration from the original single-token layout.
enum GitHubAccountStore {
    private static let defaultsKey = "github.accounts"
    private static let legacyTokenKey = "github.pat"

    static func load() -> [GitHubAccount] {
        migrateLegacyIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let accounts = try? JSONDecoder().decode([GitHubAccount].self, from: data)
        else { return [] }
        return accounts
    }

    private static func save(_ accounts: [GitHubAccount]) {
        let data = try? JSONEncoder().encode(accounts)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Create a new account with `token`, returning it. `token` may be empty
    /// (the account is created but flagged as needing a token on next refresh).
    @discardableResult
    static func add(label: String, token: String) -> GitHubAccount {
        var accounts = load()
        let account = GitHubAccount(label: label.isEmpty ? "GitHub" : label)
        CredentialStore.set(token.isEmpty ? nil : token, for: account.tokenKey)
        accounts.append(account)
        save(accounts)
        return account
    }

    static func remove(_ account: GitHubAccount) {
        CredentialStore.set(nil, for: account.tokenKey)
        save(load().filter { $0.id != account.id })
    }

    static func rename(_ account: GitHubAccount, to label: String) {
        var accounts = load()
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].label = label.isEmpty ? "GitHub" : label
        save(accounts)
    }

    @discardableResult
    static func setToken(_ token: String?, for account: GitHubAccount) -> Bool {
        CredentialStore.set(token, for: account.tokenKey)
    }

    static func hasToken(_ account: GitHubAccount) -> Bool {
        CredentialStore.has(account.tokenKey)
    }

    /// Adopt a pre-multi-account single token as the first account, exactly once.
    private static func migrateLegacyIfNeeded() {
        // Presence of the defaults key (even an empty array) means we've already
        // initialized, so this runs at most once.
        guard UserDefaults.standard.data(forKey: defaultsKey) == nil else { return }
        guard let token = CredentialStore.get(legacyTokenKey), !token.isEmpty else {
            save([])
            return
        }
        let account = GitHubAccount(label: "GitHub")
        CredentialStore.set(token, for: account.tokenKey)
        CredentialStore.set(nil, for: legacyTokenKey)
        save([account])
    }
}

/// Live, observable fetched state for a single account. The plugin owns one of
/// these per account and updates it on refresh.
@MainActor
@Observable
final class GitHubAccountData: Identifiable {
    nonisolated let id: UUID
    private(set) var account: GitHubAccount

    var login: String?
    var notifications: [GitHubAPI.Notification] = []
    var pullRequests: [GitHubAPI.Issue] = []
    var ciStatus: [Int: String] = [:]
    var contributions: GitHubAPI.ContributionCalendar?
    var error: String?

    var unreadCount: Int { notifications.filter { $0.unread }.count }

    init(account: GitHubAccount) {
        self.id = account.id
        self.account = account
    }

    /// Refresh metadata (e.g. after a rename) without dropping fetched data.
    func update(account: GitHubAccount) {
        self.account = account
    }
}
