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
        }
    }
}
#endif
