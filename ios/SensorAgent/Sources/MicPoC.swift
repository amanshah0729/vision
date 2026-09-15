#if os(iOS)
import Foundation

/// Standalone mic harness — no bridge, no DAT, no paid account. Confirms the glasses expose a
/// Bluetooth HFP mic and that dictation can capture from it. This is the one glasses capability
/// reachable on a free account today, because it rides standard AVAudioSession, not DAT.
@MainActor
final class MicPoC: ObservableObject {
    @Published var running = false
    @Published var status = "idle"
    @Published var transcript = ""
    @Published var preferGlasses = true
    @Published var inputs: [String] = []
    @Published var activeInput = "—"

    private let dictation = Dictation()

    init() {
        dictation.onText = { [weak self] text, _ in
            Task { @MainActor in self?.transcript = text }
        }
    }

    /// List what iOS sees, and flag whether a glasses-style HFP mic is among them.
    func probe() {
        inputs = Dictation.availableInputs()
        let hasHFP = inputs.contains { $0.contains("BluetoothHFP") }
        status = hasHFP
            ? "HFP mic found — glasses expose a mic"
            : "no HFP input (connect glasses, or they may not expose a mic)"
    }

    func start() {
        Task { @MainActor in
            guard await Dictation.requestPermission() else {
                status = "mic/speech denied in Settings"
                return
            }
            dictation.preferBluetoothHFP = preferGlasses
            do {
                try dictation.start()
                running = true
                activeInput = dictation.currentInputDescription
                status = preferGlasses ? "listening (glasses)" : "listening (phone)"
            } catch {
                status = "failed: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        dictation.stop()
        running = false
        activeInput = "—"
        status = "idle"
    }
}
#endif
