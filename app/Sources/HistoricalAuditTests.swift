import Foundation

func runHistoricalAuditTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message:"History audit test failed: " + message) }
    }
    let records: [String:[Record]] = [
        "agents":[["id":"legacy-contact","name":"Private fixture name","email":"private@example.com"]],
        "communications":[["id":"legacy-send","occurredOn":"2026-01-10"]],
        "workflows":[["id":"precise-call","occurredOn":"2026-01-10","occurredAt":"2026-01-10T12:00:00Z"]],
        "activities":[
            ["id":"legacy-noon","date":"2026-01-10T12:00:00","communicationId":"legacy-send","body":"Private fixture body"],
            ["id":"actual-noon","date":"2026-01-10T12:00:00Z","workflowId":"precise-call","recordedAt":"2026-01-11T01:00:00Z"],
            ["id":"date-only","date":"2026-01-10","createdAt":"2026-01-11T01:00:00Z"],
            ["id":"unlinked-noon","date":"2026-01-10T12:00:00","createdAt":"2026-01-11T01:00:00Z"]],
        "sequences":[
            ["id":"before","agentId":"contact-a","state":"active","createdAt":"2026-01-10T08:00:00.100Z"],
            ["id":"after","agentId":"contact-a","state":"active","createdAt":"2026-01-11T00:00:00Z"],
            ["id":"unknown","agentId":"contact-a","state":"active"],
            ["id":"held","agentId":"contact-a","state":"paused","pauseReason":"inbound_reply"]],
        "drafts":[
            ["id":"missing-hold","sequenceId":"held","state":"draft","approvalState":"approved","createdAt":"2026-01-11T01:00:00Z"],
            ["id":"correct-hold","sequenceId":"held","state":"draft","approvalState":"paused_reply","createdAt":"2026-01-11T01:00:00Z"],
            ["id":"sent-draft","sequenceId":"held","state":"sent","createdAt":"2026-01-11T01:00:00Z"]],
        "externalMessages":[["id":"reply","agentId":"contact-a","direction":"inbound","occurredAt":"2026-01-10T09:00:00Z","body":"Private reply body"],
                            ["id":"outbound","agentId":"contact-a","direction":"outbound","occurredAt":"2026-01-12T09:00:00Z"]]
    ]
    let before = try JSONSerialization.data(withJSONObject:records,options:.sortedKeys)
    let report = HistoricalAudit.review(records)
    let counts = report["findingCounts"] as! [String:Int]
    try check(counts["suspected_legacy_noon"] == 1,"only linked date-only legacy noon is suspected")
    try check(counts["date_only_occurrence"] == 1,"honest date-only data remains informational")
    try check(counts["occurrence_time_needs_review"] == 1,"unlinked timezone-free occurrence remains unresolved")
    try check(counts["active_sequence_after_reply"] == 1,"only earlier active enrollment is reported")
    try check(counts["reply_chronology_unknown"] == 1,"unknown enrollment date never guesses chronology")
    try check(counts["reply_hold_missing_on_draft"] == 1,"only active unheld draft of reply-paused sequence is reported")
    try check(before == JSONSerialization.data(withJSONObject:records,options:.sortedKeys),"audit does not mutate input records")
    let encoded = String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!
    try check(!encoded.contains("Private") && !encoded.contains("private@example.com"),"report excludes names, addresses and message bodies")
    let limited = HistoricalAudit.review(records,maxDetails:0)
    try check((limited["findings"] as? [Record])?.isEmpty == true && limited["detailsTruncated"] as? Bool == true,"zero-detail summary preserves finding count")
    try check(limited["totalFindings"] as? Int == report["totalFindings"] as? Int,"limit never changes coverage counts")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-history-audit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store = try Store(path:directory.appendingPathComponent("fixture.sqlite").path,seed:false)
    try store.put("activities",records["activities"]![0])
    let savedBefore = try JSONSerialization.data(withJSONObject:store.all("activities"),options:.sortedKeys)
    _ = try store.historicalAudit(["maxDetails":10])
    try check(savedBefore == JSONSerialization.data(withJSONObject:store.all("activities"),options:.sortedKeys),"database audit does not write records")
    for payload: Record in [["maxDetails":-1],["maxDetails":1001],["maxDetails":"100"],["apply":true]] {
        var rejected = false
        do { _ = try store.historicalAudit(payload) } catch { rejected = true }
        try check(rejected,"invalid audit argument rejected")
    }
    print("PASS: read-only history audit, evidence-qualified legacy noon, honest missing times, reply chronology, privacy and detail limits.")
}
