import Foundation

/// Non-secret configuration for a single Custom API tracker. Persisted as a
/// JSON-encoded array under `UserDefaults` key `glancekit.customapi.trackers`.
/// Any custom headers (which may hold secrets) are stored separately in
/// `CredentialStore` under `customapi.headers.<id>` and are NOT part of this
/// struct's persisted representation.
struct CustomAPITracker: Codable, Identifiable, Equatable {
    var id: UUID
    var label: String
    var url: String
    var jsonPath: String
    var refreshInterval: TimeInterval

    init(id: UUID = UUID(),
         label: String = "",
         url: String = "",
         jsonPath: String = "",
         refreshInterval: TimeInterval = 300) {
        self.id = id
        self.label = label
        self.url = url
        self.jsonPath = jsonPath
        self.refreshInterval = refreshInterval
    }

    /// CredentialStore key for this tracker's custom headers (JSON-encoded
    /// `[String: String]`), never stored in UserDefaults.
    var headersCredentialKey: String { "customapi.headers.\(id.uuidString)" }
}

/// Runtime (non-persisted) result of the last fetch for a tracker.
struct CustomAPIResult: Equatable {
    var value: String?
    var error: String?
}

enum CustomAPIHeadersStore {
    /// Load headers for a tracker from CredentialStore. Returns an empty
    /// dictionary on any decode failure — never crashes.
    static func load(for tracker: CustomAPITracker) -> [String: String] {
        guard let raw = CredentialStore.get(tracker.headersCredentialKey),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    /// Save (or clear, if empty) headers for a tracker to CredentialStore.
    static func save(_ headers: [String: String], for tracker: CustomAPITracker) {
        guard !headers.isEmpty,
              let data = try? JSONEncoder().encode(headers),
              let json = String(data: data, encoding: .utf8) else {
            CredentialStore.set(nil, for: tracker.headersCredentialKey)
            return
        }
        CredentialStore.set(json, for: tracker.headersCredentialKey)
    }

    static func remove(for tracker: CustomAPITracker) {
        CredentialStore.set(nil, for: tracker.headersCredentialKey)
    }
}
