import Foundation

// Exercises the real BridgeClient against a running bridge, with capture faked.
// The iOS app is the same client with AVFoundation and Speech wired in place of
// the stubs below, so if this passes, only the capture layer is unproven.
//
//   swift-sensor <base-url> <token> [seconds]

let args = CommandLine.arguments
guard args.count >= 3, let base = URL(string: args[1]) else {
    FileHandle.standardError.write(Data("usage: swift-sensor <base-url> <token> [seconds]\n".utf8))
    exit(2)
}
let token = args[2]
let seconds = args.count > 3 ? Double(args[3]) ?? 20 : 20

let client = BridgeClient(
    base: base,
    token: token,
    deviceId: "swift-harness-0001",
    name: "Swift harness (Mac)",
    // No glasses- prefixes: this is explicitly a stand-in, and the web app is
    // supposed to show it as one.
    caps: [.mic, .camera]
)

@Sendable func log(_ s: String) { print("[\(Date().formatted(date: .omitted, time: .standard))] \(s)") }

// A minimal JPEG: SOI + APP0 + EOI. Enough to prove the byte path end to end.
@Sendable func fakeJPEG() -> Data {
    var d = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
    d.append(Data(repeating: 0x20, count: 512))
    d.append(Data([0xFF, 0xD9]))
    return d
}

let task = Task {
    do {
        try await client.register()
        log("registered as \(client.deviceId)")
    } catch { log("register FAILED: \(error)") ; exit(1) }

    await client.run { command in
        log("command received: \(command.action) (id \(command.id))")
        do {
            switch command.action {
            case "mic.start":
                try await client.postTranscript("open the ortho", final: false)
                try await client.postTranscript("open the ortho repo", final: true)
                log("  -> pushed partial + final transcript")
            case "mic.stop":
                try await client.postTranscript("", final: true)
                log("  -> pushed final")
            case "camera.still":
                try await client.postStill(fakeJPEG())
                log("  -> pushed still")
            default:
                log("  -> unknown action, ignored")
            }
        } catch { log("  -> action FAILED: \(error)") }
    }
}

Thread.sleep(forTimeInterval: seconds)
task.cancel()
log("harness done")
exit(0)
