import SwiftUI

@main
struct SproutCallPilotApp: App {
    @StateObject private var calls = CallController()
    var body: some Scene { WindowGroup { PilotView(calls: calls) } }
}

struct PilotView: View {
    @ObservedObject var calls: CallController
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(calls.connection, systemImage: calls.ready ? "checkmark.circle.fill" : "phone.connection")
                    Text(calls.phase).font(.headline)
                    Text("Outgoing test calls only. Audio and recording pass through Telnyx.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !calls.message.isEmpty {
                    Section { Text(calls.message).foregroundStyle(.orange).accessibilityLabel("Status: \(calls.message)") }
                }
                Section("Connect for this test") {
                    SecureField(calls.hasSavedToken ? "Saved session available · or paste a new JWT" : "Telnyx session JWT", text: $calls.tokenInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Remember until expiry on this iPhone", isOn: $calls.rememberToken)
                    Text("Use a short-lived WebRTC token, never a Telnyx account API key. Saved tokens stay in this iPhone’s Keychain.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("Connect") { calls.connect() }.disabled(!calls.canConnect)
                        Spacer()
                        Button("Disconnect") { calls.disconnect() }.disabled(calls.busy || (!calls.ready && !calls.connecting))
                    }
                    Button("Forget saved session", role: .destructive) { calls.forgetToken() }
                        .disabled(calls.busy)
                }.disabled(calls.busy)
                Section("Designated test call") {
                    TextField("Your verified number · +1…", text: $calls.callerNumber).keyboardType(.phonePad)
                    TextField("Test recipient · +1…", text: $calls.destination).keyboardType(.phonePad)
                    Toggle("Two-track recording is set up in Telnyx", isOn: $calls.recordingConfigured)
                    Toggle("This test recipient agreed to be recorded", isOn: $calls.recipientReady)
                    Text("Confirm consent before each test call. Afterward, check the provider recording for both voices.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { calls.placeCall() } label: {
                        Label("Call test recipient", systemImage: "phone.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.green).disabled(!calls.canCall)
                }.disabled(calls.busy)
                if calls.busy {
                    Section("Call controls") {
                        HStack {
                            Button(calls.muted ? "Unmute" : "Mute") { calls.toggleMute() }
                            Spacer()
                            Button(calls.speaker ? "Use earpiece" : "Use speaker") { calls.toggleSpeaker() }
                        }
                        Text("Audio: \(calls.audioRoute)").font(.footnote)
                        Button("End call", role: .destructive) { calls.endCall() }
                    }
                }
                if let record = calls.record {
                    Section("Latest call evidence") {
                        LabeledContent("Recording", value: "Unverified")
                        LabeledContent("Call result", value: record.outcome)
                        Text("Check the retrieved audio on the Mac before accepting this test. A connected call is not proof of recording.")
                            .font(.footnote).foregroundStyle(.secondary)
                        DisclosureGroup("Call identifiers") {
                            Text("SDK: \(record.id.uuidString)")
                            Text("Session: \(record.telnyxSessionID ?? "Not supplied")")
                            Text("Leg: \(record.telnyxLegID ?? "Not supplied")")
                            Text("Call Control: \(record.telnyxCallControlID ?? "Not supplied for this call")")
                        }.font(.caption).textSelection(.enabled)
                        if !calls.exportedRecord.isEmpty {
                            ShareLink("Share call evidence", item: calls.exportedRecord)
                        }
                    }
                }
            }
            .navigationTitle("Sprout Call Pilot")
            .tint(.green)
        }
    }
}
