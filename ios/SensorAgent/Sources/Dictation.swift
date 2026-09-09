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
        // .measurement avoids the system applying its own processing to the signal,
        // and .duckOthers keeps the phone usable for anything else that is playing.
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

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
