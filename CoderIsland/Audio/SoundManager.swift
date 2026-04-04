import Foundation
import AppKit

class SoundManager {
    enum Event: String {
        case permission
        case ask
        case taskComplete
    }

    static let shared = SoundManager()
    private var lastPlayedAt: [String: Date] = [:]
    private let minInterval: TimeInterval = 0.35
    private var cachedNamedSounds: [String: NSSound] = [:]
    private var cachedFileSounds: [String: NSSound] = [:]
    private let customNamePrefix = "soundCustomName."

    private init() {}

    private var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true
    }

    private var permissionSoundEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundPermissionEnabled") as? Bool ?? true
    }

    private var askSoundEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundAskEnabled") as? Bool ?? true
    }

    private var taskDoneSoundEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundTaskDoneEnabled") as? Bool ?? true
    }

    private var appSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoderIsland", isDirectory: true)
    }

    private var customSoundsDir: URL {
        appSupportDir.appendingPathComponent("SoundPacks/Custom", isDirectory: true)
    }

    func customSoundName(for event: Event) -> String? {
        UserDefaults.standard.string(forKey: customNamePrefix + event.rawValue)
    }

    func setCustomSound(for event: Event, from sourceURL: URL) throws {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: customSoundsDir, withIntermediateDirectories: true)
        removeExistingCustomFile(for: event)

        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let targetURL = customSoundsDir.appendingPathComponent("\(event.rawValue).\(ext)")
        try fm.copyItem(at: sourceURL, to: targetURL)

        UserDefaults.standard.set(sourceURL.lastPathComponent, forKey: customNamePrefix + event.rawValue)
        cachedFileSounds.removeAll()
    }

    func clearCustomSound(for event: Event) {
        removeExistingCustomFile(for: event)
        UserDefaults.standard.removeObject(forKey: customNamePrefix + event.rawValue)
        cachedFileSounds.removeAll()
    }

    func playAgentStarted() {
        guard soundEnabled else { return }
        playSound(
            key: "agentStarted",
            preferredNames: ["Pop", "Funk", "Tink"],
            customEvent: nil
        )
    }

    func playTaskComplete() {
        guard soundEnabled, taskDoneSoundEnabled else { return }
        playSound(
            key: "taskComplete",
            preferredNames: ["Glass", "Hero", "Ping"],
            customEvent: .taskComplete
        )
    }

    func playPermissionNeeded() {
        guard soundEnabled, permissionSoundEnabled else { return }
        playSound(
            key: "permission",
            preferredNames: ["Submarine", "Basso", "Ping"],
            customEvent: .permission
        )
    }

    func playAskQuestion() {
        guard soundEnabled, askSoundEnabled else { return }
        playSound(
            key: "ask",
            preferredNames: ["Ping", "Tink", "Pop"],
            customEvent: .ask
        )
    }

    func playError() {
        guard soundEnabled else { return }
        playSound(
            key: "error",
            preferredNames: ["Basso", "Submarine", "Sosumi"],
            customEvent: nil
        )
    }

    func playPreview(for event: Event) {
        switch event {
        case .permission:
            playSound(
                key: "preview.permission",
                preferredNames: ["Submarine", "Basso", "Ping"],
                customEvent: .permission
            )
        case .ask:
            playSound(
                key: "preview.ask",
                preferredNames: ["Ping", "Tink", "Pop"],
                customEvent: .ask
            )
        case .taskComplete:
            playSound(
                key: "preview.taskComplete",
                preferredNames: ["Glass", "Hero", "Ping"],
                customEvent: .taskComplete
            )
        }
    }

    private func playSound(key: String, preferredNames: [String], customEvent: Event?) {
        let now = Date()
        if let last = lastPlayedAt[key], now.timeIntervalSince(last) < minInterval {
            return
        }
        lastPlayedAt[key] = now

        if let event = customEvent, let sound = loadCustomSound(for: event) {
            sound.play()
            return
        }

        for name in preferredNames {
            if let sound = loadNamedSound(name: name) {
                sound.play()
                return
            }
        }
        NSSound.beep()
    }

    private func loadNamedSound(name: String) -> NSSound? {
        if let cached = cachedNamedSounds[name] {
            return cached
        }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return nil }
        cachedNamedSounds[name] = sound
        return sound
    }

    private func removeExistingCustomFile(for event: Event) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: customSoundsDir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(event.rawValue + ".") {
            try? fm.removeItem(at: file)
        }
    }

    private func customSoundURL(for event: Event) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: customSoundsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return files.first(where: { $0.lastPathComponent.hasPrefix(event.rawValue + ".") })
    }

    private func loadCustomSound(for event: Event) -> NSSound? {
        guard let url = customSoundURL(for: event) else { return nil }
        if let cached = cachedFileSounds[url.path] {
            return cached
        }
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        cachedFileSounds[url.path] = sound
        return sound
    }
}
