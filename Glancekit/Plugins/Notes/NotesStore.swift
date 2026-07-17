import AppKit
import Foundation
import Observation

/// One saved note. Plain text on purpose — the point of this glance is to catch
/// something before it's gone, not to format it.
struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First non-blank line, for the list row. A note is never saved empty, so
    /// the fallback only covers a note that is entirely whitespace.
    var title: String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? "Untitled note"
    }

    /// Everything after the title line, collapsed onto one line for the row's
    /// second line. Empty for a single-line note.
    var detail: String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let titleIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return "" }
        return lines[(titleIndex + 1)...]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Owns the notes and the in-progress draft, and persists both to
/// `UserDefaults`.
///
/// The draft is persisted alongside the saved notes because the tool window
/// closes the moment it loses focus — a half-typed note has to survive a stray
/// click outside, or the glance loses the one job it has.
///
/// Notes are plain text with no secrets contract attached, so `UserDefaults` is
/// the right store here (`CredentialStore` is for secrets only).
@MainActor
@Observable
final class NotesStore {

    /// Saved notes, most recently touched first.
    private(set) var notes: [Note] = []

    /// The text in the input field. Survives closing the window and quitting.
    var draft: String = "" {
        didSet { defaults.set(draft, forKey: Self.draftKey) }
    }

    /// The note the draft is editing, or `nil` when the draft is a new note.
    /// Cleared on save, so the field always returns to composing a fresh note.
    private(set) var editingID: UUID?

    private let defaults: UserDefaults
    private static let notesKey = "glancekit.notes.items"
    private static let draftKey = "glancekit.notes.draft"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        draft = defaults.string(forKey: Self.draftKey) ?? ""
        if let data = defaults.data(forKey: Self.notesKey),
           let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
        }
    }

    /// Whether `save()` would do anything — a draft of pure whitespace doesn't
    /// count, so the button disables rather than banking an empty note.
    var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEditing: Bool { editingID != nil }

    /// Banks the draft: updates the note being edited, or files a new one at the
    /// top. Clears the field either way.
    func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let editingID, let index = notes.firstIndex(where: { $0.id == editingID }) {
            var note = notes[index]
            note.text = text
            note.updatedAt = .now
            // Back to the top: it's the note most recently worked on.
            notes.remove(at: index)
            notes.insert(note, at: 0)
        } else {
            notes.insert(Note(text: text), at: 0)
        }

        draft = ""
        editingID = nil
        persistNotes()
    }

    /// Loads a saved note back into the field for editing.
    ///
    /// An unsaved new draft would otherwise be dropped on the floor, so it's
    /// banked as its own note first rather than silently replaced.
    func edit(_ note: Note) {
        if editingID == nil && canSave { save() }
        draft = note.text
        editingID = note.id
    }

    /// Empties the field. Editing a saved note leaves that note untouched —
    /// this is "stop editing", not "delete".
    func clearDraft() {
        draft = ""
        editingID = nil
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        // The field was editing what no longer exists; saving it would file a
        // surprise duplicate, so let it go back to being a new note.
        if editingID == note.id { editingID = nil }
        persistNotes()
    }

    func deleteAll() {
        notes.removeAll()
        editingID = nil
        persistNotes()
    }

    func copyToPasteboard(_ note: Note) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(note.text, forType: .string)
    }

    private func persistNotes() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        defaults.set(data, forKey: Self.notesKey)
    }
}
