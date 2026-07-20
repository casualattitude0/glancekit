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

    let store = NotesStore.shared

    func refresh() async {}

    /// A real writing surface earns a roomier standalone window than the default
    /// 360×520 — wide enough for the Mac-Notes-style two-pane (saved list beside
    /// the editor), tall enough for both to breathe. In the narrow menu-bar
    /// popover the same view collapses to a single column (see `NotesPopover`).
    var preferredToolWindowSize: CGSize? { CGSize(width: 660, height: 640) }

    func popoverSection() -> AnyView { AnyView(NotesPopover(store: store)) }
    func settingsSection() -> AnyView { AnyView(NotesSettings(store: store)) }
}

// MARK: - Popover UI
//
// The same section renders in two very different containers: a 240pt column in
// the menu-bar popover, and a wide standalone tool window (see
// `preferredToolWindowSize`). So it has two shapes, chosen by `ViewThatFits`:
//
//   • Two-pane — a Mac-Notes-style saved-list sidebar on the LEFT beside the
//     editor, when there's room (the standalone window).
//   • Single column — editor on top, saved shelf below, in the narrow menu.
//
// `ViewThatFits` takes the widest layout that actually fits its container, so
// the section can never overflow — which is exactly what was bleeding Notes
// over the neighbouring glance in the menu popover.

private struct NotesPopover: View {
    @Bindable var store: NotesStore

    /// One-shot request to put the caret in the field when the window opens, so
    /// ⌥2 → paste → ⌘↩ works without touching the mouse. The editor flips it
    /// back to false once it has taken focus.
    @State private var wantsFocus = false

    /// Which editing surface is showing. Transient view state — a fresh window
    /// always opens ready to write.
    @State private var mode: NotesMode = .write

    var body: some View {
        ViewThatFits(in: .horizontal) {
            twoPane
            singleColumn
        }
        .onAppear { wantsFocus = true }
    }

    /// Sidebar of saved notes on the left, editor on the right.
    private var twoPane: some View {
        HStack(alignment: .top, spacing: 0) {
            NotesSidebar(store: store, wantsFocus: $wantsFocus)
                .frame(width: 214)

            Divider()

            NotesEditorColumn(store: store, mode: $mode,
                              wantsFocus: $wantsFocus, showNewNote: false)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 16)
        }
        // A hard floor so `ViewThatFits` only takes this in the wide standalone
        // window and falls back to the single column in the narrow menu.
        .frame(minWidth: 500, alignment: .topLeading)
    }

    /// Editor on top, saved shelf below — the compact menu-popover shape.
    private var singleColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotesEditorColumn(store: store, mode: $mode,
                              wantsFocus: $wantsFocus, showNewNote: true)
            if !store.notes.isEmpty {
                NotesShelf(store: store)
            }
        }
    }
}

/// The editor half: mode toolbar, the editing surface (or preview), and the
/// count/save footer. Shared by both layouts.
private struct NotesEditorColumn: View {
    @Bindable var store: NotesStore
    @Binding var mode: NotesMode
    @Binding var wantsFocus: Bool
    /// Whether the mode toolbar carries the New Note button. The two-pane layout
    /// puts it in the sidebar instead, so this is false there.
    var showNewNote: Bool

    /// Lives here rather than in the JSON pane because the status bar — a
    /// sibling view — drives it too.
    @State private var foldController = JSONFoldController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotesToolbar(store: store, mode: $mode,
                         wantsFocus: $wantsFocus, showNewNote: showNewNote)

            Group {
                switch mode {
                case .write:
                    NotesEditor(store: store, wantsFocus: $wantsFocus)
                case .json:
                    NotesJSONEditor(store: store, wantsFocus: $wantsFocus,
                                    foldController: foldController)
                case .preview:
                    NotesPreviewPane(store: store)
                }
            }

            if mode == .json {
                NotesJSONStatusBar(store: store, foldController: foldController)
            }

            NotesFooter(store: store, wantsFocus: $wantsFocus)
        }
    }
}

