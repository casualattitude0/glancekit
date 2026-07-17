import Foundation
import Security

/// Keychain-backed store for all glance secrets (API keys, tokens, custom
/// headers). Never store secrets in UserDefaults.
///
/// Values are stored as generic-password items under a shared service so they
/// are namespaced to Glancekit. Keys are plugin-defined, e.g.
/// "finnhub.apiKey", "github.pat", "customapi.headers".
///
/// Keychain choice: this app is **not** sandboxed and is typically built with
/// ad-hoc signing and no development team, so it has no `application-identifier`
/// / `keychain-access-groups` entitlement. The modern *data-protection*
/// keychain refuses writes without that entitlement (`errSecMissingEntitlement`,
/// -34018), while the legacy file-based keychain works fine in this
/// configuration. We therefore deliberately use the legacy keychain (i.e. we do
/// NOT set `kSecUseDataProtectionKeychain`). If the app later ships sandboxed or
/// signed with a team, switch these queries to the data-protection keychain.
///
/// This concrete implementation sits behind no protocol today, but is the
/// single seam through which a v2 OAuth flow can supply tokens without any
/// plugin change.
enum CredentialStore {
    private static let service = "com.glancekit.credentials"

    /// The raw `OSStatus` from the most recent write, for diagnostics/UI.
    /// `errSecSuccess` (0) means the last `set`/`delete` succeeded.
    private(set) static var lastStatus: OSStatus = errSecSuccess

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// A legacy-keychain access object whose decrypt ACL trusts *any* application
    /// with *no* password prompt.
    ///
    /// This app is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), so its code
    /// signature changes on every rebuild. A default ACL trusts only the creating
    /// app *by signature*, so after each build the trust no longer matches and
    /// macOS re-prompts — even after the user clicked "Always Allow". Binding the
    /// ACL to "any application, no prompt" makes it signature-independent and
    /// stops the repeating dialog. Trade-off: any process running as this user can
    /// read these secrets without a prompt. Acceptable for a local, unsandboxed,
    /// non-distributed dev app; revisit if the app ever ships team-signed/sandboxed
    /// (switch to the data-protection keychain, per the type note above).
    private static func promptFreeAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(service as CFString, [] as CFArray, &access) == errSecSuccess,
              let access else { return nil }
        let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL]
        for acl in acls ?? [] {
            // nil trusted-application list == any application; empty prompt
            // selector == no password prompt.
            SecACLSetContents(acl, nil, "" as CFString, [])
        }
        return access
    }

    /// Store (or overwrite) a string value for `key`. Passing `nil` deletes it.
    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        guard let value, !value.isEmpty else {
            return delete(key)
        }
        let data = Data(value.utf8)
        let query = baseQuery(for: key)

        let access = promptFreeAccess()

        // Existence check uses no `kSecReturnData`, so it never triggers a decrypt
        // prompt on its own.
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        let status: OSStatus
        if existing == errSecSuccess {
            var attributes: [String: Any] = [kSecValueData as String: data]
            if let access { attributes[kSecAttrAccess as String] = access }
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            if let access { addQuery[kSecAttrAccess as String] = access }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        lastStatus = status
        return status == errSecSuccess
    }

    /// Retrieve the string value for `key`, or `nil` if absent.
    static func get(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        lastStatus = status
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(_ key: String) -> Bool {
        get(key) != nil
    }
}
