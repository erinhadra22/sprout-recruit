import Foundation

// All Store work stays on the main queue behind the workspace ownership barrier.
// Network pages are applied atomically; pausing invalidates in-flight results.
final class GmailSyncCoordinator {
    typealias Read = (Record, @escaping (Result<Record, Error>) -> Void) -> Void
    let store: Store
    let read: Read
    var storeAvailable: () -> Bool = { true }
    var onChange: () -> Void = {}
    var clock: () -> Date = { Date() }
    private var timer: Timer?
    private var nextScan = Date.distantPast
    private var requested = false
    private var completions: [(Bool) -> Void] = []
    private var activeCompletions: [(Bool) -> Void] = []
    private var epoch: UInt64 = 0
    private var readStarted = Date.distantPast
    private var staleRetries = 0
    private var pending: (Record, Result<Record, Error>)?
    private(set) var running = false

    init(store: Store, read: @escaping Read) { self.store = store; self.read = read }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    func status() throws -> Record {
        var state = try store.gmailSyncStatus()
        if running && state["enabled"] as? Bool == true { state["status"] = "syncing" }
        return state
    }
    func scan(completion: ((Bool) -> Void)? = nil) { if let completion = completion { completions.append(completion) }; requested = true; tick() }
    func invalidate() { epoch &+= 1; pending = nil; running = false; requested = false; let queued = completions; completions = []; finish(false); queued.forEach { $0(false) } }
    private func finish(_ success: Bool) { let callbacks = activeCompletions; activeCompletions = []; callbacks.forEach { $0(success) } }
    func configured() { invalidate(); nextScan = .distantPast; onChange(); tick() }
    private func begin() throws {
        let request = try store.gmailSyncReadRequest(), generation = epoch
        readStarted = clock()
        read(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.epoch == generation else { return }
                self.pending = (request,result); self.tick()
            }
        }
    }
    func tick() {
        guard storeAvailable() else { return }
        if let (request,result) = pending {
            pending = nil
            do {
                guard try store.gmailSyncStatus()["enabled"] as? Bool == true else { invalidate(); return }
                var batch = try result.get()
                let timestamp=ISO8601DateFormatter();timestamp.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
                batch["observedAt"]=timestamp.string(from:readStarted)
                _ = try store.command("gmailSync.apply",["request":request,"batch":batch])
                onChange()
                let oldCursor = request["cursor"] as? Record ?? [:], nextCursor = batch["nextCursor"] as? Record ?? [:]
                let needsCatchUp = oldCursor["mode"] as? String != "history" && nextCursor["mode"] as? String == "history"
                if batch["hasMore"] as? Bool == true || needsCatchUp { try begin(); return }
                if !activeCompletions.isEmpty && (clock().timeIntervalSince(readStarted) > 5 || clock().timeIntervalSince(readStarted) < 0) {
                    staleRetries += 1
                    guard staleRetries <= 3 else { throw StoreError(message:"Gmail reply checks became stale before dispatch. Review sync and retry after other work finishes.") }
                    try begin(); return
                }
                running = false; finish(true)
            } catch {
                _ = try? store.command("gmailSync.failure",["generation":request["generation"] ?? 0,"message":error.localizedDescription,"errorCode":(error as? GmailAPIError)?.code ?? "gmail_scan_failed"])
                running = false; finish(false); onChange()
            }
        }
        guard !running else { return }
        let now = clock()
        // Avoid decoding every candidate on each idle timer tick, including
        // while sync is disabled. Explicit requests and configured() reset the
        // wait; pending receipts above remain independent of this deadline.
        guard requested || now >= nextScan else { return }
        nextScan = now.addingTimeInterval(60)
        do {
            guard try store.gmailSyncStatus()["enabled"] as? Bool == true else { requested = false; let callbacks = completions; completions = []; callbacks.forEach { $0(true) }; return }
            staleRetries = 0; activeCompletions = completions; completions = []; requested = false; running = true
            onChange(); try begin()
        } catch {
            if let state = try? store.gmailSyncStatus() { _ = try? store.command("gmailSync.failure",["generation":state["generation"] ?? 0,"message":error.localizedDescription,"errorCode":"gmail_request_failed"]) }
            running = false; finish(false); onChange()
        }
    }
}