/// Mode switch on the left; New Note (optional) and Focus on the right.
private struct NotesToolbar: View {
    @Bindable var store: NotesStore
    @Binding var mode: NotesMode
    @Binding var wantsFocus: Bool
    var showNewNote: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(NotesMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: mode) { _, mode in
                // Coming back to an editable surface, put the caret straight
                // back in it.
                if mode != .preview { wantsFocus = true }
            }

            Spacer()

            if showNewNote {
                NewNoteButton(store: store, wantsFocus: $wantsFocus)
            }

            Toggle(isOn: $store.focusMode) {
                Label("Focus", systemImage: "scope")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .controlSize(.large)
            // Focus mode is a prose gesture: it dims all but the paragraph
            // you're in, which means nothing in rendered preview or in JSON,
            // where the structure around the caret is the point.
            .disabled(mode != .write)
            .help("Focus mode: dim everything but the paragraph you're writing")
        }
    }
}

/// The compose button: start a fresh draft (banking any unsaved new one first).
private struct NewNoteButton: View {
    let store: NotesStore
    @Binding var wantsFocus: Bool

    var body: some View {
        Button {
            store.newNote()
            wantsFocus = true
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .keyboardShortcut("n", modifiers: .command)
        .help("New note (⌘N)")
    }
}

/// The left pane in the two-pane layout: a header with the New Note button, then
/// the saved notes — Mac Notes' sidebar, scaled down.
private struct NotesSidebar: View {
    @Bindable var store: NotesStore
    @Binding var wantsFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Saved")
                    .font(.subheadline.weight(.semibold))
                if !store.notes.isEmpty {
                    NotesCountBadge(count: store.notes.count)
                }
                Spacer()
                NewNoteButton(store: store, wantsFocus: $wantsFocus)
            }

            if store.notes.isEmpty {
                Text("No saved notes yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                NotesRowsList(store: store)
            }

            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
    }
}

/// The stacked saved-note rows, shared by the sidebar and the shelf. A plain
/// VStack, not a List: the popover and tool window already scroll, and a nested
/// scroller would trap the wheel.
private struct NotesRowsList: View {
    @Bindable var store: NotesStore

    var body: some View {
        VStack(spacing: 1) {
            ForEach(store.notes) { note in
                NotesRow(note: note, store: store)
            }
        }
    }
}

/// The small count pill used in the sidebar header and the shelf header.
private struct NotesCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .monospacedDigit()
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
        .frame(minHeight: 220)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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

/// The same draft, edited as JSON: JSON colouring instead of markdown, and ⇥ /
/// ⇧⇥ bound to expand / collapse.
///
/// The keys are the whole feature, so they're deliberately the *primary* way to
/// format — the status bar below carries the same two actions as buttons for
/// discoverability, not as the main path.
private struct NotesJSONEditor: View {
    @Bindable var store: NotesStore
    @Binding var wantsFocus: Bool
    let foldController: JSONFoldController

