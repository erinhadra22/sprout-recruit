import Foundation

func runExternalMessagesTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-external-messages-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try Store(path: directory.appendingPathComponent("fixture.sqlite").path,seedSamples:true)
    func check(_ result: Bool, _ description: String) throws {
        if !result { throw StoreError(message: "External message test failed: " + description) }
    }
    func rejects(_ payload: Record, _ description: String) throws {
        do {
            _ = try store.command("externalMessage.import", payload)
            throw StoreError(message: "Expected rejection: " + description)
        } catch let error as StoreError {
            try check(!error.message.hasPrefix("Expected rejection:"), description)
        }
    }
    _ = try store.command("agent.create", ["name":"Fixture Agent", "email":"agent@example.com", "phone":"+15125550123"])
    let agent = try store.all("agents").first { $0["name"] as? String == "Fixture Agent" }!
    let agentId = agent["id"] as! String
    let sent: Record = ["agentId":agentId,"channel":"Email","provider":"gmail",
                        "accountAddress":"operator@example.com","providerMessageId":"sent-123",
                        "providerThreadId":"thread-123","direction":"outbound",
                        "from":"operator@example.com","to":"agent@example.com",
                        "occurredAt":"2026-10-12T20:36:07Z","subject":"A hello",
                        "body":"Hi there. — Erin"]
    let activitiesBefore = try store.all("activities").count
    let statusBefore = try store.get("agents",agentId)["status"] as? String
    _ = try store.command("externalMessage.import",sent)
    let first = try store.all("externalMessages")
    try check(first.count == 1, "sent email saved")
    _ = try store.command("externalMessage.import",sent)
    try check(try store.all("externalMessages").count == 1, "exact replay is idempotent")
    let reply: Record = ["agentId":agentId,"channel":"Email","provider":"gmail",
                         "accountAddress":"operator@example.com","providerMessageId":"reply-456",
                         "providerThreadId":"thread-123","direction":"inbound",
                         "from":"agent@example.com","to":"operator@example.com",
                         "occurredAt":"2026-10-12T21:09:51Z","subject":"Re: A hello",
                         "body":"Thanks, but I will pass."]
    try store.put("sequences",["id":"sequence-before-reply","agentId":agentId,"state":"active","createdAt":"2026-10-12T21:00:00Z"])
    try store.put("sequences",["id":"sequence-after-reply","agentId":agentId,"state":"active","createdAt":"2026-10-12T21:15:00Z"])
    try store.put("drafts",["id":"draft-before-reply","agentId":agentId,"sequenceId":"sequence-before-reply","channel":"Message","body":"Fixture follow-up","state":"draft","approvalState":"approved"])
    try store.put("drafts",["id":"draft-after-reply","agentId":agentId,"sequenceId":"sequence-after-reply","channel":"Message","body":"New enrollment","state":"draft","approvalState":"pending_review"])
    _ = try store.command("externalMessage.import",reply)
    try check(try store.all("externalMessages").count == 2, "inbound reply saved")
    try check(try store.get("sequences","sequence-before-reply")["state"] as? String == "paused","new verified reply pauses earlier active enrollment")
    try check(try store.get("drafts","draft-before-reply")["approvalState"] as? String == "paused_reply","new verified reply pauses prepared draft")
    try check(try store.get("sequences","sequence-after-reply")["state"] as? String == "active","historical reply does not pause later enrollment")
    try check(try store.get("drafts","draft-after-reply")["approvalState"] as? String == "pending_review","historical reply does not alter later draft")
    let eventCount = try store.all("workflowEvents").count
    _ = try store.command("externalMessage.import",reply)
    try check(try store.all("workflowEvents").count == eventCount,"replay creates no duplicate pause event")
    try check(try store.all("activities").count == activitiesBefore, "import does not create activity or imply delivery")
    try check(try store.get("agents",agentId)["status"] as? String == statusBefore, "import leaves CRM status unchanged")
    var changed = sent; changed["body"] = "Different body"
    try rejects(changed, "conflicting content with same provider ID")
    changed = sent; changed["to"] = "other@example.com"
    try rejects(changed, "recipient mismatch")
    changed = sent; changed["direction"] = "inbound"
    try rejects(changed, "direction mismatch")
    changed = sent; changed["accountAddress"] = "other@example.com"; changed["from"] = "other@example.com"
    try rejects(changed, "same provider message in another account")
    changed = sent; changed["agentId"] = "sample-01"
    try rejects(changed, "sample contact rejected")
    let text: Record = ["agentId":agentId,"channel":"Message","provider":"apple-messages",
                        "accountAddress":"+15125550999","providerMessageId":"message-789",
                        "providerThreadId":"any;-;+15125550123","direction":"inbound",
                        "from":"+15125550123","to":"+15125550999",
                        "occurredAt":"2026-10-12T21:10:00Z","body":"Hello"]
    _ = try store.command("externalMessage.import",text)
    try check(try store.all("externalMessages").count == 3, "exact-number Messages record saved")
    print("PASS: external correspondence exact identity, sent/reply/text import, replay safety, conflict rejection and no implicit CRM change.")
}
