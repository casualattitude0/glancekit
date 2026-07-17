import Foundation
import AppKit

/// Checks GitHub Releases for a newer build and downloads it on demand.
///
/// Backing the "download latest version" button in the popover header. The flow
/// is: hit the public `releases/latest` endpoint, compare the tag against the
/// running app's `CFBundleShortVersionString`, and — when newer — download the
/// first distributable asset (`.dmg`/`.zip`) to ~/Downloads and reveal it in
/// Finder. If a release carries no binary asset we fall back to opening its
/// web page so the user can grab it manually.
@MainActor
@Observable
final class UpdateChecker {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(progress: Double)
        case downloaded(URL)
        case updateAvailable(Release)   // newer release, but no downloadable asset
        case failed(String)
    }

    struct Release: Equatable {
        var version: String          // normalized, e.g. "1.2.0"
        var tag: String              // raw tag, e.g. "v1.2.0"
        var htmlURL: URL
        var asset: URL?              // first .dmg/.zip download, if any
        var assetName: String?
    }

    /// `owner/repo` slug the updater checks against.
    static let repoSlug = "casualattitude0/glancekit"

    private(set) var phase: Phase = .idle

    private let network = NetworkClient()

    /// Current version from the app bundle (falls back to "0" if unreadable).
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Check GitHub for a newer release and, if one exists, download it. Safe to
    /// call repeatedly; a check already in flight is ignored.
    func checkAndDownload() async {
        if case .checking = phase { return }
        if case .downloading = phase { return }

        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            guard Self.isNewer(release.version, than: currentVersion) else {
                phase = .upToDate
                return
            }
            guard let asset = release.asset else {
                // Newer version exists but nothing to auto-download — open the page.
                phase = .updateAvailable(release)
                NSWorkspace.shared.open(release.htmlURL)
                return
            }
            let dest = try await download(asset, suggestedName: release.assetName)
            phase = .downloaded(dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Networking

    private func fetchLatestRelease() async throws -> Release {
        let data = try await network.data(
            from: "https://api.github.com/repos/\(Self.repoSlug)/releases/latest",
            headers: ["Accept": "application/vnd.github+json"]
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlString = json["html_url"] as? String,
              let htmlURL = URL(string: htmlString)
        else {
            throw NetworkClient.NetworkError.decoding("Unexpected releases payload")
        }

        // Prefer a .dmg, then a .zip, from the release's uploaded assets.
        var assetURL: URL?
        var assetName: String?
        if let assets = json["assets"] as? [[String: Any]] {
            let ordered = assets.sorted { rank($0) < rank($1) }
            for asset in ordered {
                guard let name = asset["name"] as? String,
                      Self.isDownloadable(name),
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString)
                else { continue }
                assetURL = url
                assetName = name
                break
            }
        }

        return Release(
            version: Self.normalize(tag),
            tag: tag,
            htmlURL: htmlURL,
            asset: assetURL,
            assetName: assetName
        )
    }

    /// Sort key so `.dmg` assets are preferred over `.zip`.
    private func rank(_ asset: [String: Any]) -> Int {
        let name = (asset["name"] as? String ?? "").lowercased()
        if name.hasSuffix(".dmg") { return 0 }
        if name.hasSuffix(".zip") { return 1 }
        return 2
    }

    private func download(_ url: URL, suggestedName: String?) async throws -> URL {
        phase = .downloading(progress: 0)
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NetworkClient.NetworkError.http(http.statusCode)
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = suggestedName ?? url.lastPathComponent
        let dest = Self.uniqueDestination(in: downloads, name: name)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - Helpers

    private static func isDownloadable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".dmg") || lower.hasSuffix(".zip")
    }

    /// Avoid clobbering an existing download by appending " (n)" before the ext.
    private static func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var i = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Strip a leading "v" and any pre-release/build suffix for comparison.
    static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Keep only the numeric dotted core (drop "-beta.1", "+build", etc.).
        if let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first {
            return String(core)
        }
        return s
    }

    /// Semantic-ish comparison of dotted numeric versions ("1.2.0" > "1.1.9").
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = normalize(lhs).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalize(rhs).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
