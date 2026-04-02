import AVFoundation
import AppKit

class SoundManager {
    static let shared = SoundManager()
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    private init() {
        setupAudioEngine()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        guard let engine = audioEngine, let player = playerNode else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    private var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true
    }

    /// Play a short 8-bit style beep sequence
    func playAgentStarted() {
        guard soundEnabled else { return }
        play8BitTone(frequencies: [440, 554, 659], duration: 0.08)
    }

    func playTaskComplete() {
        guard soundEnabled else { return }
        play8BitTone(frequencies: [523, 659, 784, 1047], duration: 0.1)
    }

    func playPermissionNeeded() {
        guard soundEnabled else { return }
        play8BitTone(frequencies: [880, 660, 880], duration: 0.12)
    }

    func playError() {
        guard soundEnabled else { return }
        play8BitTone(frequencies: [330, 220], duration: 0.15)
    }

    /// Generate and play square-wave tones (classic 8-bit sound)
    private func play8BitTone(frequencies: [Double], duration: Float) {
        guard let engine = audioEngine, let player = playerNode else { return }

        let sampleRate: Double = 44100
        let samplesPerTone = Int(sampleRate * Double(duration))
        let totalSamples = samplesPerTone * frequencies.count

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(totalSamples)
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let amplitude: Float = 0.15

        for (i, freq) in frequencies.enumerated() {
            let offset = i * samplesPerTone
            for sample in 0..<samplesPerTone {
                let phase = Double(sample) / sampleRate * freq
                // Square wave for that 8-bit sound
                let value: Float = sin(2.0 * .pi * phase) > 0 ? amplitude : -amplitude
                // Apply fade envelope to avoid clicks
                let envelope = min(Float(sample) / 200.0, Float(samplesPerTone - sample) / 200.0, 1.0)
                channelData[offset + sample] = value * envelope
            }
        }

        if !engine.isRunning {
            try? engine.start()
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }
}
