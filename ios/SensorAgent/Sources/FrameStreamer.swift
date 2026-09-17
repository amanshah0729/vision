#if os(iOS)
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import VideoToolbox

/// Turns the glasses' live HEVC frames into small JPEGs on the bridge, a few per second.
///
/// The consumer is a CV loop or an agent on the bridge, not a human — so this optimises for
/// "the newest frame, cheaply, continuously" rather than smooth video. Every frame off DAT is
/// decoded (HEVC P-frames need their predecessors), but only every `1/fps` seconds is one
/// scaled, encoded and posted, and never while a previous post is still in flight: a slow link
/// drops frames instead of queueing a backlog that would arrive seconds late.
///
/// Budget, measured 2026-09-15 on Bluetooth + cellular: a 1080×1440 still took 1.6 s to
/// upload, so a ~40 KB 480-wide JPEG should go in well under a second — 2–5 fps in practice.
final class FrameStreamer {
    struct Config {
        var fps: Double = 3
        var maxWidth: Int = 480
        var quality: Double = 0.6
        /// Streaming holds the glasses camera on and burns their battery; stop on our own
        /// rather than rely on the bridge remembering to send `camera.stream.stop`.
        var maxSeconds: Double = 600
    }

    private let config: Config
    private let client: BridgeClient
    private let onExpire: @Sendable () -> Void
    /// Called (once per stall) when frames keep arriving but none decode for ~5 s. The owner
    /// restarts the DAT camera stream, which forces a fresh keyframe — the usual cure when a
    /// decoder was (re)built mid-stream and only P-frames have arrived since.
    var onStall: (@Sendable () -> Void)?
    private var lastDecodedAtStats = 0, lastReceivedAtStats = 0, stallReports = 0
    private var handlerErrors: [Int32: Int] = [:]
    private var lastStallAt = Date.distantPast
    private let queue = DispatchQueue(label: "frame-streamer")
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var decoder: VTDecompressionSession?
    private var decoderFormat: CMFormatDescription?
    private var lastPost = Date.distantPast
    private var inFlight = false
    private let started = Date()
    private var stopped = false
    // stats, on `queue`
    private var received = 0, decoded = 0, posted = 0, failed = 0, bytes = 0, postMs = 0
    private var statsTask: Task<Void, Never>?

