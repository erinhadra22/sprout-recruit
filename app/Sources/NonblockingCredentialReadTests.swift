import Foundation

func runNonblockingCredentialReadTests() throws {
    func check(_ condition: Bool,_ message: String) throws {
        if !condition { throw StoreError(message:"Nonblocking credential read: " + message) }
    }
    func pending(_ reader: NonblockingCredentialRead) throws {
        do { _ = try reader.load() }
        catch let error as GmailAPIError {
            try check(error.code == "keychain_read_pending","pending read uses a distinct safe transient error")
            return
        }
        throw StoreError(message:"Pending credential read incorrectly returned a value")
    }
    var clock = Date(timeIntervalSince1970:1_000)
    var jobs: [() -> Void] = [],notifications: [() -> Void] = []
    var reads = 0,ready = 0
    var value: Record? = ["fixture":"first"]
    var failure: Error?
    let reader = NonblockingCredentialRead(lifetime:30,now:{clock},execute:{jobs.append($0)},notify:{notifications.append($0)},operation:{
        reads += 1
        if let failure = failure { throw failure }
        return value
    })
    reader.onReady = { ready += 1 }
    try pending(reader)
    try check(reads == 0 && jobs.count == 1,"load returns before credential operation starts")
    for _ in 0..<100 { try pending(reader) }
    try check(jobs.count == 1 && reads == 0,"repeated status/access reads coalesce without blocked-worker accumulation")
    jobs.removeFirst()()
    try check(reads == 1 && ready == 0 && notifications.count == 1,"successful read schedules readiness after completing outside the lock")
    try check(try reader.load()?["fixture"] as? String == "first" && reader.load()?["fixture"] as? String == "first","status and access share one cached result")
    try check(reads == 1 && jobs.isEmpty,"fresh cache schedules no work")
    notifications.removeFirst()()
    try check(ready == 1,"onReady is delivered through injected main notifier")

    clock = clock.addingTimeInterval(30)
    value = ["fixture":"second"]
    try pending(reader)
    try check(jobs.count == 1,"cache expiry starts one new read without blocking")
    jobs.removeFirst()();notifications.removeFirst()()
    try check(try reader.load()?["fixture"] as? String == "second" && ready == 2,"expiry replaces cached value and notifies readiness")

    reader.invalidate()
    failure = GmailAPIError(code:"keychain_unavailable",message:"Fixture failure")
    try pending(reader);jobs.removeFirst()()
    for _ in 0..<5 {
        do { _ = try reader.load();throw StoreError(message:"Failure cache incorrectly succeeded") }
        catch let error as GmailAPIError { try check(error.message == "Fixture failure","cached failure remains an error rather than arbitrary nil") }
    }
    try check(jobs.isEmpty && notifications.isEmpty,"failures cool down without retry work or onReady")
    clock = clock.addingTimeInterval(31)
    failure = nil;value = nil
    try pending(reader);jobs.removeFirst()()
    try check(try reader.load() == nil,"completed nil result records confirmed credential absence")
    try check(notifications.isEmpty,"confirmed absence does not announce a ready connection")

    reader.invalidate();value = ["fixture":"stale"]
    try pending(reader)
    reader.invalidate()
    for _ in 0..<100 { try pending(reader) }
    try check(jobs.count == 1,"invalidating a stalled operation keeps its one-worker admission slot")
    jobs.removeFirst()()
    try check(notifications.isEmpty,"old-generation result cannot announce readiness")
    value = ["fixture":"current"]
    try pending(reader)
    try check(jobs.count == 1,"fresh generation starts only after stale operation actually returns")
    jobs.removeFirst()()
    try check(try reader.load()?["fixture"] as? String == "current","late old value never populates current cache")
    // A result can become stale after the worker finishes but before main is notified.
    reader.invalidate();notifications.removeFirst()()
    try check(ready == 2,"invalidation also rejects already queued stale readiness callbacks")

    try pending(reader);jobs.removeFirst()()
    var callbackLoaded = false
    reader.onReady = { callbackLoaded = (try? reader.load()?["fixture"] as? String) == "current" }
    notifications.removeFirst()()
    try check(callbackLoaded,"onReady can immediately read the cache without a held-lock deadlock")
    print("Nonblocking credential read tests passed")
}
