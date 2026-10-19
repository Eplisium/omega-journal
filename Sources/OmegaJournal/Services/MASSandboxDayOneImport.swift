import Foundation

// MARK: - Day One import under the App Sandbox
//
// A Day One "Export → JSON" is a folder holding `Journal.json` plus a `photos/`
// folder. When the user picks only the `.json` file, the sandbox grants that one
// file, so the photos next to it can't be read. The importer then asks for the
// export folder with a second open panel (or imports text only if the user declines).
//
// Photo names come from the (untrusted) JSON file, so every photo path is checked
// twice: its shape (`photos/<one safe name>`) and where it really lands on disk
// (inside the export's `photos/` folder after resolving symlinks).

enum MASSandboxDayOneImport {
    static let photosFolderName = "photos"

    /// What to do about photos for the picked file or folder.
    enum PhotoAccess: Equatable {
        /// Read photos relative to this export folder.
        case useRoot(URL)
        /// No photos referenced: import text only, nothing to ask.
        case noPhotosNeeded
        /// Photos are referenced but the sandbox hasn't granted the folder: ask for it,
        /// starting the panel in `suggested`.
        case askForFolder(suggested: URL)
    }

    /// Decides where photos come from.
    /// - Parameters:
    ///   - selection: what the user picked (the export folder or the `.json` file).
    ///   - selectionIsDirectory: whether `selection` is a folder (a folder pick grants everything inside).
    ///   - referencesPhotos: whether any entry lists photos.
    ///   - isSandboxed: unsandboxed builds can always read next to the file.
    ///   - canReadPhotosFolder: whether `<export>/photos` can be listed right now.
    static func photoAccess(selection: URL, selectionIsDirectory: Bool, referencesPhotos: Bool,
                            isSandboxed: Bool, canReadPhotosFolder: (URL) -> Bool) -> PhotoAccess {
        if selectionIsDirectory { return .useRoot(selection) }
        guard referencesPhotos else { return .noPhotosNeeded }
        let exportFolder = selection.deletingLastPathComponent()
        if !isSandboxed { return .useRoot(exportFolder) }
        let photos = exportFolder.appendingPathComponent(photosFolderName, isDirectory: true)
        return canReadPhotosFolder(photos) ? .useRoot(exportFolder) : .askForFolder(suggested: exportFolder)
    }

    /// The export root for a folder picked in the second panel: the export folder itself
    /// (it has a `photos/` subfolder) or its `photos/` folder. Anything else is nil.
    static func exportRoot(forPickedFolder picked: URL, hasPhotosSubfolder: Bool) -> URL? {
        if picked.lastPathComponent == photosFolderName { return picked.deletingLastPathComponent() }
        return hasPhotosSubfolder ? picked : nil
    }

    /// Default check used by the app: the folder exists and can be listed.
    static func folderIsReadable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Returns the path unchanged when it is exactly `photos/<name>` with a single safe
    /// file name (no separators, no `.`/`..`, not absolute, plain characters); nil otherwise.
    static func sanitizedPhotoPath(_ path: String) -> String? {
        let prefix = photosFolderName + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty, name.count <= 255,
              name != ".", name != "..", !name.contains(".."),
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"), !name.hasPrefix("."),
              name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        else { return nil }
        return path
    }

    /// The real file for a sanitized photo path, only when it is a regular file that
    /// stays inside `<root>/photos` after resolving symlinks.
    static func containedPhotoFile(_ path: String, root: URL) -> URL? {
        guard let safe = sanitizedPhotoPath(path) else { return nil }
        let photosReal = root.appendingPathComponent(photosFolderName, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let real = root.appendingPathComponent(safe).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard real.path.hasPrefix(photosReal + "/"),
              FileManager.default.fileExists(atPath: real.path, isDirectory: &isDir), !isDir.boolValue
        else { return nil }
        return real
    }

    /// Drops every photo path that is malformed (shape check only — no disk access).
    static func sanitizedPhotoPaths(_ paths: [String]) -> [String] {
        paths.compactMap(sanitizedPhotoPath)
    }
}
