import Foundation
import Observation

/// A user-configured MCP (Model Context Protocol) server the assistant can reach.
///
/// Non-secret fields persist in `UserDefaults`; any secret (an HTTP auth header
/// value) lives in `CredentialStore` under `mcp.<id>.auth`, never in prefs. The
/// `handle` is a short, stable, filename-safe slug used to namespace this
/// server's tools into the model's tool list (`mcp__<handle>__<tool>`), keeping
/// names within provider length limits that a raw UUID would blow past.
struct MCPServerConfig: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case stdio, http
        var id: String { rawValue }
        var label: String { self == .stdio ? "Local command (stdio)" : "Remote (HTTP)" }
    }

    var id: String
    var handle: String
    var name: String
    var kind: Kind
    var enabled: Bool

    // stdio
    var command: String
    var args: [String]
    var env: [String: String]

    // http
    var url: String
    /// The header name a secret auth value is sent under (e.g. "Authorization").
    var headerName: String

    init(id: String = UUID().uuidString, handle: String = "", name: String,
         kind: Kind, enabled: Bool = true,
         command: String = "", args: [String] = [], env: [String: String] = [:],
         url: String = "", headerName: String = "") {
        self.id = id
        self.handle = handle
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headerName = headerName
    }
}

/// Owns the MCP server list and their live sessions, and bridges each server's
/// discovered tools into the assistant's tool pipeline.
///
/// A singleton like `AIConfigStore.shared`: the Settings page edits servers and
/// the running conversation reads their tools from the same instance.
@MainActor
@Observable
final class MCPStore {
    static let shared = MCPStore()

    /// The connection state of a server, surfaced in Settings.
    enum Status: Equatable {
        case idle
        case connecting
        case connected(tools: Int)
        case failed(String)
    }

    private(set) var servers: [MCPServerConfig]
    private(set) var status: [String: Status] = [:]

    /// Live sessions and their discovered tool defs, keyed by server id.
    private var sessions: [String: MCPSession] = [:]
    private var tools: [String: [MCPToolDef]] = [:]

    private let serversKey = "glancekit.ai.mcp.servers"

    private init() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }
    }

    // MARK: - Secrets

    static func secretKey(for id: String) -> String { "mcp.\(id).auth" }
    func authValue(for id: String) -> String? { CredentialStore.get(Self.secretKey(for: id)) }
    func setAuthValue(_ value: String?, for id: String) {
        CredentialStore.set((value?.isEmpty ?? true) ? nil : value, for: Self.secretKey(for: id))
    }

    // MARK: - CRUD

    func addServer(_ server: MCPServerConfig) {
        var server = server
        if server.handle.isEmpty { server.handle = makeHandle(from: server.name) }
        servers.append(server)
        persist()
        if server.enabled { Task { await connect(server.id) } }
    }

    func updateServer(_ server: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        var server = server
        if server.handle.isEmpty { server.handle = makeHandle(from: server.name) }
        servers[index] = server
        persist()
        // Re-establish the session so edits (and enable/disable) take effect.
        Task {
            await disconnect(server.id)
            if server.enabled { await connect(server.id) }
        }
    }

    func removeServer(_ id: String) {
        servers.removeAll { $0.id == id }
        persist()
        setAuthValue(nil, for: id)
        status[id] = nil
        Task { await disconnect(id) }
    }

    /// A short, unique, filename-safe slug for tool namespacing.
    private func makeHandle(from name: String) -> String {
        let base = String(name.lowercased().compactMap { $0.isLetter || $0.isNumber ? $0 : nil }).prefix(12)
        var candidate = base.isEmpty ? "srv" : String(base)
        var n = 2
        let taken = Set(servers.map(\.handle))
        while taken.contains(candidate) { candidate = "\(base)\(n)"; n += 1 }
        return candidate
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
    }

    // MARK: - Connection lifecycle

    /// Connect every enabled server and drop sessions for disabled ones. Safe to
    /// call repeatedly (on launch, after edits).
    func connectEnabled() {
        for server in servers {
            if server.enabled {
                Task { await connect(server.id) }
            } else if sessions[server.id] != nil {
                Task { await disconnect(server.id) }
            }
        }
    }

    /// (Re)connect one server: a fresh `MCPSession` each time, since a session
    /// can't be reused after shutdown.
    func connect(_ id: String) async {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        await disconnect(id)
        status[id] = .connecting
        let session = MCPSession(transport: transport(for: server))
        do {
            try await session.connect()
            let defs = try await session.listTools()
            sessions[id] = session
            tools[id] = defs
            status[id] = .connected(tools: defs.count)
        } catch {
            await session.shutdown()
            status[id] = .failed(Self.message(error))
        }
    }

    func disconnect(_ id: String) async {
        if let session = sessions[id] { await session.shutdown() }
        sessions[id] = nil
        tools[id] = nil
        if case .connected = status[id] { status[id] = .idle }
    }

    private func transport(for server: MCPServerConfig) -> MCPTransport {
        switch server.kind {
        case .stdio:
            return .stdio(command: server.command, args: server.args, env: server.env)
        case .http:
            var headers: [String: String] = [:]
            if !server.headerName.isEmpty, let value = authValue(for: server.id), !value.isEmpty {
                headers[server.headerName] = value
            }
            return .http(url: server.url, headers: headers)
        }
    }

    // MARK: - Tool bridging

    /// Namespaced tool name for a server's tool: `mcp__<handle>__<tool>`.
    private func specName(handle: String, tool: String) -> String { "mcp__\(handle)__\(tool)" }

    /// Every enabled+connected server's tools as `AIToolSpec`s for the model.
    func toolSpecs() -> [AIToolSpec] {
        var specs: [AIToolSpec] = []
        for server in servers where server.enabled {
            guard let defs = tools[server.id] else { continue }
            for def in defs {
                let schema: [String: Any] = def.inputSchema.isEmpty
                    ? ["type": "object", "properties": [String: Any]()]
                    : def.inputSchema
                specs.append(AIToolSpec(
                    name: specName(handle: server.handle, tool: def.name),
                    description: "[\(server.name)] \(def.description)",
                    parametersJSONSchema: schema))
            }
        }
        return specs
    }

    func handles(_ name: String) -> Bool { resolve(name) != nil }

    /// A friendly "Server: tool" label for the approval prompt.
    func displayName(for name: String) -> String? {
        guard let (server, tool) = resolve(name) else { return nil }
        return "\(server.name): \(tool)"
    }

    /// Route a namespaced call to its server's session.
    func execute(_ name: String, arguments: [String: Any]) async -> String {
        guard let (server, tool) = resolve(name) else { return "Unknown MCP tool \"\(name)\"." }
        guard let session = sessions[server.id] else {
            return "MCP server \u{2018}\(server.name)\u{2019} isn't connected."
        }
        do {
            return try await session.callTool(name: tool, arguments: arguments)
        } catch {
            return "MCP tool \(tool) failed: \(Self.message(error))"
        }
    }

    /// Map a namespaced name back to its server + original tool name.
    private func resolve(_ name: String) -> (server: MCPServerConfig, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        for server in servers {
            let prefix = "mcp__\(server.handle)__"
            if name.hasPrefix(prefix) {
                return (server, String(name.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
