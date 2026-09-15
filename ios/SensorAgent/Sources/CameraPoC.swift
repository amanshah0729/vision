#if os(iOS)
import AVFoundation
import CoreMedia
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
    /// Live view sink. Frames off real glasses are compressed HEVC (`.hvc1`, 504×896) and
    /// `VideoFrame.makeUIImage()` returns nil for them, so the feed is rendered by handing the
    /// raw sample buffers to this layer, which decodes in hardware. `CameraPoCView` hosts it.
    var displayLayer = AVSampleBufferDisplayLayer()
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
    /// Writes fps/frame stats to `PoCLog` every 5s while streaming and fires one capture at
    /// the 10s mark, so an unattended run still leaves the numbers in the log.
    private var statsTask: Task<Void, Never>?
    private var enqueued = 0

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
                PoCLog.write("PoCDIAG: ===== Start tapped: mock=\(useMockGlasses) res=\(resolution) fps=\(frameRate) =====")
                if useMockGlasses {
                    GlassesMock.enable()
                    await GlassesMock.awaitReady()
                }
                status = "checking access…"
                try await GlassesCamera.ensureAccess()
                PoCLog.write("PoCDIAG: access ok; registration=\(Wearables.shared.registrationState)")

                status = "starting session…"
                let wearables = Wearables.shared
                let selector = AutoDeviceSelector(wearables: wearables)
                try await waitUntil("device selection", 15) { selector.activeDevice != nil }
                PoCLog.write("PoCDIAG: selected device = \(String(describing: selector.activeDevice))")
                let session = try wearables.createSession(deviceSelector: selector)
                self.session = session
                // Session-level state + error, so a stalled/rejected session shows its reason.
                tokens.append(session.statePublisher.listen { state in
                    PoCLog.write("PoCDIAG: session state = \(state)")
                })
                tokens.append(session.errorPublisher.listen { error in
                    PoCLog.write("PoCDIAG: session ERROR = \(error) — \(error.localizedDescription)")
                })
                try session.start()
                // 30s, matching GlassesCamera: Bluetooth session setup to the glasses is slow
                // and variable — a 10s ceiling times out before the handshake finishes.
                try await waitUntil("session start", 30) { session.state == .started }
                PoCLog.write("PoCDIAG: session .started")

                status = "starting stream…"
                // `.hvc1` (compressed), matching Meta's streaming sample: the video-frame
                // publisher delivers on this codec, and `VideoFrame.makeUIImage()` decodes it.
                // (`.raw` reaches `.streaming` and serves photos but yields no video frames.)
                guard let camera = try session.addCamera(config: StreamConfiguration(
                    videoCodec: .hvc1, resolution: resolution, frameRate: frameRate)) else {
                    throw PoCError.noCamera
                }
                self.camera = camera
                PoCLog.write("PoCDIAG: camera added, config res=\(resolution) fps=\(frameRate)")
                // The mock only pumps video frames once a camera exists; re-apply the feed now.
                if useMockGlasses { GlassesMock.reapplyFeed() }
                let stream = camera.stream
                attachListeners(to: stream)
                stream.start()
                try await waitUntil("stream start", 30) { stream.state == .streaming }
                reachedStreaming = true
                PoCLog.write("PoCDIAG: reached .streaming")
                status = "streaming"
                startStatsLog()
            } catch {
                PoCLog.write("PoCDIAG: start FAILED = \(error) — \(error.localizedDescription)")
                status = "failed: \(error.localizedDescription)"
                stop()
            }
        }
    }

    private func startStatsLog() {
        statsTask?.cancel()
        statsTask = Task { @MainActor [weak self] in
            var seconds = 0
            while let self, self.running, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                seconds += 5
                let capture = self.lastCaptureLatencyMs.map { "\($0)ms" } ?? "-"
                let r = self.displayLayer.sampleBufferRenderer
                PoCLog.write("PoCDIAG: stats t=\(seconds)s fps=\(self.fps) frames=\(self.frameCount) "
                             + "size=\(self.frameSize) capture=\(capture) status=\(self.status) "
                             + "enqueued=\(self.enqueued) renderer=\(r.status.rawValue) ready=\(r.isReadyForMoreMediaData) "
                             + "layer=\(Int(self.displayLayer.bounds.width))x\(Int(self.displayLayer.bounds.height))")
                if seconds == 10 { self.measureCaptureLatency() }
            }
        }
    }

    func stop() {
        statsTask?.cancel()
        statsTask = nil
        displayLayer.sampleBufferRenderer.flush()
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
            Task { @MainActor in
                if self?.frameCount == 0 { PoCLog.write("PoCDIAG: first video frame arrived") }
                self?.onFrame(frame)
            }
        })
        tokens.append(stream.photoDataPublisher.listen { [weak self] photo in
            Task { @MainActor in self?.onPhoto(photo) }
        })
        tokens.append(stream.statePublisher.listen { [weak self] state in
            PoCLog.write("PoCDIAG: stream state = \(state)")
            Task { @MainActor in if self?.running == true { self?.status = "stream: \(state)" } }
        })
        tokens.append(stream.errorPublisher.listen { [weak self] error in
            PoCLog.write("PoCDIAG: stream ERROR = \(error) — \(error.localizedDescription)")
            Task { @MainActor in
                self?.status = "error: \(error.localizedDescription)"
                self?.stop()
            }
        })
    }

    private func onFrame(_ frame: VideoFrame) {
        guard running else { return }
        frameCount += 1
        // On real glasses over `.hvc1` the buffer is compressed HEVC, and `makeUIImage()` returns
        // nil for it (seen on hardware 2026-09-14: 30 fps of frames, zero images). Read the
        // dimensions and codec off the format description instead so the HUD is still honest.
        if let desc = CMSampleBufferGetFormatDescription(frame.sampleBuffer) {
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let codec = CMFormatDescriptionGetMediaSubType(desc)
            let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xff) }, encoding: .ascii) ?? "?"
            frameSize = "\(dims.width)×\(dims.height) \(fourcc)"
            if frameCount == 1 { PoCLog.write("PoCDIAG: frame format \(frameSize) decodable=\(frame.makeUIImage() != nil)") }
        }
        if let image = frame.makeUIImage() {
            self.frame = image
        } else {
            enqueueForDisplay(frame.sampleBuffer)
        }
        // fps = frames seen in the trailing second.
        let now = Date()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        fps = frameTimes.count
    }

    /// Push a compressed frame to the display layer. Marked display-immediately because the
    /// buffers carry the glasses' clock, not the phone's, and we want live, not scheduled.
    private func enqueueForDisplay(_ buffer: CMSampleBuffer) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            PoCLog.write("PoCDIAG: display layer failed: \(String(describing: renderer.error)) — flushing")
            renderer.flush()
        }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(buffer); enqueued += 1 }
    }

    private func onPhoto(_ photo: PhotoData) {
        guard let start = captureStart else { return }
        lastCaptureLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
        PoCLog.write("PoCDIAG: photo delivered bytes=\(photo.data.count) latency=\(lastCaptureLatencyMs ?? -1)ms")
        captureStart = nil
        // Keep the last still on disk next to poc.log so an unattended run's picture can be
        // pulled off the device and looked at — the only real proof the glasses saw something.
        let url = PoCLog.url.deletingLastPathComponent().appendingPathComponent("last-photo.jpg")
        try? photo.data.write(to: url)
        if let image = UIImage(data: photo.data) {
            frame = image
            PoCLog.write("PoCDIAG: photo decoded \(Int(image.size.width))×\(Int(image.size.height)) saved=\(url.lastPathComponent)")
        }
        // On hardware the live view froze right after a capture even though frames kept
        // arriving and being enqueued (run 7: 30 fps, renderer "rendering"). The glasses
        // restart the video encoder around a photo, so drop whatever the decoder is holding
        // and let it resync on the next keyframe.
        displayLayer.sampleBufferRenderer.flush()
        PoCLog.write("PoCDIAG: renderer flushed after photo")
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
