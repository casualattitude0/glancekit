import AppKit
import ApplicationServices
import SQLite3

/// The browsers the Browsing glance can read, and the two mechanisms it uses to
/// read them.
///
/// Two families, because macOS gives us no single API for "what is the user
/// looking at":
///
/// - `.safari` / `.chromium` are asked over Apple Events for the *active tab of
///   the front window*. Cheap, live, and gated by the per-app Automation
///   permission (Privacy & Security → Automation). We only ever send an event to
///   a browser that is already running, so polling never launches one.
/// - `.firefox` exposes no scriptable URL, so we tail its `places.sqlite`
///   history database instead. That file lives under `~/Library/Application
///   Support/Firefox`, which is *not* TCC-protected — no Full Disk Access needed.
enum Browser: String, Codable, CaseIterable, Identifiable, Sendable {
    case safari
    case chrome
    case brave
    case edge
    case vivaldi
    case opera
    case arc
    case firefox

    var id: String { rawValue }

    enum Family { case safari, chromium, firefox }

    var family: Family {
        switch self {
        case .safari: return .safari
        case .firefox: return .firefox
        default: return .chromium
        }
    }

    var bundleID: String {
        switch self {
        case .safari:  return "com.apple.Safari"
        case .chrome:  return "com.google.Chrome"
        case .brave:   return "com.brave.Browser"
        case .edge:    return "com.microsoft.edgemac"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera:   return "com.operasoftware.Opera"
        case .arc:     return "company.thebrowser.Browser"
        case .firefox: return "org.mozilla.firefox"
        }
    }

    var displayName: String {
        switch self {
        case .safari:  return "Safari"
        case .chrome:  return "Chrome"
        case .brave:   return "Brave"
        case .edge:    return "Edge"
        case .vivaldi: return "Vivaldi"
        case .opera:   return "Opera"
        case .arc:     return "Arc"
        case .firefox: return "Firefox"
        }
    }

    var systemImage: String {
        switch self {
        case .safari: return "safari"
        case .firefox: return "flame"
        default: return "globe"
        }
    }

    /// True when the browser has a live process. Checked before every Apple
    /// Event so we never cause a launch.
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// True when the app is installed at all — used to hide browsers the user
    /// doesn't have from Settings.
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// The AppleScript that yields the front window's active tab, as
    /// `url \n title \n mode`. Returns an empty string when there's no window.
    /// `nil` for Firefox, which isn't reachable this way.
    var activeTabScript: String? {
        switch family {
        case .safari:
            // Safari models tabs as documents; `front document` is the active tab
            // of the frontmost window. Safari reports no private/normal mode, so
            // the third line is always "normal" — see `skipsPrivateWindows`.
            return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set d to front document
                return (URL of d) & linefeed & (name of d) & linefeed & "normal"
            end tell
            """
        case .chromium:
            return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set w to front window
                set t to active tab of w
                return (URL of t) & linefeed & (title of t) & linefeed & (mode of w)
            end tell
            """
        case .firefox:
            return nil
        }
    }
}

/// One observation of a browser's active tab.
struct ActiveTab: Sendable {
    let url: String
    let title: String
    /// True when the source window is a private/incognito window. Chromium
    /// browsers report this accurately; Safari always reports `false` because
    /// its scripting interface exposes no such property.
    let isPrivate: Bool
}

// MARK: - Apple Events

/// Serializes NSAppleScript execution onto one background thread.
///
/// `NSAppleScript` is not thread-safe and `executeAndReturnError` blocks until
/// the target app replies — which can take a while if the browser is busy. Both
/// facts make it a bad citizen on the main actor, so every execution hops to a
/// private serial queue and the caller `await`s the result. Compiled scripts are
/// cached per source string; compilation is the expensive part.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    private let queue = DispatchQueue(label: "com.glancekit.browsing.applescript", qos: .utility)
    private var compiled: [String: NSAppleScript] = [:]

    private init() {}

    /// Run `source`, returning its string result, or `nil` if it errored (app not
    /// scriptable, permission refused, no window, …). Errors are expected and
    /// non-fatal — a browser that won't answer is simply not recorded.
    func run(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let script: NSAppleScript
                if let cached = self.compiled[source] {
                    script = cached
                } else if let made = NSAppleScript(source: source) {
                    self.compiled[source] = made
                    script = made
                } else {
                    continuation.resume(returning: nil)
                    return
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result.stringValue : nil)
            }
        }
    }
}

