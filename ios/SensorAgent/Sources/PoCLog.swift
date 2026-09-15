#if os(iOS)
import Foundation

/// Appends diagnostics to `Documents/poc.log` so they can be pulled off the device with
/// `xcrun devicectl device copy from` — this app's `print`/`NSLog` output does not reach the
/// CLI console tools, so a file in the container is the only reliable way to read what DAT
/// actually reported on real hardware.
enum PoCLog {
    static let url: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("poc.log")

    static func write(_ message: String) {
        print(message) // still handy under a debugger
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
