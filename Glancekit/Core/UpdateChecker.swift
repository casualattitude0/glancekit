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
        /// `progress` is a 0...1 fraction of bytes received once the response
        /// discloses a Content-Length, and `nil` while the total is unknown.
        /// GitHub's asset redirect can answer without one, and `URLSession` then
        /// reports `NSURLSessionTransferSizeUnknown` for the expected size, which
        /// no fraction can be computed from. `nil` says "indeterminate" so the UI
        /// can show a spinner, rather than a number nobody measured.
        case downloading(progress: Double?)
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

    /// Highest fraction published for the download in flight, reset per download.
    /// Main-actor state, deliberately separate from the delegate's own throttle:
    /// each report crosses the queue boundary as its own Task, and those are not
    /// guaranteed to run in the order they were created.
    private var progressFloor: Double = -1

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

    /// Download to ~/Downloads, reporting byte progress as it goes.
    ///
    /// `URLSession.download(from:)` is the shorter call, but it hands back only a
    /// finished file: there is no byte-level callback anywhere in it, which is why
    /// this went through a delegate instead.
    private func download(_ url: URL, suggestedName: String?) async throws -> URL {
        // Indeterminate until the first callback tells us whether a total exists.
        phase = .downloading(progress: nil)
        progressFloor = -1

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = suggestedName ?? url.lastPathComponent

        // Delegate callbacks land on the session's own queue, so a fraction has
        // to hop to the main actor before it touches @Observable state. Each hop
        // is its own Task, and two Tasks enqueued back to back can run in either
        // order, so the delegate's ascending fractions can arrive descending.
        // The floor drops any report that would walk the bar backwards, and the
        // phase guard drops reports that land after checkAndDownload() has
        // already advanced to .downloaded.
        let report: @Sendable (Double?) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                if let fraction {
                    guard fraction >= self.progressFloor else { return }
                    self.progressFloor = fraction
                }
                self.phase = .downloading(progress: fraction)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                destination: { @Sendable in Self.uniqueDestination(in: downloads, name: name) },
                onProgress: report,
                continuation: continuation
            )
            // A session holds its delegate until invalidated. Invalidating right
            // after resume() still lets this task finish, and then releases both.
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }

    // MARK: - Helpers

    private static func isDownloadable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".dmg") || lower.hasSuffix(".zip")
    }

    /// Avoid clobbering an existing download by appending " (n)" before the ext.
    ///
    /// `nonisolated` because the delegate calls this from the session's queue,
    /// synchronously, while the temp file still exists. It reads no main-actor
    /// state, so claiming main-actor isolation would only be a lie the compiler
    /// stops believing under Swift 6. Keep it free of `self` for that reason.
    nonisolated private static func uniqueDestination(in dir: URL, name: String) -> URL {
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

/// Carries one download's byte counts back to `UpdateChecker`.
///
/// `URLSessionDownloadDelegate` is an `@objc` protocol and needs an `NSObject`.
/// `UpdateChecker` can't be that itself: it's `@MainActor @Observable`, and the
/// macro's observation would then sit on top of NSObject's KVO, while the session
/// called main-actor methods from its own queue. A separate forwarder keeps the
/// two worlds apart — it lives entirely on the session's queue and hands values
/// across one explicit main-actor hop that `onProgress` owns.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    /// Resolved inside `didFinishDownloadingTo`, not before: the "(2)" suffix
    /// search only means anything at the moment the file is about to land.
    private let destination: @Sendable () -> URL
    private let onProgress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    /// Last fraction handed upward, so a hundred-megabyte .dmg doesn't queue a
    /// main-actor hop per packet.
    private var lastReported: Double = -1
    private var reportedIndeterminate = false

    init(destination: @escaping @Sendable () -> URL,
         onProgress: @escaping @Sendable (Double?) -> Void,
         continuation: CheckedContinuation<URL, Error>) {
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    /// A session serializes its delegate callbacks, so the state above needs no
    /// lock. What it does need is once-only resumption: a successful download
    /// fires `didFinishDownloadingTo` *and* `didCompleteWithError`, and resuming
    /// a continuation twice traps.
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // NSURLSessionTransferSizeUnknown (-1) when the response carried no
        // Content-Length. Report the absence once and stay quiet after that.
        // A redirect can also drop the length mid-stream, after a real fraction
        // has been shown; collapsing the bar to a spinner then would discard a
        // measurement the user already has, so hold the last fraction instead.
        guard totalBytesExpectedToWrite > 0 else {
            guard lastReported < 0, !reportedIndeterminate else { return }
            reportedIndeterminate = true
            onProgress(nil)
            return
        }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
        lastReported = fraction
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finish(.failure(NetworkClient.NetworkError.http(http.statusCode)))
            return
        }
        // `location` is unlinked as soon as this method returns, so the move has
        // to run here and now. Handing the URL to a Task would race the delete.
        do {
            let dest = destination()
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            // A successful download already resumed above, making this a no-op.
            // Landing here with no error and no file means nothing was written.
            finish(.failure(URLError(.zeroByteResource)))
        }
    }
}
