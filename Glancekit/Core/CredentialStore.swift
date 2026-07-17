import Foundation
import Security

/// File-backed store for all glance secrets (API keys, tokens, custom headers).
/// Never store secrets in UserDefaults — a `.plist` is world-readable, is copied
/// into backups, and shows up in screenshots of `defaults read`.
///
/// Keys are plugin-defined, e.g. "finnhub.apiKey", "github.pat",
/// "customapi.headers".
///
/// **Why not the Keychain?** This app is ad-hoc signed (`CODE_SIGN_IDENTITY =
/// "-"`), so its code signature changes on every rebuild and no stable identity
/// can be granted persistent Keychain trust — "Always Allow" never sticks.
/// Working around that required an ACL that trusted *any application with no
/// prompt*, which already let every process running as this user read the items
/// silently. That is the same exposure as a `0600` file in this user's home
/// directory, so the Keychain was buying protection it did not actually deliver,
/// at the cost of authorization dialogs. We therefore store secrets in a plain
/// file with tight POSIX permissions and document the trade-off honestly.
///
/// Threat model: protects against *other users* on the machine and against
/// casual disclosure (the file is not in preferences or backups of them, and is
/// covered by FileVault at rest). It does **not** protect against malicious code
/// running as this user — nor did the Keychain configuration it replaces.
/// If the app ever ships sandboxed and team-signed, switch back to the
/// data-protection Keychain, which can offer real per-app isolation.
///
/// This concrete implementation sits behind no protocol today, but is the
/// single seam through which a v2 OAuth flow can supply tokens without any
/// plugin change.
enum CredentialStore {
    /// Legacy Keychain service, read once to migrate pre-existing secrets.
    private static let legacyService = "com.glancekit.credentials"

    /// `errSecSuccess` (0) means the last `set`/`delete` succeeded. Kept as an
    /// `OSStatus` so existing diagnostics keep working; file errors surface as
    /// `errSecIO`.
    private(set) static var lastStatus: OSStatus = errSecSuccess

    private static let directoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Glancekit", isDirectory: true)
    }()

    private static let fileURL = directoryURL.appendingPathComponent("credentials.json")

    /// Serialises read-modify-write cycles so two plugins saving at once cannot
    /// clobber each other's keys.
    private static let lock = NSLock()

    // MARK: - Public API

    /// Store (or overwrite) a string value for `key`. Passing `nil` deletes it.
    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        guard let value, !value.isEmpty else { return delete(key) }
        lock.lock()
        defer { lock.unlock() }
        var secrets = load()
        secrets[key] = value
        return write(secrets)
    }

    /// Retrieve the string value for `key`, or `nil` if absent.
    static func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[key]
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var secrets = load()
        guard secrets.removeValue(forKey: key) != nil else {
            lastStatus = errSecSuccess   // already absent
            return true
        }
        return write(secrets)
    }

    static func has(_ key: String) -> Bool {
        get(key) != nil
    }

    // MARK: - Storage

    /// Reads the backing file, importing any pre-existing Keychain secrets the
    /// first time. Returns an empty dictionary on any decode failure rather than
    /// throwing — a corrupt file must not crash the app or wedge Settings.
    private static func load() -> [String: String] {
        migrateFromKeychainIfNeeded()
        guard let data = try? Data(contentsOf: fileURL),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return secrets
    }

    private static func write(_ secrets: [String: String]) -> Bool {
        do {
            // 0o700 on the directory is what actually keeps other users out: an
            // atomic write lands via a temp file, so the payload never exists
            // outside a directory they cannot traverse.
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(secrets)
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastStatus = errSecSuccess
            return true
        } catch {
            lastStatus = errSecIO
            return false
        }
    }

    // MARK: - Migration

    /// Adopt secrets written by the Keychain-backed implementation, exactly once.
    ///
    /// This is the only Keychain access left in the app, and it is deliberately
    /// allowed to prompt: suppressing interaction makes securityd refuse the read
    /// outright (`errSecAuthFailed`) rather than proceed silently, which would
    /// strand the secrets it is meant to rescue. In practice the read is silent —
    /// the items' ACL already trusts any application. Worst case the user sees
    /// the old dialog one final time; the file is written regardless, so this can
    /// never ask twice.
    private static func migrateFromKeychainIfNeeded() {
        // Presence of the file (even holding an empty object) means we've already
        // migrated, so this runs at most once.
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // Two passes on purpose: the legacy Keychain rejects `kSecMatchLimitAll`
        // combined with `kSecReturnData` (`errSecParam`), so enumerate the
        // accounts first and fetch each value on its own.
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var imported: [String: String] = [:]
        var result: AnyObject?
        if SecItemCopyMatching(listQuery as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else { continue }
                let valueQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: legacyService,
                    kSecAttrAccount as String: account,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecReturnData as String: true,
                ]
                var value: AnyObject?
                guard SecItemCopyMatching(valueQuery as CFDictionary, &value) == errSecSuccess,
                      let data = value as? Data,
                      let string = String(data: data, encoding: .utf8)
                else { continue }
                imported[account] = string
            }
        }

        // Written even when nothing was imported: the file's existence is what
        // records that migration has run, so a failed or declined import can
        // never re-prompt on the next panel open.
        guard write(imported) else { return }

        // Best-effort cleanup so the secrets don't linger in two places.
        for account in imported.keys {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
    }
}
