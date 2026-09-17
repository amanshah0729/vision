#if os(iOS)
import CoreMedia
import Foundation
import MWDATCamera
import MWDATCore
import MWDATDisplay

/// One JPEG **from the glasses** on demand, for `camera.still`.
///
/// This replaces the AVFoundation `StillCapture` it grew out of. AVFoundation can only ever
/// reach the phone's own cameras — the glasses are not a capture device the OS knows about —
/// so that path was never the thing we wanted. Meta's Device Access Toolkit is the only
/// supported route to the glasses camera.
///
/// DAT has no one-shot photo call. Photos can only be taken while a video stream is live, so
/// the shape is necessarily: session → camera → stream → wait for `.streaming` →
/// `capturePhoto` → wait for the photo publisher. That is several seconds of Bluetooth
/// setup, which is why the session is kept alive between shots and only torn down in
/// `stop()`.
@MainActor
final class GlassesCamera {
    enum Failure: Error, LocalizedError {
        case notRegistered
        case permissionDenied
        case cameraUnavailable
        case captureRejected
        case sessionEnded
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .notRegistered:     return "approve Sensor Agent in the Meta AI app"
            case .permissionDenied:  return "glasses camera denied in the Meta AI app"
            case .cameraUnavailable: return "glasses refused the camera"
            case .captureRejected:   return "glasses refused the shot"
            case .sessionEnded:      return "glasses disconnected"
            case .timedOut(let at):  return "glasses stopped responding (\(at))"
            }
        }
    }

    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []
    /// Resolution for the next stream bring-up. `.medium` is 504×896, `.high` 720×1280. Stills
    /// are 1080×1440 regardless; this only matters to the live frame stream.
    var resolution: StreamingResolution = .medium
    /// Attached to the video publisher *before* `stream.start()`, so the stream's first
    /// keyframe cannot slip past between `start()` and the `.streaming` transition. A decoder
    /// that misses it fails every frame with `kVTVideoDecoderReferenceMissingErr` (-17694)
    /// until the next keyframe — which on this link can be a long time coming.
    private var pendingFrameHandler: (@Sendable (CMSampleBuffer) -> Void)?

    // MARK: - Access

    /// Registration and camera permission both round-trip through the Meta AI app and block
    /// on a human tapping approve, so this can sit for a long time. Call it once up front,
    /// never in the middle of serving a `camera.still`.
    static func ensureAccess() async throws {
        // `Wearables.shared` traps until DAT is configured; this is the real path's bring-up
        // point. In mock mode `GlassesMock.enable()` has already run it, so this is a no-op.
        DAT.configureOnce()
        let wearables = Wearables.shared

        PoCLog.write("PoCDIAG: registrationState=\(wearables.registrationState) devices=\(wearables.devices.count)")
        if wearables.registrationState != .registered {
            do {
                try await wearables.startRegistration()
                PoCLog.write("PoCDIAG: startRegistration returned; state=\(wearables.registrationState)")
            } catch {
                PoCLog.write("PoCDIAG: startRegistration THREW \(error) — \(error.localizedDescription)")
                throw error
            }
            try await awaitRegistration(wearables)
        }

        // The permission check itself needs a *connected* pair: with the glasses known but
        // asleep/out of range it throws "All discovered devices are powered off or
        // disconnected" instantly (seen on hardware 2026-09-14). The link comes up a few
        // seconds after the glasses are unfolded/worn, so wait for it rather than fail.
        try await awaitConnectedDevice(wearables, seconds: 30)

        // `.denied` is not final — the user can still say yes to the prompt, which is why
        // this asks rather than giving up on a negative check.
        if try await wearables.checkPermissionStatus(.camera) != .granted,
           try await wearables.requestPermission(.camera) != .granted {
            throw Failure.permissionDenied
        }
    }

    private static func awaitConnectedDevice(_ wearables: any WearablesInterface,
                                             seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var lastReport = ""
        while Date() < deadline {
            let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
            let report = devices.map { "\($0.nameOrId()) link=\($0.linkState) compat=\($0.compatibility())" }
                .joined(separator: "; ")
            if report != lastReport {
                PoCLog.write("PoCDIAG: devices: \(report.isEmpty ? "none" : report)")
                lastReport = report
            }
            if devices.contains(where: { $0.linkState == .connected }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw Failure.timedOut("waiting for the glasses to connect (unfold and wear them)")
    }

    private static func awaitRegistration(_ wearables: any WearablesInterface) async throws {
        // Meta AI can bounce a registration straight back to `.available` (seen on hardware:
        // `.registering` for ~2 s, then `.available`, no sheet shown). Treating that as "keep
        // waiting" parked the agent forever — and, before commands ran off the poll loop, it
        // stopped polling too. A bounce is a failure; the caller retries with the glasses on.
        var sawRegistering = false
        for await state in wearables.registrationStateStream() {
            PoCLog.write("PoCDIAG: registration stream -> \(state)")
            switch state {
            case .registered: return
            case .unavailable: throw Failure.notRegistered
            case .registering: sawRegistering = true
            case .available: if sawRegistering { throw Failure.notRegistered }
            @unknown default: continue
            }
        }
        throw Failure.notRegistered
    }

    // MARK: - Capture

    func capture() async throws -> Data {
        let stream = try await liveStream()

        // The listener has to be attached *before* asking for the shot: the glasses can
        // answer faster than the next line runs, and a photo delivered with no listener
        // attached is simply dropped.
        let photo = Inbox<Data>()
        let token = stream.photoDataPublisher.listen { photo.deliver($0.data) }
        defer { Task { await token.cancel() } }

        guard stream.capturePhoto(format: .jpeg) else { throw Failure.captureRejected }
        return try await Self.bounded(20, "photo") { await photo.wait() }
    }

    /// Brings the session, camera and stream up if they are not already, and returns a
    /// stream that has actually reached `.streaming`. Idempotent — repeat calls reuse
    /// whatever is already live.
    ///
    /// Fully qualified because `Foundation.Stream` is also in scope and wins the ambiguity.
    private func liveStream() async throws -> MWDATCamera.Stream {
        if let camera, camera.stream.state == .streaming { return camera.stream }

        let session = try await startedSession()

        let camera = try { () -> Camera? in
            // `medium` at 15fps on purpose. Bandwidth over Bluetooth Classic is the binding
            // constraint, and DAT degrades quality to fit — asking for less up front yields
            // a *better* looking still than asking for `.high` and being throttled into it.
            // `.hvc1`, not `.raw`: on hardware `.raw` reaches `.streaming` and serves photos but
            // never delivers video frames, and one session now serves both stills and the live
            // frame stream (`startFrames`). Photos still come back as full 1080×1440 JPEGs.
            try session.addCamera(config: StreamConfiguration(videoCodec: .hvc1,
                                                              resolution: resolution,
                                                              frameRate: 15))
        }()
        guard let camera else { throw Failure.cameraUnavailable }
        self.camera = camera

        let stream = camera.stream
        let live = Inbox<Result<Void, Failure>>()
        let token = stream.statePublisher.listen { state in
            // Logged because on hardware the live stream stalled ~13 s into a run with the
            // phone locked while the same run in the foreground was flawless; the reason is
            // only visible here (DAT pauses the stream) or on the error publisher below.
            PoCLog.write("CAMERA: stream state = \(state)")
            switch state {
            case .streaming: live.deliver(.success(()))
            case .stopped:   live.deliver(.failure(.sessionEnded))
            default:         break
            }
        }
        tokens.append(token)
        tokens.append(stream.errorPublisher.listen { error in
            PoCLog.write("CAMERA: stream ERROR = \(error) — \(error.localizedDescription)")
        })
        tokens.append(camera.statePublisher.listen { state in
            PoCLog.write("CAMERA: camera state = \(state)")
        })

        if let handler = pendingFrameHandler {
            frameToken = stream.videoFramePublisher.listen { frame in handler(frame.sampleBuffer) }
        }
        stream.start()
        try await Self.bounded(30, "stream start") { await live.wait() }.get()
        return stream
    }

    private func startedSession() async throws -> DeviceSession {
        if let session, session.state == .started { return session }

        let wearables = Wearables.shared
        // AutoDeviceSelector rather than a pinned id: the user may have more than one pair
        // linked, and which one is active is Meta AI's call, not ours.
        //
        // A freshly-made selector reports no active device for a beat while it observes what
        // is connected; `createSession` against it in that beat throws `noEligibleDevice`. So
        // warm the *same* selector instance first, then hand it over — the mock exposes this
        // race plainly (the device appears only after powerOn/unfold settles) but it is real on
        // hardware too, where a pair can connect a moment after the app asks.
        let selector = AutoDeviceSelector(wearables: wearables)
        try await Self.bounded(10, "device selection") {
            while selector.activeDevice == nil && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard selector.activeDevice != nil else { throw Failure.sessionEnded }

        // `session.stop()` returns before DAT has actually released the device, and a
        // `createSession` in that window throws "A session already exists for this device"
        // (seen on hardware during a stall restart). Retry briefly rather than fail the command.
        var made: DeviceSession?
        for attempt in 1...6 {
            do { made = try wearables.createSession(deviceSelector: selector); break }
            catch {
                PoCLog.write("CAMERA: createSession attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt == 6 { throw error }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        guard let session = made else { throw Failure.sessionEnded }
        self.session = session

        // Subscribe *before* start() so the `.started` transition can't be missed — the same
        // rule the stream below follows, and one Meta's sample calls out explicitly. The old
        // code iterated `stateStream()` after start(), which dropped the transition and hung.
        let live = Inbox<Result<Void, Failure>>()
        tokens.append(session.errorPublisher.listen { error in
            PoCLog.write("CAMERA: session ERROR = \(error) — \(error.localizedDescription)")
        })
        let token = session.statePublisher.listen { state in
            PoCLog.write("CAMERA: session state = \(state)")
            switch state {
            case .started: live.deliver(.success(()))
            case .stopped: live.deliver(.failure(.sessionEnded))
            default:       break
            }
        }
        tokens.append(token)

        try session.start()
        if session.state == .started { live.deliver(.success(())) } // already-started race
        try await Self.bounded(30, "session start") { await live.wait() }.get()
        return session
    }

    // MARK: - Display

    /// What to draw on the glasses. Plain data so the bridge command maps onto it directly.
    struct DisplayContent: Sendable, Equatable {
        var title: String?
        var big: String?
        var lines: [String] = []
    }

    private var display: Display?
    private var lastContent: DisplayContent?

    /// Draw on the glasses' display from the phone, in the **same** DeviceSession as the
    /// camera. This exists because a DAT camera session takes the display from the glasses
    /// browser — the web app is black for as long as the camera runs — so a page cannot show
    /// anything during a stream. Content is remembered and re-sent when the session is rebuilt
    /// (every fresh stream start tears it down).
    func show(_ content: DisplayContent) async throws {
        lastContent = content
        let session = try await startedSession()
        if display == nil || display?.state == .stopped {
            let d = try session.addDisplay()
            display = d
            tokens.append(d.statePublisher.listen { state in
                PoCLog.write("DISPLAY: state = \(state)")
            })
            d.start()
            let deadline = Date().addingTimeInterval(10)
            while d.state != .started && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            PoCLog.write("DISPLAY: after start, state = \(d.state)")
        }
        guard let display else { return }
        try await display.send(FlexBox(direction: .column, spacing: 8, alignment: .center,
                                       crossAlignment: .center, padding: EdgeInsets(all: 16)) {
            if let title = content.title, !title.isEmpty { Text(title, style: .meta, color: .secondary) }
            if let big = content.big, !big.isEmpty { Text(big, style: .heading) }
            for line in content.lines { Text(line, style: .body) }
        })
    }

    func clearDisplay() async {
        lastContent = nil
        try? await display?.clearDisplay()
    }

    // MARK: - Live frames

    private var frameToken: (any AnyListenerToken)?

    /// Tap the live video: `handler` gets every compressed HEVC sample buffer off the glasses
    /// (~15–30/s). Brings the session/stream up if needed. The caller decodes and throttles;
    /// this hands over raw buffers because skipping P-frames before the decoder breaks it.
    ///
    /// `fresh` tears the DAT session down first and brings up a new stream, so the consumer's
    /// decoder starts on a keyframe. Attaching a new decoder to a stream that is already
    /// mid-flight (the session is kept warm between stills) is what stalled 2 of 5 runs on
    /// hardware. Costs ~3 s; always use it for a new stream, never for a still.
    func startFrames(fresh: Bool = true,
                     resolution: StreamingResolution? = nil,
                     _ handler: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        if let resolution, resolution != self.resolution { self.resolution = resolution }
        if fresh { await shutdown() }
        stopFrames()
        pendingFrameHandler = handler
        defer { pendingFrameHandler = nil }
        if let camera, camera.stream.state == .streaming {
            frameToken = camera.stream.videoFramePublisher.listen { frame in handler(frame.sampleBuffer) }
            return
        }
        _ = try await liveStream()
        // The session was rebuilt, so the display went with it — put the content back.
        if let lastContent {
            do { try await show(lastContent) }
            catch { PoCLog.write("DISPLAY: re-show after stream start FAILED \(error) — \(error.localizedDescription)") }
        }
    }

    /// `stop()`, then wait until DAT reports the session fully `.stopped` (≤5 s).
    func shutdown() async {
        let old = session
        stop()
        guard let old else { return }
        let deadline = Date().addingTimeInterval(5)
        while old.state != .stopped && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func stopFrames() {
        if let t = frameToken { Task { await t.cancel() } }
        frameToken = nil
    }

    func stop() {
        stopFrames()
        let tokens = self.tokens
        self.tokens = []
        Task { for token in tokens { await token.cancel() } }
        camera?.stop()
        display?.stop()
        session?.stop()
        camera = nil
        display = nil
        session = nil
    }

    // MARK: - Plumbing

    /// The glasses can simply never answer — hinges closed, out of range, thermal cutoff,
    /// battery. Every wait is bounded so `camera.still` fails loudly instead of wedging the
    /// agent's command loop forever.
    private static func bounded<T: Sendable>(
        _ seconds: Double,
        _ label: String,
        _ work: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.timedOut(label)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timedOut(label) }
            return first
        }
    }
}

/// Bridges DAT's callback `Announcer`s to `async`. Two things make this less trivial than a
/// bare continuation: announcers fire repeatedly but a continuation may only be resumed
/// once, and a value can arrive before anyone is waiting. Holding the first value covers
/// both — later deliveries are dropped, and an early one is handed straight to `wait()`.
private final class Inbox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var waiter: CheckedContinuation<T, Never>?

    func deliver(_ incoming: T) {
        lock.lock()
        guard value == nil else { return lock.unlock() }
        value = incoming
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: incoming)
    }

    func wait() async -> T {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}
#endif
