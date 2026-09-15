#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// Wires the protocol client to the phone's capture hardware. Everything platform-specific
/// lives here; `BridgeClient` stays Foundation-only so the same file serves the macOS
/// harness in tools/swift-sensor and, later, a DAT build.
@MainActor
final class AgentController: ObservableObject {
    @Published var baseURL: String = launchArg("-bridgeURL") ?? UserDefaults.standard.string(forKey: "baseURL") ?? ""
    @Published var token: String = launchArg("-bridgeToken") ?? UserDefaults.standard.string(forKey: "token") ?? ""
    @Published var running = false
    @Published var status = "idle"
    @Published var lastTranscript = ""
    /// The most recent still, shown inline so a capture can be confirmed on the phone without
    /// a bridge or the glasses web app. Drives the "Capture now" test button.
    @Published var lastImage: UIImage?
    /// Off by default. When on, `start()` stands a fake pair of glasses up via `GlassesMock`
    /// so the DAT capture path runs with no hardware and no Meta account. A mock session is
    /// advertised as a stand-in (see the caps below), never as the real glasses.
    @Published var useMockGlasses = UserDefaults.standard.bool(forKey: "useMockGlasses")

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
        UserDefaults.standard.set(useMockGlasses, forKey: "useMockGlasses")

        // Stand the fake glasses up before the caps are decided, so `ensureAccess` finds a
        // registered mock device already granted the camera permission.
        if useMockGlasses { GlassesMock.enable() }

        running = true
        status = useMockGlasses ? "connecting… (mock glasses)" : "connecting…"
        PoCLog.write("AGENT: start bridge=\(url) mock=\(useMockGlasses) deviceId=\(deviceId)")

        let client = BridgeClient(
            base: url, token: token, deviceId: deviceId,
            // The name carries the stand-in marker too, so a glance at `GET /api/sensors`
            // reveals it even before the caps are inspected.
            name: useMockGlasses ? "\(UIDevice.current.name) (mock)" : UIDevice.current.name,
            // Real build: `glasses-camera`, because stills come off the glasses via DAT. Mock
            // build: a stand-in, so per PROTOCOL.md it reports plain `["mic","camera"]` and the
            // web app marks it — a desk test must never be mistaken for the real thing. The mic
            // is always the phone's, so it stays unprefixed either way.
            caps: useMockGlasses ? [.mic, .camera] : [.mic, .camera, .glassesCamera]
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

    /// Take one still right now and show it, with no bridge and no `camera.still` command in the
    /// loop. This is the standalone way to confirm the glasses camera works: on a real phone the
    /// first call triggers the Meta AI registration + camera approvals, then a photo comes back.
    /// Honours the mock toggle, so the same button proves the path with or without hardware.
    func captureNow() {
        if useMockGlasses { GlassesMock.enable() }
        Task { @MainActor in
            status = useMockGlasses ? "capturing… (mock)" : "capturing…"
            do {
                if useMockGlasses { await GlassesMock.awaitReady() }
                try await GlassesCamera.ensureAccess()
                let jpeg = try await camera.capture()
                lastImage = UIImage(data: jpeg)
                status = "captured \(jpeg.count) bytes"
            } catch {
                // The camera surfaces actionable reasons — "approve Sensor Agent in the Meta AI
                // app", "hinges closed" — so show them rather than a generic failure.
                status = error.localizedDescription
            }
        }
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
            PoCLog.write("AGENT: camera.still received")
            do {
                // Both of these surface real, actionable reasons — "approve Sensor Agent in
                // the Meta AI app", "hinges closed" — so the message is shown rather than
                // flattened into a generic failure the user cannot act on.
                try await GlassesCamera.ensureAccess()
                let t0 = Date()
                let jpeg = try await camera.capture()
                let captured = Date().timeIntervalSince(t0)
                try await client.postStill(jpeg)
                PoCLog.write("AGENT: still posted bytes=\(jpeg.count) capture=\(Int(captured * 1000))ms total=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
                await set(status: "online")
            } catch {
                PoCLog.write("AGENT: camera.still FAILED \(error) — \(error.localizedDescription)")
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

/// `-name value` from the command line, so a bridge run can be driven from the Mac:
/// `device.sh bridge <url> <token>` launches with `-bridgeURL … -bridgeToken … -autoStartAgent`.
func launchArg(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
#endif
