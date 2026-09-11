import MWDATCamera
import XCTest
@testable import SensorAgent

/// Verifies the live-stream PoC brings the whole pipeline up — access → device selection →
/// session `.started` → `addCamera` → stream `.streaming` — against the mock.
///
/// It stops at `.streaming` on purpose. The 0.9.0 `MockDeviceKit` reaches that state but does
/// **not** emit synthetic video frames off `setCameraFeed`, so `videoFramePublisher` never
/// fires on the simulator (confirmed: valid 298 KB feed, `.streaming`, zero frames). Frame
/// delivery — `videoFramePublisher` → `makeUIImage` → the published `frame`/`fps` — is
/// therefore only exercised on real glasses, which have an actual sensor. The reception code
/// mirrors Meta's own sample.
final class CameraPoCStreamTests: XCTestCase {
    @MainActor
    func testMockStreamReachesStreaming() async throws {
        let poc = CameraPoC()
        poc.useMockGlasses = true
        poc.resolution = .low
        poc.frameRate = 15
        poc.start()
        defer { poc.stop() }

        let deadline = Date().addingTimeInterval(20)
        while !poc.reachedStreaming && Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        XCTAssertTrue(poc.reachedStreaming,
                      "pipeline never reached .streaming (status: \(poc.status))")
    }
}
