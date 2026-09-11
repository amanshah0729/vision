#if os(iOS)
import AVFoundation
import Foundation
import MWDATCore
import MWDATMockDevice
import UIKit

/// Stands a **fake** pair of glasses up inside DAT so the real `GlassesCamera` code path —
/// registration, permission, session, stream, `capturePhoto` — runs with no hardware and no
/// Meta account. Per `ios/README.md` this is the only way to exercise `GlassesCamera` short
/// of Aman's phone, so it is the gate that lets the app be developed at all before access is
/// granted.
///
/// It is deliberately loud about being fake. The mock advertises itself as a stand-in (see
/// `AgentController`, which drops the `glasses-` caps in mock mode so the web app marks the
/// session per PROTOCOL.md), and both the live feed and every captured frame are a generated
/// image stamped "MOCK GLASSES" so a stand-in shot can never be mistaken for something the
/// glasses actually saw. `../CLAUDE.md` exists because that mistake was made once already.
@MainActor
enum GlassesMock {
    /// The paired mock, held so it is not deallocated and so `disable()` can unpair it.
    private(set) static var glasses: (any MockGlasses)?
    /// The generated feed, kept so it can be re-applied once a camera exists (see `reapplyFeed`).
    private(set) static var feedURL: URL?

    /// Idempotent. Enables `MockDeviceKit`, pairs one mock Ray-Ban, powers it on and dons it so
    /// an `AutoDeviceSelector` session finds an eligible device, gives it a video feed (without
    /// one the stream starts and immediately stops, never reaching `.streaming`) and loads a
    /// stamped placeholder as the still `capturePhoto` returns.
    ///
    /// `initiallyRegistered`/`initialPermissionsGranted` are on so `GlassesCamera.ensureAccess`
    /// short-circuits the two Meta AI round-trips that only a human can complete — the whole
    /// point of the mock is to run the path those gates otherwise protect.
    static func enable() {
        // DAT is configured at launch (`SensorAgentApp.init`); this guards the case where the
        // mock is driven without that, e.g. a test that forgets the host. `Wearables.shared`
        // traps until it has run, and `MockDeviceKit.enable()` reaches into `shared`.
        DAT.configureOnce()

        let kit = MockDeviceKit.shared
        if !kit.isEnabled {
            kit.enable(config: MockDeviceKitConfig(initiallyRegistered: true,
                                                   initialPermissionsGranted: true))
        }
        guard glasses == nil else { return }

        // 0.9.0's GlassesModel has no `rayBanDisplay` case yet; `rayBanMeta` is the
        // camera-capable Ray-Ban stand-in. The model only shapes the mock's capability
        // profile — the capture path under test is identical.
        guard let paired = try? kit.pairGlasses(model: .rayBanMeta) else { return }
        // powerOn + unfold is the lifecycle Meta's own tests drive to make a mock eligible;
        // don() marks it worn. It takes the SDK a moment after this to surface the device to
        // `Wearables` — see `awaitReady()`.
        paired.powerOn()
        paired.unfold()
        paired.don()

        let image = placeholderImage()
        // The live feed keeps the stream in `.streaming`; the captured image is what a photo
        // returns. Both are the same stamped frame.
        if let feed = placeholderFeedURL(image) {
            feedURL = feed
            paired.services.camera.setCameraFeed(fileURL: feed)
        }
        paired.services.camera.setCapturedImage(fileURL: placeholderStillURL(image))
        glasses = paired
    }

    /// Re-applies the generated feed to the paired mock's camera. Setting the feed once at pair
    /// time keeps the stream in `.streaming`, but the mock only pumps *video frames* once a
    /// camera exists on the session — so the live-view path must re-apply it after `addCamera`.
    static func reapplyFeed() {
        guard let glasses, let feedURL else { return }
        glasses.services.camera.setCameraFeed(fileURL: feedURL)
    }

    /// Blocks until DAT would actually pick the mock for a session, so a capture that follows
    /// does not race `enable()` and fail `noEligibleDevice`. A device can be listed in
    /// `Wearables.shared.devices` a beat before the `AutoDeviceSelector` marks it active, and
    /// it is the selector's choice that `createSession` needs — so this waits on exactly that.
    /// Meta's tests use a flat 1s sleep; polling returns as soon as the device is selectable
    /// and still gives up after `timeout` if it never becomes so.
    static func awaitReady(timeout: TimeInterval = 5) async {
        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        let deadline = Date().addingTimeInterval(timeout)
        while selector.activeDevice == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func disable() {
        if let glasses { MockDeviceKit.shared.unpairDevice(glasses) }
        glasses = nil
        MockDeviceKit.shared.disable()
    }

    // MARK: - Generated media

    /// The stamped frame reused for both the feed and the still. Drawn once per `enable()`.
    private static func placeholderImage() -> UIImage {
        let size = CGSize(width: 800, height: 800)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let text = "MOCK GLASSES\nno hardware" as NSString
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 72),
                .foregroundColor: UIColor(red: 1.0, green: 0.42, blue: 0.32, alpha: 1),
                .paragraphStyle: paragraph,
            ]
            let bounds = text.boundingRect(with: size, options: .usesLineFragmentOrigin,
                                           attributes: attrs, context: nil)
            text.draw(in: CGRect(x: 0, y: (size.height - bounds.height) / 2,
                                 width: size.width, height: bounds.height),
                      withAttributes: attrs)
        }
    }

    /// The JPEG a mock `capturePhoto` returns. `setCapturedImage` takes a file URL, so it is
    /// written to a temp file; overwritten each `enable()` so nothing stale lingers.
    private static func placeholderStillURL(_ image: UIImage) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mock-still.jpg")
        if let jpeg = image.jpegData(compressionQuality: 0.9) {
            try? jpeg.write(to: url)
        }
        return url
    }

    /// A few seconds of the stamped frame as an H.264 MP4, used as the mock's live camera feed.
    /// Generated rather than bundled so there is no binary asset to track. Returns `nil` if
    /// encoding fails, in which case the stream simply won't reach `.streaming` — a loud failure
    /// beats a silently-missing feed.
    private static func placeholderFeedURL(_ image: UIImage) -> URL? {
        guard let cg = image.cgImage else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mock-feed.mp4")
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 15
        let frames = Int(fps) * 3 // three seconds of actual motion; the mock loops it
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
            // Distinct frames — a bar sweeping across the stamp — so the encoder produces a
            // normal video with motion. A clip of one identical repeated frame reaches
            // `.streaming` but the mock serves no frames off it.
            guard let buffer = pixelBuffer(from: cg, size: size, sweep: CGFloat(i) / CGFloat(frames))
            else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()

        // finishWriting's completion runs on the SDK's own queue, not main, so waiting on a
        // semaphore here does not deadlock the main actor. Encoding a couple of seconds of one
        // repeated frame is quick.
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed ? url : nil
    }

    /// One `CVPixelBuffer` for frame `sweep` (0…1): the stamped image plus a vertical bar at
    /// that horizontal position, so consecutive frames differ and the encoder emits real motion.
    private static func pixelBuffer(from cg: CGImage, size: CGSize, sweep: CGFloat) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB, attrs, &pb)
        guard let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        ctx.setFillColor(UIColor(white: 1, alpha: 0.5).cgColor)
        ctx.fill(CGRect(x: sweep * size.width, y: 0, width: 48, height: size.height))
        return buffer
    }
}
#endif
