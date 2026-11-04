import Foundation

func runActivityEventsTests() throws {
    func check(_ value: Bool, _ reason: String) throws {
        if !value { throw StoreError(message: "Activity integrity test failed: " + reason) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-activity-events-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("imports.sqlite").path, seed: false)
    let csv = root.appendingPathComponent("contacts.csv")
    let mappings: [Record] = [
        ["header":"Name","target":"core:name","label":"Name","type":"text"],
        ["header":"Courted Profile URL","target":"core:courtedProfileURL","label":"Profile","type":"text"],
        ["header":"Office","target":"core:office","label":"Office","type":"text"]
    ]
    func genericImport(_ office: String) throws -> Record {
        try Data("Name,Courted Profile URL,Office\nFixture Agent,https://brokerage.courted.io/agents/event-fixture,\(office)\n".utf8).write(to: csv)
        var input: Record = ["paths":[csv.path],"mappings":mappings]
        input["token"] = try store.previewGenericImport(input)["token"]
        return try store.commitGenericImport(input)
    }
    let firstReceipt = try genericImport("Oak")
    let first = try store.all("agents")[0], aid = first["id"] as! String
    var events = try store.all("activities").filter { $0["agentId"] as? String == aid }
    try check(events.count == 1 && events[0]["type"] as? String == "contact.imported", "new CSV contact has one import event")
    try check(events[0]["batchId"] as? String == firstReceipt["batchId"] as? String && events[0]["templateVersion"] as? Int == 1, "event retains batch evidence and template version")
    try check(events[0]["occurredAt"] as? String == first["importedAt"] as? String && events[0]["recordedAt"] as? String == first["importedAt"] as? String, "import occurrence is the committed local import time")
    _ = try genericImport("Oak")
    try check(try store.all("activities").count == 1 && store.all("agents").count == 1, "exact replay creates no contact or event duplicates")
    _ = try genericImport("Pine")
    events = try store.all("activities").filter { $0["agentId"] as? String == aid }
    try check(events.count == 2 && events.filter { $0["type"] as? String == "contact.import_updated" }.count == 1, "later batch updates one contact and adds one update event")
    try check(try store.get("agents",aid)["importedAt"] as? String == first["importedAt"] as? String, "update retains first import time")

    let unknownID = try store.recordContactEvent(agentId: aid, type: "contact.created", source: "historical evidence",
        occurredAt: nil, recordedAt: "2026-01-01T12:00:00Z", dedupeKey: "unknown-fixture")
    let unknown = try store.get("activities",unknownID)
    try check(unknown["occurredAt"] is NSNull && unknown["date"] is NSNull && unknown["recordedAt"] as? String == "2026-01-01T12:00:00Z", "unknown historical occurrence is not replaced with recording time")
    _ = try store.recordContactEvent(agentId: aid, type: "contact.created", source: "historical evidence",
        occurredAt: nil, recordedAt: "2026-01-02T12:00:00Z", dedupeKey: "unknown-fixture")
    try check(try store.get("activities",unknownID)["recordedAt"] as? String == "2026-01-01T12:00:00Z", "event replay preserves first recording time")
    do {
        _ = try store.recordContactEvent(agentId: aid, type: "contact.created", source: "changed evidence",
            occurredAt: nil, dedupeKey: "unknown-fixture")
        throw StoreError(message: "Conflicting event was accepted")
    } catch let error as StoreError { try check(error.message != "Conflicting event was accepted", "conflicting evidence cannot overwrite an event") }

    let courtedCSV = root.appendingPathComponent("courted.csv")
    let row = ["First Name":"Courted","Last Name":"Fixture","MLS Affiliation":"TEST","MLS ID":"00042",
               "Courted Profile URL":"https://brokerage.courted.io/cts/candidates/event-fixture"]
    try Data((CourtedCSV.headers.joined(separator:",") + "\n" + CourtedCSV.headers.map { row[$0] ?? "" }.joined(separator:",") + "\n").utf8).write(to:courtedCSV)
    var courtedInput: Record = ["paths":[courtedCSV.path]]
    courtedInput["token"] = try store.previewCourtedImport(courtedInput)["token"]
    let courtedReceipt = try store.commitCourtedImport(courtedInput)
    let courtedEvents = try store.all("activities").filter { $0["batchId"] as? String == courtedReceipt["batchId"] as? String }
    try check(courtedEvents.count == 1 && courtedEvents[0]["type"] as? String == "contact.imported", "Courted commit creates one per-contact event")
    let courted = try store.get("agents",courtedEvents[0]["agentId"] as! String)
    try check(courted["sourceExportDate"] as? String == "unknown", "new export is not labeled with a hardcoded historical source date")
    let count = try store.all("activities").count
    courtedInput["token"] = try store.previewCourtedImport(courtedInput)["token"]
    _ = try store.commitCourtedImport(courtedInput)
    try check(try store.all("activities").count == count, "Courted replay creates no duplicate event")

    let reportStore = try Store(path:root.appendingPathComponent("report.sqlite").path,seed:false)
    for id in ["a","b"] { try reportStore.put("agents",["id":id,"name":"Fixture " + id,"datasetId":"live"]) }
    let day = "2026-01-01", occurrence = day + "T12:00:00Z"
    try reportStore.put("communications",["id":"delivered","agentId":"a","channel":"message","state":"delivered","confirmationSource":"provider","provider":"apple-messages","providerId":"shared-out","occurredOn":day])
    try reportStore.put("communications",["id":"submitted","agentId":"a","channel":"message","state":"submitted","createdAt":occurrence])
    func external(_ id: String,_ agent: String,_ channel: String,_ provider: String,_ direction: String,_ sourceID: String) throws {
        try reportStore.put("externalMessages",["id":id,"agentId":agent,"channel":channel,"provider":provider,"providerMessageId":sourceID,"accountAddress":"operator@example.com","direction":direction,"occurredAt":occurrence,"importedAt":Store.now(),"body":"Private body"])
    }
    try external("delivered-copy","a","Message","apple-messages","outbound","shared-out")
    try external("sent-only","a","Email","gmail","outbound","sent-id")
    try external("reply","b","Email","gmail","inbound","reply-id")
    try reportStore.put("activities",["id":"sent-log","agentId":"a","kind":"interaction","title":"Email — Completed","date":day,"provider":"gmail","providerMessageId":"sent-id"])
    try reportStore.put("activities",["id":"reply-log","agentId":"b","kind":"interaction","title":"Email — Completed","date":day,"externalMessageId":"reply"])
    try reportStore.put("activities",["id":"draft","agentId":"a","kind":"draft","title":"Message draft saved","date":day])
    for id in ["outbox-confirmed","outbox-duplicate"] {
        try reportStore.put("activities",["id":id,"agentId":"a","kind":"interaction","activityType":"message.user_confirmed_sent","title":"Text sent — confirmed by you","date":day,"outboxJobId":"job-one","confirmationSource":"user"])
    }
    let report = try reportStore.managerReport(["fromDate":day,"toDate":day,"timeZone":"UTC"])
    let metrics = report["metrics"] as! [String:Int], exclusions = report["exclusions"] as! [String:Int]
    try check(metrics["messages"] == 2 && metrics["emails"] == 1 && metrics["emailReplies"] == 1, "provider history and confirmed outbox sends contribute distinct outbound and inbound totals")
    try check(metrics["confirmedDeliveries"] == 1 && report["distinctContacts"] as? Int == 1 && report["distinctRespondingContacts"] as? Int == 1, "Sent and inbound evidence do not inflate delivery or outreach coverage")
    try check(exclusions["linkedDuplicates"] == 4 && exclusions["drafts"] == 1 && exclusions["unconfirmed"] == 1, "source IDs and outbox IDs dedupe logs; drafts/submission remain excluded")
    try check((report["verificationCounts"] as? [String:Int])?["user"] == 1, "outbox confirmation is user evidence and counted once")
    let ledger = report["events"] as! [Record]
    try check(ledger.contains { ($0["label"] as? String ?? "").contains("delivery unverified") }, "Sent history is labeled without delivery claim")
    try check(!Store.managerReportText(report).contains("Private body"), "report export omits correspondence bodies")

    let replyStore = try Store(path:root.appendingPathComponent("replies.sqlite").path,seed:false)
    try replyStore.put("agents",["id":"reply-agent","name":"Fixture","datasetId":"live","email":"candidate@example.com","phone":"+15125550123"])
    for (id,state,created) in [("completed","completed","2026-01-01T10:00:00Z"),("later","completed","2026-01-01T14:00:00Z"),("sent","completed","2026-01-01T10:00:00Z")] {
        try replyStore.put("sequences",["id":id,"agentId":"reply-agent","state":state,"createdAt":created])
    }
    for (id,sequence,state,approval) in [("final-draft","completed","draft","approved"),("later-draft","later","draft","pending_review"),("sent-draft","sent","sent","approved"),("rejected-draft","completed","draft","rejected")] {
        try replyStore.put("drafts",["id":id,"agentId":"reply-agent","sequenceId":sequence,"channel":"Message","body":"Fixture","state":state,"approvalState":approval,"createdAt":"2026-01-01T11:00:00Z"])
    }
    let reply: Record = ["agentId":"reply-agent","channel":"Email","provider":"gmail","accountAddress":"operator@example.com","providerMessageId":"completed-reply","providerThreadId":"thread","direction":"inbound","from":"candidate@example.com","to":"operator@example.com","occurredAt":occurrence,"body":"Thanks for reaching out."]
    _ = try replyStore.command("externalMessage.import",reply)
    try check(try replyStore.get("drafts","final-draft")["approvalState"] as? String == "paused_reply", "reply holds unsent final output of completed sequence")
    try check(try replyStore.get("sequences","completed")["state"] as? String == "completed" && replyStore.get("sequences","completed")["pendingOutputState"] as? String == "paused_reply", "all-steps-prepared fact survives reply hold")
    try check(try replyStore.get("drafts","later-draft")["approvalState"] as? String == "pending_review", "historical reply cannot pause newer enrollment")
    try check(try replyStore.get("drafts","sent-draft")["state"] as? String == "sent" && replyStore.get("drafts","rejected-draft")["approvalState"] as? String == "rejected", "reply leaves sent and rejected outputs unchanged")
    let pauses = try replyStore.all("workflowEvents").count
    _ = try replyStore.command("externalMessage.import",reply)
    try check(try replyStore.all("workflowEvents").count == pauses, "reply replay is idempotent")
    print("PASS: contact event templates, both import lifecycles/replay, unknown timestamps, correspondence report reconciliation and completed-sequence reply holds.")
}
