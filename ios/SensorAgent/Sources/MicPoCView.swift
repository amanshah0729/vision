#if os(iOS)
import SwiftUI

/// Mic PoC screen: probe the audio inputs, pick phone vs glasses, and watch the live transcript
/// with the active input shown so it's unambiguous which mic is feeding it.
struct MicPoCView: View {
    @StateObject private var mic = MicPoC()

    var body: some View {
        Form {
            Section("Inputs") {
                Button("Probe audio inputs") { mic.probe() }
                    .frame(maxWidth: .infinity)
                if mic.inputs.isEmpty {
                    Text("Connect the glasses, then probe. Look for a line with BluetoothHFP.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(mic.inputs, id: \.self) { Text($0).font(.footnote.monospaced()) }
                }
            }

            Section("Capture") {
                Toggle("Use glasses mic (Bluetooth HFP)", isOn: $mic.preferGlasses)
                    .disabled(mic.running)
                LabeledContent("Status", value: mic.status)
                LabeledContent("Active input", value: mic.activeInput)
                Button(mic.running ? "Stop" : "Start dictation") {
                    mic.running ? mic.stop() : mic.start()
                }
                .frame(maxWidth: .infinity)
            }

            Section("Heard") {
                Text(mic.transcript.isEmpty ? "—" : mic.transcript)
            }

            Section {
                Text("The glasses mic is plain Bluetooth HFP — mono, speech-quality, beamformed "
                     + "to the wearer. No DAT, no Wi-Fi entitlements, no paid account. The "
                     + "\"Active input\" line tells you whether it actually routed to the glasses.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Mic PoC")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { mic.stop() }
    }
}
#endif
