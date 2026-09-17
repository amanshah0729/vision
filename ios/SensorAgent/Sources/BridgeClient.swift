import Foundation

/// Client half of `PROTOCOL.md` v1.
///
/// Deliberately Foundation-only: no AVFoundation, no Speech, no SwiftUI. Capture is
/// injected by the host, so this same file drives the iOS app, a macOS test harness,
/// and later a DAT build. Swift and Kotlin share no code — the protocol is the reusable
/// thing, so the part that encodes it must not drag a platform in with it.
public struct BridgeCommand: Decodable, Sendable {
    public let id: String
    public let action: String
    /// Free-form per-action arguments (e.g. `camera.stream.start`'s fps). Foundation-only
    /// JSON, so a tiny value enum rather than `Any`.
    public let args: [String: JSONValue]?

    public func number(_ key: String) -> Double? {
        if case let .number(n)? = args?[key] { return n }
        return nil
    }

    public func string(_ key: String) -> String? {
        if case let .string(s)? = args?[key] { return s }
        return nil
    }

    /// An array of strings; numbers are rendered, anything else dropped.
    public func strings(_ key: String) -> [String] {
        guard case let .array(items)? = args?[key] else { return [] }
        return items.compactMap {
            switch $0 {
            case let .string(s): return s
            case let .number(n): return n == n.rounded() ? String(Int(n)) : String(n)
            default: return nil
            }
        }
    }
}

public indirect enum JSONValue: Decodable, Sendable {
    case number(Double), string(String), bool(Bool), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .null } // objects: unused by any action today
    }
}

public enum BridgeError: Error, CustomStringConvertible {
    case badStatus(Int, String)
    case badURL

    public var description: String {
        switch self {
        case let .badStatus(code, body): return "HTTP \(code): \(body)"
        case .badURL: return "bad base URL"
        }
    }
}

/// What the host can actually do *right now*. `mic`/`camera` are the function;
/// the `glasses-` prefix means the signal originates at the glasses rather than
/// the phone, so the web app can mark a desk stand-in as not the real thing.
public enum Capability: String, Sendable {
    case mic, camera
    case glassesMic = "glasses-mic"
    case glassesCamera = "glasses-camera"
}

public final class BridgeClient: @unchecked Sendable {
    public let deviceId: String
    private let base: URL
    private let token: String
    private let name: String
    private let caps: [String]
    private let session: URLSession

    public init(base: URL, token: String, deviceId: String, name: String, caps: [Capability]) {
        self.base = base
        self.token = token
        self.deviceId = deviceId
        self.name = name
        self.caps = caps.map(\.rawValue)
        let cfg = URLSessionConfiguration.ephemeral
        // The commands endpoint is held for 25s by design. A default 60s timeout
        // would work, but being explicit keeps a future default change from
        // silently turning every long poll into a spurious failure.
        cfg.timeoutIntervalForRequest = 40
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - transport

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         body: Data? = nil, contentType: String? = nil) throws -> URLRequest {
        guard var comps = URLComponents(url: base.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else { throw BridgeError.badURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // Bearer rather than ?k= so the token never lands in a proxy or server log.
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        return req
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw BridgeError.badStatus(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - phone → bridge

    /// Announce presence and capabilities. Doubles as the heartbeat: a device with no
    /// register for 90s is dropped, so `run()` re-posts every 30s.
    public func register() async throws {
        let body = try json(["deviceId": deviceId, "name": name, "caps": caps])
        try await send(request("POST", "api/sensors/register", body: body,
                               contentType: "application/json"))
    }

    /// Push dictation. Partials freely; `final: true` when the recognizer settles.
    public func postTranscript(_ text: String, final: Bool) async throws {
        let body = try json(["deviceId": deviceId, "text": text, "final": final])
        try await send(request("POST", "api/sensors/transcript", body: body,
                               contentType: "application/json"))
    }

    /// Raw JPEG bytes. The bridge caps this at 3 MB and answers 413 rather than
    /// resetting the socket, so a rejection is readable instead of a bare failure.
    public func postStill(_ jpeg: Data) async throws {
        try await send(request("POST", "api/sensors/still",
                               query: [URLQueryItem(name: "deviceId", value: deviceId)],
                               body: jpeg, contentType: "image/jpeg"))
    }

    /// One live-stream frame: a small JPEG. Fire-and-forget quality of service — the bridge
    /// keeps only the newest, so a lost frame costs nothing and a slow one is skipped by
    /// the sender rather than queued.
    public func postFrame(_ jpeg: Data) async throws {
        try await send(request("POST", "api/sensors/frame",
                               query: [URLQueryItem(name: "deviceId", value: deviceId)],
                               body: jpeg, contentType: "image/jpeg"))
    }

    /// Long poll, held up to 25s. Returns as soon as a command is queued, else empty.
    /// Commands are delivered at most once — a dropped connection can lose one, so
    /// every action must be idempotent and user-retriable.
    public func pollCommands() async throws -> [BridgeCommand] {
        struct Response: Decodable { let commands: [BridgeCommand] }
        let data = try await send(request("GET", "api/sensors/commands",
                                          query: [URLQueryItem(name: "deviceId", value: deviceId)]))
        return (try? JSONDecoder().decode(Response.self, from: data))?.commands ?? []
    }

    // MARK: - run loop

    /// Heartbeat and command pump. Runs until the task is cancelled. Network errors are
    /// swallowed and retried rather than thrown: a phone walks in and out of signal, and
    /// the agent must come back on its own without the user reopening the app.
    public func run(handle: @escaping @Sendable (BridgeCommand) async -> Void) async {
        var lastRegister = Date.distantPast
        while !Task.isCancelled {
            do {
                if Date().timeIntervalSince(lastRegister) > 30 {
                    try await register()
                    lastRegister = Date()
                }
                for command in try await pollCommands() {
                    // Detached on purpose: a command can block on a human (registration in
                    // Meta AI, a permission prompt) or run for minutes (a stream). Awaiting it
                    // here stalled polling, the bridge expired the device after 90 s, and every
                    // later command was refused "no matching device" — seen on hardware.
                    Task { await handle(command) }
                }
                // Reconnect immediately: the bridge, not the client, decides how long
                // to hold. Sleeping here would only add latency to the next command.
            } catch {
                if Task.isCancelled { return }
                // Force a re-register on reconnect; the bridge may have expired us.
                lastRegister = .distantPast
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
