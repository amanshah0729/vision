#if os(iOS)
import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// A standalone live-camera harness whose whole reason to exist is **measuring**: how many
/// frames per second actually arrive off the glasses, and how long a photo round-trips. It is
/// deliberately separate from `GlassesCamera` (which is a one-shot capture for the bridge) —
/// this one keeps the stream open and surfaces every frame plus timing, with no bridge and no
/// server in the loop.
///
/// The numbers only mean something on real hardware. Against `MockDeviceKit` the feed is a
/// canned MP4, so fps reflects the mock file and latency is ~0 — that run proves the pipeline
/// wires up, nothing about the real Bluetooth/Wi-Fi link.
@MainActor
final class CameraPoC: ObservableObject {
    @Published var frame: UIImage?
    @Published var running = false
    @Published var status = "idle"
    /// True once the stream reaches `.streaming` — the whole session/camera/stream bring-up
    /// succeeded. Frames arriving is a *separate* thing (see the stream tests): the mock reaches
    /// this state but emits no synthetic frames, so on the simulator this is as far as it goes.
    @Published private(set) var reachedStreaming = false
    @Published var fps = 0
    @Published var frameCount = 0
    @Published var frameSize = "—"
    /// Round-trip for `capturePhoto` → photo delivered, in ms. The one latency number the app
    /// can measure on its own; true glass-to-screen latency needs the point-at-a-clock method.
    @Published var lastCaptureLatencyMs: Int?

    // Knobs — the point of the PoC is watching these move the numbers.
    @Published var useMockGlasses = UserDefaults.standard.bool(forKey: "useMockGlasses")
    @Published var resolution: StreamingResolution = .medium
    @Published var frameRate: UInt = 30

    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []
    private var frameTimes: [Date] = []
    private var captureStart: Date?

    enum PoCError: LocalizedError {
        case noCamera, timeout(String)
        var errorDescription: String? {
            switch self {
            case .noCamera:       return "glasses refused the camera"
            case .timeout(let s): return "timed out at \(s)"
            }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        reachedStreaming = false
        frameCount = 0
        frameTimes = []
        fps = 0

        Task { @MainActor in
            do {
                if useMockGlasses {
                    GlassesMock.enable()
                    await GlassesMock.awaitReady()
                }
                status = "checking access…"
                try await GlassesCamera.ensureAccess()

                status = "starting session…"
                let wearables = Wearables.shared
                let selector = AutoDeviceSelector(wearables: wearables)
                try await waitUntil("device selection", 8) { selector.activeDevice != nil }
                let session = try wearables.createSession(deviceSelector: selector)
                self.session = session
                try session.start()
                try await waitUntil("session start", 10) { session.state == .started }

                status = "starting stream…"
                // `.hvc1` (compressed), matching Meta's streaming sample: the video-frame
                // publisher delivers on this codec, and `VideoFrame.makeUIImage()` decodes it.
                // (`.raw` reaches `.streaming` and serves photos but yields no video frames.)
                guard let camera = try session.addCamera(config: StreamConfiguration(
                    videoCodec: .hvc1, resolution: resolution, frameRate: frameRate)) else {
                    throw PoCError.noCamera
                }
                self.camera = camera
                // The mock only pumps video frames once a camera exists; re-apply the feed now.
                if useMockGlasses { GlassesMock.reapplyFeed() }
                let stream = camera.stream
                attachListeners(to: stream)
                stream.start()
                try await waitUntil("stream start", 15) { stream.state == .streaming }
                reachedStreaming = true
                status = "streaming"
            } catch {
                status = "failed: \(error.localizedDescription)"
                stop()
            }
        }
    }

    func stop() {
        let toks = tokens
        tokens = []
        Task { for t in toks { await t.cancel() } }
        camera?.stop()
        session?.stop()
        camera = nil
        session = nil
        running = false
        reachedStreaming = false
        fps = 0
        frameTimes = []
        captureStart = nil
        if status != "idle" && !status.hasPrefix("failed") { status = "idle" }
    }

    /// Fire one photo and time the round trip. Requires the stream to be live.
    func measureCaptureLatency() {
        guard let stream = camera?.stream, stream.state == .streaming else {
            status = "start the stream first"
            return
        }
        captureStart = Date()
        if !stream.capturePhoto(format: .jpeg) {
            captureStart = nil
            status = "capture rejected"
        }
    }

    // MARK: - Frame plumbing

    // Fully qualified because `Foundation.Stream` is also in scope and wins the ambiguity.
    private func attachListeners(to stream: MWDATCamera.Stream) {
        // `VideoFrame`, `PhotoData`, `StreamState`, `StreamError` are all Sendable, so hop the
        // value to the main actor and do the (cheap, for .raw) UIImage decode there.
        tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in self?.onFrame(frame) }
        })
        tokens.append(stream.photoDataPublisher.listen { [weak self] photo in
            Task { @MainActor in self?.onPhoto(photo) }
        })
        tokens.append(stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in if self?.running == true { self?.status = "stream: \(state)" } }
        })
        tokens.append(stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                self?.status = "error: \(error.localizedDescription)"
                self?.stop()
            }
        })
    }

    private func onFrame(_ frame: VideoFrame) {
        guard running else { return }
        frameCount += 1
        if let image = frame.makeUIImage() {
            self.frame = image
            frameSize = "\(Int(image.size.width))×\(Int(image.size.height))"
        }
        // fps = frames seen in the trailing second.
        let now = Date()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        fps = frameTimes.count
    }

    private func onPhoto(_ photo: PhotoData) {
        guard let start = captureStart else { return }
        lastCaptureLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
        captureStart = nil
        if let image = UIImage(data: photo.data) { frame = image }
    }

    private func waitUntil(_ label: String, _ seconds: Double,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw PoCError.timeout(label) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
#endif
