import Foundation
import AVFoundation

/// A loaded `.cipack` directory. Owns its root URL and manifest; resolves
/// per-category file URLs and caches AVAudioPCMBuffers on demand.
final class SoundPack {
    let root: URL
    let manifest: SoundPackManifest
    /// True when this pack is shipped inside the app bundle (read-only, can't be removed).
    let isBuiltIn: Bool

    private var bufferCache: [String: AVAudioPCMBuffer] = [:]
    private let cacheQueue = DispatchQueue(label: "app.coderisland.soundpack.cache")

    init(root: URL, manifest: SoundPackManifest, isBuiltIn: Bool) {
        self.root = root
        self.manifest = manifest
        self.isBuiltIn = isBuiltIn
    }

    /// Loads a `.cipack` directory (manifest.json + referenced files).
    /// Does NOT verify individual sound files exist — playback will do that lazily.
    static func load(from packRoot: URL, isBuiltIn: Bool) throws -> SoundPack {
        let manifestURL = packRoot.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SoundPackError.manifestMissing(manifestURL)
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw SoundPackError.manifestMalformed(manifestURL, underlying: error)
        }
        let manifest: SoundPackManifest
        do {
            manifest = try JSONDecoder().decode(SoundPackManifest.self, from: data)
        } catch {
            throw SoundPackError.manifestMalformed(manifestURL, underlying: error)
        }
        try manifest.validate()
        return SoundPack(root: packRoot, manifest: manifest, isBuiltIn: isBuiltIn)
    }

    // MARK: - Entry selection

    /// Returns one entry for the category, picked at random if `randomizeVariants`
    /// is on (per pack defaults). Returns `nil` if the category is absent.
    func pickEntry(for categoryId: String) -> SoundPackManifest.SoundEntry? {
        guard let entries = manifest.sounds[categoryId], !entries.isEmpty else {
            return nil
        }
        let randomize = manifest.defaults?.randomizeVariants ?? true
        if !randomize || entries.count == 1 {
            return entries.first
        }
        // Weighted random selection: if no weights, equal probability.
        let weights = entries.map { $0.weight ?? 1.0 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return entries.first }
        var roll = Float.random(in: 0..<total)
        for (i, w) in weights.enumerated() {
            roll -= w
            if roll <= 0 { return entries[i] }
        }
        return entries.last
    }

    // MARK: - File resolution

    /// Resolves an entry's `file` field to a playable URL (for file entries)
    /// or returns `nil` for `system:` entries (callers check `isSystemSound`).
    func resolveFileURL(for entry: SoundPackManifest.SoundEntry) -> URL? {
        if entry.file.hasPrefix("system:") { return nil }
        return root.appendingPathComponent(entry.file)
    }

    func isSystemSound(_ entry: SoundPackManifest.SoundEntry) -> String? {
        guard entry.file.hasPrefix("system:") else { return nil }
        return String(entry.file.dropFirst("system:".count))
    }

    // MARK: - Buffer cache

    /// Returns a cached AVAudioPCMBuffer for the given file entry, or nil if
    /// the file doesn't exist / can't be decoded / is a system sound.
    func cachedBuffer(for entry: SoundPackManifest.SoundEntry) -> AVAudioPCMBuffer? {
        guard let url = resolveFileURL(for: entry) else { return nil }
        let key = url.path
        return cacheQueue.sync {
            if let cached = bufferCache[key] { return cached }
            guard let buffer = Self.loadBuffer(from: url) else { return nil }
            bufferCache[key] = buffer
            return buffer
        }
    }

    static func loadBuffer(from url: URL) -> AVAudioPCMBuffer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            NSLog("[SoundPack] cannot open %@ for reading: %@", url.path, error.localizedDescription)
            return nil
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            NSLog("[SoundPack] cannot decode %@: %@", url.path, error.localizedDescription)
            return nil
        }
        return buffer
    }

    func clearCache() {
        cacheQueue.sync { bufferCache.removeAll() }
    }
}
