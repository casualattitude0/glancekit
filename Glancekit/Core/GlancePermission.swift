import SwiftUI

/// A system permission a glance needs before it may show its feature.
///
/// A plugin returns the permissions it *currently* needs but doesn't yet have
/// from `GlancePlugin.requiredPermissions`. The popover wraps every section in
/// `PermissionGatedSection`, which shows a grant prompt until all required
/// permissions are granted — then reveals `popoverSection()`.
struct GlancePermission: Identifiable {
    enum Status { case granted, denied, notDetermined }

    let id: String
    /// Display name, e.g. "Calendar", "Photos".
    let title: String
    let iconSystemName: String
    /// One-line reason shown in the prompt.
    let rationale: String
    /// Live authorization status. Read at render time.
    let status: @MainActor () -> Status
    /// Prompt the user (meaningful when status == .notDetermined).
    let request: @MainActor () async -> Void
    /// Deep link to the System Settings privacy pane (for the .denied case).
    let settingsURL: String
}

/// Wraps a plugin's popover content behind its permission requirements. Shows a
/// grant prompt for any not-yet-granted permission; reveals the feature only
/// once everything is granted.
struct PermissionGatedSection: View {
    let plugin: any GlancePlugin
    @State private var refreshToken = 0

    var body: some View {
        let ungranted = plugin.requiredPermissions.filter { $0.status() != .granted }
        Group {
            if ungranted.isEmpty {
                plugin.popoverSection()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Permission needed", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(ungranted) { permission in
                        PermissionRow(permission: permission) { refreshToken += 1 }
                    }
                }
            }
        }
        .id(refreshToken)
    }
}

private struct PermissionRow: View {
    let permission: GlancePermission
    let onChange: () -> Void
    @State private var requesting = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.callout.weight(.semibold))
                Text(permission.rationale).font(.caption).foregroundStyle(.secondary)
                actionButton
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch permission.status() {
        case .notDetermined:
            Button(requesting ? "Requesting…" : "Grant Access") {
                requesting = true
                Task {
                    await permission.request()
                    requesting = false
                    onChange()
                }
            }
            .controlSize(.small)
            .disabled(requesting)
        case .denied:
            Button("Open System Settings…") {
                if let url = URL(string: permission.settingsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        case .granted:
            EmptyView()
        }
    }
}
