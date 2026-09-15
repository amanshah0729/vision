#if os(iOS)
import AVFoundation
import Foundation

/// Keeps the agent alive while the phone is locked or the app is backgrounded.
///
/// iOS suspends a backgrounded app within seconds unless it is doing something the system
/// recognises, and a suspended agent stops long-polling the bridge — so with the phone in a
/// pocket every command from the glasses just queued (seen 2026-09-15: registered once, then
/// silence until relaunch). The classic answer is a continuous, silent audio session under the
/// `audio` background mode: iOS keeps the process running, network included, indefinitely.
/// Not App Store material; this is a personal build and the glasses are the whole product.
///
/// Dictation owns the audio session while it runs (its `AVAudioEngine` is itself a keepalive),
/// so `AgentController` pauses this around `mic.start`/`mic.stop`.
final class Keepalive {
    private var player: AVAudioPlayer?
    private var interruptionToken: NSObjectProtocol?

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback (not .ambient): ambient is silenced by the ring switch and does not
            // hold the app in the background. mixWithOthers so music keeps playing.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            PoCLog.write("KEEPALIVE: session failed \(error.localizedDescription)")
            return
        }
        if player == nil { player = Self.makeSilentPlayer() }
        player?.play()
        // The session can be interrupted (a call, Siri); resume when it ends or we are
        // silently suspended a moment later.
        if interruptionToken == nil {
            interruptionToken = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.start() }
            }
        }
        PoCLog.write("KEEPALIVE: on")
    }

    func stop() {
        player?.stop()
        if let t = interruptionToken { NotificationCenter.default.removeObserver(t); interruptionToken = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        PoCLog.write("KEEPALIVE: off")
    }

    /// One second of 16-bit silence as a WAV, generated in memory — no asset to track.
    private static func makeSilentPlayer() -> AVAudioPlayer? {
        let rate: UInt32 = 8000, seconds: UInt32 = 1
        let dataLen = rate * seconds * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataLen); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataLen)
        d.append(Data(count: Int(dataLen)))
        guard let p = try? AVAudioPlayer(data: d, fileTypeHint: AVFileType.wav.rawValue) else { return nil }
        p.numberOfLoops = -1
        p.volume = 0
        p.prepareToPlay()
        return p
    }
}
#endif
