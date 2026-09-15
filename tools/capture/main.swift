// capture — grab a single JPEG still from a Mac-visible camera.
//
// Why this exists: the glasses browser has no camera (probed on hardware), and the
// iOS SensorAgent that was meant to supply one cannot be built without full Xcode.
// But AVFoundation compiles fine against Command Line Tools, and Continuity Camera
// exposes the iPhone as an ordinary Mac capture device. So an agent can see *today*,
// with no Xcode, no developer account, and no provisioning.
//
//   swiftc -O -o bin/capture main.swift
//   ./bin/capture --list
//   ./bin/capture --out /tmp/shot.jpg
//   ./bin/capture --device "My iPhone" --out /tmp/phone.jpg
//
// Exit codes are distinct so a caller can tell "denied" from "no camera" from
// "capture failed" without scraping stderr.

import AVFoundation
import CoreImage
import CoreMedia
import Foundation

let E_USAGE: Int32 = 2, E_DENIED: Int32 = 3, E_NODEV: Int32 = 4, E_CAPTURE: Int32 = 5

func die(_ code: Int32, _ msg: String) -> Never {
    FileHandle.standardError.write(Data(("capture: " + msg + "\n").utf8))
    exit(code)
}

// .continuityCamera rather than .external: the latter is deprecated for iPhone
// cameras and makes AVFoundation print a warning on every run.
func discover() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) { types.append(.continuityCamera) }
    types.append(.external)
    return AVCaptureDevice.DiscoverySession(
        deviceTypes: types, mediaType: .video, position: .unspecified).devices
}

// Deliberately AVCaptureVideoDataOutput rather than AVCapturePhotoOutput. The photo
// path needs KVO machinery the ObjC runtime cannot synthesise in a bare CLI — it fails
// with "NSKVONotifying_AVCapturePhotoOutput not linked into application" and then simply
// never fires the delegate. Pulling raw frames sidesteps that entirely.
final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let sem = DispatchSemaphore(value: 0)
    private let ctx = CIContext()
    private let warmupFrames: Int
    private var seen = 0
    private(set) var jpeg: Data?

    init(warmupFrames: Int) { self.warmupFrames = warmupFrames }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        seen += 1
        // Discard early frames instead of sleeping: a just-woken sensor is still
        // auto-exposing, and the first frames come back black or blown out.
        guard jpeg == nil, seen > warmupFrames,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let data = ctx.jpegRepresentation(of: image, colorSpace: space, options: [:])
        else { return }
        jpeg = data
        sem.signal()
    }
}

// ---- args ----
var outPath: String?
var wanted: String?
var listOnly = false
var warmupMs = 700          // see below; a cold sensor returns a black frame

var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    switch argv[i] {
    case "--list": listOnly = true
    case "--out":    i += 1; outPath = i < argv.count ? argv[i] : nil
    case "--device": i += 1; wanted  = i < argv.count ? argv[i] : nil
    case "--warmup": i += 1; warmupMs = Int(i < argv.count ? argv[i] : "") ?? warmupMs
    case "-h", "--help":
        print("usage: capture [--list] [--device <name substring>] [--out <path>] [--warmup <ms>]")
        print("       writes JPEG to --out, or to stdout if omitted")
        exit(0)
    default: die(E_USAGE, "unknown argument \(argv[i])")
    }
    i += 1
}

let devices = discover()

if listOnly {
    if devices.isEmpty { print("no video devices") }
    for d in devices { print("\(d.localizedName)\t\(d.uniqueID)") }
    let st = AVCaptureDevice.authorizationStatus(for: .video)
    let label = [0: "notDetermined", 1: "restricted", 2: "denied", 3: "authorized"][st.rawValue] ?? "?"
    print("authorization: \(label)")
    exit(0)
}

// ---- permission ----
// TCC attributes the prompt to whatever launched us. A capture started from a
// headless/background process with no GUI session can be denied with no visible
// prompt, so say that plainly instead of returning a broken image.
switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized: break
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    AVCaptureDevice.requestAccess(for: .video) { ok = $0; sem.signal() }
    if sem.wait(timeout: .now() + 60) == .timedOut {
        die(E_DENIED, "timed out waiting for camera permission. Run once from a normal terminal window and click Allow.")
    }
    if !ok { die(E_DENIED, "camera permission denied") }
default:
    die(E_DENIED, "camera access denied or restricted. Grant it in System Settings > Privacy & Security > Camera for the app that launches this.")
}

// ---- pick device ----
guard !devices.isEmpty else { die(E_NODEV, "no video capture devices found") }
let device: AVCaptureDevice
if let w = wanted {
    guard let d = devices.first(where: {
        $0.localizedName.localizedCaseInsensitiveContains(w) || $0.uniqueID == w
    }) else {
        die(E_NODEV, "no device matching \"\(w)\". Try --list.")
    }
    device = d
} else {
    device = devices[0]
}

// ---- session ----
let session = AVCaptureSession()
session.beginConfiguration()
session.sessionPreset = .photo
guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
    die(E_CAPTURE, "cannot open \(device.localizedName)")
}
session.addInput(input)

let output = AVCaptureVideoDataOutput()
output.alwaysDiscardsLateVideoFrames = true
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
// Roughly warmupMs at ~30fps, floored so there is always some settling time.
let grabber = FrameGrabber(warmupFrames: max(8, warmupMs * 30 / 1000))
output.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "capture.frames"))
guard session.canAddOutput(output) else { die(E_CAPTURE, "cannot attach video output") }
session.addOutput(output)
session.commitConfiguration()
session.startRunning()

// Continuity Camera can take a few seconds to wake the phone and start streaming,
// so this budget is generous on purpose.
let deadline = DispatchTime.now() + 20
if grabber.sem.wait(timeout: deadline) == .timedOut {
    session.stopRunning()
    die(E_CAPTURE, "timed out waiting for a frame from \(device.localizedName)")
}
session.stopRunning()

guard let jpeg = grabber.jpeg, !jpeg.isEmpty else { die(E_CAPTURE, "camera returned no image data") }

if let p = outPath {
    do { try jpeg.write(to: URL(fileURLWithPath: p)) }
    catch { die(E_CAPTURE, "cannot write \(p): \(error.localizedDescription)") }
    FileHandle.standardError.write(Data("captured \(jpeg.count) bytes from \(device.localizedName) -> \(p)\n".utf8))
} else {
    FileHandle.standardOutput.write(jpeg)
}
