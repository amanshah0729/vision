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
    private let camera = GlassesCamera()

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

        let client = BridgeClient(
            base: url, token: token, deviceId: deviceId,
            name: UIDevice.current.name,
            // `glasses-camera` because stills now come off the glasses via DAT. The mic is
            // still the phone's, so it stays unprefixed — the web app is meant to be able to
            // tell those apart at a glance.
            caps: [.mic, .camera, .glassesCamera]
        )

        dictation.onText = { [weak self] text, isFinal in
            Task { @MainActor in self?.lastTranscript = text }
            Task { try? await client.postTranscript(text, final: isFinal) }
        }

        // Both closures capture `self` weakly in their own right. Letting the inner one
        // reach through the outer one's captured variable is an error under Swift 6.
        task = Task { [weak self] in
            await client.run { [weak self] command in
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
            await set(status: "capturing")
            do {
                // Both of these surface real, actionable reasons — "approve Sensor Agent in
                // the Meta AI app", "hinges closed" — so the message is shown rather than
                // flattened into a generic failure the user cannot act on.
                try await GlassesCamera.ensureAccess()
                let jpeg = try await camera.capture()
                try await client.postStill(jpeg)
                await set(status: "online")
            } catch {
                await set(status: error.localizedDescription)
            }
        default:
            break
        }
    }

    private func set(status value: String) async {
        await MainActor.run { self.status = value }
    }
}
#endif
