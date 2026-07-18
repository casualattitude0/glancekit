import SwiftUI
import Observation

/// Notes glance: a field to paste or type something into, and a list of what
/// you've saved.
///
/// Purely local and user-driven — nothing to fetch, so it opts out of the shared
/// refresh loop (`refreshInterval` 0, no-op `refresh()`).
@MainActor
@Observable
final class NotesPlugin: GlancePlugin {
    nonisolated var id: String { "notes" }
    nonisolated var title: String { "Notes" }
    nonisolated var iconSystemName: String { "note.text" }

    let store = NotesStore()

    func refresh() async {}

    func popoverSection() -> AnyView { AnyView(NotesPopover(store: store)) }
    func settingsSection() -> AnyView { AnyView(NotesSettings(store: store)) }
}

// MARK: - Popover UI

private struct NotesPopover: View {
    @Bindable var store: NotesStore

    /// One-shot request to put the caret in the field when the window opens, so
    /// ⌥2 → paste → ⌘↩ works without touching the mouse. The editor flips it
    /// back to false once it has taken focus.
    @State private var wantsFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotesEditor(store: store, wantsFocus: $wantsFocus)
            NotesStatusRow(store: store)
            NotesActionRow(store: store, wantsFocus: $wantsFocus)

            if !store.notes.isEmpty {
                Divider()
                NotesList(store: store)
            }
        }
        .frame(minWidth: 320)
        .onAppear { wantsFocus = true }
    }
}

private struct NotesEditor: View {
    @Bindable var store: NotesStore
    @Binding var wantsFocus: Bool

    var body: some View {
        // The custom editor draws no placeholder of its own, hence the overlay.
        MarkdownEditor(
            text: $store.draft,
            focusMode: store.focusMode,
            wantsFocus: $wantsFocus,
            onCommandReturn: {
                store.save()
                wantsFocus = true
            }
        )
        .frame(minHeight: 200)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            if store.draft.isEmpty {
                Text("Write or paste something…  **markdown** works")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Word/character count on the left, focus-mode toggle on the right — the
/// writing chrome iA Writer keeps at the edges of the page.
private struct NotesStatusRow: View {
    @Bindable var store: NotesStore

    var body: some View {
        HStack(spacing: 8) {
            Text("^[\(store.wordCount) word](inflect: true) · \(store.characterCount) characters")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Spacer()

            Toggle(isOn: $store.focusMode) {
                Label("Focus", systemImage: "scope")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .font(.caption)
            .help("Focus mode: dim everything but the paragraph you're writing")
        }
    }
}

private struct NotesActionRow: View {
    @Bindable var store: NotesStore
    @Binding var wantsFocus: Bool

    var body: some View {
        HStack(spacing: 8) {
            if store.isEditing {
                Label("Editing a saved note", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(store.isEditing ? "Cancel" : "Clear") {
                store.clearDraft()
                wantsFocus = true
            }
            .disabled(store.draft.isEmpty)

            Button(store.isEditing ? "Update" : "Save") {
                store.save()
                wantsFocus = true
            }
            .buttonStyle(.borderedProminent)
            // ↩ alone has to stay as-is: it's a newline in the field. The editor
            // also intercepts ⌘↩ directly, for when this button is disabled.
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!store.canSave)
            .help("Save this note (⌘↩)")
        }
    }
}

private struct NotesList: View {
    @Bindable var store: NotesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("^[\(store.notes.count) note](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // A plain VStack, not a List: the popover and the tool window both
            // already scroll, and a nested scroller would trap the wheel.
            ForEach(store.notes) { note in
                NotesRow(note: note, store: store)
                if note.id != store.notes.last?.id { Divider() }
            }
        }
    }
}

private struct NotesRow: View {
    let note: Note
    let store: NotesStore

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.renderedTitle)
                    .font(.callout)
                    .lineLimit(1)
                if !note.detail.isEmpty {
                    Text(note.renderedDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { store.edit(note) }

            // Kept mounted rather than shown on hover alone: appearing controls
            // shift the row under the pointer the moment you aim at them.
            HStack(spacing: 4) {
                Button {
                    store.copyToPasteboard(note)
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .help("Copy this note")

                Button {
                    store.delete(note)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this note")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
        .help("Click to edit this note")
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopy = false
        }
    }
}

// MARK: - Settings UI

private struct NotesSettings: View {
    @Bindable var store: NotesStore

    @State private var isConfirmingDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes are stored on this Mac only, as plain markdown — don't keep passwords or other secrets here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("^[\(store.notes.count) note](inflect: true) saved")
                Spacer()
                Button("Delete All…") { isConfirmingDeleteAll = true }
                    .disabled(store.notes.isEmpty)
            }
        }
        .confirmationDialog(
            "Delete all notes?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}
