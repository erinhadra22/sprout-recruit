import Foundation

@main
struct PilotRecordTests {
    static func main() throws {
        precondition(PilotValidation.phone("+15125550123") == "+15125550123")
        for invalid in ["911", "+442071234567", "sip:a@b", "+15125550123;ext=1", "15125550123", "+11115550123"] {
            precondition(PilotValidation.phone(invalid) == nil)
        }
        let now = Date(timeIntervalSince1970: 1000)
        func jwt(_ value: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["exp": value])
            return "test." + data.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".test"
        }
        let fresh = try jwt(1200), expired = try jwt(1000), malformed = try jwt(true)
        precondition(PilotValidation.usableToken(fresh, now: now))
        precondition(!PilotValidation.usableToken(expired, now: now))
        precondition(!PilotValidation.usableToken(malformed, now: now))
        precondition(!PilotValidation.usableToken("KEYnot-a-jwt", now: now))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("calls.json")
        let journal = try PilotJournal(url: file)
        var call = PilotCallRecord(id: UUID(), from: "+15125550123", to: "+15125550124", requestedAt: now)
        call.append("requested", at: now)
        try journal.save(call)
        call.telnyxSessionID = UUID().uuidString
        precondition((try? PilotJournal(url: file))?.records.first?.operatorConfirmedTestConsent == nil)
        call.operatorConfirmedTestConsent = true
        try journal.save(call)
        precondition(journal.records.count == 1, "Repeated events must update the same call")
        let restored = try PilotJournal(url: file)
        precondition(restored.records[0].outcome == "interrupted-unverified")
        precondition(restored.records[0].connectedAt == nil, "Restart must not invent an answer")
        precondition(restored.records[0].endedAt == nil, "Restart must not invent a remote hangup time")
        precondition(restored.records[0].recoveryObservedAt != nil)
        precondition(restored.records[0].providerRecording == "unverified")
        precondition(restored.records[0].operatorConfirmedTestConsent == true)
        let json = try PilotJournal.export(call)
        precondition(json.contains("telnyxSessionID"))
        try Data("invalid".utf8).write(to: file)
        do { _ = try PilotJournal(url: file); fatalError("Corrupt evidence must not be silently replaced") }
        catch { }
        print("Pilot model checks passed: number/token guards, call identity, restart ambiguity, export, corrupt-file preservation.")
    }
}