    init(config: Config, client: BridgeClient, onExpire: @escaping @Sendable () -> Void) {
        self.config = config
        self.client = client
        self.onExpire = onExpire
        PoCLog.write("STREAM: start fps=\(config.fps) maxWidth=\(config.maxWidth) q=\(config.quality) max=\(Int(config.maxSeconds))s")
        statsTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.queue.async { self.logStats() }
            }
        }
    }

    /// Entry point from the DAT listener thread. Cheap; real work hops to `queue`.
    func handle(_ buffer: CMSampleBuffer) {
        queue.async { [self] in
            guard !stopped else { return }
            received += 1
            if Date().timeIntervalSince(started) > config.maxSeconds {
                stopped = true
                PoCLog.write("STREAM: max duration reached, stopping")
                onExpire()
                return
            }
            decode(buffer)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            logStats()
            if let d = decoder { VTDecompressionSessionInvalidate(d) }
            decoder = nil
            decoderFormat = nil
        }
        statsTask?.cancel()
        PoCLog.write("STREAM: stopped")
    }

    // MARK: - decode → scale → jpeg → post (all on `queue`)

    private func decode(_ buffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(buffer) else { return }
        if decoder == nil || decoderFormat == nil
            || !CMFormatDescriptionEqual(desc, otherFormatDescription: decoderFormat) {
            // The glasses restart the encoder around a photo (new parameter sets), so a
            // decoder built for the old format must be rebuilt, not fed.
            if let d = decoder { VTDecompressionSessionInvalidate(d) }
            decoder = nil
            var session: VTDecompressionSession?
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
            let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc,
                                                      decoderSpecification: nil,
                                                      imageBufferAttributes: attrs as CFDictionary,
                                                      outputCallback: nil,
                                                      decompressionSessionOut: &session)
            guard status == noErr, let session else {
                if failed % 100 == 0 { PoCLog.write("STREAM: decoder create failed \(status)") }
                failed += 1
                return
            }
            decoder = session
            decoderFormat = desc
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            PoCLog.write("STREAM: decoder ready \(dims.width)x\(dims.height)")
        }
        guard let decoder else { return }
        // Decide *before* decoding whether this frame will be posted, so the (cheap) decode
        // still happens for every frame but the (costly) encode only at the target rate.
        let due = Date().timeIntervalSince(lastPost) >= 1.0 / config.fps && !inFlight
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: buffer,
                                                       flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.queue.async {
                    self.failed += 1
                    let n = (self.handlerErrors[status] ?? 0) + 1
                    self.handlerErrors[status] = n
                    if n == 1 || n % 200 == 0 { PoCLog.write("STREAM: decode output error \(status) (x\(n))") }
                }
                return
            }
            // Output callback runs on VT's thread; our state lives on `queue`.
            self.queue.async {
                self.decoded += 1
                if due && !self.inFlight { self.post(image) }
            }
        }
        if status != noErr {
            failed += 1
            if failed % 200 == 1 { PoCLog.write("STREAM: decode call error \(status)") }
            // iOS invalidates hardware decoders when the app changes foreground state (seen on
            // hardware: unlock + foreground for 2 s → every frame kVTInvalidSessionErr until
            // restart). Drop the session; the next frame rebuilds it from its format description.
            if status == kVTInvalidSessionErr || failed % 50 == 1 {
                PoCLog.write("STREAM: decode failed \(status) — rebuilding decoder")
            }
            if status == kVTInvalidSessionErr {
                VTDecompressionSessionInvalidate(decoder)
                self.decoder = nil
                decoderFormat = nil
            }
        }
    }

    private func post(_ image: CVImageBuffer) {
        var ciImage = CIImage(cvImageBuffer: image)
        let w = ciImage.extent.width
        if Int(w) > config.maxWidth {
            let s = CGFloat(config.maxWidth) / w
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let opts: [CIImageRepresentationOption: Any] =
            [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): config.quality]
        guard let jpeg = ci.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: opts)
        else { failed += 1; return }
        inFlight = true
        lastPost = Date()
        let t0 = Date()
        Task { [weak self] in
            guard let self else { return }
            var ok = true
            do { try await self.client.postFrame(jpeg) } catch { ok = false }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            self.queue.async {
                self.inFlight = false
                if ok { self.posted += 1; self.bytes += jpeg.count; self.postMs += ms } else { self.failed += 1 }
            }
        }
    }

    private func logStats() {
        let secs = Int(Date().timeIntervalSince(started))
        // Stall: nothing decoded since the last tick — either frames arrive but fail (decoder
        // lost its reference) or none arrive at all (the glasses ended the session; seen on
        // hardware as "Session ended by device"). Ask the owner for a fresh stream. At most
        // once per 10 s and 6 times per stream, so a dead pair cannot spin this forever.
        let quiet = decoded == lastDecodedAtStats
        if !stopped, secs >= 8, quiet, stallReports < 6,
           Date().timeIntervalSince(lastStallAt) >= 10 {
            stallReports += 1
            lastStallAt = Date()
            let arrived = received - lastReceivedAtStats
            PoCLog.write("STREAM: stall #\(stallReports) — \(arrived) frames in, 0 decoded; requesting fresh camera stream")
            onStall?()
        }
        lastReceivedAtStats = received
        lastDecodedAtStats = decoded
        let avgKB = posted > 0 ? bytes / posted / 1024 : 0
        let avgMs = posted > 0 ? postMs / posted : 0
        PoCLog.write("STREAM: t=\(secs)s received=\(received) decoded=\(decoded) posted=\(posted) failed=\(failed) avg=\(avgKB)KB \(avgMs)ms/post inFlight=\(inFlight)")
    }
}
#endif
