import SwiftUI

/// Shared building blocks for every settings page, so they read as one design
/// instead of twenty hand-rolled variants.
///
/// The Settings detail pane already supplies the `ScrollView` and a 20pt inset
/// (see `SettingsView.detail`), so pages never add their own outer padding or
/// scroller — they start with a `SettingsPage` (a leading `VStack`) and fill it
/// with the components here.
///
/// The vocabulary, smallest to largest:
/// - ``SettingsPage`` — the page scaffold: a leading `VStack` at the standard
///   rhythm, opening with a title + optional intro caption.
/// - ``SettingsGroup`` — a titled run of related rows with a subheadline
///   header (no border), the default grouping.
/// - ``SettingsCard`` — a titled *bordered* run of rows, for pages that want the
///   System-Settings card look (Shortcuts, Notifications).
/// - ``SettingsRow`` — one label(+detail) on the left, a control in a shared
///   trailing column on the right. The column is why switches, pickers and
///   buttons line up down the page.
/// - ``SettingsToggleRow`` — the common case of ``SettingsRow`` whose control is
///   a switch. Every on/off setting uses this, so toggles look and sit the same
///   everywhere.
/// - ``SettingsHelp`` — secondary caption text for explanations.
/// - ``LabeledField`` — a caption stacked above a text/secure field, for the
///   form-entry pages (keys, URLs).
enum SettingsMetrics {
    /// Vertical gap between the top-level elements of a page.
    static let pageSpacing: CGFloat = 14
    /// Vertical gap between a section header and its body / between rows.
    static let sectionSpacing: CGFloat = 6
    /// The trailing control column caps its width here. A filling control (a
    /// segmented picker, a slider) grows to this and no further, so wide controls
    /// line up down the page; a switch or button shrinks to its own size and
    /// hands the rest of the column back to the label and detail text, which is
    /// what keeps captions from crowding into a narrow gutter.
    static let controlColumn: CGFloat = 190
    /// Inset inside a row.
    static let rowInsetH: CGFloat = 12
    static let rowInsetV: CGFloat = 8
    static let cardCornerRadius: CGFloat = 8
}

// MARK: - Page scaffold

/// The standard page scaffold: a leading `VStack` at the shared rhythm, opening
/// with a `.headline` title and an optional secondary intro caption.
struct SettingsPage<Content: View>: View {
    let title: String
    var intro: String? = nil
    @ViewBuilder var content: Content

    init(_ title: String, intro: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.intro = intro
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.pageSpacing) {
            Text(title)
                .font(.headline)
            if let intro {
                SettingsHelp(intro)
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Section headers

/// A section header: `.subheadline.weight(.semibold)` in secondary, the single
/// in-page heading idiom shared by every page.
struct SettingsSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A titled, borderless run of related rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            SettingsSectionHeader(title)
            content
        }
    }
}

/// A titled, bordered card of rows — the System-Settings card look. Rows inside
/// separate themselves with `Divider()`.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            if let title {
                SettingsSectionHeader(title)
            }
            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary)
            )
        }
    }
}

// MARK: - Rows

/// One settings row: a label (and optional detail caption) on the left, a
/// control in the shared trailing column on the right.
///
/// The fixed-width trailing column is what keeps switches, pickers, sliders and
/// buttons on one right edge down the page instead of each ending wherever its
/// own content happens to.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    /// Some controls (a bare segmented picker, a slider) look better filling the
    /// column; a switch or button wants to sit at the trailing edge. A filling
    /// control claims the full column width; a trailing one shrinks to its own
    /// size and leaves the rest of the column to the label and detail text.
    var controlAlignment: Alignment = .trailing
    @ViewBuilder var control: Control

    init(
        _ title: String,
        detail: String? = nil,
        controlAlignment: Alignment = .trailing,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.controlAlignment = controlAlignment
        self.control = control()
    }

    /// A control that isn't trailing-aligned wants to fill the column (a
    /// segmented picker, a slider); a trailing one shrinks to its own size.
    private var isFillingControl: Bool { controlAlignment != .trailing }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The label column claims every point the control leaves — without
            // this the intervening spacer wins the tug-of-war for slack width and
            // the caption is crushed into a narrow gutter while empty space sits
            // between it and the control.
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                // A filling control (non-trailing) takes the whole column so
                // wide controls align; a trailing control (switch, button) caps
                // at the column but shrinks to its own width, returning the slack
                // to the text so captions stop crowding into a narrow gutter.
                .frame(
                    minWidth: isFillingControl ? SettingsMetrics.controlColumn : nil,
                    maxWidth: SettingsMetrics.controlColumn,
                    alignment: controlAlignment
                )
        }
        .padding(.horizontal, SettingsMetrics.rowInsetH)
        .padding(.vertical, SettingsMetrics.rowInsetV)
    }
}

/// The common case: a row whose control is a switch. Every on/off setting uses
/// this so toggles look and sit identically across pages.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Text

/// Secondary caption text — the single style for every explanation and help line.
struct SettingsHelp: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A caption stacked above its field — the form row the key/URL entry pages use.
struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content
        }
    }
}
