import Foundation

// Disk reads run off the main thread. Store access stays on the main thread and
// waits behind the same CSV/recovery ownership barrier as the text outbox.
final class MessagesSyncCoordinator {
    typealias Read = (Record, @escaping (Result<Record, Error>) -> Void) -> Void
    let store: Store
    let read: Read
    var storeAvailable: () -> Bool = { true }
    var onChange: () -> Void = {}
    var clock: () -> Date = { Date() }
    private(set) var running = false
    private var timer: Timer?
    private var nextAutomaticScan = Date.distantPast
    private var requested = false
    private var queuedCompletions: [(Bool) -> Void] = []
    private var activeCompletions: [(Bool) -> Void] = []
    private var pending: (Record, Date, Result<Record, Error>)?
    private var epoch: UInt64 = 0
    private var staleDispatchRefreshes = 0

    init(store: Store, read: Read? = nil) {
        self.store = store
        let ioQueue = DispatchQueue(label:"com.sprout.messages-reader",qos:.utility)
        self.read = read ?? { request, completion in
            ioQueue.async {
                let result = Result {
                    try MessagesHistoryReader().read(
                        phones: request["phones"] as? [String] ?? [],
                        since: request["since"] as? String ?? "",
                        afterRowID: (request["afterRowID"] as? NSNumber)?.int64Value ?? 0,
                        expectedSourceID: request["sourceID"] as? String)
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func status() throws -> Record {
        var result = try store.messagesSyncStatus()
        if running && result["enabled"] as? Bool == true { result["status"] = "syncing" }
        return result
    }

    // A request during a disk read schedules a fresh pass after that pass. The
    // outbox uses this before dispatch, so it never relies on an earlier poll.
    func scan(completion: ((Bool) -> Void)? = nil) {
        if let completion = completion { queuedCompletions.append(completion) }
        requested = true
        tick()
    }

    func configure(_ payload: Record) throws -> Record {
        var result = try store.command("messagesSync.configure", payload)
        nextAutomaticScan = .distantPast
        onChange()
        if payload["enabled"] as? Bool == true { scan() }
        else {
            epoch &+= 1
            pending = nil; requested = false; running = false; staleDispatchRefreshes = 0
            let cancelled = activeCompletions + queuedCompletions
            activeCompletions = []; queuedCompletions = []
            cancelled.forEach { $0(false) }
        }
        result["messagesSync"] = try status()
        return result
    }

    private func finish(_ success: Bool) {
        running = false
        staleDispatchRefreshes = 0
        let callbacks = activeCompletions
        activeCompletions = []
        onChange()
        callbacks.forEach { $0(success) }
    }

    private func beginPage() throws {
        let request = try store.messagesSyncReadRequest()
        guard request["enabled"] as? Bool != false else { finish(true); return }
        let readEpoch = epoch
        let startedAt = clock()
        read(request) { [weak self] result in
            guard let self = self, self.epoch == readEpoch else { return }
            self.pending = (request, startedAt, result)
            self.tick()
        }
    }

    func tick() {
        guard storeAvailable() else { return }
        if let (request, startedAt, result) = pending {
            pending = nil
            do {
                let current = try store.messagesSyncStatus()
                // Pausing cancels an in-flight import before any record is saved.
                guard current["enabled"] as? Bool == true else { finish(true); return }
                var batch = try result.get()
                let timestamp = ISO8601DateFormatter()
                timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                batch["observedAt"] = timestamp.string(from:startedAt)
                _ = try store.command("messagesSync.apply", ["request": request, "batch": batch])
                onChange()
                if batch["hasMore"] as? Bool == true { try beginPage(); return }
                // A completed read may have waited behind CSV/recovery work.
                // Keep its reply holds, but never grant a send from an old read.
                let age = clock().timeIntervalSince(startedAt)
                if !activeCompletions.isEmpty && (age > 5 || age < 0) {
                    staleDispatchRefreshes += 1
                    guard staleDispatchRefreshes <= 3 else {
                        throw MessagesHistoryReadError(code:"stale_scan",message:"Messages reply checks kept becoming stale before dispatch. No text was sent. Finish other workspace work, check reply sync, and review a new send.")
                    }
                    try beginPage(); return
                }
                finish(true)
            } catch {
                let issue = error as? MessagesHistoryReadError
                _ = try? store.command("messagesSync.failure", [
                    "generation": request["generation"] ?? 0,
                    "errorCode": issue?.code ?? "sync_reconciliation_failed",
                    "message": error.localizedDescription,
                    "status": "blocked"
                ])
                finish(false)
            }
        }
        guard !running else { return }
        let now = clock()
        // Idle timer ticks must not rebuild contact matching state. Explicit
        // requests and configure() bypass this deadline; pending pages above
        // still apply immediately once workspace ownership is available.
        guard requested || now >= nextAutomaticScan else { return }
        nextAutomaticScan = now.addingTimeInterval(15)
        do {
            let state = try store.messagesSyncStatus()
            guard state["enabled"] as? Bool == true else {
                requested = false
                let callbacks = queuedCompletions; queuedCompletions = []
                callbacks.forEach { $0(true) }
                return
            }
            requested = false
            activeCompletions = queuedCompletions; queuedCompletions = []
            staleDispatchRefreshes = 0
            running = true
            onChange()
            try beginPage()
        } catch {
            if let state = try? store.messagesSyncStatus() {
                _ = try? store.command("messagesSync.failure",[
                    "generation":state["generation"] ?? 0,
                    "errorCode":"sync_request_failed",
                    "message":error.localizedDescription,"status":"blocked"])
            }
            finish(false)
        }
    }
}
