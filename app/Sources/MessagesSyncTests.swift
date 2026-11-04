import Foundation

func runMessagesSyncTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-messages-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let phone = "+12025550123", otherPhone = "+12025550456"
    let now = Date(), floor = ISO8601DateFormatter().string(from:now.addingTimeInterval(-600))
    let occurred = ISO8601DateFormatter().string(from:now.addingTimeInterval(-120))
    let prepared = ISO8601DateFormatter().string(from:now.addingTimeInterval(-300))
    func check(_ condition: Bool,_ message: String) throws {
        if !condition { throw StoreError(message:"Messages sync test failed: " + message) }
    }
    func rejects(_ message: String,_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw StoreError(message:"Messages sync test failed: expected rejection: " + message)
    }
    func contact(_ store: Store,_ id: String = "a",_ number: String? = nil) throws {
        try store.put("agents",["id":id,"name":"Fixture " + id,"source":"Manual contact","manual":true,"datasetId":"live","phone":number ?? phone,"status":"Identified"])
    }
    func fixture(_ label: String) throws -> Store {
        let store = try Store(path:directory.appendingPathComponent(label + ".sqlite").path,seed:false)
        try contact(store)
        return store
    }
    func enable(_ store: Store) throws {
        try store.transaction { try store.configureMessagesSync(["enabled":true,"confirmed":true]) }
        // Fixture-only clock setup. Production enable always uses the current time.
        var setting = try store.get("settings","messages-reply-sync"); setting["since"] = floor
        try store.put("settings",setting)
    }
    func row(_ number: Int = 1,_ guid: String = "message-guid",_ changes: Record = [:]) -> Record {
        var r: Record = ["providerMessageId":guid,"providerThreadId":"iMessage;-;" + phone,"phone":phone,
            "occurredAt":occurred,"body":"A private fixture reply.","bodyKind":"text","service":"iMessage",
            "sourceRowID":number,"direction":"inbound","isGroup":false]
        for (key,value) in changes { r[key] = value }; return r
    }
    func batch(_ rows: [Record], after: Int = 0, next: Int = 10, source: String = "fixture-source-A", hasMore: Bool = false) -> Record {
        ["sourceID":source,"scannedFromRowID":after,"nextRowID":next,"hasMore":hasMore,"scannedCount":max(rows.count,next-after),"messages":rows]
    }
    func apply(_ store: Store,_ request: Record,_ page: Record) throws {
        try store.transaction { try store.applyMessagesSyncBatch(request:request,batch:page) }
    }

    let initial = try fixture("initial")
    try check(try initial.messagesSyncStatus()["enabled"] as? Bool == false, "reply sync starts disabled")
    try rejects("first enable needs explicit confirmation") { try initial.transaction { try initial.configureMessagesSync(["enabled":true]) } }
    try initial.transaction { try initial.configureMessagesSync(["enabled":true,"confirmed":true]) }
    let enabled = try initial.messagesSyncStatus()
    try check(Store.activityEventDate(enabled["since"] as? String ?? "").map { $0 >= now.addingTimeInterval(-2) } == true, "first enable begins at current time rather than importing old history")
    let initialRequest = try initial.messagesSyncReadRequest()
    try apply(initial,initialRequest,batch([row()]))
    try check(try initial.all("externalMessages").isEmpty && initial.messagesSyncStatus()["cursor"] as? Int == 10, "pre-opt-in history stays excluded while scan cursor progresses")

    let store = try fixture("success"); try enable(store)
    let request = try store.messagesSyncReadRequest(), page = batch([row()])
    try apply(store,request,page)
    let saved = try store.all("externalMessages")[0], savedID = saved["id"] as! String
    try check(saved["providerMessageId"] as? String == "message-guid" && saved["providerThreadId"] as? String == "iMessage;-;" + phone, "actual provider and conversation GUIDs are retained")
    try check(saved["accountAddress"] is NSNull && saved["to"] is NSNull && saved["accountScope"] as? String == "local-messages", "unknown receiving account is honest and never invented")
    try check(try store.get("agents","a")["status"] as? String == "Identified", "reply sync leaves recruiting status unchanged")
    let review = try store.all("tasks").filter { $0["reviewKind"] as? String == "messages-sync-reply" }
    try check(review.count == 1 && review[0]["externalMessageId"] as? String == savedID && review[0]["completed"] as? Bool == false, "new reply creates one verified contact review task")
    try check(!(review[0]["description"] as? String ?? "").contains("private fixture reply"), "review task references evidence without copying private body")
    try apply(store,request,page)
    try check(try store.all("externalMessages").count == 1 && store.all("tasks").count == 1 && store.messagesSyncStatus()["importedReplies"] as? Int == 1, "exact apply replay is idempotent")
    let replacementRequest = try store.messagesSyncReadRequest()
    try apply(store,replacementRequest,batch([row(1)],next:2,source:"replacement-source"))
    try check(try store.all("externalMessages").count == 1 && store.messagesSyncStatus()["cursor"] as? Int == 2, "database replacement resets row cursor and deduplicates immutable GUID content")
    try check((try store.get("externalMessages",savedID)["nativeSourceObservations"] as? [Record])?.count == 2, "replacement database provenance is separate from immutable message content")
    let reopened = try Store(path:store.path,seed:false)
    try check(try reopened.messagesSyncReadRequest()["afterRowID"] as? Int == 2 && reopened.messagesSyncStatus()["since"] as? String == floor, "cursor and initial floor survive reopening")

    let inflight = try reopened.messagesSyncReadRequest(), generation = inflight["generation"] as! Int
    try reopened.transaction { try reopened.configureMessagesSync(["enabled":false]) }
    try rejects("disabled in-flight page cannot be applied") { try apply(reopened,inflight,batch([row(3,"disabled-reply")],after:2,next:3,source:"replacement-source")) }
    try reopened.transaction { try reopened.recordMessagesSyncFailure(["generation":generation,"errorCode":"permission_denied","message":"Old failure."]) }
    try check(try reopened.messagesSyncStatus()["status"] as? String == "disabled" && reopened.all("externalMessages").count == 1, "stale failure cannot undo pause or import a reply")
    try reopened.transaction { try reopened.configureMessagesSync(["enabled":true,"confirmed":true]) }
    let resumed = try reopened.messagesSyncReadRequest()
    try check(resumed["since"] as? String == floor && resumed["afterRowID"] as? Int == 2 && resumed["generation"] as? Int != generation, "resume catches up from cursor and original floor with new generation")

    let ambiguity = try fixture("ambiguous"); try contact(ambiguity,"b"); try enable(ambiguity)
    for aid in ["a","b"] { try ambiguity.put("sequences",["id":"ambiguous-sequence-" + aid,"agentId":aid,"state":"active","createdAt":prepared]) }
    let ambiguousRequest = try ambiguity.messagesSyncReadRequest()
    try check(ambiguousRequest["phones"] as? [String] == [phone] && ambiguity.messagesSyncStatus()["ambiguousCandidateCount"] as? Int == 2, "each phone is requested once and duplicate candidates are visible")
    try apply(ambiguity,ambiguousRequest,page)
    try check(try ambiguity.all("externalMessages").isEmpty, "shared phone never attaches reply to guessed contact")
    let ambiguityTasks = try ambiguity.all("tasks")
    try check(ambiguityTasks.count == 1 && ambiguityTasks[0]["agentId"] == nil && (ambiguityTasks[0]["candidateIDs"] as? [String]) == ["a","b"], "ambiguity creates one general task with exact candidate IDs")
    try check(try ambiguity.messagesSyncHoldReason(phone:phone,draftCreatedAt:prepared) != nil
              && ambiguity.messagesSyncHoldReason(phone:phone,draftCreatedAt:Store.now()) != nil,
              "ambiguous reply blocks both queued and newly prepared texts to the unresolved phone")
    let phoneHold = try ambiguity.all("settings").first { ($0["id"] as? String ?? "").hasPrefix("messages-sync-phone-hold-") }!
    let holdJSON = String(decoding:try JSONSerialization.data(withJSONObject:phoneHold),as:UTF8.self)
    try check(phoneHold["agentId"] == nil && !holdJSON.contains("private fixture reply") && phoneHold["body"] == nil,
              "phone hold stores source metadata without assigning reply body or ownership to a candidate")
    let ambiguousSequence = try ambiguity.get("sequences","ambiguous-sequence-a")
    try check(ambiguousSequence["state"] as? String == "paused" && ambiguousSequence["pauseReason"] as? String == "ambiguous_reply_identity"
              && ambiguousSequence["replyMessageId"] == nil, "possible contacts' active sequences pause with an explicit identity reason, not an attributed reply")
    try contact(ambiguity,"b",otherPhone)
    let remapped = try ambiguity.messagesSyncReadRequest()
    try check(remapped["afterRowID"] as? Int == 0 && remapped["since"] as? String == floor, "phone corrections rewind cursor without broadening history")
    try check(try ambiguity.messagesSyncHoldReason(phone:phone,draftCreatedAt:prepared) != nil,
              "changing contact mapping alone cannot clear the phone hold")
    try apply(ambiguity,remapped,page)
    try check(try ambiguity.all("externalMessages").count == 1 && ambiguity.all("externalMessages")[0]["agentId"] as? String == "a", "resolved identity allows replayed reply to attach exactly once")
    try check(try ambiguity.messagesSyncHoldReason(phone:phone,draftCreatedAt:prepared) == nil,
              "successful exact GUID import clears its resolved phone hold")
    try check(try ambiguity.get("tasks",ambiguityTasks[0]["id"] as! String)["completed"] as? Bool == false
              && ambiguity.get("sequences","ambiguous-sequence-a")["state"] as? String == "paused",
              "source reconciliation leaves human identity review and paused sequences for explicit review")
    try contact(ambiguity,"b",phone)
    try apply(ambiguity,ambiguity.messagesSyncReadRequest(),page)
    try check(try ambiguity.messagesSyncHoldReason(phone:phone,draftCreatedAt:prepared) != nil,
              "new identity ambiguity re-establishes the phone hold even for a previously saved GUID")
    try contact(ambiguity,"b",otherPhone)
    try apply(ambiguity,ambiguity.messagesSyncReadRequest(),page)
    try check(try ambiguity.messagesSyncHoldReason(phone:phone,draftCreatedAt:prepared) == nil && ambiguity.all("externalMessages").count == 1,
              "unique exact GUID reconciliation clears the hold without duplicating saved correspondence")

    let multiple = try fixture("multiple-ambiguous-replies"); try contact(multiple,"b"); try enable(multiple)
    try apply(multiple,multiple.messagesSyncReadRequest(),batch([row(1,"ambiguous-one"),row(2,"ambiguous-two")],next:2))
    try contact(multiple,"b",otherPhone)
    try apply(multiple,multiple.messagesSyncReadRequest(),batch([row(1,"ambiguous-one")],next:1,hasMore:true))
    try check(try multiple.messagesSyncHoldReason(phone:phone,draftCreatedAt:prepared) != nil,
              "reconciling one of multiple ambiguous GUIDs keeps the other phone hold pending")
    try apply(multiple,multiple.messagesSyncReadRequest(),batch([row(2,"ambiguous-two")],after:1,next:2))
    try check(try multiple.messagesSyncHoldReason(phone:phone,draftCreatedAt:prepared) == nil,
              "phone hold clears only after every pending GUID is uniquely reconciled")

    let ambiguousOutbox = try fixture("ambiguous-outbox"); try contact(ambiguousOutbox,"b")
    try ambiguousOutbox.transaction { try ambiguousOutbox.setOutboxConnection(["enabled":true,"accountId":"fixture-account","accountLabel":"Fixture identity"]) }
    func ambiguousDraft(_ id: String,_ created: String) throws -> Record {
        let body = "Unsent ambiguity fixture " + id
        try ambiguousOutbox.put("drafts",["id":id,"agentId":"a","channel":"Message","state":"draft","body":body,"createdAt":created,"updatedAt":created])
        return ["id":UUID().uuidString.lowercased(),"agentId":"a","draftId":id,"phone":phone,"body":body,"confirmed":true]
    }
    let preflightRequest = try ambiguousDraft("before-ambiguity",prepared)
    let waitingRequest = try ambiguousDraft("queued-before-ambiguity",prepared)
    try ambiguousOutbox.transaction {
        try ambiguousOutbox.enqueueOutbox(preflightRequest)
        try ambiguousOutbox.enqueueOutbox(waitingRequest)
    }
    guard let claimed = try ambiguousOutbox.transaction({ try ambiguousOutbox.claimNextOutbox() }) else {
        throw StoreError(message:"Messages sync test failed: expected a native preflight claim")
    }
    try enable(ambiguousOutbox)
    try apply(ambiguousOutbox,ambiguousOutbox.messagesSyncReadRequest(),batch([row(1,"ambiguous-during-preflight")]))
    do {
        try ambiguousOutbox.transaction { try ambiguousOutbox.revalidateOutboxClaim(["id":claimed["id"]!,"claimToken":claimed["claimToken"]!]) }
        throw StoreError(message:"Ambiguous preflight claim unexpectedly passed")
    } catch {
        try check(error.localizedDescription.contains("multiple contacts"), "claimed job is denied specifically by unresolved phone identity")
    }
    try ambiguousOutbox.transaction {
        try ambiguousOutbox.finishOutbox(["id":claimed["id"]!,"claimToken":claimed["claimToken"]!,"state":"failed","dispatchStarted":false,"errorCode":"preflight_recheck_failed"])
    }
    let heldClaim = try ambiguousOutbox.transaction { try ambiguousOutbox.claimNextOutbox() }
    let waiting = try ambiguousOutbox.get("outboxJobs",waitingRequest["id"] as! String)
    try check(heldClaim == nil && waiting["state"] as? String == "held" && waiting["reasonCode"] as? String == "ambiguous_reply_identity",
              "already queued job transitions to explicit identity hold without being dispatched")
    let newerRequest = try ambiguousDraft("created-after-ambiguity",Store.now())
    do {
        try ambiguousOutbox.transaction { try ambiguousOutbox.enqueueOutbox(newerRequest) }
        throw StoreError(message:"New draft bypassed ambiguous phone hold")
    } catch {
        try check(error.localizedDescription.contains("multiple contacts"), "creating a newer draft cannot bypass the unresolved phone hold")
    }
    try check(try ambiguousOutbox.all("outboxJobs").count == 2 && ambiguousOutbox.all("externalMessages").isEmpty
              && ambiguousOutbox.all("activities").isEmpty && ambiguousOutbox.get("drafts","before-ambiguity")["state"] as? String == "draft",
              "ambiguity produces no sent receipt, no guessed correspondence owner, and no extra send job")

    let reassign = try fixture("no-retarget"); try enable(reassign)
    try apply(reassign,reassign.messagesSyncReadRequest(),page)
    try contact(reassign,"a",otherPhone); try contact(reassign,"b",phone)
    let changedIdentity = try reassign.messagesSyncReadRequest()
    try rejects("saved GUID cannot move to a different contact") { try apply(reassign,changedIdentity,page) }
    try check(try reassign.all("externalMessages")[0]["agentId"] as? String == "a" && reassign.messagesSyncStatus()["cursor"] as? Int == 10, "identity conflict preserves original owner and cursor")

    let atomic = try fixture("atomic"); try enable(atomic)
    let atomicRequest = try atomic.messagesSyncReadRequest()
    for changes: Record in [["direction":"outbound"],["isGroup":true],["providerMessageId":""],["sourceRowID":99],["service":"unknown"]] {
        try rejects("malformed row rejects entire page") { try apply(atomic,atomicRequest,batch([row(1,"first-valid"),row(2,"invalid",changes)])) }
        try check(try atomic.all("externalMessages").isEmpty && atomic.all("tasks").isEmpty && atomic.messagesSyncStatus()["cursor"] as? Int == 0, "failed page rolls back messages, tasks and cursor")
    }
    try contact(atomic,"new-contact",otherPhone)
    try rejects("mapping changed while reader was running") { try apply(atomic,atomicRequest,page) }
    try check(try atomic.all("externalMessages").isEmpty, "stale identity fingerprint causes no partial import")

    let failure = try fixture("failure"); try enable(failure)
    let failureGeneration = try failure.messagesSyncStatus()["generation"] as! Int
    for _ in 0..<2 { try failure.transaction { try failure.recordMessagesSyncFailure(["generation":failureGeneration,"errorCode":"permission_denied","message":"Full Disk Access is required.","status":"blocked"]) } }
    let failureTasks = try failure.all("tasks")
    try check(failureTasks.count == 1 && failureTasks[0]["agentId"] == nil && (failureTasks[0]["description"] as? String ?? "").contains("manually enable Sprout Recruit"), "permission failures create one actionable general task")
    try check(try failure.messagesSyncStatus()["cursor"] as? Int == 0, "failure never advances cursor")
    try apply(failure,failure.messagesSyncReadRequest(),batch([]))
    try check(try failure.all("tasks")[0]["completed"] as? Bool == true, "successful scan resolves only the sync failure task")

    let paged = try fixture("multi-page"); try enable(paged)
    var pagedSetting = try paged.get("settings","messages-reply-sync")
    pagedSetting["lastSuccessAt"] = floor
    try paged.put("settings",pagedSetting)
    try paged.transaction { try paged.recordMessagesSyncFailure(["generation":pagedSetting["generation"]!,"errorCode":"permission_denied","message":"Fixture prior scan failed."]) }
    let firstPageRequest = try paged.messagesSyncReadRequest()
    try apply(paged,firstPageRequest,batch([row(1,"page-one",["service":"RCS"])],next:2,hasMore:true))
    let partial = try paged.messagesSyncStatus()
    try check(partial["status"] as? String == "syncing" && partial["lastSuccessAt"] as? String == floor,
              "partial page remains syncing and cannot advance last successful scan time")
    try check(partial["newReplyCount"] as? Int == 0 && partial["pendingScanImported"] as? Int == 1,
              "partial imports accumulate without announcing a completed scan count")
    let openFailure = try paged.all("tasks").first { $0["reviewKind"] as? String == "messages-sync-error" }!
    try check(openFailure["completed"] as? Bool == false, "partial recovery leaves the sync failure task open")
    try check(try paged.all("externalMessages")[0]["service"] as? String == "RCS", "native RCS reply preserves its actual service")
    let terminalRequest = try paged.messagesSyncReadRequest()
    let terminalPage = batch([row(3,"page-two")],after:2,next:3)
    try apply(paged,terminalRequest,terminalPage)
    let finished = try paged.messagesSyncStatus()
    try check(finished["status"] as? String == "ready" && finished["lastSuccessAt"] as? String != floor
              && Store.activityEventDate(finished["lastSuccessAt"] as? String ?? "") != nil,
              "terminal page records a complete successful scan")
    try check(finished["newReplyCount"] as? Int == 2 && finished["importedReplies"] as? Int == 2
              && finished["pendingScanImported"] as? Int == 0, "completed scan aggregates new replies across pages exactly once")
    let finishedTasks = try paged.all("tasks")
    try check(finishedTasks.first { $0["reviewKind"] as? String == "messages-sync-error" }?["completed"] as? Bool == true,
              "terminal success resolves the prior sync failure task")
    let replyReviews = finishedTasks.filter { $0["reviewKind"] as? String == "messages-sync-reply" }
    try check(replyReviews.count == 2 && replyReviews.allSatisfy { $0["completed"] as? Bool == false },
              "scan recovery leaves both candidate reply reviews open")
    try apply(paged,terminalRequest,terminalPage)
    try check(try paged.messagesSyncStatus()["importedReplies"] as? Int == 2 && paged.all("externalMessages").count == 2,
              "terminal-page replay cannot inflate multi-page totals")

    let hold = try fixture("reply-holds")
    try hold.transaction { try hold.setOutboxConnection(["enabled":true,"accountId":"fixture","accountLabel":"Fixture account"]) }
    try hold.put("sequences",["id":"sequence","agentId":"a","state":"completed","createdAt":prepared])
    try hold.put("drafts",["id":"final","agentId":"a","sequenceId":"sequence","channel":"Message","state":"draft","approvalState":"approved","body":"Fixture follow-up.","createdAt":prepared,"updatedAt":prepared])
    let jobID = UUID().uuidString.lowercased()
    try hold.transaction { try hold.enqueueOutbox(["id":jobID,"agentId":"a","draftId":"final","phone":phone,"body":"Fixture follow-up.","confirmed":true]) }
    try hold.transaction { try hold.recoverOutbox() }
    try check(try hold.get("outboxJobs",jobID)["state"] as? String == "paused_restart", "fixture starts with an outstanding restart-paused job")
    try enable(hold)
    try apply(hold,hold.messagesSyncReadRequest(),batch([row(1,"pause-guid",["accountAddress":"operator@example.com"])]))
    try check(try hold.get("drafts","final")["approvalState"] as? String == "paused_reply" && hold.get("outboxJobs",jobID)["state"] as? String == "held", "native reply atomically holds final sequence output and pre-dispatch outbox job")
    try check(try hold.all("externalMessages")[0]["to"] as? String == "operator@example.com", "actual known receiving email handle is retained")
    let task = try hold.all("tasks").first { $0["reviewKind"] as? String == "messages-sync-reply" }!
    try check((task["heldOutboxJobIds"] as? [String]) == [jobID] && (task["pausedSequenceIds"] as? [String]) == ["sequence"], "reply review records exact pause outcomes")
    print("PASS: local reply sync opt-in floor, exact identity/provenance, replay, ambiguity/remapping, generation guard, restart, rollback, multi-page completion/RCS, actionable tasks and atomic follow-up holds.")
}
