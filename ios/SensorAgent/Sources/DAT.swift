#if os(iOS)
import Foundation
import MWDATCore

/// One-time DAT bring-up. `Wearables.shared` traps with "Call `configure()` before attempting
/// to access Wearables!" until `Wearables.configure()` has run once, so every entry point that
/// touches DAT funnels through here first. `configure()` throws `.alreadyConfigured` on a
/// repeat, which the guard avoids.
///
/// This was found by running, not reading: the app compiled without it and would have trapped
/// on the first real `camera.still`. `GlassesMockCaptureTests` exercises the path that catches
/// it.
///
/// **It must run at launch.** `configure()` only succeeds the first time it is called during
/// app startup; called later — lazily on first capture, or from a test method — it throws
/// `.internalError` and leaves `Wearables.shared` trapping. So `SensorAgentApp.init()` calls
/// this, exactly as Meta's own sample configures in `@main`. Everything else calls it too, but
/// only as a guard that finds the work already done.
@MainActor
enum DAT {
    private static var configured = false

    static func configureOnce() {
        guard !configured else { return }
        configured = true
        do {
            try Wearables.configure()
        } catch {
            // Matches Meta's sample, which logs and continues: on a real device without the
            // Meta AI hop this can fail, and there is nothing actionable to do here.
            NSLog("DAT: Wearables.configure() failed: \(error)")
        }
    }
}
#endif
