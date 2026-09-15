#if os(iOS)
import Foundation
import MWDATCamera
import MWDATCore

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
        for await state in wearables.registrationStateStream() {
            PoCLog.write("PoCDIAG: registration stream -> \(state)")
            switch state {
            case .registered: return
            case .unavailable: throw Failure.notRegistered
            case .available, .registering: continue
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
            try session.addCamera(config: StreamConfiguration(videoCodec: .raw,
                                                              resolution: .medium,
                                                              frameRate: 15))
        }()
        guard let camera else { throw Failure.cameraUnavailable }
        self.camera = camera

        let stream = camera.stream
        let live = Inbox<Result<Void, Failure>>()
        let token = stream.statePublisher.listen { state in
            switch state {
            case .streaming: live.deliver(.success(()))
            case .stopped:   live.deliver(.failure(.sessionEnded))
            default:         break
            }
        }
        tokens.append(token)

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

        let session = try wearables.createSession(deviceSelector: selector)
        self.session = session

        // Subscribe *before* start() so the `.started` transition can't be missed — the same
        // rule the stream below follows, and one Meta's sample calls out explicitly. The old
        // code iterated `stateStream()` after start(), which dropped the transition and hung.
        let live = Inbox<Result<Void, Failure>>()
        let token = session.statePublisher.listen { state in
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

    func stop() {
        let tokens = self.tokens
        self.tokens = []
        Task { for token in tokens { await token.cancel() } }
        camera?.stop()
        session?.stop()
        camera = nil
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
