import AVFoundation
import CallKit
import Combine
import Foundation
import TelnyxRTC

// UI and CallKit run on the main queue. SDK callbacks explicitly return to it.
final class CallController: NSObject, ObservableObject {
    @Published var tokenInput = ""
    @Published var rememberToken = false
    @Published var callerNumber = "" {
        didSet { if callerNumber != oldValue { recipientReady = false } }
    }
    @Published var destination = "" {
        didSet { if destination != oldValue { recipientReady = false } }
    }
    @Published var recordingConfigured = false
    @Published var recipientReady = false
    @Published private(set) var connection = "Disconnected"
    @Published private(set) var phase = "Ready for a test"
    @Published private(set) var ready = false
    @Published private(set) var connecting = false
    @Published private(set) var busy = false
    @Published private(set) var muted = false
    @Published private(set) var speaker = false
    @Published private(set) var audioRoute = "No call audio"
    @Published private(set) var message = ""
    @Published private(set) var record: PilotCallRecord?
    @Published private(set) var exportedRecord = ""
    @Published private(set) var hasSavedToken = false

    private var client: TxClient?
    fileprivate var connectionID = UUID()
    private var sessionDelegate: SessionDelegate?
    private var currentCall: Call?
    private var activeID: UUID?
    private var sessionExpiry: Date?
    private var journal: PilotJournal?
    private var connectionTimeout: DispatchWorkItem?
    private var localEndRequested = false
    private let systemCalls = CXCallController()
    private let provider: CXProvider

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "Sprout Call Pilot")
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            journal = try PilotJournal(url: base.appendingPathComponent("pilot-calls.json"))
            record = journal?.records.last
            refreshExport()
            if let token = try SessionKeychain.read() {
                if PilotValidation.usableToken(token) { hasSavedToken = true; rememberToken = true }
                else { try SessionKeychain.remove() }
            }
        } catch {
            message = "Local setup needs attention. Calls are disabled if the call journal cannot be opened."
        }
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var canConnect: Bool { !busy && !ready && !connecting && (!tokenInput.isEmpty || hasSavedToken) }
    var canCall: Bool {
        ready && !busy && journal != nil && recordingConfigured && recipientReady &&
        PilotValidation.phone(callerNumber) != nil && PilotValidation.phone(destination) != nil
    }

    func connect() {
        guard canConnect else { return }
        message = ""
        do {
            let typedToken = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = typedToken.isEmpty ? (try SessionKeychain.read() ?? "") : typedToken
            guard PilotValidation.usableToken(token) else {
                message = "Enter a fresh Telnyx WebRTC session JWT with an expiry more than 30 seconds away. Never enter an account API key."
                return
            }
            if rememberToken { try SessionKeychain.save(token); hasSavedToken = true }
            else { try SessionKeychain.remove(); hasSavedToken = false }
            retireConnection()
            sessionExpiry = PilotValidation.tokenExpiry(token)
            let newClient = TxClient()
            client = newClient
            let delegate = SessionDelegate(owner: self, generation: connectionID)
            sessionDelegate = delegate
            newClient.delegate = delegate
            newClient.isAudioDeviceEnabled = false
            connecting = true
            connection = "Connecting"
            // Explicitly disable optional provider diagnostics in SDK 4.2.1.
            let config = TxConfig(token: token, logLevel: .none, debug: false,
                                  enableQualityMetrics: false, sendWebRTCStatsViaSocket: false,
                                  enableCallReports: false)
            try newClient.connect(txConfig: config)
            tokenInput = ""
            let expectedConnection = connectionID
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.connectionID == expectedConnection, self.connecting else { return }
                self.disconnect()
                self.message = "Connection timed out. Check the session token and internet connection before reconnecting."
            }
            connectionTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        } catch {
            disconnect()
            message = "Could not connect or store the session securely. Check Telnyx setup and try a fresh session token."
        }
    }

    func disconnect() {
        guard !busy else { return }
        retireConnection()
        connection = "Disconnected"
    }

    private func retireConnection() {
        connectionID = UUID() // Invalidates callbacks already queued by a prior client.
        connectionTimeout?.cancel()
        client?.delegate = nil
        client?.disconnect()
        client = nil
        sessionDelegate = nil
        ready = false; connecting = false
        sessionExpiry = nil
    }

    func forgetToken() {
        guard !busy else { return }
        disconnect()
        tokenInput = ""
        do { try SessionKeychain.remove(); hasSavedToken = false; rememberToken = false }
        catch { message = "The saved session could not be removed. Retry after unlocking this iPhone." }
    }

    func placeCall() {
        guard canCall, let from = PilotValidation.phone(callerNumber),
              let to = PilotValidation.phone(destination) else { return }
        guard let expiry = sessionExpiry, expiry > Date() else {
            disconnect(); message = "The session expired. Connect with a fresh token."; return
        }
        busy = true // Freeze this exact request while the microphone prompt is open.
        recipientReady = false // Require fresh consent before each test attempt.
        message = ""
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    self.busy = false
                    self.message = "Microphone access is needed. Enable it for Sprout Call Pilot in iPhone Settings."
                    return
                }
                guard self.ready else { self.busy = false; self.message = "Reconnect before calling."; return }
                self.startSystemCall(from: from, to: to)
            }
        }
    }

    private func startSystemCall(from: String, to: String) {
        let id = UUID()
        var next = PilotCallRecord(id: id, from: from, to: to, requestedAt: Date())
        next.operatorConfirmedTestConsent = true
        next.append("User requested designated test call; provider recording unverified")
        do { try journal?.save(next) }
        catch { busy = false; message = "Cannot save the call record. No call was placed."; return }
        record = next; activeID = id; localEndRequested = false
        phase = "Starting call"; refreshExport()
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .phoneNumber, value: to))
        action.isVideo = false
        systemCalls.request(CXTransaction(action: action)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, error != nil else { return }
                self.finish(id: id, outcome: "callkit-start-failed", systemReason: .failed)
                self.message = "iPhone could not start the call. No automatic retry was made."
            }
        }
    }

    func endCall() {
        guard let id = activeID else { return }
        systemCalls.request(CXTransaction(action: CXEndCallAction(call: id))) { [weak self] error in
            DispatchQueue.main.async {
                if error != nil { self?.message = "Could not request hangup. Use the iPhone call controls; do not assume the call ended." }
            }
        }
    }

    func toggleMute() {
        guard let id = activeID, currentCall != nil else { return }
        systemCalls.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: !muted))) { [weak self] error in
            DispatchQueue.main.async { if error != nil { self?.message = "The mute change could not be applied." } }
        }
    }

    func toggleSpeaker() {
        guard currentCall != nil else { return }
        if speaker { client?.setEarpiece() } else { client?.setSpeaker() }
        routeChanged()
    }

    @objc private func routeChanged() {
        DispatchQueue.main.async { [weak self] in
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            self?.speaker = outputs.contains { $0.portType == .builtInSpeaker }
            self?.audioRoute = outputs.map(\.portName).joined(separator: ", ")
        }
    }

    private func saveState(_ state: String) {
        guard var current = record, current.id == activeID else { return }
        current.telnyxSessionID = currentCall?.telnyxSessionId?.uuidString ?? current.telnyxSessionID
        current.telnyxLegID = currentCall?.telnyxLegId?.uuidString ?? current.telnyxLegID
        current.telnyxCallControlID = currentCall?.telnyxCallControlId ?? current.telnyxCallControlID
        current.append(state)
        record = current
        persist()
    }

    private func persist() {
        guard let record else { return }
        do { try journal?.save(record) }
        catch { message = "The call state could not be saved locally. Keep this screen open and reconcile the provider record." }
        refreshExport()
    }

    private func refreshExport() { exportedRecord = (try? record.map(PilotJournal.export)) ?? "" }

    private func finish(id: UUID, outcome: String, systemReason: CXCallEndedReason?) {
        guard activeID == id else { return } // Ignore duplicate/old terminal callbacks.
        saveState(outcome)
        record?.endedAt = Date(); record?.outcome = outcome
        persist()
        if let systemReason { provider.reportCall(with: id, endedAt: Date(), reason: systemReason) }
        activeID = nil; currentCall = nil; busy = false; muted = false
        phase = "Call ended · recording unverified"
        recipientReady = false
    }
}