    var body: some View {
        JSONEditor(
            text: $store.draft,
            foldController: foldController,
            wantsFocus: $wantsFocus,
            onCommandReturn: {
                store.save()
                wantsFocus = true
            },
            // Returning false when the draft doesn't parse lets ⇥ insert a real
            // tab instead of being swallowed — half-typed JSON still behaves
            // like a text field.
            onTab: { store.expandDraftJSON() },
            onBacktab: { store.collapseDraftJSON() }
        )
        .frame(minHeight: 220)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            if store.draft.isEmpty {
                Text("Paste JSON, then press ⇥ to format\nClick the gutter marks to fold a block")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Under the JSON field: what the draft currently is (or why it won't parse),
/// the sort-keys switch, and the two formatting actions.
private struct NotesJSONStatusBar: View {
    @Bindable var store: NotesStore
    let foldController: JSONFoldController

    var body: some View {
        HStack(spacing: 8) {
            status
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)

            Spacer(minLength: 4)

            Button {
                foldController.foldAll()
            } label: {
                Label("Fold All", systemImage: "arrow.down.right.and.arrow.up.left")
                    .labelStyle(.iconOnly)
            }
            .help("Collapse every block")

            Button {
                foldController.expandAll()
            } label: {
                Label("Expand All", systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly)
            }
            .help("Expand every block")

            Toggle("Sort keys", isOn: $store.sortJSONKeys)
                .toggleStyle(.checkbox)
                .font(.caption2)
                .help("Sort every object's keys alphabetically when formatting")

            // Only the actions dim when the draft won't parse. The status text
            // stays at full strength — it's the error explaining *why* they're
            // unavailable, so greying it out would hide the one useful thing.
            Group {
                Button("Format") { store.expandDraftJSON() }
                    .help("Expand to indented JSON (⇥)")

                Button("Minify") { store.collapseDraftJSON() }
                    .help("Collapse onto one line (⇧⇥)")
            }
            .disabled(!store.canFormatDraft)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private var status: some View {
        switch store.jsonStatus {
        case .empty:
            Text("Nothing to format yet")
                .foregroundStyle(.tertiary)
        case .valid(let summary):
            Label(summary, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .repairable(let summary, let repairs):
            // Says what it *will* change, not just that something's off — the
            // repairs are applied to your text, so they're the headline.
            Label("\(summary) · fixes on ⇥: \(repairs.joined(separator: ", "))",
                  systemImage: "wand.and.sparkles")
                .foregroundStyle(.secondary)
                .help("This isn't strict JSON, but ⇥ will repair it: \(repairs.joined(separator: ", "))")
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// The rendered-markdown view of the current draft, in the same bounded box the
/// editor uses so toggling between them doesn't jump the layout.
private struct NotesPreviewPane: View {
    @Bindable var store: NotesStore

    var body: some View {
        MarkdownPreview(text: store.draft)
            .padding(14)
            .frame(minHeight: 220, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Bottom zone of the editor: the live count and edit state on the left, the
/// save actions on the right — one row instead of two, so the eye reads
/// "how much / what state → what to do" in a single sweep.
private struct NotesFooter: View {
    @Bindable var store: NotesStore
    @Binding var wantsFocus: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("^[\(store.wordCount) word](inflect: true) · \(store.characterCount) characters")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                // Truncates rather than shoves the buttons off the edge in the
                // narrow menu column.
                .lineLimit(1)
                .layoutPriority(-1)

            if store.isEditing {
                Label("Editing", systemImage: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .transition(.opacity)
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
        .animation(.easeOut(duration: 0.15), value: store.isEditing)
    }
}

/// The saved-notes shelf below the editor in the single-column layout: a quiet
/// header and the rows.
private struct NotesShelf: View {
    @Bindable var store: NotesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Saved")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                NotesCountBadge(count: store.notes.count)
            }
            .padding(.horizontal, 2)

            NotesRowsList(store: store)
        }
        .padding(.top, 2)
    }
}

private struct NotesRow: View {
    let note: Note
    let store: NotesStore

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.renderedTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Time and the hover actions share one trailing slot, cross-faded
                // in place — both stay mounted so the row never shifts under the
                // pointer as controls appear.
                ZStack(alignment: .trailing) {
                    Text(note.updatedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 0 : 1)

                    HStack(spacing: 2) {
                        Button {
                            store.copyToPasteboard(note)
                            didCopy = true
                        } label: {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .help("Copy this note")

                        Button(role: .destructive) {
                            store.delete(note)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete this note")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .opacity(isHovering ? 1 : 0)
                }
            }

            if !note.detail.isEmpty {
                Text(note.renderedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(.rect)
        .onTapGesture { store.edit(note) }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
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

            Divider()

            Text("JSON mode")
                .font(.subheadline.weight(.semibold))

            Toggle("Sort object keys when formatting", isOn: $store.sortJSONKeys)

            Picker("Indent", selection: $store.jsonIndent) {
                Text("2 spaces").tag(2)
                Text("4 spaces").tag(4)
                Text("8 spaces").tag(8)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Text("In JSON mode, ⇥ expands the draft to indented JSON and ⇧⇥ collapses it onto one line.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
