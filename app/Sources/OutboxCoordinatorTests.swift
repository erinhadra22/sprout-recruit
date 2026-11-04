import Foundation

private final class FixtureMessageTransport: IMessageTransporting {
    var requests: [Record] = []
    private var completions: [(Record)->Void] = []
    func perform(_ input: Record, completion: @escaping (Record)->Void) {
        requests.append(input); completions.append(completion)
    }
    func complete(_ result: Record) throws {
        guard !completions.isEmpty else { throw StoreError(message:"No fixture transport operation is pending.") }
        completions.removeFirst()(result)
    }
}

// Calls no Messages APIs. Deferred mock callbacks exercise the real coordinator
// against a disposable workspace, including the import/backup busy barrier.
func runOutboxCoordinatorTests() throws {
    func check(_ condition: Bool,_ message: String) throws {
        if !condition { throw StoreError(message:"Outbox coordinator test failed: " + message) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-outbox-coordinator-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = try Store(path:root.appendingPathComponent("fixture.sqlite").path,seed:false)
    _ = try store.command("outbox.connection",["enabled":true,"accountId":"fixture-account","accountLabel":"Fixture identity"])
    let prepared = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-60))
    var jobs: [String] = []
    for index in 1...2 {
        let aid = "fixture-contact-\(index)", did = "fixture-draft-\(index)", id = UUID().uuidString.lowercased()
        let phone = "+1202555000\(index)", body = "Fixture \(index); never actually sent."
        try store.put("agents",["id":aid,"name":"Fixture \(index)","source":"Manual contact","manual":true,"datasetId":"live","phone":phone,"status":"Identified"])
        try store.put("drafts",["id":did,"agentId":aid,"body":body,"channel":"Message","state":"draft","createdAt":prepared,"updatedAt":prepared])
        _ = try store.command("outbox.enqueue",["id":id,"agentId":aid,"draftId":did,"phone":phone,"body":body,"confirmed":true])
        jobs.append(id)
    }
    let transport = FixtureMessageTransport(), coordinator = OutboxCoordinator(store:store,transport:transport)
    var available = false, changed = 0
    coordinator.storeAvailable = { available }; coordinator.onChange = { changed += 1 }
    coordinator.tick()
    try check(transport.requests.isEmpty && !coordinator.inFlight, "busy workspace cannot claim or dispatch a job")
    available = true; coordinator.tick()
    try check(transport.requests.count == 1 && coordinator.inFlight, "one queued job begins preflight when workspace is free")
    try check(transport.requests[0]["mode"] as? String == "check" && transport.requests[0]["accountId"] as? String == "fixture-account" && transport.requests[0]["service"] as? String == "iMessage", "preflight checks frozen sender account and legacy default service")
    coordinator.tick()
    try check(transport.requests.count == 1, "repeated ticks cannot overlap a native send")
    available = false
    try transport.complete(["state":"ready","service":"iMessage","accountId":"fixture-account","accountLabel":"Fixture identity"])
    try check(transport.requests.count == 1, "preflight cannot dispatch while a workspace operation is busy")
    available = true; coordinator.tick()
    try check(transport.requests.count == 2 && transport.requests[1]["mode"] as? String == "send" && transport.requests[1]["phone"] as? String == "+12025550001", "validated transport receives frozen reviewed recipient")
    available = false
    try transport.complete(["state":"submitted","dispatchStarted":true])
    try check(try store.get("outboxJobs",jobs[0])["state"] as? String == "sending" && coordinator.inFlight, "transport receipt waits while import or backup owns Store")
    available = true; coordinator.tick()
    try check(try store.get("outboxJobs",jobs[0])["state"] as? String == "submitted", "deferred receipt is persisted on next free tick")
    try check(transport.requests.count == 3 && coordinator.inFlight && transport.requests[2]["mode"] as? String == "check", "next queued preflight begins only after prior receipt is persisted")
    try transport.complete(["state":"ready","service":"iMessage","accountId":"fixture-account","accountLabel":"Fixture identity"])
    try check(transport.requests.count == 4 && transport.requests[3]["mode"] as? String == "send", "second preflight revalidates before dispatch")
    try transport.complete(["state":"unknown","errorCode":"helper_interrupted"])
    coordinator.tick()
    try check(try store.get("outboxJobs",jobs[1])["state"] as? String == "unknown" && !coordinator.inFlight, "interrupted helper is uncertain and never automatically retried")
    try check(transport.requests.count == 4 && changed >= 4, "receipts notify UI without redispatch")

    var connectionReply = false, connectionError: String?
    coordinator.connect { _,error in connectionReply = true; connectionError = error }
    try check(transport.requests.last?["mode"] as? String == "check", "connect uses transport preflight")
    available = false
    try transport.complete(["state":"ready","service":"iMessage","accountId":"new-fixture-account","accountLabel":"New fixture identity","checkedAt":Store.now()])
    let connectionBefore = try store.get("settings","imessage")
    try check(!connectionReply && connectionBefore["accountId"] as? String == "fixture-account", "connection callback waits for Store ownership")
    available = true; coordinator.tick()
    let connectionAfter = try store.get("settings","imessage")
    try check(connectionReply && connectionError == nil && connectionAfter["accountId"] as? String == "new-fixture-account", "connection is saved before success callback")

    let interruptedID = UUID().uuidString.lowercased()
    try store.put("agents",["id":"reply-agent","name":"Reply fixture","source":"Manual contact","manual":true,"datasetId":"live","phone":"+12025550003","status":"Identified"])
    try store.put("drafts",["id":"reply-draft","agentId":"reply-agent","body":"Fixture reply hold.","channel":"Message","state":"draft","createdAt":prepared,"updatedAt":prepared])
    _ = try store.command("outbox.enqueue",["id":interruptedID,"agentId":"reply-agent","draftId":"reply-draft","phone":"+12025550003","body":"Fixture reply hold.","confirmed":true])
    coordinator.tick()
    let preflightCount = transport.requests.count
    try check(transport.requests.last?["mode"] as? String == "check", "new send is still in preflight")
    _ = try store.command("externalMessage.import",["agentId":"reply-agent","channel":"Message","provider":"apple-messages","accountAddress":"+12025550999","providerMessageId":"race-reply","providerThreadId":"race-thread","direction":"inbound","from":"+12025550003","to":"+12025550999","occurredAt":Store.now(),"body":"Fixture reply while native preflight was running."])
    available = false
    try transport.complete(["state":"ready","service":"iMessage","accountId":"new-fixture-account","accountLabel":"New fixture identity"])
    available = true; coordinator.tick()
    let interruptedJob = try store.get("outboxJobs",interruptedID)
    try check(transport.requests.count == preflightCount && interruptedJob["state"] as? String == "failed", "reply arriving during preflight prevents send after Store revalidation")
    try check((interruptedJob["dispatchResult"] as? Record)?["dispatchStarted"] as? Bool == false && !coordinator.inFlight, "preflight reply hold records certain non-dispatch")

    var smsConnected=false
    coordinator.connect(service:"SMS") { _,error in smsConnected = error == nil }
    try check(transport.requests.last?["service"] as? String == "SMS","SMS connection is explicitly requested")
    try transport.complete(["state":"ready","service":"SMS","accountId":"sms-account","accountLabel":"SMS fixture identity"])
    try check(smsConnected && store.get("settings","imessage")["service"] as? String == "SMS","verified SMS service is saved with the connection")
    for index in 4...5 {
        let agent="sms-contact-\(index)",draft="sms-draft-\(index)",id=UUID().uuidString.lowercased(),phone="+1202555000\(index)",body="SMS fixture \(index); never actually sent."
        try store.put("agents",["id":agent,"name":"SMS fixture \(index)","source":"Manual contact","manual":true,"datasetId":"live","phone":phone,"status":"Identified"])
        try store.put("drafts",["id":draft,"agentId":agent,"body":body,"channel":"Message","state":"draft","createdAt":prepared,"updatedAt":prepared])
        _=try store.command("outbox.enqueue",["id":id,"agentId":agent,"draftId":draft,"phone":phone,"body":body,"confirmed":true,"expectedService":"SMS"])
        coordinator.tick()
        let count=transport.requests.count
        try check(transport.requests.last?["service"] as? String == "SMS","job preflight uses frozen SMS service")
        try transport.complete(["state":"ready","service":index==4 ? "SMS" : "iMessage","accountId":"sms-account","accountLabel":"SMS fixture identity"])
        if index==4 {
            try check(transport.requests.count==count+1 && transport.requests.last?["mode"] as? String == "send" && transport.requests.last?["service"] as? String == "SMS","SMS dispatch retains exactly the preflight service")
            try transport.complete(["state":"failed","dispatchStarted":false,"errorCode":"messages_recipient_handle_failed"])
            try check(try store.get("outboxJobs",id)["state"] as? String == "failed","verified pre-send rejection persists as certain failure")
        } else {
            try check(transport.requests.count==count && store.get("outboxJobs",id)["state"] as? String == "failed","wrong-service preflight cannot dispatch even when the account ID matches")
        }
    }
    var wrongServiceError:String?
    coordinator.connect(service:"SMS") { _,error in wrongServiceError=error }
    try transport.complete(["state":"ready","service":"iMessage","accountId":"different-account","accountLabel":"Wrong-service fixture"])
    try check(wrongServiceError != nil && store.get("settings","imessage")["accountId"] as? String == "sms-account","connect rejects a different returned service without replacing the verified identity")

    // Enabled reply sync must finish after transport preflight and before send.
    let barrierStore = try Store(path:root.appendingPathComponent("reply-barrier.sqlite").path,seed:false)
    _ = try barrierStore.command("outbox.connection",["enabled":true,"accountId":"fixture-account","accountLabel":"Fixture identity"])
    try barrierStore.put("agents",["id":"barrier-agent","name":"Barrier fixture","source":"Manual contact","manual":true,"datasetId":"live","phone":"+12025550199","status":"Identified"])
    try barrierStore.put("drafts",["id":"barrier-draft","agentId":"barrier-agent","body":"Do not send this fixture","channel":"Message","state":"draft","createdAt":prepared,"updatedAt":prepared])
    let barrierJob=UUID().uuidString.lowercased()
    _ = try barrierStore.command("outbox.enqueue",["id":barrierJob,"agentId":"barrier-agent","draftId":"barrier-draft","phone":"+12025550199","body":"Do not send this fixture","confirmed":true])
    let barrierTransport=FixtureMessageTransport(),barrier=OutboxCoordinator(store:barrierStore,transport:barrierTransport)
    var gate:((Bool)->Void)?
    barrier.beforeDispatch={ gate=$0 }
    barrier.tick()
    try barrierTransport.complete(["state":"ready","service":"iMessage","accountId":"fixture-account","accountLabel":"Fixture identity"])
    try check(barrierTransport.requests.count==1 && gate != nil,"dispatch waits for the fresh reply scan")
    barrier.tick()
    try check(barrierTransport.requests.count==1,"timer cannot bypass an in-flight reply check")
    gate?(false)
    try check(try barrierStore.get("outboxJobs",barrierJob)["state"] as? String == "failed" && barrierTransport.requests.count==1,"unavailable reply sync records not-sent without a send command")
    try check(try barrierStore.get("outboxJobs",barrierJob)["reasonCode"] as? String == "reply_sync_unavailable","failure explains the reply-access gap")

    // Descriptor construction is pure: this does not execute an Apple event.
    let body = "Quotation \" and newline\n do shell script \"false\""
    let event = IMessageWorker.event("dispatchmessage",["account","iMessage","+12025550001",body])
    try check(event.eventClass == 0x61736372 && event.eventID == 0x70736272, "AppleScript subroutine event constants are correct")
    try check(event.paramDescriptor(forKeyword:0x736e616d)?.stringValue == "dispatchmessage" && event.paramDescriptor(forKeyword:0x2d2d2d2d)?.atIndex(4)?.stringValue == body, "message text stays a literal argument descriptor")
    print("PASS: mocked outbox coordinator serialization, Store busy barrier, deferred receipts/connections, unknown outcomes and literal Apple event arguments.")
}
