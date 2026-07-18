import AppKit
import Foundation
import Observation

/// One saved note. Stored as plain markdown text — you edit the source, and the
/// list rows render it. The point of the glance is still to catch something
/// before it's gone; markdown just means what you catch keeps its shape.
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

    /// The title line with its inline markdown rendered (bold, italic, code,
    /// links), for the list row. A heading's leading `#`s are stripped so the
    /// row reads as a title, not as raw source.
    var renderedTitle: AttributedString {
        Note.renderInline(stripHeadingMarks(from: title))
    }

    /// The collapsed remainder, inline-rendered the same way.
    var renderedDetail: AttributedString {
        Note.renderInline(detail)
    }

    private func stripHeadingMarks(from line: String) -> String {
        guard let hashes = line.range(of: "^#{1,6}[ \\t]+", options: .regularExpression) else { return line }
        return String(line[hashes.upperBound...])
    }

    /// Renders one line of markdown as inline-styled text, falling back to the
    /// raw string if it doesn't parse. Block constructs are intentionally left
    /// as-is — a row is a single line.
    static func renderInline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
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

    /// The app-wide notes store. Shared so every surface — the Notes glance and
    /// the AI assistant's `create_note` tool — reads and writes the same list,
    /// the way `ColorPaletteStore.shared` is shared across the Colors surfaces.
    static let shared = NotesStore()

    /// Saved notes, most recently touched first.
    private(set) var notes: [Note] = []

    /// The text in the input field. Survives closing the window and quitting.
    var draft: String = "" {
        didSet { defaults.set(draft, forKey: Self.draftKey) }
    }

    /// The note the draft is editing, or `nil` when the draft is a new note.
    /// Cleared on save, so the field always returns to composing a fresh note.
    private(set) var editingID: UUID?

    /// iA-Writer-style focus mode: dim everything but the paragraph you're in.
    /// A preference, so it sticks between sessions.
    var focusMode: Bool = false {
        didSet { defaults.set(focusMode, forKey: Self.focusModeKey) }
    }

    private let defaults: UserDefaults
    private static let notesKey = "glancekit.notes.items"
    private static let draftKey = "glancekit.notes.draft"
    private static let focusModeKey = "glancekit.notes.focusMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        draft = defaults.string(forKey: Self.draftKey) ?? ""
        focusMode = defaults.bool(forKey: Self.focusModeKey)
        if let data = defaults.data(forKey: Self.notesKey),
           let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
        }
    }

    /// Live word count of the draft — whitespace-separated runs of non-space.
    var wordCount: Int {
        draft.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Live character count of the draft, excluding trailing whitespace so an
    /// empty-but-for-a-newline draft reads as 0.
    var characterCount: Int {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).count
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

    /// Files a new note straight from given text, without touching the draft.
    ///
    /// Unlike `save()` (which banks the in-progress draft), this is for callers
    /// that hand over finished text — e.g. the AI assistant creating a note on
    /// the user's behalf. Whitespace-only text is ignored, and the created note
    /// (or `nil`) is returned so the caller can report what it made.
    @discardableResult
    func add(text: String) -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = Note(text: trimmed)
        notes.insert(note, at: 0)
        persistNotes()
        return note
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

    /// Starts a fresh, empty draft — the compose button.
    ///
    /// Loss-averse, like `edit`: an in-progress *new* draft is banked first so
    /// starting a new note doesn't throw away what you were writing. Abandoning
    /// an edit of a saved note leaves that note untouched.
    func newNote() {
        if editingID == nil && canSave { save() }
        draft = ""
        editingID = nil
    }

    /// Empties the field. Editing a saved note leaves that note untouched —
    /// this is "stop editing", not "delete".
    func clearDraft() {
        draft = ""
        editingID = nil
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        // The field was editing what no longer exists. Clearing `editingID`
        // alone leaves its text behind in the draft, which then looks like an
        // unsaved *new* note — so the next `edit()`/`newNote()` would bank it
        // and resurrect the note just deleted. Drop the draft too, so deleting
        // the note you're editing empties the field and stays deleted.
        if editingID == note.id {
            editingID = nil
            draft = ""
        }
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
