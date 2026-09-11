import XCTest
@testable import SensorAgent

/// The first thing in this repo that exercises `GlassesCamera` end to end. It stands the mock
/// glasses up and drives the real DAT path — `ensureAccess` → session → stream → `capturePhoto`
/// — asserting an actual JPEG comes back. Until this ran, "the camera path works" was a claim
/// about compilation; this makes it a claim about behaviour, with no hardware and no Meta
/// account. See `../Sources/GlassesMock.swift`.
final class GlassesMockCaptureTests: XCTestCase {
    @MainActor
    func testMockGlassesCaptureProducesJPEG() async throws {
        GlassesMock.enable()
        await GlassesMock.awaitReady()

        // With the mock registered and camera-granted, these are the same calls the real
        // `camera.still` command runs — no branch for the mock in the capture path itself.
        try await GlassesCamera.ensureAccess()
        let camera = GlassesCamera()
        defer { camera.stop() }
        let jpeg = try await camera.capture()

        XCTAssertGreaterThan(jpeg.count, 0, "capture returned no bytes")
        // JPEG SOI marker — proves it is an image, not an empty or error payload.
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "not a JPEG")
    }
}
