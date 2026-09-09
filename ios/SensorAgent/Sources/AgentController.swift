#if os(iOS)
import Foundation
import SwiftUI

/// Wires the protocol client to the phone's capture hardware. Everything platform-specific
/// lives here; `BridgeClient` stays Foundation-only so the same file serves the macOS
/// harness in tools/swift-sensor and, later, a DAT build.
@MainActor
final class AgentController: ObservableObject {
    @Published var baseURL: String = UserDefaults.standard.string(forKey: "baseURL") ?? ""
    @Published var token: String = UserDefaults.standard.string(forKey: "token") ?? ""
    @Published var running = false
    @Published var status = "idle"
    @Published var lastTranscript = ""

    private var task: Task<Void, Never>?
    private let dictation = Dictation()
    private let camera = StillCapture()

    /// One stable id per install, as PROTOCOL.md requires. Regenerating it on every
    /// launch would leave the bridge showing phantom devices until their TTL expired.
    private var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: "deviceId") { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "deviceId")
        return fresh
    }

    func start() {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              !token.isEmpty else {
            status = "need a bridge URL and token"
            return
        }
        UserDefaults.standard.set(baseURL, forKey: "baseURL")
        UserDefaults.standard.set(token, forKey: "token")

        running = true
        status = "connecting…"
        camera.configure()

        let client = BridgeClient(
            base: url, token: token, deviceId: deviceId,
            name: UIDevice.current.name,
            // No glasses- prefixes: the phone is a stand-in and the web app is meant
            // to show it as one rather than pass it off as the real sensors.
            caps: [.mic, .camera]
        )

        dictation.onText = { [weak self] text, isFinal in
            Task { @MainActor in self?.lastTranscript = text }
            Task { try? await client.postTranscript(text, final: isFinal) }
        }

        task = Task { [weak self] in
            await client.run { command in
                await self?.handle(command, client: client)
            }
        }
        status = "online"
    }

    func stop() {
        task?.cancel()
        task = nil
        dictation.stop()
        camera.stop()
        running = false
        status = "idle"
    }

    private func handle(_ command: BridgeCommand, client: BridgeClient) async {
        switch command.action {
        case "mic.start":
            guard await Dictation.requestPermission() else {
                await set(status: "mic denied in Settings"); return
            }
            await set(status: "listening")
            try? dictation.start()
        case "mic.stop":
            dictation.stop()
            await set(status: "online")
        case "camera.still":
            guard await StillCapture.requestPermission() else {
                await set(status: "camera denied in Settings"); return
            }
            await set(status: "capturing")
            let jpeg: Data? = await withCheckedContinuation { c in
                camera.capture { c.resume(returning: $0) }
            }
            if let jpeg { try? await client.postStill(jpeg) }
            await set(status: jpeg == nil ? "capture failed" : "online")
        default:
            break
        }
    }

    private func set(status value: String) async {
        await MainActor.run { self.status = value }
    }
}
#endif
