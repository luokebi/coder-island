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

    /// Legacy per-event override directory. Retained for reading existing
    /// user files; new writes go to `overridesDir`.
    private var legacyCustomSoundsDir: URL {
        appSupportDir.appendingPathComponent("SoundPacks/Custom", isDirectory: true)
    }

    /// New per-category override directory, used by the Settings UI
    /// introduced in Phase 3.
    private var overridesDir: URL {
        appSupportDir.appendingPathComponent("SoundPacks/Overrides", isDirectory: true)
    }

    var selectedPreset: Preset {
        let raw = UserDefaults.standard.string(forKey: presetKey) ?? ""
        return Preset(rawValue: raw) ?? .mario
    }

    private let activePackKey = "sound.activePackId"

    /// The active pack id, preferring the new `sound.activePackId` key and
    /// falling back to the legacy `soundPreset`'s mapping.
    var activePackId: String {
        get {
            if let id = UserDefaults.standard.string(forKey: activePackKey), !id.isEmpty {
                return id
            }
            return selectedPreset.packId
        }
        set {
            UserDefaults.standard.set(newValue, forKey: activePackKey)
            // Best-effort mirror into legacy `soundPreset` so older Settings
            // UI still shows the right value if it ever re-renders.
            if let preset = Preset.allCases.first(where: { $0.packId == newValue }) {
                UserDefaults.standard.set(preset.rawValue, forKey: presetKey)
            }
        }
    }

    /// The active pack, resolved against SoundPackStore.
    var activePack: SoundPack? {
        let store = SoundPackStore.shared
        return store.pack(withId: activePackId) ?? store.defaultPack
    }

    // MARK: - Per-category override API (Phase 3)

    /// Returns the override file URL for a category, preferring the new
    /// `Overrides/<category>.<ext>` location and falling back to the legacy
    /// per-event file if this category maps to a legacy Event.
    func overrideFileURL(for category: SoundCategory) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: overridesDir.path),
           let files = try? fm.contentsOfDirectory(at: overridesDir, includingPropertiesForKeys: nil),
           let match = files.first(where: { $0.lastPathComponent.hasPrefix(category.rawValue + ".") }) {
            return match
        }
        if let legacyEvent = category.legacyEvent {
            return customSoundURL(for: legacyEvent)
        }
        return nil
    }

    /// User-friendly file name for the override (for Settings row subtitle).
    /// Uses the stored display name first; falls back to the actual file's
    /// basename if we only know the file on disk.
    func overrideDisplayName(for category: SoundCategory) -> String? {
        if let stored = UserDefaults.standard.string(forKey: category.overrideFileDefaultsKey),
           !stored.isEmpty {
            return stored
        }
        if let legacyEvent = category.legacyEvent,
           let stored = customSoundName(for: legacyEvent), !stored.isEmpty {
            return stored
        }
        return overrideFileURL(for: category)?.lastPathComponent
    }

    /// Imports a user-selected file as the override for `category`.
    /// Writes to `Overrides/<category>.<ext>` and persists the display name.
    /// For categories that map to a legacy Event, this also removes the
    /// legacy per-event file to avoid double-play.
    func setOverride(for category: SoundCategory, from sourceURL: URL) throws {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try fm.createDirectory(at: overridesDir, withIntermediateDirectories: true)
        removeExistingOverrideFile(for: category)

        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let target = overridesDir.appendingPathComponent("\(category.rawValue).\(ext)")
        try fm.copyItem(at: sourceURL, to: target)

        UserDefaults.standard.set(sourceURL.lastPathComponent, forKey: category.overrideFileDefaultsKey)

        // Migrate forward: if a legacy per-event file exists, remove it so
        // resolution doesn't accidentally prefer the old file.
        if let legacyEvent = category.legacyEvent {
            removeExistingCustomFile(for: legacyEvent)
            UserDefaults.standard.removeObject(forKey: customNamePrefix + legacyEvent.rawValue)
        }
    }

    /// Removes the per-category override, reverting to active-pack behavior.
    func clearOverride(for category: SoundCategory) {
        removeExistingOverrideFile(for: category)
        UserDefaults.standard.removeObject(forKey: category.overrideFileDefaultsKey)
        if let legacyEvent = category.legacyEvent {
            removeExistingCustomFile(for: legacyEvent)
            UserDefaults.standard.removeObject(forKey: customNamePrefix + legacyEvent.rawValue)
        }
    }

    private func removeExistingOverrideFile(for category: SoundCategory) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: overridesDir.path),
              let files = try? fm.contentsOfDirectory(at: overridesDir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(category.rawValue + ".") {
            try? fm.removeItem(at: file)
        }
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

        // 1. Override file (new Overrides/<category>.<ext> → legacy fallback)
        if let url = overrideFileURL(for: category),
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
