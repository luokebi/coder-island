import Foundation
import AppKit

/// Public facade for sound playback. Routes every request through
/// `SoundPackPlayer` + `SoundPackStore`. The original `Event` enum and method
/// names are preserved so callers elsewhere in the app don't need changes.
///
/// Category IDs used internally are the ones from `docs/soundpack-manifest-schema.md`.
/// Phase 2 will introduce a proper `Category` enum and richer event coverage;
/// for now `Event` cases are mapped 1:1 to the four currently-active categories.
class SoundManager {

    // MARK: - Backwards-compatible Event type

    enum Event: String {
        case permission
        case ask
        case taskComplete
        case appStarted

        /// Category id used by the pack manifest.
        var categoryId: String {
            switch self {
            case .permission:   return "inputRequired"
            case .ask:          return "inputQuestion"
            case .taskComplete: return "taskComplete"
            case .appStarted:   return "appStarted"
            }
        }

        /// Legacy per-event UserDefaults key used by the existing Settings UI.
        /// The new Category-based API reads this so toggling a legacy checkbox
        /// still takes effect until Phase 3 migrates Settings.
        var legacyEnabledDefaultsKey: String {
            switch self {
            case .permission:   return "soundPermissionEnabled"
            case .ask:          return "soundAskEnabled"
            case .taskComplete: return "soundTaskDoneEnabled"
            case .appStarted:   return "soundAppStartedEnabled"
            }
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case system
        case mario

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .mario:  return "Mario"
            }
        }

