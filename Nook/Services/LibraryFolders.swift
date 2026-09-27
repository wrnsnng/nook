import Foundation

/// A Nook folder is a real directory, directly inside the notes folder.
///
/// Nothing about folders is persisted anywhere else: a note belongs to the
/// folder that holds its Markdown file, and a folder created in Finder is as
/// much a Nook folder as one created in the app. Only one level is honoured.
/// Deeper nesting would turn a notes folder that happens to be ~/Documents
/// into a recursive scan of somebody's whole document tree.
enum LibraryFolders {
    /// Directories Nook keeps inside the notes folder for itself. They are
    /// hidden today, which already excludes them, but naming them keeps a
    /// future visible internal directory from silently becoming a folder.
    static let reservedNames: Set<String> = [".recordings"]

    /// Whether a directory entry name can be a folder at all. Hidden and
    /// reserved names never are, whoever created them.
    static func isFolderName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..",
              !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              !name.contains("\0")
        else { return false }
        return !reservedNames.contains(where: {
            $0.compare(name, options: .caseInsensitive) == .orderedSame
        })
    }

    /// Trims a typed name and refuses what cannot become a safe single
    /// directory component. Nook never rewrites a name into something the
    /// person did not type, so an unusable name is refused rather than mangled.
    static func sanitizedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryFolderError.emptyName }
        guard !name.contains("/"), !name.contains(":") else {
            throw LibraryFolderError.nameContainsSeparator
        }
        guard !name.hasPrefix(".") else { throw LibraryFolderError.hiddenName }
        guard !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }), isFolderName(name) else {
            throw LibraryFolderError.invalidName
        }
        // APFS and HFS+ limit a component to 255 UTF-16 units / bytes.
        guard name.utf8.count <= 255 else { throw LibraryFolderError.nameTooLong }
        return name
    }

    /// Visible, real (not linked, not package) directories one level inside
    /// the notes folder, sorted the way Finder sorts them.
    static func folderURLs(
        in library: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        return try fileManager.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard isFolderName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys))
            else { return false }
            // A link could point anywhere, including back at the library or
            // at another volume; the save path's directory checks assume a
            // real directory, so links are left for Finder to show.
            return values.isDirectory == true
                && values.isSymbolicLink != true
                && values.isPackage != true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func folderNames(
        in library: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        ((try? folderURLs(in: library, fileManager: fileManager)) ?? []).map(\.lastPathComponent)
    }

    /// The folder holding a file, or nil when it sits at the library's root
    /// or outside the library entirely.
    static func folderName(
        of file: URL,
        in library: URL,
        resolvingSymlinks: Bool = false
    ) -> String? {
        let parent = normalized(file.deletingLastPathComponent(), resolvingSymlinks)
        let root = normalized(library, resolvingSymlinks)
        guard parent.deletingLastPathComponent().path == root.path,
              isFolderName(parent.lastPathComponent)
        else { return nil }
        return parent.lastPathComponent
    }

    /// Whether a note file lives where the library loads notes from: the
    /// notes folder itself, or one of its folders. Ownership checks across
    /// the app used to require the notes folder as the direct parent, which
    /// is still the only answer for a file that is outside every folder.
    static func contains(
        _ file: URL,
        in library: URL,
        resolvingSymlinks: Bool = false
    ) -> Bool {
        let parent = normalized(file.deletingLastPathComponent(), resolvingSymlinks)
        let root = normalized(library, resolvingSymlinks)
        return parent.path == root.path
            || folderName(of: file, in: library, resolvingSymlinks: resolvingSymlinks) != nil
    }

    /// The library root for a note file, given the notes folder it is
    /// expected to belong to. Kept audio and other Nook storage live at the
    /// root, never beside a note inside a folder.
    static func libraryRoot(for file: URL, expected library: URL?) -> URL {
        if let library, contains(file, in: library) {
            return library.standardizedFileURL
        }
        return file.deletingLastPathComponent()
    }

    private static func normalized(_ url: URL, _ resolvingSymlinks: Bool) -> URL {
        resolvingSymlinks
            ? url.standardizedFileURL.resolvingSymlinksInPath()
            : url.standardizedFileURL
    }
}

enum LibraryFolderError: LocalizedError, Equatable {
    case emptyName
    case nameContainsSeparator
    case hiddenName
    case invalidName
    case nameTooLong
    case duplicateName(String)
    case folderMissing(String)
    case folderKeptOtherFiles(String)
    case moveRequiresSavedNote
    case noteOutsideLibrary
    case noteIsBusy
    case moveFailed
    case renameFailed
    case unfinishedMarkdown
    case draftSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Type a name for the folder."
        case .nameContainsSeparator:
            "Folder names can’t contain a slash or a colon."
        case .hiddenName:
            "Folder names can’t start with a period, because Finder would hide the folder."
        case .invalidName:
            "That name can’t be used for a folder. Choose a different name."
        case .nameTooLong:
            "That folder name is too long. Choose a shorter name."
        case .duplicateName(let name):
            "A folder named “\(name)” already exists. Choose a different name."
        case .folderMissing(let name):
            "The folder “\(name)” is no longer in your notes folder. Nothing was changed."
        case .folderKeptOtherFiles(let name):
            "Notes from “\(name)” are back in your library. The folder still holds other files, so it was kept."
        case .moveRequiresSavedNote:
            "This note has no saved Markdown file to move."
        case .noteOutsideLibrary:
            "This note’s file is outside your notes folder, so it was not moved."
        case .noteIsBusy:
            "This note is being updated. Move it when the summary or recording finishes."
        case .moveFailed:
            "Nook couldn’t move this note’s file, so it was left where it was."
        case .renameFailed:
            "Nook couldn’t rename this folder, so it was left unchanged."
        case .unfinishedMarkdown:
            "Save or discard your Markdown changes before moving notes."
        case .draftSaveFailed(let reason):
            "My notes couldn’t be saved, so nothing was moved. \(reason)"
        }
    }
}
