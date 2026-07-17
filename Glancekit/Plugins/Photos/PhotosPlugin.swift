import SwiftUI
import Observation
import AppKit
import Photos

/// A rotating photo slideshow shown in the popover, sourced either from a
/// user-chosen folder on disk (security-scoped bookmark) or from the macOS
/// Photos library (PhotoKit).
///
/// Popover-only glance — contributes nothing to the menu-bar summary.
@MainActor
@Observable
final class PhotosPlugin: GlancePlugin {
    nonisolated var id: String { "photos" }
    nonisolated var title: String { "Photos" }
    nonisolated var iconSystemName: String { "photo.on.rectangle" }
    /// Reload the slide list every ~10 minutes; slide-to-slide advance is
    /// handled locally by a timer in the popover view.
    var refreshInterval: TimeInterval { 600 }
    var menuBarSummary: String? { nil }

    private static let sourceKey = "glancekit.photos.source"
    private static let intervalKey = "glancekit.photos.interval"

    var source: PhotoSourceKind {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            Task { await refresh() }
        }
    }

    /// Seconds between slide advances in the popover.
    var slideInterval: Double {
        didSet { UserDefaults.standard.set(slideInterval, forKey: Self.intervalKey) }
    }

    private(set) var slides: [PhotoSlide] = []
    private(set) var lastError: String?
    private(set) var photosAuthStatus: PHAuthorizationStatus = .notDetermined

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.sourceKey),
           let kind = PhotoSourceKind(rawValue: raw) {
            source = kind
        } else {
            source = .folder
        }
        let savedInterval = UserDefaults.standard.double(forKey: Self.intervalKey)
        slideInterval = savedInterval > 0 ? savedInterval : 5
        photosAuthStatus = LibraryPhotoLoader.authorizationStatus
    }

    /// Re-reads the current Photos authorization status (called from Settings).
    func syncAuthStatus() {
        photosAuthStatus = LibraryPhotoLoader.authorizationStatus
    }

    // MARK: GlancePlugin

    func refresh() async {
        switch source {
        case .folder:
            let loaded = await Task.detached(priority: .utility) {
                FolderPhotoLoader.loadSlides()
            }.value
            slides = loaded
            lastError = loaded.isEmpty ? "No photos found. Choose a folder in Settings." : nil

        case .photosLibrary:
            photosAuthStatus = LibraryPhotoLoader.authorizationStatus
            guard photosAuthStatus == .authorized || photosAuthStatus == .limited else {
                slides = []
                lastError = "Photos access not granted."
                return
            }
            let loaded = await LibraryPhotoLoader.loadSlides()
            slides = loaded
            lastError = loaded.isEmpty ? "No photos found in your library." : nil
        }
    }

    func requestPhotosAccess() {
        Task { await requestPhotosAccessAsync() }
    }

    /// Awaitable variant used by the permission gate so it can re-render once the
    /// system prompt is dismissed.
    func requestPhotosAccessAsync() async {
        photosAuthStatus = await LibraryPhotoLoader.requestAuthorization()
        await refresh()
    }

    /// The Photos library permission is only needed in `.library` source mode;
    /// folder mode reads a user-picked folder and needs no system permission.
    var requiredPermissions: [GlancePermission] {
        guard source == .photosLibrary else { return [] }
        return [GlancePermission(
            id: "photos.library",
            title: "Photos",
            iconSystemName: "photo.on.rectangle",
            rationale: "Show photos from your library.",
            status: { [weak self] in
                switch self?.photosAuthStatus ?? LibraryPhotoLoader.authorizationStatus {
                case .authorized, .limited: return .granted
                case .denied, .restricted: return .denied
                default: return .notDetermined
                }
            },
            request: { [weak self] in await self?.requestPhotosAccessAsync() },
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        )]
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FolderPhotoLoader.saveBookmark(for: url)
        Task { await refresh() }
    }

    func popoverSection() -> AnyView {
        AnyView(PhotosPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(PhotosSettings(plugin: self))
    }
}

// MARK: - Popover UI

private struct PhotosPopover: View {
    let plugin: PhotosPlugin
    @State private var index: Int = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = plugin.lastError, plugin.slides.isEmpty {
                emptyState(message: err)
            } else if plugin.slides.isEmpty {
                emptyState(message: "No photos / choose a source")
            } else {
                let slide = plugin.slides[index % plugin.slides.count]
                Image(nsImage: slide.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 300, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(slide.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 300)
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: plugin.slideInterval) { _, _ in startTimer() }
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 300, height: 180)
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = max(plugin.slideInterval, 1)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                guard !plugin.slides.isEmpty else { return }
                index = (index + 1) % plugin.slides.count
            }
        }
    }
}

// MARK: - Settings UI

private struct PhotosSettings: View {
    @Bindable var plugin: PhotosPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Source")
                .font(.headline)
            Picker("", selection: $plugin.source) {
                ForEach(PhotoSourceKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch plugin.source {
            case .folder:
                Button("Choose folder…") { plugin.chooseFolder() }

            case .photosLibrary:
                switch plugin.photosAuthStatus {
                case .authorized, .limited:
                    Label("Photos access granted", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .denied, .restricted:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Photos access denied.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                default:
                    Button("Grant Photos access") { plugin.requestPhotosAccess() }
                }
            }

            Divider()

            Text("Slide interval")
                .font(.headline)
            Stepper(value: $plugin.slideInterval, in: 2...60, step: 1) {
                Text("\(Int(plugin.slideInterval)) seconds")
            }

            if let err = plugin.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            plugin.syncAuthStatus()
        }
    }
}
