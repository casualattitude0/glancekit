import Foundation

/// The set of actions the AI assistant can take inside Glancekit, plus their
/// wire-format specs.
///
/// `specs` describes every tool to the model; `execute(_:)` runs a call the
/// model chose and returns a short string (usually JSON) the model reads back.
/// Everything is wired to the real stores — `ColorPaletteStore.shared`,
/// `NotesStore.shared`, and the injected `PluginRegistry` / `RefreshCoordinator`
/// — so the assistant manipulates the same state the rest of the app shows.
///
/// `@MainActor` because it touches those observable stores. It's a `struct`: it
/// holds only references and is cheap to recreate per turn.
@MainActor
struct AIToolbox {
    private let registry: PluginRegistry
    private let coordinator: RefreshCoordinator

    private var palettes: ColorPaletteStore { .shared }
    private var notes: NotesStore { .shared }

    init(registry: PluginRegistry, coordinator: RefreshCoordinator) {
        self.registry = registry
        self.coordinator = coordinator
    }

    // MARK: - Specs

    var specs: [AIToolSpec] {
        [
            AIToolSpec(
                name: "list_palettes",
                description: "List all color palettes with their ids, names, and colors (#RRGGBB).",
                parametersJSONSchema: Self.objectSchema([:])),

            AIToolSpec(
                name: "create_palette",
                description: "Create a new color palette with an optional set of colors.",
                parametersJSONSchema: Self.objectSchema([
                    "name": Self.stringProperty("Name for the new palette."),
                    "colors": Self.stringArrayProperty("Colors as #RRGGBB hex strings."),
                ], required: ["name"])),

            AIToolSpec(
                name: "add_colors_to_palette",
                description: "Add colors to an existing palette, identified by name or id.",
                parametersJSONSchema: Self.objectSchema([
                    "palette": Self.stringProperty("Palette name or id."),
                    "colors": Self.stringArrayProperty("Colors as #RRGGBB hex strings."),
                ], required: ["palette", "colors"])),

            AIToolSpec(
                name: "rename_palette",
                description: "Rename an existing palette, identified by name or id.",
                parametersJSONSchema: Self.objectSchema([
                    "palette": Self.stringProperty("Palette name or id."),
                    "newName": Self.stringProperty("The new name."),
                ], required: ["palette", "newName"])),

            AIToolSpec(
                name: "delete_palette",
                description: "Delete a palette, identified by name or id.",
                parametersJSONSchema: Self.objectSchema([
                    "palette": Self.stringProperty("Palette name or id."),
                ], required: ["palette"])),

            AIToolSpec(
                name: "list_notes",
                description: "List saved notes with their ids, titles, and last-updated time.",
                parametersJSONSchema: Self.objectSchema([:])),

            AIToolSpec(
                name: "create_note",
                description: "Create a new note from the given markdown text.",
                parametersJSONSchema: Self.objectSchema([
                    "text": Self.stringProperty("The note's markdown text."),
                ], required: ["text"])),

            AIToolSpec(
                name: "list_tools",
                description: "List every Glancekit tool/glance with its id, title, and whether it's enabled.",
                parametersJSONSchema: Self.objectSchema([:])),

            AIToolSpec(
                name: "enable_tool",
                description: "Enable a tool/glance by its id.",
                parametersJSONSchema: Self.objectSchema([
                    "id": Self.stringProperty("The tool/glance id."),
                ], required: ["id"])),

            AIToolSpec(
                name: "disable_tool",
                description: "Disable a tool/glance by its id.",
                parametersJSONSchema: Self.objectSchema([
                    "id": Self.stringProperty("The tool/glance id."),
                ], required: ["id"])),
        ]
    }

    // MARK: - Schema builders

