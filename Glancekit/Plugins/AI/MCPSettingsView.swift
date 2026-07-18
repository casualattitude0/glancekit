import SwiftUI
import Observation

/// Manages the assistant's MCP servers and the remembered tool allowances.
/// Embedded at the bottom of the AI Assistant settings page.
struct MCPSettingsView: View {
    @Bindable private var store = MCPStore.shared
    @Bindable private var approval = AIApprovalGate.shared

    @State private var isEditing = false
    @State private var draft = MCPServerConfig(name: "", kind: .stdio)
    @State private var draftArgsText = ""
    @State private var draftSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools & MCP Servers")
                .font(.headline)
            Text("Connect MCP servers to expand what the assistant can do. Local servers run a command over stdio (e.g. npx); remote servers connect over HTTP. Mutating actions and external tools ask before running.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.servers.isEmpty {
                Text("No MCP servers configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.servers) { server in
                        MCPServerRow(
                            server: server,
                            status: store.status[server.id] ?? .idle,
                            onToggle: { toggle(server) },
                            onEdit: { beginEdit(server) },
                            onReconnect: { Task { await store.connect(server.id) } },
                            onDelete: { store.removeServer(server.id) })
                    }
                }
            }

            if isEditing {
                editor
            } else {
                Button { beginAdd() } label: {
                    Label("Add server", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if !approval.alwaysAllowed.isEmpty {
                Divider()
                Text("Always-allowed tools")
                    .font(.subheadline.weight(.semibold))
                Text("Tools you told the assistant to run without asking.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(approval.alwaysAllowed.sorted(), id: \.self) { name in
                    HStack {
                        Text(name).font(.caption.monospaced())
                        Spacer()
                        Button("Revoke") { approval.revoke(name) }
                            .controlSize(.mini)
                    }
                }
            }
        }
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            Picker("Type", selection: $draft.kind) {
                ForEach(MCPServerConfig.Kind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            if draft.kind == .stdio {
                TextField("Command (e.g. npx)", text: $draft.command)
                    .textFieldStyle(.roundedBorder)
                TextField("Arguments (space-separated)", text: $draftArgsText)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("URL (https://…)", text: $draft.url)
                    .textFieldStyle(.roundedBorder)
                TextField("Auth header name (optional, e.g. Authorization)", text: $draft.headerName)
                    .textFieldStyle(.roundedBorder)
                if !draft.headerName.trimmingCharacters(in: .whitespaces).isEmpty {
                    SecureField("Auth value (e.g. Bearer sk-…)", text: $draftSecret)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel") { clearDraft() }
                    .controlSize(.small)
                Button("Save") { save() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var isValid: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch draft.kind {
        case .stdio: return !draft.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http: return !draft.url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Actions

    private func beginAdd() {
        draft = MCPServerConfig(name: "", kind: .stdio)
        draftArgsText = ""
        draftSecret = ""
        isEditing = true
    }

    private func beginEdit(_ server: MCPServerConfig) {
        draft = server
        draftArgsText = server.args.joined(separator: " ")
        draftSecret = store.authValue(for: server.id) ?? ""
        isEditing = true
    }

    private func clearDraft() {
        isEditing = false
        draftArgsText = ""
        draftSecret = ""
    }

    private func save() {
        var server = draft
        server.args = draftArgsText
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let exists = store.servers.contains { $0.id == server.id }
        if server.kind == .http {
            store.setAuthValue(draftSecret, for: server.id)
        }
        if exists { store.updateServer(server) } else { store.addServer(server) }
        clearDraft()
    }

    private func toggle(_ server: MCPServerConfig) {
        var server = server
        server.enabled.toggle()
        store.updateServer(server)
    }
}

/// One server's row: enable switch, identity, live status, and controls.
private struct MCPServerRow: View {
    let server: MCPServerConfig
    let status: MCPStore.Status
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onReconnect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { server.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            statusView
            Button { onReconnect() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Reconnect")
            Button { onEdit() } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(6)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private var subtitle: String {
        switch server.kind {
        case .stdio: return "stdio · \(server.command) \(server.args.joined(separator: " "))"
        case .http: return "http · \(server.url)"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Text("Idle").font(.caption2).foregroundStyle(.secondary)
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected(let count):
            Label("\(count)", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green).help("\(count) tools available")
        case .failed(let message):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).help(message)
        }
    }
}
