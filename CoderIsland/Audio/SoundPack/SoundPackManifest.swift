import Foundation

/// Codable model for a `.cipack` bundle's manifest.json.
/// See docs/soundpack-manifest-schema.md for the canonical spec.
struct SoundPackManifest: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let author: Author
    let license: String
    let description: String?
    let preview: String?
    let defaults: Defaults?
    /// Keyed by category ID (e.g. "taskComplete"). Value is an ordered list
    /// of candidate sound entries; the player picks one per play using weights.
    let sounds: [String: [SoundEntry]]

    struct Author: Codable, Equatable {
        let name: String
        let url: String?
        let avatar: String?
    }

    struct Defaults: Codable, Equatable {
        let volume: Float?
        let randomizeVariants: Bool?
    }

    struct SoundEntry: Codable, Equatable {
        /// Either a relative file path (e.g. `sounds/complete.wav`) or a
        /// `system:<NSSoundName>` reference (e.g. `system:Glass`).
        let file: String
        let weight: Float?
        let volume: Float?
    }

    /// Bundle-ID-style regex used by validate(). Accepts lowercase, digits, dots, dashes.
    static let idRegex = #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#

    /// Throws `SoundPackError` if the manifest violates a schema invariant.
    /// Path resolution (file existence) is handled by SoundPack, not here.
    func validate() throws {
        guard schemaVersion == 1 else {
            throw SoundPackError.unsupportedSchema(schemaVersion)
        }
        guard id.range(of: Self.idRegex, options: .regularExpression) != nil else {
            throw SoundPackError.invalidID(id)
        }
        guard !sounds.isEmpty, sounds.values.contains(where: { !$0.isEmpty }) else {
            throw SoundPackError.emptySounds
        }
        for (category, entries) in sounds {
            for entry in entries {
                // Reject path traversal attempts. System sounds (`system:`) are always safe.
                if !entry.file.hasPrefix("system:"),
                   entry.file.contains("..") || entry.file.hasPrefix("/") {
                    throw SoundPackError.unsafePath(category: category, path: entry.file)
                }
            }
        }
    }
}

enum SoundPackError: Error, CustomStringConvertible {
    case unsupportedSchema(Int)
    case invalidID(String)
    case emptySounds
    case unsafePath(category: String, path: String)
    case manifestMissing(URL)
    case manifestMalformed(URL, underlying: Error)

    var description: String {
        switch self {
        case .unsupportedSchema(let v):
            return "Unsupported schemaVersion \(v); only 1 is accepted."
        case .invalidID(let id):
            return "Invalid pack id \"\(id)\"; expected reverse-DNS form."
        case .emptySounds:
            return "Pack declares no category entries."
        case .unsafePath(let category, let path):
            return "Unsafe file path in category \(category): \(path)"
        case .manifestMissing(let url):
            return "manifest.json missing at \(url.path)"
        case .manifestMalformed(let url, let err):
            return "manifest.json malformed at \(url.path): \(err)"
        }
    }
}
