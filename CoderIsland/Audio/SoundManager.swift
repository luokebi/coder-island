import Foundation
import AppKit

class SoundManager {
    enum Event: String {
        case permission
        case ask
        case taskComplete
        case appStarted
    }

    enum Preset: String, CaseIterable, Identifiable {
        case system
        case mario

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .mario: return "Mario"
            }
        }
    }

    static let shared = SoundManager()
    private var lastPlayedAt: [String: Date] = [:]
    private let minInterval: TimeInterval = 0.35
    private var cachedNamedSounds: [String: NSSound] = [:]
    private var cachedFileSounds: [String: NSSound] = [:]
    private let customNamePrefix = "soundCustomName."
    private let presetKey = "soundPreset"

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

    private var appStartedSoundEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundAppStartedEnabled") as? Bool ?? true
    }

    private var appSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoderIsland", isDirectory: true)
    }

    private var customSoundsDir: URL {
        appSupportDir.appendingPathComponent("SoundPacks/Custom", isDirectory: true)
    }

    var selectedPreset: Preset {
        let raw = UserDefaults.standard.string(forKey: presetKey) ?? ""
        return Preset(rawValue: raw) ?? .mario
    }

    func effectiveSoundLabel(for event: Event) -> String {
        if let customName = customSoundName(for: event), !customName.isEmpty {
            return "Custom: \(customName)"
        }

        switch selectedPreset {
        case .system:
            return "Preset: System"
        case .mario:
            return "Preset: Mario"
        }
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
        SoundManager.traceSoundPlay("agentStarted")
        playSound(
            key: "agentStarted",
            preferredNames: ["Pop", "Funk", "Tink"],
            customEvent: nil
        )
    }

    func playAppStarted() {
        guard soundEnabled, appStartedSoundEnabled else { return }
        SoundManager.traceSoundPlay("appStarted")
        playSound(
            key: "appStarted",
            preferredNames: ["Glass", "Hero", "Funk"],
            customEvent: .appStarted
        )
    }

    func playTaskComplete(context: String = "") {
        guard soundEnabled, taskDoneSoundEnabled else { return }
        SoundManager.traceSoundPlay("taskComplete \(context)")
        playSound(
            key: "taskComplete",
            preferredNames: ["Glass", "Hero", "Ping"],
            customEvent: .taskComplete
        )
    }

    func playPermissionNeeded() {
        guard soundEnabled, permissionSoundEnabled else { return }
        SoundManager.traceSoundPlay("permissionNeeded")
        playSound(
            key: "permission",
            preferredNames: ["Submarine", "Basso", "Ping"],
            customEvent: .permission
        )
    }

    func playAskQuestion() {
        guard soundEnabled, askSoundEnabled else { return }
        SoundManager.traceSoundPlay("askQuestion")
        playSound(
            key: "ask",
            preferredNames: ["Ping", "Tink", "Pop"],
            customEvent: .ask
        )
    }

    func playError() {
        guard soundEnabled else { return }
        SoundManager.traceSoundPlay("error")
        playSound(
            key: "error",
            preferredNames: ["Basso", "Submarine", "Sosumi"],
            customEvent: nil
        )
    }

    /// Append one line per sound play to ~/Library/Logs/CoderIsland/sound-trace.log
    /// so we can tell which sound effect fires when. Also captures a stack
    /// trace so we know the call site when a mystery sound plays.
    private static func traceSoundPlay(_ kind: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoderIsland", isDirectory: true)
            .appendingPathComponent("sound-trace.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // Short callsite from the stack (skip this func + its caller).
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(3).joined(separator: " <- ")
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(kind)\n  \(stack)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
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
        case .appStarted:
            playSound(
                key: "preview.appStarted",
                preferredNames: ["Glass", "Hero", "Funk"],
                customEvent: .appStarted
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

        if let event = customEvent, let sound = loadPresetSound(for: event) {
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

    private func loadPresetSound(for event: Event) -> NSSound? {
        switch selectedPreset {
        case .system:
            return nil
        case .mario:
            switch event {
            case .permission:
                return loadBundledSound(fileName: "mario_permission.mp3")
            case .ask:
                return loadBundledSound(fileName: "mario_question.mp3")
            case .taskComplete:
                return loadBundledSound(fileName: "mario_complete.mp3")
            case .appStarted:
                return loadBundledSound(fileName: "mario_start.mp3")
            }
        }
    }

    private func loadBundledSound(fileName: String) -> NSSound? {
        guard !fileName.isEmpty else { return nil }
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "sounds")
            ?? Bundle.main.url(forResource: name, withExtension: ext)

        guard let url else { return nil }
        if let cached = cachedFileSounds[url.path] {
            return cached
        }
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        cachedFileSounds[url.path] = sound
        return sound
    }
}