        /// Preset rawValue → new pack id. Used during the transition; Phase 3
        /// will migrate the UI to pick by pack id directly.
        var packId: String {
            switch self {
            case .system: return "com.coderisland.system"
            case .mario:  return "com.coderisland.default"
            }
        }
    }

    static let shared = SoundManager()

    private var lastPlayedAt: [String: Date] = [:]
    private let minInterval: TimeInterval = 0.35
    private let customNamePrefix = "soundCustomName."
    private let presetKey = "soundPreset"

    private init() {}

    // MARK: - Settings getters (unchanged)

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

    /// Legacy per-event override directory. Kept so existing user files keep
    /// working until Phase 3 migrates them under `Overrides/<category>.<ext>`.
    private var legacyCustomSoundsDir: URL {
        appSupportDir.appendingPathComponent("SoundPacks/Custom", isDirectory: true)
    }

    var selectedPreset: Preset {
        let raw = UserDefaults.standard.string(forKey: presetKey) ?? ""
        return Preset(rawValue: raw) ?? .mario
    }

    /// The active pack. Currently resolved via the legacy `Preset` setting;
    /// Phase 3 will read `sound.activePackId` directly.
    private var activePack: SoundPack? {
        let store = SoundPackStore.shared
        return store.pack(withId: selectedPreset.packId) ?? store.defaultPack
    }

    // MARK: - Custom-per-event API (legacy, preserved for Settings UI)

    func effectiveSoundLabel(for event: Event) -> String {
        if let customName = customSoundName(for: event), !customName.isEmpty {
            return "Custom: \(customName)"
        }
        return "Preset: \(selectedPreset.displayName)"
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
        try fm.createDirectory(at: legacyCustomSoundsDir, withIntermediateDirectories: true)
        removeExistingCustomFile(for: event)

        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let targetURL = legacyCustomSoundsDir.appendingPathComponent("\(event.rawValue).\(ext)")
        try fm.copyItem(at: sourceURL, to: targetURL)

        UserDefaults.standard.set(sourceURL.lastPathComponent, forKey: customNamePrefix + event.rawValue)
    }

    func clearCustomSound(for event: Event) {
        removeExistingCustomFile(for: event)
        UserDefaults.standard.removeObject(forKey: customNamePrefix + event.rawValue)
    }

    // MARK: - Public play methods (unchanged names / signatures)

    func playAgentStarted() {
        guard soundEnabled else { return }
        Self.traceSoundPlay("agentStarted")
        // No category yet; keep the original system-sound fallback.
        for name in ["Pop", "Funk", "Tink"] {
            if SoundPackPlayer.shared.play(source: .systemNamed(name)) { return }
        }
        SoundPackPlayer.shared.play(source: .beep)
    }

    func playAppStarted() {
        guard soundEnabled, appStartedSoundEnabled else { return }
        Self.traceSoundPlay("appStarted")
        playEvent(.appStarted, key: "appStarted", fallback: ["Glass", "Hero", "Funk"])
    }

    func playTaskComplete(context: String = "") {
        guard soundEnabled, taskDoneSoundEnabled else { return }
        Self.traceSoundPlay("taskComplete \(context)")
        playEvent(.taskComplete, key: "taskComplete", fallback: ["Glass", "Hero", "Ping"])
    }

    func playPermissionNeeded() {
        guard soundEnabled, permissionSoundEnabled else { return }
        Self.traceSoundPlay("permissionNeeded")
        playEvent(.permission, key: "permission", fallback: ["Submarine", "Basso", "Ping"])
    }

    func playAskQuestion() {
        guard soundEnabled, askSoundEnabled else { return }
        Self.traceSoundPlay("askQuestion")
        playEvent(.ask, key: "ask", fallback: ["Ping", "Tink", "Pop"])
    }

    func playError() {
        guard soundEnabled else { return }
        Self.traceSoundPlay("error")
        for name in ["Basso", "Submarine", "Sosumi"] {
            if SoundPackPlayer.shared.play(source: .systemNamed(name)) { return }
        }
        SoundPackPlayer.shared.play(source: .beep)
    }

    func playPreview(for event: Event) {
        // Preview bypasses the cooldown debounce — users re-click ▶ freely.
        playEvent(event, key: "preview.\(event.rawValue)", fallback: fallbackNames(for: event), bypassDebounce: true)
    }

    // MARK: - Category-based API (Phase 2+)

    /// Plays a sound for the given category, honoring the per-category enable
    /// flag in UserDefaults. Legacy (`Event`) trigger points still call the
    /// original play* methods; this entry point is for new code and for the
    /// Settings UI preview.
    ///
    /// NOTE: v1 has no trigger points calling this directly for the reserved
    /// categories (sessionStart, taskError, taskAcknowledge, userSpam,
    /// resourceLimit, remoteConnected). When those get wired up later, they
    /// can call `play(.xxx)` and nothing else in this file needs to change.
    func play(_ category: SoundCategory, context: String = "") {
        guard soundEnabled else { return }
        guard isEnabled(category) else { return }
        Self.traceSoundPlay("category.\(category.rawValue)\(context.isEmpty ? "" : " \(context)")")
        playCategory(category, key: "cat.\(category.rawValue)", bypassDebounce: false)
    }

    /// Preview variant: ignores cooldown and enable flag, so the user can
    /// audition even muted categories from Settings.
    func playPreview(for category: SoundCategory) {
        playCategory(category, key: "preview.cat.\(category.rawValue)", bypassDebounce: true)
    }

    // MARK: - Per-category enable / override

    func isEnabled(_ category: SoundCategory) -> Bool {
        // Legacy keys win if present (so flipping a toggle in the old UI
        // still has effect until Phase 3 migrates to the new key).
        if let legacyEvent = category.legacyEvent,
           let legacy = UserDefaults.standard.object(forKey: legacyEvent.legacyEnabledDefaultsKey) as? Bool {
            return legacy
        }
        return UserDefaults.standard.object(forKey: category.enabledDefaultsKey) as? Bool ?? true
    }

    func setEnabled(_ category: SoundCategory, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: category.enabledDefaultsKey)
        if let legacyEvent = category.legacyEvent {
            UserDefaults.standard.set(enabled, forKey: legacyEvent.legacyEnabledDefaultsKey)
        }
    }

    // MARK: - Core resolution chain

    /// Resolution order:
    ///   1. Legacy per-event override file  (~/…/SoundPacks/Custom/<event>.<ext>)
    ///   2. Active pack entry for event.categoryId
    ///   3. NSSound system-named fallback list
    ///   4. NSSound.beep()
    private func playEvent(_ event: Event,
                           key: String,
                           fallback systemNames: [String],
                           bypassDebounce: Bool = false) {
        if !bypassDebounce {
            let now = Date()
            if let last = lastPlayedAt[key], now.timeIntervalSince(last) < minInterval {
                return
            }
            lastPlayedAt[key] = now
        }

        // 1. Per-event override file
        if let url = customSoundURL(for: event),
           SoundPackPlayer.shared.play(source: .file(url)) {
            return
        }

        // 2. Active pack
        if let pack = activePack,
           SoundPackPlayer.shared.play(pack: pack, categoryId: event.categoryId) {
            return
        }

        // 3. System named fallback
        for name in systemNames {
            if SoundPackPlayer.shared.play(source: .systemNamed(name)) { return }
        }

        // 4. Beep
        SoundPackPlayer.shared.play(source: .beep)
    }

    private func fallbackNames(for event: Event) -> [String] {
        switch event {
        case .permission:   return ["Submarine", "Basso", "Ping"]
        case .ask:          return ["Ping", "Tink", "Pop"]
        case .taskComplete: return ["Glass", "Hero", "Ping"]
        case .appStarted:   return ["Glass", "Hero", "Funk"]
        }
    }

    /// Category-level playback with the full resolution chain:
    ///   1. per-category override file (new key `sound.category.<name>.overrideFile`
    ///      OR legacy `soundCustomName.<event>` file if present)
    ///   2. active pack entry for category.manifestKey
    ///   3. category.systemSoundFallback
    ///   4. NSSound.beep()
    private func playCategory(_ category: SoundCategory, key: String, bypassDebounce: Bool) {
        if !bypassDebounce {
            let now = Date()
            if let last = lastPlayedAt[key], now.timeIntervalSince(last) < minInterval {
                return
            }
            lastPlayedAt[key] = now
        }

        // 1. New-style override file
        if let overridePath = UserDefaults.standard.string(forKey: category.overrideFileDefaultsKey),
           !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath)
            if SoundPackPlayer.shared.play(source: .file(url)) { return }
        }
        // 1b. Legacy per-event override file (if this category maps to one)
        if let legacyEvent = category.legacyEvent,
           let url = customSoundURL(for: legacyEvent),
           SoundPackPlayer.shared.play(source: .file(url)) {
            return
        }

        // 2. Active pack
        if let pack = activePack,
           SoundPackPlayer.shared.play(pack: pack, categoryId: category.manifestKey) {
            return
        }

        // 3. System named fallback
        for name in category.systemSoundFallback {
            if SoundPackPlayer.shared.play(source: .systemNamed(name)) { return }
        }

        // 4. Beep
        SoundPackPlayer.shared.play(source: .beep)
    }

    // MARK: - Legacy custom-file helpers

    private func removeExistingCustomFile(for event: Event) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: legacyCustomSoundsDir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(event.rawValue + ".") {
            try? fm.removeItem(at: file)
        }
    }

    private func customSoundURL(for event: Event) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: legacyCustomSoundsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return files.first(where: { $0.lastPathComponent.hasPrefix(event.rawValue + ".") })
    }

    // MARK: - Tracing

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
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(3).joined(separator: " <- ")
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(kind)\n  \(stack)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
