import Foundation
import AppKit

/// Checks GitHub Releases for a newer build and installs it in place on demand.
///
/// Backing the "Check for Updates" button. The flow is: hit the public
/// `releases/latest` endpoint, compare the tag against the running app's
/// `CFBundleShortVersionString`, and — when newer — download the `.zip` asset,
/// unpack it, and **replace the running app bundle in place**, then relaunch.
/// The swap can't run in-process (the executable is memory-mapped and busy while
/// we're alive), so a small detached helper waits for us to quit, rsyncs the new
/// bundle over the old one, refreshes the widget daemons, and reopens the app.
///
/// Fallbacks, in order: a release that ships only a `.dmg` (or whose install
/// location isn't writable — e.g. a copy the user can't modify) reverts to the
/// old behavior of saving the asset to ~/Downloads and revealing it in Finder;
/// a release with no binary asset opens its web page.
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
        case installing                 // unpacking + swapping the bundle in place
        case relaunching                // helper launched; the app is about to quit
        case downloaded(URL)            // fallback: asset saved to ~/Downloads
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

    /// Check GitHub for a newer release and, if one exists, install it in place.
    /// Safe to call repeatedly; a check or install already in flight is ignored.
    func checkAndDownload() async {
        switch phase {
        case .checking, .downloading, .installing, .relaunching: return
        default: break
        }

        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            guard Self.isNewer(release.version, than: currentVersion) else {
                phase = .upToDate
                return
            }
            guard let asset = release.asset, let name = release.assetName else {
                // Newer version exists but nothing to auto-download — open the page.
                phase = .updateAvailable(release)
                NSWorkspace.shared.open(release.htmlURL)
                return
            }

            // A `.zip` is an app bundle we can swap in place; a `.dmg` needs
            // mounting and a manual drag, so it keeps the reveal-in-Finder path.
            // In-place install also needs a writable bundle location — a copy the
            // user can't modify (owned by another user, on a read-only volume)
            // falls back to the download so they can install it by hand.
            if name.lowercased().hasSuffix(".zip"), Self.canInstallInPlace {
                let zip = try await download(asset, suggestedName: name,
                                            directory: FileManager.default.temporaryDirectory)
                try await installUpdate(zipAt: zip, version: release.version)
                // installUpdate quits the app on success; nothing runs past it.
            } else {
                let dest = try await download(asset, suggestedName: name)
                phase = .downloaded(dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Whether the running bundle can be replaced in place: its location and the
    /// directory it lives in must both be writable by this user. A drag-installed
    /// `/Applications/Glancekit.app` is user-owned and passes; a copy installed by
    /// another admin, or one on a read-only mount, does not.
    private static var canInstallInPlace: Bool {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        return fm.isWritableFile(atPath: bundle.path)
            && fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
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

    /// Sort key so a `.zip` is preferred over a `.dmg`. The zip is a bare app
    /// bundle this updater can unpack and swap in place; the dmg is the manual,
    /// drag-to-install fallback. (Prior to in-place updates this order was
    /// reversed.)
    private func rank(_ asset: [String: Any]) -> Int {
        let name = (asset["name"] as? String ?? "").lowercased()
        if name.hasSuffix(".zip") { return 0 }
        if name.hasSuffix(".dmg") { return 1 }
        return 2
    }

    /// Download to ~/Downloads, reporting byte progress as it goes.
    ///
    /// `URLSession.download(from:)` is the shorter call, but it hands back only a
    /// finished file: there is no byte-level callback anywhere in it, which is why
    /// this went through a delegate instead.
    private func download(_ url: URL, suggestedName: String?, directory: URL? = nil) async throws -> URL {
        // Indeterminate until the first callback tells us whether a total exists.
        phase = .downloading(progress: nil)
        progressFloor = -1

        let downloads = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
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

    // MARK: - In-place install

    /// Unpack the downloaded `.zip`, validate the app inside it, then hand the
    /// swap to a detached helper and quit so the helper can overwrite our
    /// now-idle bundle and relaunch us. On any failure before the helper starts,
    /// the temp working directory is cleaned up and the error surfaces as
    /// `.failed`; once the helper is running the app terminates and never returns.
    private func installUpdate(zipAt zip: URL, version: String) async throws {
        phase = .installing
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("GlancekitUpdate-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            // `ditto -x -k` mirrors the `ditto -c -k` that built the release zip,
            // merging its AppleDouble metadata instead of scattering ._ files.
            try await Self.runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

            guard let newApp = Self.locateApp(in: work) else {
                throw NetworkClient.NetworkError.decoding("Update archive had no .app bundle")
            }
            try await Self.validate(newApp, expectedVersion: version)

            try Self.launchSwapHelper(newApp: newApp, dest: Bundle.main.bundleURL, workDir: work)
        } catch {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: zip)
            throw error
        }

        // The helper is waiting on our PID. Quit so it can replace the bundle.
        phase = .relaunching
        NSApp.terminate(nil)
    }

    /// The first `*.app` at the archive's top level (the release zip stores it as
    /// `Glancekit.app/…`, but tolerate a leading folder just in case).
    nonisolated private static func locateApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let app = top.first(where: { $0.pathExtension == "app" }) { return app }
        for sub in top where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let inner = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            if let app = inner.first(where: { $0.pathExtension == "app" }) { return app }
        }
        return nil
    }

    /// Refuse to install anything that isn't the same app, a genuinely newer
    /// version, and validly signed. The download is HTTPS from GitHub, but a
    /// signature check is cheap insurance against a corrupted or swapped payload
    /// before we hand it to a helper that will overwrite the running app.
    nonisolated private static func validate(_ app: URL, expectedVersion: String) async throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw NetworkClient.NetworkError.decoding("Update bundle has no Info.plist")
        }
        let newID = info["CFBundleIdentifier"] as? String
        guard newID == Bundle.main.bundleIdentifier else {
            throw NetworkClient.NetworkError.decoding("Update bundle identifier mismatch")
        }
        let newVersion = info["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(newVersion, than: expectedVersion) || normalize(newVersion) == normalize(expectedVersion) else {
            throw NetworkClient.NetworkError.decoding("Update bundle is version \(newVersion), expected \(expectedVersion)")
        }
        // `codesign -v` returns non-zero on a broken/altered signature.
        do {
            try await runProcess("/usr/bin/codesign", ["-v", "--strict", app.path])
        } catch {
            throw NetworkClient.NetworkError.decoding("Downloaded update failed its code-signature check")
        }
    }

    /// Write a swap-and-relaunch script, launch it detached, and return. The
    /// script outlives us on purpose: it waits for this PID to exit, replaces the
    /// bundle **in place** (rsync --delete keeps the bundle directory itself, so
    /// chronod doesn't prune placed-widget instances — the same reason
    /// scripts/install.sh never `rm -rf`s the destination), clears the download
    /// quarantine, re-registers with LaunchServices, restarts the widget daemons,
    /// and reopens the app.
    nonisolated private static func launchSwapHelper(newApp: URL, dest: URL, workDir: URL) throws {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework"
            + "/Frameworks/LaunchServices.framework/Support/lsregister"
        let script = """
        #!/bin/bash
        set -u
        pid="$1"; new="$2"; dst="$3"; work="$4"
        # Wait (up to ~15s) for the old app to release its executable.
        for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        # Swap contents while keeping the bundle directory in place. --checksum
        # compares by content, not size+mtime: two builds of the same file can
        # share both, and rsync's default quick-check would then skip the very
        # executable we're here to replace.
        if [ -d "$dst" ]; then
          rsync -a --delete --checksum "$new/" "$dst/"
        else
          ditto "$new" "$dst"
        fi
        xattr -dr com.apple.quarantine "$dst" 2>/dev/null || true
        "\(lsregister)" -f -R "$dst" 2>/dev/null || true
        killall pkd chronod 2>/dev/null || true
        rm -rf "$work"
        open "$dst"
        """
        let scriptURL = workDir.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            newApp.path,
            dest.path,
            workDir.path,
        ]
        // Detach from our stdio so the child isn't tied to a pipe we're closing.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        try proc.run()   // fire-and-forget; do not wait — we're about to exit
    }

    /// Run a tool and await its exit off the main actor, throwing on non-zero.
    nonisolated private static func runProcess(_ launchPath: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: NetworkClient.NetworkError.decoding(
                        "\(URL(fileURLWithPath: launchPath).lastPathComponent) exited \(p.terminationStatus)"))
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
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
    nonisolated static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Keep only the numeric dotted core (drop "-beta.1", "+build", etc.).
        if let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first {
            return String(core)
        }
        return s
    }

    /// Semantic-ish comparison of dotted numeric versions ("1.2.0" > "1.1.9").
    nonisolated static func isNewer(_ lhs: String, than rhs: String) -> Bool {
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
