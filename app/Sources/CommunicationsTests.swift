import Foundation

// These tests create a disposable local database and never open a URL or make a network request.
func runCommunicationsTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-communication-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try Store(path: directory.appendingPathComponent("test.sqlite").path,seedSamples:true)
    let phone = "+12025550123", sender = "+12025550124", text = "Fixture message — never sent."
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message: "Communications test failed: " + message) }
    }
    func fail(_ action: String, _ payload: Record, _ message: String) throws {
        do { _ = try store.command(action, payload) }
        catch is StoreError { return }
        throw StoreError(message: "Communications test failed: " + message)
    }
    func prepare(_ changes: Record = [:]) -> Record {
        var p: Record = ["id": UUID().uuidString, "channel": "message", "transport": "apple-messages", "target": "agent", "agentId": "fixture-manual", "phone": phone, "body": text]
        for (key, value) in changes { p[key] = value }; return p
    }
    func update(_ request: Record, _ state: String, _ extra: Record = [:]) throws {
        var p = extra; p["id"] = request["id"]; p["state"] = state
        _ = try store.command("communication.update", p)
    }
    func state(_ p: Record) throws -> String { try store.get("communications", p["id"] as! String)["state"] as? String ?? "missing" }
    func countInteractions() throws -> Int { try store.all("activities").filter { $0["kind"] as? String == "interaction" }.count }
    let originalActivities = try store.all("activities").count
    let originalInteractions = try countInteractions()
    try store.put("agents", ["id": "fixture-manual", "manual": true, "source": "Manual contact", "name": "Fixture contact", "phone": "(202) 555-0123", "status": "Connected", "lastInteraction": Store.day()])
    try store.put("agents", ["id": "fixture-dnc", "manual": true, "name": "Do not contact fixture", "phone": phone, "status": "Do not contact"])
    try store.put("agents", ["id": "fixture-sample", "manual": true, "name": "Sample fixture", "phone": phone, "status": "Identified", "datasetId": "sample"])


    try check(try Store.normalizedCommunicationPhone("+1 (202) 555-0123") == phone, "normalize a formatted number with explicit country code")
    try check(try Store.normalizedCommunicationPhone("(202) 555-0123") == phone, "normalize a ten-digit US number")
    try check(try Store.normalizedCommunicationPhone("1-202-555-0123") == phone, "normalize an eleven-digit US number")
    for bad in ["202555012", "+0123456789", "+123", "+12025550123 ext 4", "+1+2025550123"] {
        try fail("communication.prepare", prepare(["phone": bad]), "reject malformed or ambiguous phone")
    }
    try fail("communication.prepare", prepare(["agentId": "sample-01"]), "reject seeded sample agent")
    try fail("communication.prepare", prepare(["agentId": "fixture-sample"]), "reject manual flag on sample dataset")
    try fail("communication.prepare", prepare(["agentId": "fixture-dnc"]), "reject do not contact")
    try fail("communication.prepare", prepare(["phone": sender]), "reject number mismatched to contact")
    try fail("communication.prepare", prepare(["body": "  "]), "reject empty message")
    try fail("communication.prepare", prepare(["body": String(repeating: "x", count: 1601)]), "enforce message length")
    try fail("communication.prepare", prepare(["id": "not-a-uuid"]), "require stable attempt UUID")
    try fail("communication.prepare", prepare(["apiKey": "fixture-secret-not-real"]), "never persist a credential field")
    try fail("communication.prepare", prepare(["transport": "system-phone"]), "reject mismatched channel and transport")
    var missingConsent = prepare(["target": "test"]); missingConsent.removeValue(forKey: "agentId")
    try fail("communication.prepare", missingConsent, "test target needs explicit permission")
    try check(try store.all("communications").isEmpty, "invalid preparations leave no attempt rows")

    let apple = prepare()
    _ = try store.command("communication.prepare", apple)
    _ = try store.command("communication.prepare", apple)
    try check(try store.all("communications").count == 1, "same attempt preparation is idempotent")
    var changed = apple; changed["body"] = "Changed text"
    try fail("communication.prepare", changed, "same ID cannot be reused with a different body")
    try check(try store.all("activities").count == originalActivities, "preparing does not log an interaction or activity")
    try fail("communication.update", ["id": apple["id"]!, "state": "user_confirmed_sent", "confirmed": true, "phone": phone, "body": text], "cannot confirm before system handoff")
    try fail("communication.update", ["id": apple["id"]!, "state": "accepted", "providerId": UUID().uuidString], "handoff cannot become provider accepted")
    try update(apple, "handoff_opened")
    try update(apple, "handoff_opened")
    try check(try countInteractions() == originalInteractions, "opening a composer does not count as a sent message")
    try fail("communication.update", ["id": apple["id"]!, "state": "user_confirmed_sent", "phone": phone, "body": text], "requires explicit confirmation")
    try fail("communication.update", ["id": apple["id"]!, "state": "user_confirmed_sent", "confirmed": true, "phone": sender, "body": text], "requires exact recipient")
    try fail("communication.update", ["id": apple["id"]!, "state": "user_confirmed_sent", "confirmed": true, "phone": phone, "body": text + " "], "requires exact message text")
    try fail("communication.update", ["id": apple["id"]!, "state": "user_confirmed_sent", "confirmed": true, "phone": phone, "body": text, "occurredOn": Store.plusDays(1)], "reject future interaction date")
    try check(try state(apple) == "handoff_opened", "invalid confirmation leaves ledger unchanged")
    let confirmation: Record = ["confirmed": true, "phone": phone, "body": text, "occurredOn": Store.plusDays(-2)]
    try update(apple, "user_confirmed_sent", confirmation)
    try update(apple, "user_confirmed_sent", confirmation)
    try check(try countInteractions() == originalInteractions + 1, "confirmed manual message is logged exactly once")
    let logged = try store.get("activities", "communication-" + (apple["id"] as! String).lowercased())
    try check(logged["confirmationSource"] as? String == "user" && logged["date"] as? String == Store.plusDays(-2), "date-only confirmation preserves unknown time without inventing noon")
    try check(try store.get("agents", "fixture-manual")["status"] as? String == "Connected", "confirmation preserves recruiting status")
    try check(try store.get("agents", "fixture-manual")["lastInteraction"] as? String == Store.day(), "backdated confirmations never move last interaction backward")
    try fail("communication.update", ["id": apple["id"]!, "state": "user_confirmed_sent", "confirmed": true, "phone": phone, "body": text, "occurredOn": Store.day()], "duplicate confirmation cannot silently change date")

    let cancelled = prepare(); _ = try store.command("communication.prepare", cancelled)
    try update(cancelled, "handoff_opened"); try update(cancelled, "cancelled")
    try fail("communication.update", ["id": cancelled["id"]!, "state": "handoff_opened"], "canceled attempt does not restart")
    let call = prepare(["channel": "call", "transport": "system-phone", "body": ""])
    _ = try store.command("communication.prepare", call); try update(call, "handoff_opened")
    try fail("communication.update", ["id": call["id"]!, "state": "user_confirmed_sent", "confirmed": true, "phone": phone, "body": text], "call cannot be confirmed as text")
    try update(call, "user_confirmed_call", ["confirmed": true, "phone": phone])
    try update(call, "user_confirmed_call", ["confirmed": true, "phone": phone])
    try check(try countInteractions() == originalInteractions + 2, "confirmed call logs once; cancelled handoff logs nothing")

    let optOut = prepare(); _ = try store.command("communication.prepare", optOut)
    var agent = try store.get("agents", "fixture-manual"); agent["status"] = "Do not contact"; try store.put("agents", agent)
    try fail("communication.update", ["id": optOut["id"]!, "state": "handoff_opened"], "recheck restrictions immediately before handoff")
    agent["status"] = "Connected"; try store.put("agents", agent)
    let provider = prepare(["transport": "telnyx", "sender": sender])
    var noSender = provider; noSender.removeValue(forKey: "sender")
    try fail("communication.prepare", noSender, "provider request needs an exact sender snapshot")
    _ = try store.command("communication.prepare", provider)
    var wrongSender = provider; wrongSender["sender"] = "+12025550125"
    try fail("communication.prepare", wrongSender, "same attempt cannot change sender")
    try update(provider, "submitting"); try update(provider, "submitting")
    _ = try store.command("communication.prepare", provider)
    try check(try state(provider) == "submitting", "preparation retry never resets a submitting attempt")
    try fail("communication.update", ["id": provider["id"]!, "state": "accepted"], "provider acceptance needs its stable ID")
    try fail("communication.update", ["id": provider["id"]!, "state": "accepted", "providerId": "invalid"], "malformed provider ID is rejected")
    let providerID = UUID().uuidString
    try update(provider, "accepted", ["providerId": providerID])
    try check(try countInteractions() == originalInteractions + 2, "provider acceptance is not delivery")
    try update(provider, "delivered", ["providerId": providerID])
    try update(provider, "delivered", ["providerId": providerID])
    try check(try countInteractions() == originalInteractions + 3, "provider delivery logs once")
    try check(try store.get("communications", provider["id"] as! String)["confirmationSource"] as? String == "provider", "provider delivery stays distinguishable from user confirmation")
    try fail("communication.update", ["id": provider["id"]!, "state": "failed"], "delivery cannot be overwritten by a late incompatible status")

    var testTarget = prepare(["target": "test", "transport": "telnyx", "sender": sender, "consentConfirmed": true]); testTarget.removeValue(forKey: "agentId")
    _ = try store.command("communication.prepare", testTarget); try update(testTarget, "submitting")
    try fail("communication.update", ["id": testTarget["id"]!, "state": "accepted", "providerId": providerID], "one provider ID cannot bind to two attempts")
    let testProviderID = UUID().uuidString
    try update(testTarget, "accepted", ["providerId": testProviderID]); try update(testTarget, "delivered", ["providerId": testProviderID])
    try check(try countInteractions() == originalInteractions + 3, "test delivery never creates agent interaction rows")

    let ambiguous = prepare(["transport": "telnyx", "sender": sender])
    _ = try store.command("communication.prepare", ambiguous); try update(ambiguous, "submitting"); try update(ambiguous, "unknown", ["errorCode": "network_timeout"])
    _ = try store.command("communication.prepare", ambiguous)
    try fail("communication.update", ["id": ambiguous["id"]!, "state": "submitting"], "uncertain attempt cannot be blindly retried")
    try fail("communication.update", ["id": ambiguous["id"]!, "state": "accepted", "providerId": UUID().uuidString], "unknown without preexisting provider ID cannot invent a reconciliation")
    try check(try state(ambiguous) == "unknown", "uncertain state persists")
    let recoverable = prepare(["transport": "telnyx", "sender": sender])
    let recoverableID = UUID().uuidString
    _ = try store.command("communication.prepare", recoverable); try update(recoverable, "submitting")
    try update(recoverable, "unknown", ["errorCode": "malformed_success", "providerId": recoverableID])
    try fail("communication.update", ["id": recoverable["id"]!, "state": "delivered", "providerId": UUID().uuidString], "reconciliation cannot switch provider ID")
    try update(recoverable, "delivered", ["providerId": recoverableID])
    try update(recoverable, "delivered", ["providerId": recoverableID])
    try check(try countInteractions() == originalInteractions + 4, "known provider receipt can reconcile unknown delivery once")
    let failed = prepare(["transport": "telnyx", "sender": sender])
    _ = try store.command("communication.prepare", failed); try update(failed, "submitting"); try update(failed, "failed", ["errorCode": "request_rejected"])
    try fail("communication.update", ["id": failed["id"]!, "state": "submitting"], "failed attempt needs a new explicit attempt rather than replay")

    let reopened = try Store(path: store.path)
    try check(try reopened.get("communications", ambiguous["id"] as! String)["state"] as? String == "unknown", "unknown survives app restart")
    try check(try reopened.get("communications", provider["id"] as! String)["sender"] as? String == sender, "provider sender snapshot survives restart")
    try check(try reopened.all("communications").count == store.all("communications").count, "all attempt receipts survive restart")
    try store.put("agents", ["id":"fixture-imported","manual":false,"datasetId":"live","source":"CSV import",
                              "name":"Imported fixture","phone":phone,"status":"Identified"])
    let importedRequest = prepare(["agentId":"fixture-imported"])
    try fail("communication.prepare", importedRequest, "unreviewed imported contact cannot start a handoff")
    try fail("agent.verifyCommunication", ["agentId":"fixture-imported","name":"Imported fixture","phone":phone,"confirmed":false],
             "imported review needs an explicit confirmation")
    _ = try store.command("agent.verifyCommunication", ["agentId":"fixture-imported","name":"Imported fixture","phone":phone,"confirmed":true])
    try check(try store.get("agents","fixture-imported")["communicationVerification"] as? Record != nil,
              "imported contact review is saved")
    _ = try store.command("communication.prepare", importedRequest)
    try check(try store.get("communications", importedRequest["id"] as! String)["state"] as? String == "prepared",
              "reviewed imported contact can prepare exact-number message without sending")
    _ = try store.command("agent.update", ["agentId":"fixture-imported","phone":"+12025550125"])
    try fail("communication.prepare", prepare(["agentId":"fixture-imported","phone":"+12025550125"]),
             "changing the saved phone invalidates imported communication review")

    let actualTimestamp = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-3600))
    let timed = prepare(); _ = try store.command("communication.prepare",timed); try update(timed,"handoff_opened")
    try fail("communication.update",["id":timed["id"]!,"state":"user_confirmed_sent","phone":phone,"body":text,"confirmed":true,"occurredAt":ISO8601DateFormatter().string(from:Date().addingTimeInterval(3600))],"future exact timestamp rejected")
    try update(timed,"user_confirmed_sent",["phone":phone,"body":text,"confirmed":true,"occurredAt":actualTimestamp])
    try check(try store.get("activities","communication-" + (timed["id"] as! String).lowercased())["date"] as? String == actualTimestamp,"exact sent timestamp survives activity readback")
    try update(timed,"user_confirmed_sent",["phone":phone,"body":text,"confirmed":true,"occurredAt":actualTimestamp])

    let linkedDraft: Record = ["id":"linked-fixture","agentId":"fixture-manual","channel":"Message","body":text,"state":"draft","approvalState":"pending_review"]
    try store.put("drafts",linkedDraft)
    let linked = prepare(["draftId":"linked-fixture"])
    _ = try store.command("communication.prepare",linked)
    try check(try store.get("communications",linked["id"] as! String)["draftId"] as? String == "linked-fixture","attempt retains linked draft identity")
    try fail("communication.prepare",prepare(["draftId":"linked-fixture","body":"Changed wording"]),"linked draft must match exact body")
    var paused = linkedDraft; paused["approvalState"] = "paused_reply"; try store.put("drafts",paused)
    try fail("communication.update",["id":linked["id"]!,"state":"handoff_opened"],"reply pause arriving after review blocks handoff")
    try fail("communication.prepare",prepare(["draftId":"linked-fixture"]),"paused linked draft cannot prepare another send")
    paused["approvalState"] = "rejected"; try store.put("drafts",paused)
    try fail("communication.prepare",prepare(["draftId":"linked-fixture"]),"rejected linked draft cannot prepare a send")

    try store.put("drafts",linkedDraft)
    let sentLinked = prepare(["draftId":"linked-fixture"])
    _ = try store.command("communication.prepare",sentLinked); try update(sentLinked,"handoff_opened")
    let linkedConfirmation: Record = ["phone":phone,"body":text,"confirmed":true,"occurredAt":actualTimestamp]
    try update(sentLinked,"user_confirmed_sent",linkedConfirmation)
    let sentDraft = try store.get("drafts","linked-fixture")
    try check(sentDraft["state"] as? String == "sent" && sentDraft["sentAt"] as? String == actualTimestamp,"exact confirmed linked draft becomes sent with actual timestamp")
    let sentTasks = try store.all("tasks").filter { $0["draftId"] as? String == "linked-fixture" }
    try check(sentTasks.count == 1 && sentTasks[0]["completed"] as? Bool == false && (sentTasks[0]["title"] as? String)?.hasPrefix("Message sent") == true,"sent draft review task stays open with honest outcome wording")
    try update(sentLinked,"user_confirmed_sent",linkedConfirmation)
    try check(try store.all("tasks").filter { $0["draftId"] as? String == "linked-fixture" }.count == 1,"confirmation replay does not duplicate review task")

    var changedDraft = linkedDraft; changedDraft["id"] = "changed-after-handoff"
    try store.put("drafts",changedDraft)
    let changedAttempt = prepare(["draftId":"changed-after-handoff"])
    _ = try store.command("communication.prepare",changedAttempt); try update(changedAttempt,"handoff_opened")
    changedDraft["body"] = "A newer unsent draft"; try store.put("drafts",changedDraft)
    try update(changedAttempt,"user_confirmed_sent",linkedConfirmation)
    try check(try store.get("drafts","changed-after-handoff")["state"] as? String == "draft","confirmation of prior text cannot mark edited wording sent")
    try check(try store.get("communications",changedAttempt["id"] as! String)["draftReconciliationState"] as? String == "changed_draft","changed-draft reconciliation reason is retained")

    var deliveredDraft = linkedDraft; deliveredDraft["id"] = "provider-linked"
    try store.put("drafts",deliveredDraft)
    let deliveredAttempt = prepare(["draftId":"provider-linked","transport":"telnyx","sender":sender])
    let linkedProviderId = UUID().uuidString
    _ = try store.command("communication.prepare",deliveredAttempt); try update(deliveredAttempt,"submitting")
    try update(deliveredAttempt,"accepted",["providerId":linkedProviderId])
    try check(try store.get("drafts","provider-linked")["state"] as? String == "draft","queued provider acceptance does not falsely mark draft sent")
    try update(deliveredAttempt,"delivered",["providerId":linkedProviderId,"occurredAt":actualTimestamp])
    try update(deliveredAttempt,"delivered",["providerId":linkedProviderId,"occurredAt":actualTimestamp])
    try check(try store.get("drafts","provider-linked")["state"] as? String == "sent","exact provider delivery reconciles linked draft once")

    var heldDraft = linkedDraft; heldDraft["id"] = "paused-after-handoff"
    try store.put("drafts",heldDraft)
    let heldAttempt = prepare(["draftId":"paused-after-handoff"])
    _ = try store.command("communication.prepare",heldAttempt); try update(heldAttempt,"handoff_opened")
    heldDraft["approvalState"] = "paused_reply"; try store.put("drafts",heldDraft)
    try update(heldAttempt,"user_confirmed_sent",linkedConfirmation)
    try check(try store.get("drafts","paused-after-handoff")["state"] as? String == "draft","late confirmation preserves a paused draft hold")

    print("PASS: communication validation, sample/DNC blocks, recipient/body confirmation, retry and transition safety, provider reconciliation, exactly-once interactions and persistence; no calls or messages sent.")
}
