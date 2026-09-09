#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation

/// One JPEG on demand, for `camera.still`. The capture session carries no audio input
/// on purpose — Dictation owns the audio session, and adding a second claimant is how
/// you get a session that silently refuses to start.
final class StillCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var pending: ((Data?) -> Void)?
    private let queue = DispatchQueue(label: "still.capture")

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .video) { c.resume(returning: $0) }
        }
    }

    func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    /// Bringing the session up takes a moment, so it is started on first use and left
    /// running. Callers should `stop()` when the agent goes idle to release the camera.
    func capture(_ completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            if !session.isRunning { session.startRunning() }
            pending = completion
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        pending?(data)
        pending = nil
    }
}
#endif
