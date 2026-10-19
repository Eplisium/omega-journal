import Foundation

// MARK: - Remembered backup folder under the App Sandbox
//
// A plain path is not enough inside the App Sandbox: access to a folder picked in
// an NSOpenPanel ends when the app quits. The folder is therefore remembered as a
// bookmark:
// - sandboxed (App Store) builds store a security-scoped bookmark and wrap every
//   use of the folder in start/stopAccessingSecurityScopedResource;
// - unsandboxed (direct / dev) builds store a plain bookmark (security-scoped
//   bookmarks need an entitlement they don't have) and fall back to the path.
// The path is always stored too, so older builds keep working with the same journal.
//
// This file holds the decision logic only; `DatabaseManager` (BackupFolder.swift)
// reads and writes the settings.

/// Starts/stops access to a security-scoped URL. Injectable so tests can check
/// that every start is balanced by a stop.
protocol MASSandboxScopeAccessing {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Creates and resolves bookmark data. Injectable so tests can simulate stale or
/// unresolvable bookmarks.
protocol MASSandboxBookmarkCoding {
    func makeBookmark(for url: URL, securityScoped: Bool) throws -> Data
    /// Returns the resolved URL and whether the bookmark is stale (should be re-created).
    func resolveBookmark(_ data: Data, securityScoped: Bool) throws -> (url: URL, isStale: Bool)
}

struct MASSandboxSystemScopeAccessor: MASSandboxScopeAccessing {
    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

struct MASSandboxSystemBookmarkCoder: MASSandboxBookmarkCoding {
    func makeBookmark(for url: URL, securityScoped: Bool) throws -> Data {
        try url.bookmarkData(options: securityScoped ? [.withSecurityScope] : [],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data, securityScoped: Bool) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

enum MASSandboxBackupFolder {
    /// Everything that differs between the real app and a test.
    struct Environment {
        var isSandboxed: Bool
        var coder: MASSandboxBookmarkCoding
        var accessor: MASSandboxScopeAccessing

        static var system: Environment {
            Environment(isSandboxed: AppEnvironment.isSandboxed,
                        coder: MASSandboxSystemBookmarkCoder(),
                        accessor: MASSandboxSystemScopeAccessor())
        }
    }

    /// Test override, scoped to the current task so parallel suites are unaffected.
    @TaskLocal static var environmentOverride: Environment?
    static var environment: Environment { environmentOverride ?? .system }

    /// The bookmark as stored in settings: `"scoped:<base64>"` or `"plain:<base64>"`.
    struct StoredBookmark: Equatable {
        var data: Data
        var securityScoped: Bool

        var encoded: String { (securityScoped ? "scoped:" : "plain:") + data.base64EncodedString() }

        init(data: Data, securityScoped: Bool) {
            self.data = data
            self.securityScoped = securityScoped
        }

        init?(encoded: String) {
            let parts = encoded.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "scoped" || parts[0] == "plain",
                  let data = Data(base64Encoded: parts[1]), !data.isEmpty else { return nil }
            self.init(data: data, securityScoped: parts[0] == "scoped")
        }
    }

    /// What the app can do with the remembered folder right now.
    enum State: Equatable {
        /// No extra folder chosen.
        case notSet
        /// Usable. `securityScoped` means every use must be wrapped in start/stop access.
        case ready(URL, securityScoped: Bool)
        /// A folder was chosen, but this build can't get at it (sandboxed with only a
        /// path, or the bookmark no longer resolves). The user must choose it again.
        case needsRepick(lastKnownPath: String)

        var url: URL? { if case .ready(let url, _) = self { return url }; return nil }
        var needsRepick: Bool { if case .needsRepick = self { return true }; return false }
    }

    /// Result of resolving the stored settings. `updatedBookmark` / `updatedPath`
    /// are set when the caller should persist a refreshed value.
    struct Resolution: Equatable {
        var state: State
        var updatedBookmark: StoredBookmark?
        var updatedPath: String?
    }

    /// Decides what to do with the stored `path` + `bookmark` settings.
    static func resolve(path: String, bookmark encoded: String, environment env: Environment) -> Resolution {
        let bookmark = StoredBookmark(encoded: encoded)
        let pathURL = path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        let lastKnown = path.isEmpty ? "the folder you chose" : path

        guard let bookmark else {
            guard let pathURL else {
                // An undecodable bookmark with no path is still "a folder was chosen".
                return Resolution(state: encoded.isEmpty ? .notSet : .needsRepick(lastKnownPath: lastKnown))
            }
            // Legacy: only a plain path. The sandbox gives no access to it.
            if env.isSandboxed { return Resolution(state: .needsRepick(lastKnownPath: lastKnown)) }
            // Unsandboxed builds keep using the path and quietly upgrade to a bookmark.
            let upgraded = (try? env.coder.makeBookmark(for: pathURL, securityScoped: false))
                .map { StoredBookmark(data: $0, securityScoped: false) }
            return Resolution(state: .ready(pathURL, securityScoped: false), updatedBookmark: upgraded)
        }

        // A plain bookmark grants nothing inside the sandbox.
        if env.isSandboxed && !bookmark.securityScoped {
            return Resolution(state: .needsRepick(lastKnownPath: lastKnown))
        }

        guard let resolved = try? env.coder.resolveBookmark(bookmark.data, securityScoped: bookmark.securityScoped) else {
            if !env.isSandboxed, let pathURL {
                return Resolution(state: .ready(pathURL, securityScoped: false))
            }
            return Resolution(state: .needsRepick(lastKnownPath: lastKnown))
        }

        // Keep the stored spelling when it names the same folder (`/var` vs `/private/var`),
        // otherwise follow the bookmark (folder moved or renamed) and remember the new path.
        // Inside the sandbox the URL instance returned by resolution must be kept: only
        // it carries the security scope that start/stopAccessing needs.
        let scoped = bookmark.securityScoped
        let useScope = scoped && env.isSandboxed
        var url = resolved.url
        var updatedPath: String?
        if let pathURL, samePath(pathURL, resolved.url) {
            if !useScope { url = pathURL }
        } else {
            updatedPath = resolved.url.path
        }

        if useScope {
            // Resolving can succeed while access is still refused (e.g. a bookmark made by
            // another build). Probe once so the UI can ask for the folder again.
            guard env.accessor.startAccessing(resolved.url) else {
                return Resolution(state: .needsRepick(lastKnownPath: lastKnown))
            }
            env.accessor.stopAccessing(resolved.url)
        }

        var refreshed: StoredBookmark?
        if resolved.isStale {
            refreshed = refreshBookmark(for: resolved.url, securityScoped: scoped, environment: env)
        }
        // Security-scoped access only means something inside the sandbox; unsandboxed
        // builds use the folder directly even when the stored bookmark is scoped.
        return Resolution(state: .ready(url, securityScoped: useScope),
                          updatedBookmark: refreshed, updatedPath: updatedPath)
    }

    /// Re-creates a stale bookmark. Security-scoped bookmarks can only be made while
    /// the resource is being accessed.
    static func refreshBookmark(for url: URL, securityScoped: Bool, environment env: Environment) -> StoredBookmark? {
        let started = securityScoped ? env.accessor.startAccessing(url) : false
        defer { if started { env.accessor.stopAccessing(url) } }
        guard let data = try? env.coder.makeBookmark(for: url, securityScoped: securityScoped) else { return nil }
        return StoredBookmark(data: data, securityScoped: securityScoped)
    }

    /// The bookmark to store for a folder the user just picked. Sandboxed builds need
    /// a security-scoped bookmark (nil means the folder can't be remembered);
    /// unsandboxed builds store a plain one, or nothing (the path alone still works).
    static func bookmarkForNewFolder(_ url: URL, environment env: Environment) -> StoredBookmark? {
        if env.isSandboxed {
            return (try? env.coder.makeBookmark(for: url, securityScoped: true))
                .map { StoredBookmark(data: $0, securityScoped: true) }
        }
        return (try? env.coder.makeBookmark(for: url, securityScoped: false))
            .map { StoredBookmark(data: $0, securityScoped: false) }
    }

    /// Runs `body` with access to a ready folder. Security-scoped access is started
    /// first and always stopped afterwards, also when `body` throws. Returns nil
    /// without calling `body` when the folder isn't usable.
    static func withAccess<T>(to state: State, environment env: Environment, _ body: (URL) throws -> T) rethrows -> T? {
        guard case .ready(let url, let scoped) = state else { return nil }
        guard scoped else { return try body(url) }
        guard env.accessor.startAccessing(url) else { return nil }
        defer { env.accessor.stopAccessing(url) }
        return try body(url)
    }

    /// Path equality after standardizing and resolving symlinks.
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// True when `file` lives inside `folder` (after resolving symlinks).
    static func isInside(_ file: URL, folder: URL) -> Bool {
        let f = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let p = file.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }
}

/// Wording for the "Extra backup folder" row in Settings › Data, per state.
struct MASSandboxBackupFolderCopy: Equatable {
    let title: String
    let detail: String
    let chooseLabel: String
    let isWarning: Bool

    init(state: MASSandboxBackupFolder.State) {
        switch state {
        case .notSet:
            title = "Extra backup folder"
            detail = "Not set — backups stay on this Mac only"
            chooseLabel = "Choose…"
            isWarning = false
        case .ready(let url, _):
            title = "Extra backup folder"
            detail = url.path
            chooseLabel = "Choose…"
            isWarning = false
        case .needsRepick(let last):
            let name = last.hasPrefix("/") ? "“\((last as NSString).lastPathComponent)”" : last
            title = "Choose your backup folder again"
            detail = "Omega Journal needs your permission again to copy backups to \(name). Daily backups are still saved on this Mac."
            chooseLabel = "Choose Again…"
            isWarning = true
        }
    }
}
