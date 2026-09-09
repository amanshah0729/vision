#if os(iOS)
import SwiftUI

@main
struct SensorAgentApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
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
