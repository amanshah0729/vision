#if os(iOS)
import AVFoundation
import MWDATCamera
import SwiftUI

/// The Camera PoC screen: live glasses feed with an fps/latency HUD and the knobs (resolution,
/// frame rate) that move those numbers. Point it at real glasses to see how bad the link is;
/// on the mock it just proves the pipeline draws frames.
struct CameraPoCView: View {
    @StateObject private var poc = CameraPoC()
    /// Start streaming as soon as the screen appears (see `ContentView.autoPoC`).
    var autoStart = false

    var body: some View {
        Form {
            Section {
                ZStack {
                    Color.black
                    // Hardware-decoded live feed (HEVC off real glasses). Sits under the
                    // still, so a captured photo briefly replaces the feed when it lands.
                    SampleBufferView(layer: poc.displayLayer, onLayer: { poc.displayLayer = $0 })
                    if let frame = poc.frame {
                        Image(uiImage: frame).resizable().scaledToFit()
                    } else if poc.frameCount == 0 {
                        Text(poc.running ? "waiting for frames…" : "not streaming")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
            }

            Section("Live") {
                LabeledContent("Status", value: poc.status)
                LabeledContent("FPS", value: "\(poc.fps)")
                LabeledContent("Frames", value: "\(poc.frameCount)")
                LabeledContent("Frame size", value: poc.frameSize)
                LabeledContent("Capture round-trip",
                               value: poc.lastCaptureLatencyMs.map { "\($0) ms" } ?? "—")
            }

            Section("Config") {
                Toggle("Mock glasses (no hardware)", isOn: $poc.useMockGlasses)
                    .disabled(poc.running)
                Picker("Resolution", selection: $poc.resolution) {
                    ForEach(StreamingResolution.allCases, id: \.self) { res in
                        Text(name(res)).tag(res)
                    }
                }
                .disabled(poc.running)
                Stepper("Frame rate: \(poc.frameRate)", value: $poc.frameRate, in: 5...30, step: 5)
                    .disabled(poc.running)
            }

            Section {
                Button(poc.running ? "Stop stream" : "Start stream") {
                    poc.running ? poc.stop() : poc.start()
                }
                .frame(maxWidth: .infinity)
                Button("Measure capture latency") { poc.measureCaptureLatency() }
                    .frame(maxWidth: .infinity)
                    .disabled(!poc.running)
            }

            Section {
                Text("FPS and latency are only meaningful on real glasses. Requesting a lower "
                     + "resolution / frame rate is what DAT falls back to when the link is "
                     + "starved, so try each and watch the numbers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Camera PoC")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if autoStart && !poc.running { poc.start() } }
        .onDisappear { poc.stop() }
    }

    /// Hosts an `AVSampleBufferDisplayLayer` in SwiftUI. Plain UIKit because SwiftUI has no
    /// sample-buffer sink of its own. The layer is the view's *backing* layer (`layerClass`)
    /// rather than a sublayer, so it always has the view's bounds — a sublayer sized in
    /// `updateUIView` can be left at zero size if no SwiftUI update lands after layout.
    private struct SampleBufferView: UIViewRepresentable {
        let layer: AVSampleBufferDisplayLayer

        final class HostView: UIView {
            override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        }

        func makeUIView(context: Context) -> UIView {
            let view = HostView()
            view.backgroundColor = .black
            // The PoC owns one layer for its lifetime; the host view adopts it by
            // re-parenting the enqueued frames' sink. `layerClass` makes the view's own
            // layer a display layer, so hand that one back to the PoC instead.
            if let own = view.layer as? AVSampleBufferDisplayLayer {
                own.videoGravity = .resizeAspect
                onLayer(own)
            }
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {}

        var onLayer: (AVSampleBufferDisplayLayer) -> Void = { _ in }
    }

    private func name(_ res: StreamingResolution) -> String {
        switch res {
        case .high:   return "High"
        case .medium: return "Medium"
        case .low:    return "Low"
        @unknown default: return "?"
        }
    }
}
#endif
