import Foundation

func runMessagesSyncCoordinatorTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        if !value { throw StoreError(message:"Messages sync coordinator test failed: " + message) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-sync-coordinator-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = try Store(path:root.appendingPathComponent("fixture.sqlite").path,seed:false)
    var requests:[Record] = [], callbacks:[(Result<Record,Error>)->Void] = []
    let coordinator = MessagesSyncCoordinator(store:store,read:{ request,callback in requests.append(request);callbacks.append(callback) })
    coordinator.tick()
    try check(requests.isEmpty,"disabled startup never reads Messages")
    _ = try store.command("agent.create",["name":"Sync fixture","phone":"+12025550111"])
    var available = false
    coordinator.storeAvailable = { available }
    _ = try coordinator.configure(["enabled":true,"confirmed":true])
    try check(requests.isEmpty,"disk scan waits until workspace ownership is available")
    available = true;coordinator.tick()
    try check(requests.count == 1 && coordinator.running,"enabled sync starts one asynchronous read")
    let since = try store.messagesSyncStatus()["since"] as? String
    try check(since != nil,"coverage begins at explicit enablement")
    var freshResult:Bool?
    coordinator.scan { freshResult = $0 }
    try check(requests.count == 1,"fresh dispatch scan queues behind existing read")
    func batch(_ request:Record,_ cursor:Int) -> Record {
        ["sourceID":"fixture-source","nextRowID":cursor,"scannedFromRowID":request["afterRowID"] ?? 0,
         "hasMore":false,"messages":[Record](),"scannedCount":0]
    }
    available = false
    callbacks.removeFirst()(.success(batch(requests[0],5)))
    try check(try !(store.messagesSyncStatus()["lastSuccessAt"] is String),"read receipt cannot mutate Store during CSV/recovery work")
    available = true;coordinator.tick()
    try check(requests.count == 2 && freshResult == nil,"dispatch waits for a new scan, not the old in-flight result")
    callbacks.removeFirst()(.success(batch(requests[1],5)))
    try check(freshResult == true && !coordinator.running,"fresh scan completes only after successful persistence")
    let lastSuccess = try store.messagesSyncStatus()["lastSuccessAt"] as? String
    var failedResult:Bool?
    coordinator.scan { failedResult = $0 }
    callbacks.removeFirst()(.failure(MessagesHistoryReadError(code:"access_unavailable",message:"Fixture permission denied")))
    try check(failedResult == false,"missing history access fails the pre-send check")
    try check(try store.messagesSyncStatus()["lastSuccessAt"] as? String == lastSuccess,"failed scan does not advance successful coverage")
    var cancellationResults: [Bool] = []
    coordinator.scan { cancellationResults.append($0) }
    let pendingRequest = requests.last!
    _ = try coordinator.configure(["enabled":false])
    try check(cancellationResults == [false],"pausing cancels the active pre-send approval exactly once")
    callbacks.removeFirst()(.success(batch(pendingRequest,99)))
    try check(cancellationResults == [false],"late scan completion cannot grant a cancelled send")
    let disabled = try store.messagesSyncStatus()
    try check(disabled["enabled"] as? Bool == false && !coordinator.running,"pause discards in-flight receipt")
    try check((disabled["cursor"] as? NSNumber)?.intValue != 99,"paused scan cannot advance cursor")
    let count = requests.count
    coordinator.tick()
    try check(requests.count == count,"paused scheduler stays idle")
    _ = try coordinator.configure(["enabled":true,"confirmed":true])
    let oldRequest = requests.last!, oldCallback = callbacks.removeFirst()
    _ = try coordinator.configure(["enabled":false])
    _ = try coordinator.configure(["enabled":true,"confirmed":true])
    let resumedRequest = requests.last!, resumedCallback = callbacks.removeFirst()
    available = false
    resumedCallback(.success(batch(resumedRequest,6)))
    oldCallback(.success(batch(oldRequest,55)))
    available = true; coordinator.tick()
    try check(try store.messagesSyncStatus()["cursor"] as? Int == 6,"late result from an earlier enablement cannot replace a resumed scan")
    var scanClock = Date().addingTimeInterval(-60)
    coordinator.clock = { scanClock }
    var delayedGrant: Bool?
    coordinator.scan { delayedGrant = $0 }
    let delayedRequest = requests.last!
    available = false
    callbacks.removeFirst()(.success(batch(delayedRequest,7)))
    scanClock = Date()
    available = true; coordinator.tick()
    try check(delayedGrant == nil && coordinator.running,"a scan delayed by Store ownership cannot grant dispatch")
    let observed = try store.messagesSyncStatus()["lastSuccessAt"] as! String
    try check(Store.activityEventDate(observed)!.timeIntervalSinceNow < -30,"coverage time records observation, not delayed persistence")
    let refreshedRequest = requests.last!
    callbacks.removeFirst()(.success(batch(refreshedRequest,8)))
    try check(delayedGrant == true,"dispatch receives approval only after a new recent scan commits")
    // The clock advanced past the automatic deadline while ownership was busy.
    // That independent due pass must not grant the dispatch callback again.
    if coordinator.running { callbacks.removeFirst()(.success(batch(requests.last!,8))) }
    var exhaustedGrant: Bool?
    scanClock = Date().addingTimeInterval(-120)
    coordinator.scan { exhaustedGrant = $0 }
    for cursor in 9...12 {
        let staleRequest = requests.last!
        scanClock = scanClock.addingTimeInterval(10)
        callbacks.removeFirst()(.success(batch(staleRequest,cursor)))
        if cursor < 12 { try check(exhaustedGrant == nil,"stale scans retry without granting dispatch") }
    }
    try check(exhaustedGrant == false,"repeated stale scans fail the dispatch request rather than trapping it")
    try check(try store.messagesSyncStatus()["errorCode"] as? String == "stale_scan","stale scan exhaustion remains actionable")
    if coordinator.running { callbacks.removeFirst()(.success(batch(requests.last!,12))) }
    // Deterministic cadence: configuration and explicit checks bypass the idle
    // deadline, while timer ticks cannot start early or overlap an active read.
    _ = try coordinator.configure(["enabled":false])
    coordinator.tick()
    let pausedCount = requests.count
    for _ in 0..<30 { coordinator.tick() }
    try check(requests.count == pausedCount,"disabled idle ticks do not start reads")
    var disabledResults:[Bool] = []
    coordinator.scan { disabledResults.append($0) }
    try check(disabledResults == [true] && requests.count == pausedCount,"explicit check while disabled completes exactly once before the idle deadline")
    _ = try coordinator.configure(["enabled":true,"confirmed":true])
    try check(requests.count == pausedCount + 1,"enable resets the disabled idle deadline immediately")
    callbacks.removeFirst()(.success(batch(requests.last!,13)))
    let enabledCount = requests.count
    scanClock = scanClock.addingTimeInterval(14)
    for _ in 0..<30 { coordinator.tick() }
    try check(requests.count == enabledCount,"automatic Messages scan waits for the full 15-second deadline")
    scanClock = scanClock.addingTimeInterval(1);coordinator.tick()
    try check(requests.count == enabledCount + 1,"automatic Messages scan starts when its deadline is reached")
    for _ in 0..<30 { coordinator.tick() }
    try check(requests.count == enabledCount + 1,"due timer ticks cannot overlap the running read")
    callbacks.removeFirst()(.success(batch(requests.last!,14)))
    var explicitResults:[Bool] = []
    coordinator.scan { explicitResults.append($0) }
    try check(requests.count == enabledCount + 2,"explicit scan bypasses the next automatic deadline")
    callbacks.removeFirst()(.success(batch(requests.last!,15)))
    try check(explicitResults == [true],"explicit scan completes once after persistence")
    print("PASS: reply sync coordinator background serialization, idle deadlines, fresh pre-send scans, busy barriers, permission failures and enablement generation cancellation.")
}
