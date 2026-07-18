import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// TOUR OVERLAY
// ─────────────────────────────────────────────────────────────────────────────
// The visual layer of the guided tour: a dimming scrim with a spotlight cut out
// over the step's sidebar page, an accent ring around it, and a callout card
// beside it with the copy and the Back / Next / Done controls.
//
// It finds the page to spotlight through anchor preferences: the sidebar rows in
// `SettingsView` tag themselves with `.tutorialAnchor(id)`, this reads the frame
// for the current step's `anchorID`. That keeps the overlay decoupled from the
// sidebar's layout — it never needs to know where the rows actually sit.
// ─────────────────────────────────────────────────────────────────────────────

/// Collects the frames of the sidebar rows that opt into the tour, keyed by id.
struct TutorialAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Publish this view's bounds under `id` so `TutorialOverlay` can spotlight
    /// it. Rows always publish, whether or not a tour is running — the anchors
    /// are cheap and the overlay just ignores them when idle.
    func tutorialAnchor(_ id: String) -> some View {
        anchorPreference(key: TutorialAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

struct TutorialOverlay: View {
    @Environment(TutorialController.self) private var tutorial

    let anchors: [String: Anchor<CGRect>]
    let proxy: GeometryProxy

    private var accent: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.purple, Color.pink],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        if let step = tutorial.currentStep {
            // The row's frame in the overlay's own coordinate space. A step with
            // no resolved anchor (shouldn't happen — the rows are always present)
            // still shows the card centred, just without a spotlight.
            let spot = anchors[step.anchorID].map { proxy[$0].insetBy(dx: -6, dy: -4) }

            ZStack(alignment: .topLeading) {
                scrim(cutout: spot)
                if let spot { ring(spot) }
                card(step: step, near: spot)
            }
            .animation(.easeInOut(duration: 0.25), value: step)
        }
    }

    // MARK: - Scrim + spotlight

    /// Dims the whole window except a rounded hole over `cutout`, using an
    /// even-odd fill so the highlighted row shows through at full brightness.
    private func scrim(cutout: CGRect?) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: proxy.size))
            if let cutout {
                path.addRoundedRect(in: cutout, cornerSize: CGSize(width: 8, height: 8))
            }
        }
        .fill(Color.black.opacity(0.34), style: FillStyle(eoFill: true))
        // Swallow clicks on the dimmed area so the tour stays in control; the
        // card's own buttons sit above this and still receive theirs.
        .contentShape(Rectangle())
    }

    private func ring(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(accent, lineWidth: 2)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
            .allowsHitTesting(false)
    }

    // MARK: - Callout card

    private func card(step: TutorialController.Step, near spot: CGRect?) -> some View {
        let width: CGFloat = 288
        // Sit the card just right of the spotlighted sidebar row, in the detail
        // pane's empty space, vertically aligned to the row's top. Clamp so it
        // never spills past the window on either axis.
        let rawX = (spot?.maxX ?? proxy.size.width / 2 - width / 2) + 18
        let x = min(rawX, proxy.size.width - width - 16)
        let rawY = (spot?.minY ?? proxy.size.height / 2 - 120) - 6
        let y = min(max(rawY, 16), proxy.size.height - 210)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: step.iconSystemName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(step.title)
                    .font(.headline)
                Spacer(minLength: 0)
            }

            Text(step.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                progressDots
                Spacer(minLength: 0)
                if tutorial.currentStep != .glances {
                    Button("Back") { tutorial.back() }
                        .buttonStyle(.bordered)
                }
                Button(isLastStep ? "Done" : "Next") { tutorial.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .overlay(alignment: .topTrailing) {
            Button { tutorial.finish() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Skip the tour")
            .padding(10)
        }
        .offset(x: x, y: y)
    }

    private var isLastStep: Bool {
        tutorial.stepNumber == tutorial.stepCount
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<tutorial.stepCount, id: \.self) { index in
                Circle()
                    .fill(index == tutorial.stepNumber - 1 ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
