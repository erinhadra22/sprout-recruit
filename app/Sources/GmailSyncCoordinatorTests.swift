import Foundation

func runGmailSyncCoordinatorTests() throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-gmail-coordinator-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    func check(_ value:Bool,_ message:String) throws { if !value { throw StoreError(message:"Gmail coordinator test: "+message) } }
    func drain() { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    let store=try Store(path:folder.appendingPathComponent("fixture.sqlite").path,seed:false)
    try store.put("agents",["id":"a","name":"Fixture","email":"candidate@example.test","datasetId":"live","source":"Manual contact","manual":true])
    var requests:[Record]=[],callbacks:[(Result<Record,Error>)->Void]=[]
    let coordinator=GmailSyncCoordinator(store:store,read:{ request,callback in requests.append(request);callbacks.append(callback) })
    coordinator.tick();try check(requests.isEmpty,"disabled startup never reads Gmail")
    func page(_ request:Record,more:Bool=false,history:String="100",token:String?=nil)->Record {
        var cursor:Record=["mode":"history","historyId":history];if let token { cursor["pageToken"]=token }
        return ["accountAddress":request["accountAddress"]!,"fromCursor":request["cursor"]!,"nextCursor":cursor,"hasMore":more,"messages":[Record](),"scannedCount":0]
    }
    func deliver(_ batch:Record) throws { try check(!callbacks.isEmpty,"expected one pending page callback");callbacks.removeFirst()(.success(batch));drain() }
    try store.setGmailSyncConnection(["connected":true,"accountAddress":"operator@example.test"])
    try store.configureGmailSync(["enabled":true,"confirmed":true,"historyMode":"all"])
    var available=false;coordinator.storeAvailable={available};coordinator.configured()
    try check(requests.isEmpty,"workspace barrier prevents starting network work")
    available=true;coordinator.tick();try check(requests.count==1 && coordinator.running,"starts one page")
    var granted:[Bool]=[];coordinator.scan{granted.append($0)}
    try check(requests.count==1,"dispatch request queues behind an in-flight scan")
    available=false;try deliver(page(requests[0]))
    try check(try !(store.gmailSyncStatus()["lastSuccessAt"] is String),"pending receipt cannot mutate busy Store")
    available=true;coordinator.tick()
    try check(requests.count==2 && granted.isEmpty && coordinator.running,"full-to-history transition requires catch-up before completion")
    try check(try !(store.gmailSyncStatus()["lastSuccessAt"] is String),"full result does not claim catch-up coverage")
    try deliver(page(requests[1]))
    try check(requests.count==3 && granted.isEmpty,"pre-send callback receives a new scan after catch-up")
    try deliver(page(requests[2]))
    try check(granted==[true] && !coordinator.running,"only persisted fresh history completion grants dispatch once")

    var active:[Bool]=[],queued:[Bool]=[]
    coordinator.scan{active.append($0)};coordinator.scan{queued.append($0)}
    let lateRequest=requests.last!,lateCallback=callbacks.removeFirst()
    try store.configureGmailSync(["enabled":false]);coordinator.configured()
    try check(active==[false] && queued==[false] && !coordinator.running,"pause cancels active and queued callbacks exactly once")
    let cursorBefore=try store.gmailSyncReadRequestDisabledTestCursor()
    try store.configureGmailSync(["enabled":true,"confirmed":true]);coordinator.configured()
    let resumed=requests.last!
    lateCallback(.success(page(lateRequest,history:"999")));drain()
    try check(active==[false] && queued==[false] && coordinator.running,"old result cannot re-grant callbacks or replace resumed work")
    try check(NSDictionary(dictionary:try store.gmailSyncReadRequestDisabledTestCursor()).isEqual(to:cursorBefore),"late old-generation page cannot advance cursor")
    try deliver(page(resumed))

    coordinator.scan()
    let middle=requests.last!;try deliver(page(middle,more:true,token:"page-2"))
    let heldCursor=try store.gmailSyncStatus()["cursor"] as! Record
    callbacks.removeFirst()(.failure(StoreError(message:"Fixture network outage")));drain()
    try check(NSDictionary(dictionary:try store.gmailSyncStatus()["cursor"] as! Record).isEqual(to:heldCursor),"page failure preserves committed page token")
    try check(try store.gmailSyncStatus()["status"] as? String=="blocked" && !coordinator.running,"network failure is visible and releases coordinator")

    var clock=Date().addingTimeInterval(-30);coordinator.clock={clock}
    var delayed:[Bool]=[];coordinator.scan{delayed.append($0)}
    let stale=requests.last!;available=false;try deliver(page(stale));clock=Date();available=true;coordinator.tick()
    try check(delayed.isEmpty && coordinator.running,"a result delayed behind workspace ownership cannot grant a send")
    try deliver(page(requests.last!));try check(delayed==[true],"fresh retry grants exactly once")
    var exhausted:[Bool]=[];clock=Date().addingTimeInterval(-120)
    coordinator.scan{exhausted.append($0)}
    for _ in 0..<4 { clock=clock.addingTimeInterval(10);try deliver(page(requests.last!)) }
    try check(exhausted==[false] && !coordinator.running,"stale refresh attempts are bounded and fail closed")
    try store.configureGmailSync(["enabled":false]);coordinator.configured()
    let pausedCount=requests.count
    for _ in 0..<30 { coordinator.tick() }
    try check(requests.count==pausedCount,"disabled idle ticks do not start reads")
    var disabledResults:[Bool]=[];coordinator.scan{disabledResults.append($0)}
    try check(disabledResults==[true] && requests.count==pausedCount,"explicit disabled check completes exactly once before the idle deadline")
    try store.configureGmailSync(["enabled":true,"confirmed":true]);coordinator.configured()
    try check(requests.count==pausedCount+1,"enable resets the disabled idle deadline immediately")
    try deliver(page(requests.last!))
    let enabledCount=requests.count
    clock=clock.addingTimeInterval(59)
    for _ in 0..<30 { coordinator.tick() }
    try check(requests.count==enabledCount,"automatic Gmail scan waits for the full 60-second deadline")
    clock=clock.addingTimeInterval(1);coordinator.tick()
    try check(requests.count==enabledCount+1,"automatic Gmail scan starts at its deadline")
    for _ in 0..<30 { coordinator.tick() }
    try check(requests.count==enabledCount+1,"due timer ticks cannot overlap a running read")
    try deliver(page(requests.last!))
    var explicitResults:[Bool]=[];coordinator.scan{explicitResults.append($0)}
    try check(requests.count==enabledCount+2,"explicit scan bypasses the next automatic deadline")
    try deliver(page(requests.last!));try check(explicitResults==[true],"explicit scan completes once after persistence")
    let beforePending = try store.gmailSyncStatus()
    let pendingTaskCount = try store.all("tasks").count
    var pendingGrants: [Bool] = []
    coordinator.scan { pendingGrants.append($0) }
    callbacks.removeFirst()(.failure(GmailAPIError(code:"keychain_read_pending",message:"Saved connection read is pending.")))
    drain()
    try check(pendingGrants == [false] && !coordinator.running,"a pending credential read fails closed for sends without holding UI work")
    try check(NSDictionary(dictionary:try store.gmailSyncStatus()).isEqual(to:beforePending),"pending credential read preserves sync state, approved window, coverage and cursor")
    try check(try store.all("tasks").count == pendingTaskCount,"ordinary background credential loading creates no phantom attention task")
    coordinator.scan()
    try deliver(page(requests.last!))
    try check(!coordinator.running,"credential readiness can retry and finish the same saved scope")
    print("PASS: Gmail coordinator scope catch-up, idle deadlines, cancellation, busy barriers, no overlap, cursor retention and fresh pre-send grants; no network or live data.")
}

// Fixture convenience: status is valid even while the mailbox is paused.
private extension Store {
    func gmailSyncReadRequestDisabledTestCursor() throws -> Record { try gmailSyncStatus()["cursor"] as? Record ?? [:] }
}
