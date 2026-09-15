#if canImport(Speech)
import AVFoundation
import Foundation
import Speech

/// Live dictation via SFSpeechRecognizer. Emits partials as they arrive and one final
/// when the recognizer settles, matching `POST /api/sensors/transcript` in PROTOCOL.md.
///
/// This is the piece the glasses cannot do themselves: the MRBD browser exposes no
/// audioinput at all, so the phone's microphone stands in for it.
final class Dictation: NSObject {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Called with (text, isFinal). Fires on an arbitrary queue.
    var onText: ((String, Bool) -> Void)?

    /// Route capture to the glasses' **Bluetooth HFP** mic instead of the phone's. The glasses
    /// are an ordinary Bluetooth headset here — DAT never exposes the mic, so this is plain
    /// AVAudioSession and needs no DAT, no Wi-Fi entitlements, and no paid account. HFP is mono,
    /// speech-quality, and beamformed to the wearer.
    var preferBluetoothHFP = false

    /// The inputs iOS currently sees, so a caller can confirm the glasses present an HFP mic.
    /// BT inputs only appear once the category allows HFP and the session is active.
    static func availableInputs() -> [String] {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try? session.setActive(true)
        return (session.availableInputs ?? []).map { "\($0.portName) [\($0.portType.rawValue)]" }
    }

    /// What the mic is actually capturing from right now — phone vs glasses at a glance.
    var currentInputDescription: String {
        AVAudioSession.sharedInstance().currentRoute.inputs
            .map { "\($0.portName) [\($0.portType.rawValue)]" }
            .joined(separator: ", ")
    }

    static func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        return speech && mic
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { return }
        stop()

        let session = AVAudioSession.sharedInstance()
        if preferBluetoothHFP {
            // HFP is the two-way call profile, so .playAndRecord + .allowBluetoothHFP is what
            // surfaces the glasses as a selectable input; .measurement would strip the
            // processing HFP relies on. Then explicitly prefer the HFP port so capture routes
            // to the glasses rather than the phone's own mic.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try? session.setPreferredInput(hfp)
            }
        } else {
            // .measurement avoids the system applying its own processing to the signal,
            // and .duckOthers keeps the phone usable for anything else that is playing.
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        // Tap in the hardware's own format. Hardcoding a sample rate is the classic
        // way this crashes on a device whose input runs at something unexpected.
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
            req.append(buf)
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.onText?(result.bestTranscription.formattedString, result.isFinal)
            }
            if error != nil || result?.isFinal == true { self.stop() }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