extension CallController: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        currentCall?.hangup()
        if let id = activeID { finish(id: id, outcome: "system-reset-unverified", systemReason: nil) }
        disconnect()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard action.callUUID == activeID else { action.fail(); return }
        guard let record, let client, ready else {
            action.fail()
            finish(id: action.callUUID, outcome: "connection-lost-before-start", systemReason: .failed)
            message = "The connection was lost before dialing. Reconnect before another test."
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            currentCall = try client.newCall(callerName: "Sprout Recruit", callerNumber: record.from,
                                            destinationNumber: record.to, callId: record.id,
                                            customHeaders: ["X-Sprout-Pilot-ID": record.id.uuidString], debug: false)
            let update = CXCallUpdate()
            update.remoteHandle = action.handle
            update.supportsDTMF = false; update.supportsHolding = true
            update.supportsGrouping = false; update.supportsUngrouping = false
            provider.reportCall(with: record.id, updated: update)
            provider.reportOutgoingCall(with: record.id, startedConnectingAt: Date())
            saveState("SDK accepted outbound request")
            action.fulfill()
        } catch {
            action.fail()
            finish(id: action.callUUID, outcome: "sdk-start-failed", systemReason: .failed)
            message = "The call could not be placed. Check Telnyx routing, allowed destinations, caller ID, and balance."
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == activeID, let client else { action.fail(); return }
        localEndRequested = true
        saveState("Local hangup requested")
        phase = "Ending call"
        client.endCallFromCallkit(endAction: action, callId: action.callUUID)
        // The SDK owns action fulfillment. A terminal callback owns our call outcome.
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard action.callUUID == activeID, let call = currentCall else { action.fail(); return }
        if action.isMuted { call.muteAudio() } else { call.unmuteAudio() }
        muted = call.isMuted
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard action.callUUID == activeID, let call = currentCall else { action.fail(); return }
        if action.isOnHold { call.hold() } else { call.unhold() }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        if let start = action as? CXStartCallAction, start.callUUID == activeID, currentCall == nil {
            finish(id: start.callUUID, outcome: "system-start-timeout-no-sdk-call", systemReason: .failed)
            return
        }
        message = "A system call action timed out. Check the iPhone call controls before retrying."
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        client?.enableAudioSession(audioSession: audioSession)
        routeChanged()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        client?.disableAudioSession(audioSession: audioSession)
    }
}

