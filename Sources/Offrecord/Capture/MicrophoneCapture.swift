@preconcurrency import AVFoundation

/// Captures the default input device with AVAudioEngine and restarts itself
/// when the input device changes (e.g. headphones plugged in).
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var voiceProcessing: Bool
    /// Whether Apple voice processing ended up active (it is dropped if the device refuses it).
    private(set) var voiceProcessingActive = false

    /// `voiceProcessing`: Apple's echo cancellation + noise suppression + automatic gain,
    /// the same processing call apps use. Keeps the user's voice at a normal level even
    /// while a call app is processing the microphone.
    init(voiceProcessing: Bool = false, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.voiceProcessing = voiceProcessing
        self.onBuffer = onBuffer
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        try installTapAndStart()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            try? self?.installTapAndStart()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func installTapAndStart() throws {
        do {
            try configureAndStart(voiceProcessing: voiceProcessing)
        } catch where voiceProcessing {
            // Some devices refuse voice processing: fall back to the raw microphone.
            voiceProcessing = false
            try configureAndStart(voiceProcessing: false)
        }
    }

    private func configureAndStart(voiceProcessing: Bool) throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if input.isVoiceProcessingEnabled != voiceProcessing {
            try input.setVoiceProcessingEnabled(voiceProcessing)
        }
        if voiceProcessing {
            input.isVoiceProcessingAGCEnabled = true
            input.isVoiceProcessingBypassed = false
            // Do not turn down the call audio the user is listening to.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing runs input and output together; keep the output silent.
            engine.mainMixerNode.outputVolume = 0
        }
        voiceProcessingActive = voiceProcessing
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noMicrophone
        }
        let handler = onBuffer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            handler(buffer)
        }
        engine.prepare()
        try engine.start()
    }
}

enum CaptureError: LocalizedError {
    case noMicrophone
    case microphoneDenied
    case noDisplay
    case screenTargetGone
    case screenPermission(Error)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: L("No microphone found.")
        case .microphoneDenied: L("No microphone permission. Allow Offrecord in System Settings › Privacy & Security › Microphone.")
        case .noDisplay: L("No display to record.")
        case .screenTargetGone: L("The screen or window to record is no longer available.")
        case .screenPermission(let error):
            L("Permission needed for system audio / screen. Allow Offrecord in System Settings › Privacy & Security › Screen & System Audio Recording, then restart the app. (%@)", error.localizedDescription)
        }
    }
}