    /// A JSON-Schema object: `{"type":"object","properties":…,"required":…}`.
    /// Typed helpers keep the schema literals from tripping Swift's inference of
    /// heterogeneous nested dictionaries.
    private static func objectSchema(_ properties: [String: Any],
                                     required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func stringProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func stringArrayProperty(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }

    // MARK: - Execution

    /// Run one tool call. Never throws — any failure comes back as a plain
    /// message string the model can read and recover from.
    func execute(_ call: AIToolCall) async -> String {
        switch call.name {
        case "list_palettes": return listPalettes()
        case "create_palette": return createPalette(call.arguments)
        case "add_colors_to_palette": return addColorsToPalette(call.arguments)
        case "rename_palette": return renamePalette(call.arguments)
        case "delete_palette": return deletePalette(call.arguments)
        case "list_notes": return listNotes()
        case "create_note": return createNote(call.arguments)
        case "list_tools": return listTools()
        case "enable_tool": return setToolEnabled(call.arguments, enabled: true)
        case "disable_tool": return setToolEnabled(call.arguments, enabled: false)
        default:
            return "Unknown tool \"\(call.name)\"."
        }
    }

    // MARK: - Palette tools

    private func listPalettes() -> String {
        let payload = palettes.palettes.map { palette in
            [
                "id": palette.id.uuidString,
                "name": palette.name,
                "colors": palette.colors,
            ] as [String: Any]
        }
        return Self.json(payload)
    }

    private func createPalette(_ args: [String: Any]) -> String {
        let name = Self.string(args["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return "A palette name is required." }

        let (valid, invalid) = Self.partitionColors(Self.stringArray(args["colors"]))
        let id = palettes.addPalette(name: name)
        for color in valid { palettes.addColor(color, to: id) }

        var message = "Created palette \u{2018}\(name)\u{2019} (id \(id.uuidString)) with \(valid.count) color(s)."
        if !invalid.isEmpty {
            message += " Ignored invalid colors: \(invalid.joined(separator: ", "))."
        }
        return message
    }

    private func addColorsToPalette(_ args: [String: Any]) -> String {
        guard let palette = resolvePalette(args["palette"]) else {
            return unresolvedPaletteMessage(args["palette"])
        }
        let (valid, invalid) = Self.partitionColors(Self.stringArray(args["colors"]))
        guard !valid.isEmpty else {
            return invalid.isEmpty
                ? "No colors were provided."
                : "None of the colors were valid #RRGGBB hex: \(invalid.joined(separator: ", "))."
        }
        for color in valid { palettes.addColor(color, to: palette.id) }

        var message = "Added \(valid.count) color(s) to \u{2018}\(palette.name)\u{2019}."
        if !invalid.isEmpty {
            message += " Ignored invalid colors: \(invalid.joined(separator: ", "))."
        }
        return message
    }

    private func renamePalette(_ args: [String: Any]) -> String {
        guard let palette = resolvePalette(args["palette"]) else {
            return unresolvedPaletteMessage(args["palette"])
        }
        let newName = Self.string(args["newName"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !newName.isEmpty else { return "A new name is required." }
        palettes.rename(palette.id, to: newName)
        return "Renamed palette to \u{2018}\(newName)\u{2019}."
    }

    private func deletePalette(_ args: [String: Any]) -> String {
        guard let palette = resolvePalette(args["palette"]) else {
            return unresolvedPaletteMessage(args["palette"])
        }
        let name = palette.name
        palettes.removePalette(palette.id)
        return "Deleted palette \u{2018}\(name)\u{2019}."
    }

    /// Resolve a palette by exact id (UUID) first, then case-insensitive name.
    private func resolvePalette(_ raw: Any?) -> ColorPalette? {
        guard let key = Self.string(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        if let uuid = UUID(uuidString: key), let match = palettes.palette(uuid) {
            return match
        }
        return palettes.palettes.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    private func unresolvedPaletteMessage(_ raw: Any?) -> String {
        let key = Self.string(raw) ?? ""
        let available = palettes.palettes.map { "\($0.name) (\($0.id.uuidString))" }
        if available.isEmpty {
            return "No palette matches \"\(key)\". There are no palettes yet."
        }
        return "No palette matches \"\(key)\". Available: \(available.joined(separator: ", "))."
    }

    // MARK: - Note tools

    private func listNotes() -> String {
        let formatter = ISO8601DateFormatter()
        let payload = notes.notes.map { note in
            [
                "id": note.id.uuidString,
                "title": note.title,
                "updatedAt": formatter.string(from: note.updatedAt),
            ] as [String: Any]
        }
        return Self.json(payload)
    }

    private func createNote(_ args: [String: Any]) -> String {
        let text = Self.string(args["text"]) ?? ""
        guard let note = notes.add(text: text) else {
            return "The note text was empty, so nothing was created."
        }
        return "Created note \u{2018}\(note.title)\u{2019} (id \(note.id.uuidString))."
    }

    // MARK: - Tool (glance) management

    private func listTools() -> String {
        let payload = registry.orderedPlugins.map { plugin in
            [
                "id": plugin.id,
                "title": plugin.title,
                "enabled": registry.isEnabled(plugin.id),
            ] as [String: Any]
        }
        return Self.json(payload)
    }

    private func setToolEnabled(_ args: [String: Any], enabled: Bool) -> String {
        let key = (Self.string(args["id"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "A tool id is required." }
        guard let plugin = registry.plugins.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame }) else {
            let available = registry.plugins.map(\.id).joined(separator: ", ")
            return "No tool with id \"\(key)\". Available ids: \(available)."
        }
        registry.setEnabled(plugin.id, enabled)
        coordinator.reconcile()
        return "\(enabled ? "Enabled" : "Disabled") \u{2018}\(plugin.title)\u{2019} (\(plugin.id))."
    }

    // MARK: - Argument helpers

    /// Coerce a JSON value to a String. Accepts strings and numbers (a model may
    /// send a bare number where a string is expected).
    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// Coerce a JSON value to `[String]`. Accepts an array (each element coerced)
    /// or a single scalar (wrapped into a one-element array).
    private static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { string($0) }
        }
        if let single = string(value) {
            return [single]
        }
        return []
    }

    /// Split raw color strings into normalized valid `#RRGGBB` and the originals
    /// that failed to parse.
    private static func partitionColors(_ raw: [String]) -> (valid: [String], invalid: [String]) {
        var valid: [String] = []
        var invalid: [String] = []
        for entry in raw {
            if let normalized = normalizeHex(entry) {
                valid.append(normalized)
            } else {
                invalid.append(entry)
            }
        }
        return (valid, invalid)
    }

    /// Canonicalize a hex color to uppercase `#RRGGBB`, or `nil` if it isn't a
    /// valid 6-digit hex. Self-contained so this file doesn't lean on the Colors
    /// plugin's helpers.
    private static func normalizeHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.uppercased().allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s.uppercased()
    }

    /// Serialize a JSON-compatible value to a compact string, with a readable
    /// fallback so a serialization failure never surfaces as a crash.
    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(object)"
        }
        return string
    }
}
