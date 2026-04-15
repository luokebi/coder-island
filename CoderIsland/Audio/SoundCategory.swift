import Foundation

/// Grouped enumeration of all sound-eligible events. Section groupings come
/// from the Vibe Island / docs/sound-design.md taxonomy. In v1 only the four
/// cases with `.isActiveInV1 == true` actually have trigger points wired in;
/// the rest are architecturally reserved so Settings UI can let the user
/// assign sounds today even though nothing will fire them until later.
enum SoundCategory: String, CaseIterable, Identifiable {
    // Section: session
    case sessionStart
    case taskComplete
    case taskError

    // Section: interactions
    case inputRequired
    case inputQuestion
    case taskAcknowledge

    // Section: filters
    case userSpam
    case resourceLimit

    // Section: system
    case appStarted
    case remoteConnected

    var id: String { rawValue }

    /// Matches the category IDs used in `.cipack` manifests.
    var manifestKey: String { rawValue }

    // MARK: - Sections

    enum Section: String, CaseIterable {
        case session
        case interactions
        case filters
        case system

        var displayName: String {
            switch self {
            case .session:      return "Session"
            case .interactions: return "Interactions"
            case .filters:      return "Filters"
            case .system:       return "System"
            }
        }
    }

    var section: Section {
        switch self {
        case .sessionStart, .taskComplete, .taskError:
            return .session
        case .inputRequired, .inputQuestion, .taskAcknowledge:
            return .interactions
        case .userSpam, .resourceLimit:
            return .filters
        case .appStarted, .remoteConnected:
            return .system
        }
    }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .sessionStart:    return "Session start"
        case .taskComplete:    return "Task complete"
        case .taskError:       return "Task error"
        case .inputRequired:   return "Permission pending"
        case .inputQuestion:   return "Question pending"
        case .taskAcknowledge: return "Prompt acknowledged"
        case .userSpam:        return "Rapid prompts"
        case .resourceLimit:   return "Context compacting"
        case .appStarted:      return "App started"
        case .remoteConnected: return "Remote connected"
        }
    }

    /// One-line description for Settings UI. Mirrors Vibe Island's
    /// `sound.desc.*` localizable strings.
    var helpText: String {
        switch self {
        case .sessionStart:    return "New AI session begins"
        case .taskComplete:    return "AI finishes a turn"
        case .taskError:       return "Tool or API error"
        case .inputRequired:   return "Permission approval pending"
        case .inputQuestion:   return "Waiting for your answer"
        case .taskAcknowledge: return "You submit a prompt"
        case .userSpam:        return "Rapid prompt submissions"
        case .resourceLimit:   return "Context window compacting"
        case .appStarted:      return "Coder Island launches"
        case .remoteConnected: return "SSH Remote tunnel established"
        }
    }

    // MARK: - v1 activation flag

    /// True when a trigger point in the app currently fires this category.
    /// The other six values are reserved for future phases.
    var isActiveInV1: Bool {
        switch self {
        case .taskComplete, .inputRequired, .inputQuestion, .appStarted:
            return true
        default:
            return false
        }
    }

    // MARK: - Bridging from the legacy Event enum

    init?(event: SoundManager.Event) {
        switch event {
        case .permission:   self = .inputRequired
        case .ask:          self = .inputQuestion
        case .taskComplete: self = .taskComplete
        case .appStarted:   self = .appStarted
        }
    }

    /// The legacy Event case this category maps to, if any. Used so the new
    /// Category-based enable API can honor the pre-existing UserDefaults
    /// toggles until Phase 3 migrates Settings UI.
    var legacyEvent: SoundManager.Event? {
        switch self {
        case .inputRequired:   return .permission
        case .inputQuestion:   return .ask
        case .taskComplete:    return .taskComplete
        case .appStarted:      return .appStarted
        default:               return nil
        }
    }

    // MARK: - UserDefaults keys

    var enabledDefaultsKey: String { "sound.category.\(rawValue).enabled" }
    var overrideFileDefaultsKey: String { "sound.category.\(rawValue).overrideFile" }

    /// Fallback NSSound names if the active pack has no entry for this category.
    /// Mirrors the hard-coded lists previously in SoundManager.
    var systemSoundFallback: [String] {
        switch self {
        case .appStarted, .sessionStart:   return ["Glass", "Hero", "Funk"]
        case .taskComplete:                return ["Glass", "Hero", "Ping"]
        case .taskError:                   return ["Basso", "Submarine", "Sosumi"]
        case .inputRequired:               return ["Submarine", "Basso", "Ping"]
        case .inputQuestion:               return ["Ping", "Tink", "Pop"]
        case .taskAcknowledge:             return ["Pop", "Tink"]
        case .userSpam:                    return ["Funk", "Sosumi"]
        case .resourceLimit:               return ["Submarine", "Basso"]
        case .remoteConnected:             return ["Blow", "Ping"]
        }
    }
}
