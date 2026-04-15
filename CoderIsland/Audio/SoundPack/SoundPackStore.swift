import Foundation

/// Central registry of available SoundPacks. Scans two roots:
///   1. Built-in:  `<app>.app/Contents/Resources/SoundPacks/*.cipack`  (read-only)
///   2. Installed: `~/Library/Application Support/CoderIsland/SoundPacks/Installed/*.cipack`
///
/// The store is built once at app launch and refreshed when packs are imported/removed.
final class SoundPackStore {
    static let shared = SoundPackStore()

    private(set) var packs: [SoundPack] = []
    /// Per-pack errors encountered on the last scan. Exposed for Settings UI to surface.
    private(set) var scanIssues: [String] = []

    private init() {
        rescan()
    }

    // MARK: - Discovery

    @discardableResult
    func rescan() -> [SoundPack] {
        var loaded: [SoundPack] = []
        var issues: [String] = []

        for dir in Self.builtinRoots() {
            loaded.append(contentsOf: Self.scan(root: dir, isBuiltIn: true, issues: &issues))
        }
        for dir in Self.userRoots() {
            loaded.append(contentsOf: Self.scan(root: dir, isBuiltIn: false, issues: &issues))
        }

        // Deduplicate by manifest.id (user packs override built-in with same id).
        var byId: [String: SoundPack] = [:]
        for pack in loaded {
            if let existing = byId[pack.manifest.id], existing.isBuiltIn, !pack.isBuiltIn {
                // User pack shadows built-in.
                byId[pack.manifest.id] = pack
            } else if byId[pack.manifest.id] == nil {
                byId[pack.manifest.id] = pack
            }
        }
        self.packs = Array(byId.values).sorted {
            // Built-in first, then alphabetical.
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn && !$1.isBuiltIn }
            return $0.manifest.name.localizedCompare($1.manifest.name) == .orderedAscending
        }
        self.scanIssues = issues
        return self.packs
    }

    func pack(withId id: String) -> SoundPack? {
        packs.first { $0.manifest.id == id }
    }

    /// First pack, preferring built-in default, then any built-in, then any loaded.
    var defaultPack: SoundPack? {
        pack(withId: "com.coderisland.default")
            ?? packs.first(where: { $0.isBuiltIn })
            ?? packs.first
    }

    // MARK: - Root discovery

    static func builtinRoots() -> [URL] {
        // `Resources/SoundPacks` ships as a folder reference in the app bundle.
        guard let resURL = Bundle.main.resourceURL else { return [] }
        let packDir = resURL.appendingPathComponent("SoundPacks", isDirectory: true)
        return [packDir]
    }

    static func userRoots() -> [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoderIsland/SoundPacks/Installed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return [base]
    }

    static func userOverridesRoot() -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoderIsland/SoundPacks/Overrides", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func scan(root: URL, isBuiltIn: Bool, issues: inout [String]) -> [SoundPack] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            issues.append("scan failed: \(root.path) \(error.localizedDescription)")
            return []
        }

        var loaded: [SoundPack] = []
        for url in contents where url.pathExtension.lowercased() == "cipack" {
            do {
                let pack = try SoundPack.load(from: url, isBuiltIn: isBuiltIn)
                loaded.append(pack)
            } catch {
                issues.append("skip \(url.lastPathComponent): \(error)")
            }
        }
        return loaded
    }

    // MARK: - Installation

    /// Copies a `.cipack` directory (or zipped pack in v2) into the user's Installed folder.
    /// Returns the installed SoundPack on success.
    @discardableResult
    func install(from source: URL) throws -> SoundPack {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        // v1: only directory-form .cipack supported.
        guard source.pathExtension.lowercased() == "cipack" else {
            throw SoundPackError.manifestMalformed(source, underlying: NSError(
                domain: "SoundPackStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Only .cipack directories are supported in v1"]
            ))
        }

        // Parse manifest first to know target dir name.
        let probe = try SoundPack.load(from: source, isBuiltIn: false)
        let installRoot = Self.userRoots().first!
        let target = installRoot.appendingPathComponent("\(probe.manifest.id).cipack", isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
        rescan()
        guard let installed = pack(withId: probe.manifest.id) else {
            throw SoundPackError.manifestMissing(target)
        }
        return installed
    }

    /// Removes an installed (non-builtin) pack. Throws if the pack is built-in.
    func uninstall(_ pack: SoundPack) throws {
        guard !pack.isBuiltIn else {
            throw NSError(
                domain: "SoundPackStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot uninstall built-in pack"]
            )
        }
        try FileManager.default.removeItem(at: pack.root)
        rescan()
    }
}
