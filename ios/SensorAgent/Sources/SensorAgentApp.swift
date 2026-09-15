#if os(iOS)
import MWDATCore
import SwiftUI

@main
struct SensorAgentApp: App {
    /// DAT must be configured once, here, at launch. Configuring later — lazily on the first
    /// capture, or from a test — throws `internalError` and leaves `Wearables.shared` trapping.
    /// This mirrors Meta's sample, which calls `Wearables.configure()` in its `@main` init.
    init() {
        DAT.configureOnce()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Meta AI bounces the user back here through the `sensoragent://` scheme
                // after they approve registration. Without this hop the approval succeeds
                // on Meta's side and the app never finds out, so it sits in `.registering`
                // forever.
                .onOpenURL { url in
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
        }
    }
}

/// Deliberately plain. This app is a headless-ish daemon with a switch; the interface
/// that matters is the one on the glasses.
struct ContentView: View {
    @StateObject private var agent = AgentController()
    /// `-autoStartCameraPoC` on the command line pushes the Camera PoC and starts the stream
    /// with no taps, so a hardware run can be driven from the Mac:
    /// `ios/SensorAgent/device.sh run` (which wraps `xcrun devicectl device process launch … -- -autoStartCameraPoC`)
    /// then `device.sh log`. Exists because nobody is guaranteed to be holding the phone.
    @State private var autoPoC = CommandLine.arguments.contains("-autoStartCameraPoC")
    /// Connect on launch when `-autoStartAgent` is passed, or whenever a bridge URL and token
    /// are already saved. iOS will eventually terminate the agent (memory pressure, a reboot,
    /// a swipe-up), and with the phone locked nothing can relaunch it — so recovery has to be
    /// a single tap on the icon with no typing, not a form.
    private let autoAgent = CommandLine.arguments.contains("-autoStartAgent")
        || (!(UserDefaults.standard.string(forKey: "baseURL") ?? "").isEmpty
            && !(UserDefaults.standard.string(forKey: "token") ?? "").isEmpty)

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge") {
                    TextField("https://glasses.example.com", text: $agent.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("token", text: $agent.token)
                }
                Section("Status") {
                    LabeledContent("State", value: agent.status)
                    if !agent.lastTranscript.isEmpty {
                        LabeledContent("Heard", value: agent.lastTranscript)
                    }
                }
                // A stand-in for hardware, not a shortcut around it. Locked while running so
                // the caps a session advertised cannot change out from under the bridge.
                Section("Debug") {
                    Toggle("Mock glasses (no hardware)", isOn: $agent.useMockGlasses)
                        .disabled(agent.running)
                    if agent.useMockGlasses {
                        Text("Captures return a frame stamped MOCK and the session reports as "
                             + "a stand-in, never the real glasses.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // Standalone capture: no bridge, no command loop. The first real capture
                    // triggers the Meta AI registration + camera approvals.
                    Button("Capture now") { agent.captureNow() }
                        .frame(maxWidth: .infinity)
                    if let image = agent.lastImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 300)
                    }
                }
                Section("Proof of concept") {
                    NavigationLink("Camera PoC — live feed + latency") {
                        CameraPoCView()
                    }
                    NavigationLink("Mic PoC — glasses mic (Bluetooth)") {
                        MicPoCView()
                    }
                }
                Section {
                    Button(agent.running ? "Stop" : "Start") {
                        agent.running ? agent.stop() : agent.start()
                    }
                    .frame(maxWidth: .infinity)
                }
                Section {
                    Text("Keep this open with the screen on for the first test. "
                         + "Background audio is enabled, so dictation survives a lock, "
                         + "but iOS will still suspend the app eventually.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sensor Agent")
            .navigationDestination(isPresented: $autoPoC) { CameraPoCView(autoStart: true) }
            .onAppear { if autoAgent && !agent.running { agent.start() } }
        }
    }
}
#endif
