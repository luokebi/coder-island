import Foundation
import AVFoundation
import AppKit

/// AVAudioEngine-backed sound effect player. A single shared engine with a
/// pool of player nodes so overlapping categories can mix instead of cutting
/// each other off.
///
/// Responsibilities:
///   - Hold the audio engine / mixer graph
///   - Resolve (override URL → active pack entry → system NSSound → beep)
///   - Playback with per-play volume; scheduling on a pool of AVAudioPlayerNodes
///
/// Playback *policy* (cooldown, priority, quiet hours) lives in SoundManager;
/// this class just plays what it's told.
final class SoundPackPlayer {
    static let shared = SoundPackPlayer()

    private let engine = AVAudioEngine()
    private var playerNodes: [AVAudioPlayerNode] = []
    private let maxConcurrentPlayers = 4
    private var isEngineStarted = false
    private let engineQueue = DispatchQueue(label: "app.coderisland.soundplayer.engine")

    /// master multiplier applied to every playback. Range 0.0 – 1.0.
    var masterVolume: Float = 0.7

    private init() {
        // AVAudioEngine is lazy-started on first play. Starting eagerly at
        // launch can cause coreaudiod warmup delays visible to the user.
    }

    // MARK: - Public API

    /// Plays a resolved source. Returns false if nothing could be played
    /// (in which case callers may fall back to NSSound.beep()).
    @discardableResult
    func play(source: PlaybackSource, volume: Float = 1.0) -> Bool {
        let effective = max(0, min(1, masterVolume * volume))
        switch source {
        case .buffer(let buffer):
            return playBuffer(buffer, volume: effective)
        case .file(let url):
            guard let buffer = SoundPack.loadBuffer(from: url) else { return false }
            return playBuffer(buffer, volume: effective)
        case .systemNamed(let name):
            return playSystemNamed(name, volume: effective)
        case .beep:
            NSSound.beep()
            return true
        }
    }

    /// High-level helper: given a pack and category id, pick an entry and play.
    @discardableResult
    func play(pack: SoundPack, categoryId: String, additionalVolume: Float = 1.0) -> Bool {
        guard let entry = pack.pickEntry(for: categoryId) else { return false }
        let combined = additionalVolume * (entry.volume ?? 1.0)
        if let systemName = pack.isSystemSound(entry) {
            return play(source: .systemNamed(systemName), volume: combined)
        }
        if let buffer = pack.cachedBuffer(for: entry) {
            return play(source: .buffer(buffer), volume: combined)
        }
        return false
    }

    // MARK: - Engine management

    private func ensureEngineStarted() {
        engineQueue.sync {
            guard !isEngineStarted else { return }
            // Build pool of player nodes.
            for _ in 0..<maxConcurrentPlayers {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: nil)
                playerNodes.append(node)
            }
            do {
                try engine.start()
                isEngineStarted = true
            } catch {
                NSLog("[SoundPackPlayer] AVAudioEngine start failed: %@", error.localizedDescription)
            }
        }
    }

    private func playBuffer(_ buffer: AVAudioPCMBuffer, volume: Float) -> Bool {
        ensureEngineStarted()
        guard isEngineStarted else { return false }
        guard let node = pickFreeNode() else { return false }
        node.volume = volume
        // Important: do NOT call node.stop() from the completion handler.
        // The handler runs on AVAudioPlayerNodeImpl.CompletionHandlerQueue
        // and stop() internally dispatches sync to that same queue, causing
        // a libdispatch deadlock (BUG IN CLIENT OF LIBDISPATCH). The node
        // is already idle once the buffer finishes playing — no action needed.
        node.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        node.play()
        return true
    }

    /// Round-robin pick: prefer a node not currently playing; otherwise reuse
    /// the first node (it will be interrupted by the .interrupts option).
    private func pickFreeNode() -> AVAudioPlayerNode? {
        if let idle = playerNodes.first(where: { !$0.isPlaying }) {
            return idle
        }
        return playerNodes.first
    }

    private func playSystemNamed(_ name: String, volume: Float) -> Bool {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return false }
        sound.volume = volume
        // Stop any prior play so repeated triggers don't queue.
        sound.stop()
        return sound.play()
    }

    // MARK: - PlaybackSource

    enum PlaybackSource {
        case buffer(AVAudioPCMBuffer)
        case file(URL)
        case systemNamed(String)
        case beep
    }
}