/// Automation (Apple Events) permission, per target app.
///
/// `AEDeterminePermissionToAutomateTarget` is the only supported way to ask TCC
/// about this without actually sending an event. Note that the *first* real
/// consent prompt is what creates the entry in Privacy & Security → Automation;
/// there is no programmatic reset, so a denied browser can only be re-enabled by
/// the user in System Settings.
enum AutomationPermission {
    /// Ask TCC about `bundleID` without prompting. `.notDetermined` also covers
    /// "the app isn't running", since TCC can't answer for a dead process.
    static func status(for bundleID: String) -> GlancePermission.Status {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else {
            return .notDetermined
        }
        let code = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false)
        switch code {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:
            // -1744 errAEEventWouldRequireUserConsent, -600 procNotFound, etc.
            return .notDetermined
        }
    }

    /// Trigger the system consent prompt. Blocks until the user answers, so it
    /// runs off the main actor.
    static func request(for bundleID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc {
                    _ = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, true)
                }
                continuation.resume()
            }
        }
    }
}

// MARK: - Firefox

/// A row read out of Firefox's history database.
struct FirefoxVisit: Sendable {
    let url: String
    let title: String
    /// Firefox stores visit dates as microseconds since the Unix epoch.
    let visitDateMicros: Int64
}

/// Reads new visits out of Firefox's `places.sqlite`.
///
/// Firefox keeps the database in WAL mode and holds it open, so we copy the
/// three WAL-set files to a scratch directory and read the copy — opening the
/// live file read-only fails once a `-wal` exists, because SQLite needs to write
/// the shared-memory index to replay it.
enum FirefoxHistory {
    private static var profilesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
    }

    /// The profile most recently written to. Firefox's `profiles.ini` names a
    /// default, but a user with several open windows is really using whichever
    /// database is being touched — mtime answers that directly and needs no
    /// ini parsing.
    static func activeProfileDatabase() -> URL? {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(
            at: profilesRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return profiles
            .map { $0.appendingPathComponent("places.sqlite") }
            .filter { fm.fileExists(atPath: $0.path) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
    }

    /// Visits strictly newer than `sinceMicros`, oldest first so the caller can
    /// record them in the order they happened. Returns `[]` on any failure —
    /// a missing profile or a torn copy is not worth surfacing as an error.
    static func visits(sinceMicros: Int64, limit: Int = 200) -> [FirefoxVisit] {
        guard let live = activeProfileDatabase(), let scratch = copyDatabase(live) else { return [] }
        defer { try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent()) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(scratch.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT p.url, IFNULL(p.title, ''), v.visit_date
        FROM moz_historyvisits v
        JOIN moz_places p ON p.id = v.place_id
        WHERE v.visit_date > ?
        ORDER BY v.visit_date ASC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sinceMicros)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [FirefoxVisit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlC = sqlite3_column_text(stmt, 0) else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            out.append(FirefoxVisit(
                url: String(cString: urlC),
                title: title,
                visitDateMicros: sqlite3_column_int64(stmt, 2)
            ))
        }
        return out
    }

    /// Copy the WAL set (`places.sqlite`, `-wal`, `-shm`) into a fresh scratch
    /// directory. The `-wal` file is the one that matters: without it the copy
    /// is stale by up to a few minutes of browsing.
    private static func copyDatabase(_ live: URL) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("glancekit-firefox-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }

        let destination = dir.appendingPathComponent("places.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: live.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: destination.path + suffix)
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                // The main file failing is fatal; a missing/racing -wal is not.
                if suffix.isEmpty {
                    try? fm.removeItem(at: dir)
                    return nil
                }
            }
        }
        return destination
    }
}
