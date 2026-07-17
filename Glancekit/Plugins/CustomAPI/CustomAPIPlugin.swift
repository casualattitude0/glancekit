import SwiftUI
import Observation

/// Turns any REST/JSON endpoint into a personal glance. The user configures a
/// list of "trackers"; each fetches a URL, parses the JSON body, and walks a
/// dot/bracket `jsonPath` (see `JSONPath.swift`) to find a leaf value to
/// display.
///
/// - Non-secret config (label/url/jsonPath/interval) persists in
///   `UserDefaults` under `glancekit.customapi.trackers`.
/// - Custom headers (may contain secrets like `Authorization`) persist in
///   `CredentialStore` under `customapi.headers.<trackerID>`.
@MainActor
@Observable
final class CustomAPIPlugin: GlancePlugin {
    nonisolated var id: String { "customapi" }
    nonisolated var title: String { "Custom API" }
    nonisolated var iconSystemName: String { "antenna.radiowaves.left.and.right" }

    var refreshInterval: TimeInterval {
        let intervals = trackers.map(\.refreshInterval).filter { $0 > 0 }
        return intervals.min() ?? 300
    }

    /// Persisted tracker configs.
    var trackers: [CustomAPITracker] {
        didSet { persistTrackers() }
    }

    /// Last-fetch results keyed by tracker id. Not persisted.
    private(set) var results: [UUID: CustomAPIResult] = [:]

    private let trackersKey = "glancekit.customapi.trackers"
    private let network = NetworkClient()

    init() {
        if let data = UserDefaults.standard.data(forKey: "glancekit.customapi.trackers"),
           let decoded = try? JSONDecoder().decode([CustomAPITracker].self, from: data) {
            trackers = decoded
        } else {
            trackers = []
        }
    }

    private func persistTrackers() {
        if let data = try? JSONEncoder().encode(trackers) {
            UserDefaults.standard.set(data, forKey: trackersKey)
        }
    }

    // MARK: GlancePlugin

    var menuBarSummary: String? {
        for tracker in trackers {
            if let value = results[tracker.id]?.value, !value.isEmpty {
                return "\(tracker.label) \(value)"
            }
        }
        return nil
    }

    func refresh() async {
        guard !trackers.isEmpty else { return }
        for tracker in trackers {
            results[tracker.id] = await Self.fetch(tracker: tracker, network: network)
        }
    }

    /// Fetch and evaluate a single tracker. Never throws — captures errors
    /// into the returned `CustomAPIResult`. Static + testable independent of
    /// plugin state.
    static func fetch(tracker: CustomAPITracker, network: NetworkClient) async -> CustomAPIResult {
        guard !tracker.url.trimmingCharacters(in: .whitespaces).isEmpty else {
            return CustomAPIResult(value: nil, error: "No URL configured")
        }
        let headers = CustomAPIHeadersStore.load(for: tracker)
        do {
            let data = try await network.data(from: tracker.url, headers: headers)
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                return CustomAPIResult(value: nil, error: "Response is not valid JSON")
            }
            guard let value = JSONPath.evaluate(path: tracker.jsonPath, in: json) else {
                return CustomAPIResult(value: nil, error: "Path \"\(tracker.jsonPath)\" not found")
            }
            return CustomAPIResult(value: value, error: nil)
        } catch {
            return CustomAPIResult(value: nil, error: error.localizedDescription)
        }
    }

    func popoverSection() -> AnyView {
        AnyView(CustomAPIPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(CustomAPISettings(plugin: self))
    }
}

// MARK: - Popover UI

private struct CustomAPIPopover: View {
    let plugin: CustomAPIPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plugin.trackers.isEmpty {
                Text("No trackers configured. Add one in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plugin.trackers) { tracker in
                    HStack(alignment: .firstTextBaseline) {
                        Text(tracker.label.isEmpty ? "Untitled" : tracker.label)
                            .font(.body.weight(.semibold))
                        Spacer()
                        let result = plugin.results[tracker.id]
                        if let value = result?.value {
                            Text(value)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.primary)
                        } else if let error = result?.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        } else {
                            Text("—")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Settings UI

private struct CustomAPISettings: View {
    @Bindable var plugin: CustomAPIPlugin
    @State private var editingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trackers")
                .font(.headline)
            Text("Turn any REST/JSON endpoint into a glance. Use a jsonPath like \"data.price\" or \"results[0].value\".")
                .font(.caption).foregroundStyle(.secondary)

            if plugin.trackers.isEmpty {
                Text("No trackers yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($plugin.trackers) { $tracker in
                CustomAPITrackerEditor(
                    tracker: $tracker,
                    plugin: plugin,
                    onDelete: {
                        CustomAPIHeadersStore.remove(for: tracker)
                        plugin.trackers.removeAll { $0.id == tracker.id }
                    }
                )
                Divider()
            }

            Button("Add tracker") {
                plugin.trackers.append(CustomAPITracker())
            }
        }
    }
}

private struct CustomAPITrackerEditor: View {
    @Binding var tracker: CustomAPITracker
    let plugin: CustomAPIPlugin
    let onDelete: () -> Void

    @State private var intervalText: String = ""
    @State private var headersText: String = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Label", text: $tracker.label)
                .textFieldStyle(.roundedBorder)
            TextField("URL", text: $tracker.url)
                .textFieldStyle(.roundedBorder)
            TextField("JSON path (e.g. data.price)", text: $tracker.jsonPath)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Refresh every (s):")
                    .font(.caption)
                TextField("300", text: $intervalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit(commitInterval)
                    .onChange(of: intervalText) { _, _ in commitInterval() }
            }

            Text("Custom headers (one per line, key:value). Stored securely.")
                .font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: $headersText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 50)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .onChange(of: headersText) { _, newValue in
                    CustomAPIHeadersStore.save(Self.parseHeaders(newValue), for: tracker)
                }

            HStack {
                Button(isTesting ? "Testing…" : "Test") {
                    Task { await runTest() }
                }
                .disabled(isTesting)

                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("Error") ? .orange : .green)
                        .lineLimit(2)
                }

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            intervalText = String(Int(tracker.refreshInterval))
            let headers = CustomAPIHeadersStore.load(for: tracker)
            headersText = headers.map { "\($0.key):\($0.value)" }.joined(separator: "\n")
        }
    }

    private func commitInterval() {
        if let seconds = TimeInterval(intervalText), seconds > 0 {
            tracker.refreshInterval = seconds
        }
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        let outcome = await CustomAPIPlugin.fetch(tracker: tracker, network: NetworkClient())
        if let value = outcome.value {
            testResult = "Resolved: \(value)"
        } else {
            testResult = "Error: \(outcome.error ?? "unknown")"
        }
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            headers[key] = value
        }
        return headers
    }
}