// Called only by the generation-checked proxy below, already on the main queue.
extension CallController {
    func onSocketConnected() {
        connection = "Authenticating"
    }
    func onClientReady() {
        guard client?.isRegistered == true else { return }
        connectionTimeout?.cancel()
        ready = true; connecting = false; connection = "Connected"
    }
    func onSocketDisconnected() {
        ready = false; connection = "Connection lost"
        saveState("Signaling disconnected; call outcome not yet known")
    }
    func onClientError(error: Error) {
        // Avoid storing SDK error payloads, which can include private signaling data.
        message = "Telnyx reported a connection or call error. Check the provider setup; no automatic redial was made."
        if !busy { disconnect() }
    }
    func onSessionUpdated(sessionId: String) { }
    func onPushDisabled(success: Bool, message: String) { }
    func onIncomingCall(call: Call) {
        // Outbound-only pilot: no automatic answer and no PushKit registration.
        call.hangup()
        message = "An incoming call was declined; this pilot tests outgoing calls only."
    }
    func onPushCall(call: Call) { call.hangup() }
    func onRemoteCallEnded(callId: UUID, reason: CallTerminationReason?) {
        finish(id: callId, outcome: localEndRequested ? "ended-after-local-request" : "remote-ended",
               systemReason: localEndRequested ? nil : .remoteEnded)
    }
    func onCallStateUpdated(callState: CallState, callId: UUID) {
            guard self.activeID == callId else { return }
            switch callState {
            case .NEW, .CONNECTING: self.phase = "Connecting call"; self.saveState("connecting")
            case .RINGING: self.phase = "Ringing"; self.saveState("ringing")
            case .ACTIVE:
                if self.record?.connectedAt == nil {
                    self.record?.connectedAt = Date()
                    self.provider.reportOutgoingCall(with: callId, connectedAt: Date())
                }
                self.phase = "In call · recording unverified"; self.saveState("active")
            case .HELD: self.phase = "On hold"; self.saveState("held")
            case .RECONNECTING: self.phase = "Reconnecting call"; self.saveState("reconnecting")
            case .DROPPED: self.finish(id: callId, outcome: "dropped", systemReason: .failed)
            case .DONE(let reason):
                let cause = reason?.cause ?? "unknown"
                self.finish(id: callId, outcome: "done:\(cause)", systemReason: self.localEndRequested ? nil : .remoteEnded)
            }
    }
}

private final class SessionDelegate: TxClientDelegate {
    private weak var owner: CallController?
    private let generation: UUID
    init(owner: CallController, generation: UUID) { self.owner = owner; self.generation = generation }
    private func deliver(_ event: @escaping (CallController) -> Void) {
        let expected = generation
        DispatchQueue.main.async { [weak owner = self.owner] in
            guard let owner, owner.connectionID == expected else { return }
            event(owner)
        }
    }
    func onSocketConnected() { deliver { $0.onSocketConnected() } }
    func onSocketDisconnected() { deliver { $0.onSocketDisconnected() } }
    func onClientReady() { deliver { $0.onClientReady() } }
    func onClientError(error: Error) { deliver { $0.onClientError(error: error) } }
    func onSessionUpdated(sessionId: String) { deliver { $0.onSessionUpdated(sessionId: sessionId) } }
    func onPushDisabled(success: Bool, message: String) { deliver { $0.onPushDisabled(success: success, message: message) } }
    func onIncomingCall(call: Call) { deliver { $0.onIncomingCall(call: call) } }
    func onPushCall(call: Call) { deliver { $0.onPushCall(call: call) } }
    func onRemoteCallEnded(callId: UUID, reason: CallTerminationReason?) { deliver { $0.onRemoteCallEnded(callId: callId, reason: reason) } }
    func onCallStateUpdated(callState: CallState, callId: UUID) { deliver { $0.onCallStateUpdated(callState: callState, callId: callId) } }
}
