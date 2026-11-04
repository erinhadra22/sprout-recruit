import Foundation

// Disposable persistence fixtures only: no Messages automation, URLs, permissions,
// provider connections or production workspace are used by these checks.
func runOutboxTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-outbox-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let prepared = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
    let replyTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
    let oldReply = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-900))
    let sender = "+12025550999"
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message: "Outbox test failed: " + message) }
    }
    func rejected(_ message: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch { return }
        throw StoreError(message: "Outbox test failed: " + message)
    }
    func fixture(_ label: String) throws -> Store {
        let store = try Store(path: directory.appendingPathComponent(label + ".sqlite").path, seed: false)
        try store.transaction {
            try store.setOutboxConnection(["enabled":true, "accountId":"fixture-imessage", "accountLabel":sender])
        }
        return store
    }
    func draft(_ store: Store, _ number: Int = 1, changes: Record = [:]) throws -> Record {
        let aid = "fixture-contact-" + String(number), did = "fixture-draft-" + String(number)
        let phone = "+1202555" + String(format: "%04d", number)
        try store.put("agents", ["id":aid, "name":"Fixture Contact \(number)", "source":"Manual contact", "manual":true,
            "datasetId":"live", "phone":phone, "status":"Identified"])
        var saved: Record = ["id":did, "agentId":aid, "channel":"Message", "state":"draft", "body":"Fixture \(number), never actually sent.",
            "createdAt":prepared, "updatedAt":prepared]
        for (key,value) in changes { saved[key] = value }
        try store.put("drafts", saved)
        return ["id":UUID().uuidString.lowercased(), "draftId":did, "agentId":aid, "phone":phone, "body":saved["body"]!, "confirmed":true]
    }
    func enqueue(_ store: Store, _ request: Record) throws { try store.transaction { try store.enqueueOutbox(request) } }
    func claim(_ store: Store) throws -> Record? { try store.transaction { try store.claimNextOutbox() } }
    func finish(_ store: Store, _ job: Record, _ state: String, extra: Record = [:]) throws {
        var p: Record = ["id":job["id"]!, "claimToken":job["claimToken"]!, "state":state]
        for (key,value) in extra { p[key] = value }
        try store.transaction { try store.finishOutbox(p) }
    }
    func outcome(_ store: Store, _ job: Record, _ state: String, extra: Record = [:]) throws {
        var p: Record = ["id":job["id"]!, "state":state, "phone":job["phone"]!, "body":job["body"]!, "confirmed":true, "occurredAt":replyTime]
        for (key,value) in extra { p[key] = value }
        try store.transaction { try store.confirmOutbox(p) }
    }
    func state(_ store: Store, _ request: Record) throws -> String { try store.get("outboxJobs", request["id"] as! String)["state"] as? String ?? "missing" }
    func resume(_ store: Store, _ request: Record) throws {
        try store.transaction { try store.resumeOutbox(["id":request["id"]!, "phone":request["phone"]!, "body":request["body"]!, "confirmed":true]) }
    }
    func importReply(_ store: Store, _ request: Record, _ time: String, _ id: String) throws {
        try store.transaction {
            try store.importExternalMessage(["agentId":request["agentId"]!, "channel":"Message", "provider":"apple-messages",
                "accountAddress":sender, "providerMessageId":id, "providerThreadId":"fixture-thread-" + id,
                "direction":"inbound", "from":request["phone"]!, "to":sender, "occurredAt":time, "body":"Fixture reply, never received."])
        }
    }

    let serial = try fixture("serial")
    var requests = [Record]()
    for number in 1...20 { let p = try draft(serial, number); try enqueue(serial, p); requests.append(p) }
    try check(try serial.all("outboxJobs").count == 20, "twenty rapid enqueues create exactly twenty durable jobs")
    try check(try serial.all("activities").isEmpty, "queueing never claims an interaction occurred")
    let initialEvents = try serial.all("outboxEvents").count
    try enqueue(serial, requests[0])
    try check(try serial.all("outboxEvents").count == initialEvents, "enqueue replay is harmless")
    var changedID = requests[0]; changedID["body"] = "Different authorized body"
    try rejected("reject reuse of job ID with different text") { try enqueue(serial, changedID) }
    var sameBody = requests[0]; sameBody["id"] = UUID().uuidString.lowercased()
    try rejected("a new job ID cannot duplicate unresolved text") { try enqueue(serial, sameBody) }
    for index in 0..<20 {
        guard let job = try claim(serial) else { throw StoreError(message: "Outbox test failed: expected serial claim") }
        try check(job["id"] as? String == requests[index]["id"] as? String, "queue order is stable even within one timestamp")
        try check(job["sequenceNumber"] as? Int == index + 1 && job["attemptCount"] as? Int == 1, "sequence and attempt counts are durable")
        try check(try claim(serial) == nil, "only one native send is claimed at a time")
        try finish(serial, job, "submitted")
        try finish(serial, job, "submitted")
        try check(try serial.get("drafts", job["draftId"] as! String)["state"] as? String == "draft", "submission is never promoted to sent")
    }
    try check(try serial.all("outboxEvents").count == 60, "enqueue, claim and submission append exactly one event each")
    try check(try serial.all("activities").isEmpty, "Apple event submission is not a sent interaction")
    try check(try serial.all("tasks").count == 20 && serial.all("tasks").allSatisfy { $0["completed"] as? Bool == false }, "submission keeps exactly one existing review task actionable per draft")
    try enqueue(serial, requests[0])
    try check(try state(serial, requests[0]) == "submitted", "enqueue replay never requeues a submitted send")
    try rejected("sent or submitted text cannot be duplicated") { try enqueue(serial, sameBody) }

    let validation = try fixture("validation")
    for (number, approval) in [(1,"paused_reply"), (2,"rejected"), (3,"blocked_contact")] {
        let p = try draft(validation, number, changes: ["approvalState":approval])
        try rejected("paused, rejected and blocked drafts are not sendable") { try enqueue(validation, p) }
    }
    let invalid = try draft(validation, 4)
    for delta: Record in [["phone":"+12025550099"], ["body":"Changed draft"], ["confirmed":false], ["id":"invalid"], ["token":"credential-must-not-persist"], ["expectedUpdatedAt":oldReply]] {
        var p = invalid; for (key,value) in delta { p[key] = value }
        try rejected("invalid requests are rejected before persistence") { try enqueue(validation, p) }
    }
    var imported = try validation.get("agents", invalid["agentId"] as! String); imported["manual"] = false
    try validation.put("agents", imported)
    try rejected("unreviewed imported identity is not sendable") { try enqueue(validation, invalid) }
    imported["communicationVerification"] = ["confirmed":true, "name":imported["name"]!, "source":imported["source"]!, "phone":invalid["phone"]!]
    try validation.put("agents", imported)
    try enqueue(validation, invalid)
    var changedSource = imported; changedSource["source"] = "Changed source"
    try validation.put("agents", changedSource)
    try check(try claim(validation) == nil && state(validation, invalid) == "held", "a changed imported source invalidates authorization")
    try check(try validation.get("outboxJobs", invalid["id"] as! String)["reasonCode"] as? String == "contact_unreviewed", "held queue provides an actionable reason")

    var versioned = try draft(validation, 5); versioned["expectedUpdatedAt"] = prepared
    try enqueue(validation, versioned); try enqueue(validation, versioned)
    var replayRevision = versioned; replayRevision["expectedUpdatedAt"] = replyTime
    try rejected("same queue ID cannot be replayed for a different expected draft revision") { try enqueue(validation, replayRevision) }

    let changes = try fixture("changed-drafts")
    let changedPhone = try draft(changes, 1), changedBody = try draft(changes, 2), terminal = try draft(changes, 3), valid = try draft(changes, 4)
    for request in [changedPhone, changedBody, terminal, valid] { try enqueue(changes, request) }
    var contact = try changes.get("agents", changedPhone["agentId"] as! String); contact["phone"] = "+12025550888"; try changes.put("agents", contact)
    var edited = try changes.get("drafts", changedBody["draftId"] as! String); edited["body"] = "Edited after authorization"; try changes.put("drafts", edited)
    var closed = try changes.get("agents", terminal["agentId"] as! String); closed["status"] = "Recruited"; try changes.put("agents", closed)
    let afterHolds = try claim(changes)
    try check(afterHolds?["id"] as? String == valid["id"] as? String, "invalid queued jobs are held without blocking later eligible jobs")
    for request in [changedPhone, changedBody, terminal] { try check(try state(changes, request) == "held", "changed recipient, draft and terminal contact are held") }
    try rejected("a changed body cannot be silently resumed") { try resume(changes, changedBody) }
    try rejected("cancellation is too late after dispatch starts") { try changes.transaction { try changes.cancelOutbox(["id":valid["id"]!]) } }
    try changes.transaction { try changes.cancelOutbox(["id":changedBody["id"]!]); try changes.cancelOutbox(["id":changedBody["id"]!]) }
    try check(try state(changes, changedBody) == "cancelled", "pre-dispatch cancellation is idempotent")

    let identity = try fixture("sender-identity")
    let original = try draft(identity)
    try enqueue(identity, original)
    try identity.transaction { try identity.setOutboxConnection(["enabled":true, "accountId":"other-account", "accountLabel":"other@example.invalid"]) }
    try check(try claim(identity) == nil && state(identity, original) == "held", "sender change holds previously authorized jobs")
    try rejected("sender changes require a new authorized job") { try resume(identity, original) }
    try identity.transaction { try identity.cancelOutbox(["id":original["id"]!]); try identity.setOutboxConnection(["enabled":false]) }
    var newIdentityJob = original; newIdentityJob["id"] = UUID().uuidString.lowercased()
    try rejected("an unconnected sender cannot enqueue") { try enqueue(identity, newIdentityJob) }

    let services = try fixture("explicit-service")
    try check(try services.get("settings", "imessage")["service"] as? String == "iMessage", "legacy connection calls explicitly persist the iMessage default")
    let imessageRequest = try draft(services)
    try enqueue(services, imessageRequest)
    try check(try services.get("outboxJobs", imessageRequest["id"] as! String)["senderService"] as? String == "iMessage", "legacy enqueue freezes iMessage rather than an implicit service")
    // Simulate a pre-service persisted job and setting without changing its
    // original request. Its replay and dispatch remain iMessage-only.
    var legacyJob = try services.get("outboxJobs", imessageRequest["id"] as! String)
    var legacyRequest = legacyJob["request"] as! Record; legacyRequest.removeValue(forKey:"expectedService")
    legacyJob["request"] = legacyRequest; legacyJob.removeValue(forKey:"expectedService"); legacyJob.removeValue(forKey:"senderService")
    try services.put("outboxJobs", legacyJob)
    var legacyConnection = try services.get("settings", "imessage"); legacyConnection.removeValue(forKey:"service")
    try services.put("settings", legacyConnection)
    try enqueue(services, imessageRequest)
    let legacyClaim = try claim(services)!
    try check(legacyClaim["id"] as? String == imessageRequest["id"] as? String && legacyClaim["senderService"] as? String == "iMessage",
              "legacy saved jobs and settings remain dispatchable only as explicitly frozen iMessage")
    try finish(services, legacyClaim, "failed", extra:["dispatchStarted":false])
    try services.transaction { try services.setOutboxConnection(["enabled":true, "accountId":"fixture-imessage", "accountLabel":sender, "service":"SMS"]) }
    var smsRequest = try draft(services, 2)
    try rejected("legacy enqueue cannot silently authorize the newly selected SMS service") { try enqueue(services, smsRequest) }
    var staleService = smsRequest; staleService["expectedService"] = "iMessage"
    try rejected("a stale UI service selection cannot enqueue through SMS") { try enqueue(services, staleService) }
    smsRequest["expectedService"] = "SMS"
    try enqueue(services, smsRequest); try enqueue(services, smsRequest)
    let smsSaved = try services.get("outboxJobs", smsRequest["id"] as! String)
    try check(smsSaved["senderService"] as? String == "SMS" && (smsSaved["request"] as? Record)?["expectedService"] as? String == "SMS",
              "explicit SMS authorization is frozen in both job and immutable request")
    var serviceReplay = smsRequest; serviceReplay["expectedService"] = "iMessage"
    try rejected("same job ID cannot be reused with a different service") { try enqueue(services, serviceReplay) }
    try rejected("a connection cannot enable unknown RCS service") {
        try services.transaction { try services.setOutboxConnection(["enabled":true, "accountId":"fixture-imessage", "accountLabel":sender, "service":"RCS"]) }
    }
    var unsupportedRequest = try draft(services, 3); unsupportedRequest["expectedService"] = "RCS"
    try rejected("unsupported services cannot enter the text queue") { try enqueue(services, unsupportedRequest) }
    try check(try services.get("settings", "imessage")["service"] as? String == "SMS", "invalid service configuration preserves the prior verified selection")
    try services.transaction { try services.setOutboxConnection(["enabled":true, "accountId":"fixture-imessage", "accountLabel":sender, "service":"iMessage"]) }
    try check(try claim(services) == nil && state(services, smsRequest) == "held", "changing service on the same account still holds the authorized SMS job")
    try check(try services.get("outboxJobs", smsRequest["id"] as! String)["reasonCode"] as? String == "service_changed", "service-change hold supplies its precise reason")
    try rejected("a service mismatch cannot be implicitly resumed") { try resume(services, smsRequest) }

    let serviceRace = try fixture("service-change-after-claim")
    try serviceRace.transaction { try serviceRace.setOutboxConnection(["enabled":true, "accountId":"fixture-imessage", "accountLabel":sender, "service":"SMS"]) }
    var smsClaimRequest = try draft(serviceRace); smsClaimRequest["expectedService"] = "SMS"
    try enqueue(serviceRace, smsClaimRequest)
    let smsClaim = try claim(serviceRace)!
    try check(smsClaim["senderService"] as? String == "SMS", "native dispatch receives the frozen explicit SMS service")
    try serviceRace.transaction { try serviceRace.setOutboxConnection(["enabled":true, "accountId":"fixture-imessage", "accountLabel":sender, "service":"iMessage"]) }
    try rejected("service change after claim is caught by immediate pre-dispatch validation") {
        try serviceRace.transaction { try serviceRace.revalidateOutboxClaim(["id":smsClaim["id"]!, "claimToken":smsClaim["claimToken"]!]) }
    }

    let restart = try fixture("restart")
    let interrupted = try draft(restart, 1), waiting = try draft(restart, 2)
    try enqueue(restart, interrupted); try enqueue(restart, waiting)
    let claimed = try claim(restart)!
    let reopened = try Store(path: restart.path, seed: false)
    try reopened.transaction { try reopened.recoverOutbox() }
    try check(try state(reopened, interrupted) == "unknown" && state(reopened, waiting) == "paused_restart", "restart never redispatches a sending or queued job")
    let recoveredCount = try reopened.all("outboxEvents").count
    try reopened.transaction { try reopened.recoverOutbox() }
    try check(try reopened.all("outboxEvents").count == recoveredCount && claim(reopened) == nil, "recovery replay has no effects and leaves queue paused")
    try rejected("unknown jobs cannot resume") { try resume(reopened, interrupted) }
    try rejected("stale completion cannot resolve a recovered unknown job") { try finish(reopened, claimed, "submitted") }
    var duplicateUnknown = interrupted; duplicateUnknown["id"] = UUID().uuidString.lowercased()
    try rejected("unknown outcomes block a new attempt") { try enqueue(reopened, duplicateUnknown) }
    try outcome(reopened, claimed, "not_sent")
    try outcome(reopened, claimed, "not_sent")
    try check(try reopened.all("activities").isEmpty, "not-sent confirmation creates no interaction")
    try enqueue(reopened, duplicateUnknown)
    try check(try state(reopened, duplicateUnknown) == "queued", "explicit not-sent reconciliation allows a deliberate new attempt")
    try resume(reopened, waiting)
    try check(try claim(reopened)?["id"] as? String == waiting["id"] as? String, "explicit resume preserves original queue order")

    let results = try fixture("dispatch-outcomes")
    let resultRequest = try draft(results)
    try enqueue(results, resultRequest)
    let resultJob = try claim(results)!
    try rejected("a possibly dispatched failure must be unknown") { try finish(results, resultJob, "failed") }
    try rejected("a different native worker token cannot finish the job") {
        try results.transaction { try results.finishOutbox(["id":resultJob["id"]!, "claimToken":UUID().uuidString, "state":"submitted"]) }
    }
    try finish(results, resultJob, "unknown", extra:["errorCode":"fixture_timeout"])
    try rejected("an unknown job cannot simply be marked failed later") { try finish(results, resultJob, "failed", extra:["dispatchStarted":false]) }
    try rejected("confirmation requires exact recipient") { try outcome(results, resultJob, "user_confirmed_sent", extra:["phone":"+12025550098"]) }
    try rejected("confirmation requires exact text") { try outcome(results, resultJob, "user_confirmed_sent", extra:["body":"different body"]) }
    try rejected("confirmation cannot be future-dated") { try outcome(results, resultJob, "user_confirmed_sent", extra:["occurredAt":ISO8601DateFormatter().string(from:Date().addingTimeInterval(1000))]) }
    try outcome(results, resultJob, "user_confirmed_sent")
    try outcome(results, resultJob, "user_confirmed_sent")
    let interactions = try results.all("activities")
    try check(interactions.count == 1 && interactions[0]["confirmationSource"] as? String == "user", "confirmed sent creates one user-attributed immutable interaction")
    try check(interactions[0]["occurredAt"] as? String == replyTime, "confirmation preserves actual occurrence time")
    try check(try results.get("drafts", resultJob["draftId"] as! String)["state"] as? String == "sent", "exact sent draft reconciles after confirmation")
    try check(try results.all("tasks").count == 1 && results.all("tasks")[0]["completed"] as? Bool == false, "confirmed send leaves explicit outcome review actionable")
    try check(try results.get("agents", resultJob["agentId"] as! String)["status"] as? String == "Identified", "send confirmation never changes recruiting status")
    try rejected("a recorded user outcome cannot be silently rewritten") { try outcome(results, resultJob, "not_sent") }
    try rejected("sent confirmation replay cannot revise its timestamp") { try outcome(results, resultJob, "user_confirmed_sent", extra:["occurredAt":oldReply]) }
    let failureRequest = try draft(results, 2); try enqueue(results, failureRequest)
    let failureJob = try claim(results)!
    try finish(results, failureJob, "failed", extra:["dispatchStarted":false, "errorCode":"permission_missing"])
    var retry = failureRequest; retry["id"] = UUID().uuidString.lowercased()
    try enqueue(results, retry)
    try check(try state(results, retry) == "queued", "known pre-dispatch failure permits only an explicit new attempt")

    let completedReview = try fixture("completed-review")
    let completedRequest = try draft(completedReview)
    var initialTask = try completedReview.all("tasks")[0]; initialTask["completed"] = true; try completedReview.put("tasks", initialTask)
    try enqueue(completedReview, completedRequest)
    let completedJob = try claim(completedReview)!
    try finish(completedReview, completedJob, "unknown")
    var unknownTask = try completedReview.all("tasks").first { $0["completed"] as? Bool != true }!
    unknownTask["completed"] = true; try completedReview.put("tasks", unknownTask)
    try outcome(completedReview, completedJob, "user_confirmed_sent")
    try check(try completedReview.get("tasks", unknownTask["id"] as! String)["completed"] as? Bool == true,
              "new outcome review never rewrites a previous task completion")
    try check(try completedReview.all("tasks").filter { $0["completed"] as? Bool != true }.count == 1,
              "a later confirmed outcome has one fresh open review when previous reviews completed")

    let legacyTimestamp = try fixture("legacy-draft-timestamp")
    let legacyDraftRequest = try draft(legacyTimestamp)
    var legacyDraft = try legacyTimestamp.get("drafts", legacyDraftRequest["draftId"] as! String)
    legacyDraft.removeValue(forKey:"updatedAt"); try legacyTimestamp.put("drafts", legacyDraft)
    try enqueue(legacyTimestamp, legacyDraftRequest)
    try check(try claim(legacyTimestamp) != nil, "a draft with known creation time consistently uses that revision fallback")

    let replies = try fixture("reply-race")
    let final = try draft(replies, changes:["sequenceId":"fixture-final-sequence"])
    try replies.put("sequences", ["id":"fixture-final-sequence", "agentId":final["agentId"]!, "state":"completed", "createdAt":prepared])
    try importReply(replies, final, oldReply, "old-reply")
    try enqueue(replies, final)
    try importReply(replies, final, replyTime, "new-reply")
    try check(try state(replies, final) == "held" && claim(replies) == nil, "a new reply holds the final queued sequence draft even after step preparation completed")
    let replyEvents = try replies.all("outboxEvents").count
    try importReply(replies, final, replyTime, "new-reply")
    try check(try replies.all("outboxEvents").count == replyEvents, "replayed inbound import does not duplicate outbox events")
    try rejected("a reply-held draft cannot resume without new review") { try resume(replies, final) }
    let claimReply = try fixture("claim-reply-check")
    let unpaused = try draft(claimReply); try enqueue(claimReply, unpaused)
    try claimReply.put("externalMessages", ["id":"fixture-imported-reply", "agentId":unpaused["agentId"]!, "channel":"Email", "direction":"inbound", "occurredAt":replyTime])
    try check(try claim(claimReply) == nil && state(claimReply, unpaused) == "held", "claim independently observes newer cross-channel replies without a sequence state change")

    let preflightReply = try fixture("reply-during-preflight")
    let preflightRequest = try draft(preflightReply); try enqueue(preflightReply, preflightRequest)
    let preflightJob = try claim(preflightReply)!
    let claimIdentity: Record = ["id":preflightJob["id"]!, "claimToken":preflightJob["claimToken"]!]
    try preflightReply.transaction { try preflightReply.revalidateOutboxClaim(claimIdentity) }
    try importReply(preflightReply, preflightRequest, replyTime, "reply-during-preflight")
    try rejected("reply arriving after claim still blocks immediate pre-dispatch validation") {
        try preflightReply.transaction { try preflightReply.revalidateOutboxClaim(claimIdentity) }
    }
    try finish(preflightReply, preflightJob, "failed", extra:["dispatchStarted":false, "errorCode":"revalidation_failed"])
    try check(try state(preflightReply, preflightRequest) == "failed", "worker can record a known no-dispatch failure after preflight revalidation fails")

    let history = try fixture("existing-history")
    let legacy = try draft(history, 1), importedMessage = try draft(history, 2)
    try history.put("communications", ["id":"fixture-legacy", "channel":"message", "transport":"apple-messages", "phone":legacy["phone"]!, "body":legacy["body"]!, "state":"handoff_opened"])
    try rejected("earlier composer attempt needs outcome reconciliation") { try enqueue(history, legacy) }
    try history.transaction {
        try history.importExternalMessage(["agentId":importedMessage["agentId"]!, "channel":"Message", "provider":"apple-messages",
            "accountAddress":sender, "providerMessageId":"fixture-outbound", "providerThreadId":"fixture-thread-outbound",
            "direction":"outbound", "from":sender, "to":importedMessage["phone"]!, "occurredAt":replyTime, "body":importedMessage["body"]!])
    }
    try rejected("imported exact sent text cannot be resent under a fresh job ID") { try enqueue(history, importedMessage) }

    let event = try results.all("outboxEvents").first!
    let eventID = event["id"] as! String
    try rejected("event acknowledgements roll back as a unit if an ID is missing") {
        try results.transaction { try results.acknowledgeOutboxEvents(["ids":[eventID,"missing-event"]]) }
    }
    try check(try results.get("outboxEvents", eventID)["acknowledgedAt"] == nil, "failed batch does not silently acknowledge an outcome")
    try results.transaction { try results.acknowledgeOutboxEvents(["ids":[eventID,eventID]]) }
    let receipt = try results.get("outboxEvents", eventID)["acknowledgedAt"] as? String
    try results.transaction { try results.acknowledgeOutboxEvents(["ids":[eventID]]) }
    try check(receipt != nil && results.get("outboxEvents", eventID)["acknowledgedAt"] as? String == receipt, "acknowledgement is durable and idempotent")
    let status = try results.outboxStatus()
    try check(status["jobs"] is [Record] && status["events"] is [Record] && status["connection"] is Record, "route-independent status includes durable jobs, notifications and connection")
    print("PASS: durable serial text outbox, twenty enqueues, exact authorization, replay/unknown/restore safety, reply holds, outcome evidence and notification receipts.")
}
