import Foundation

// A noninteractive Security call can still stall in system IPC. This cache keeps
// optional credential reads off the UI thread and never queues a second read
// behind a stalled one. Only the caller receives the credential result.
final class NonblockingCredentialRead {
    static let worker = DispatchQueue(label:"com.sprout-recruit.credential-read",qos:.utility)
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private let now: () -> Date
    private let execute: (@escaping () -> Void) -> Void
    private let notify: (@escaping () -> Void) -> Void
    private let operation: () throws -> Record?
    private var generation: UInt64 = 0
    private var inFlight = false
    private var cached: (result: Result<Record?,Error>, recordedAt: Date)?
    var onReady: (() -> Void)?

    init(lifetime: TimeInterval = 30, now: @escaping () -> Date = Date.init,
         execute: @escaping (@escaping () -> Void) -> Void = { work in NonblockingCredentialRead.worker.async(execute:work) },
         notify: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute:work) },
         operation: @escaping () throws -> Record?) {
        self.lifetime = max(0,lifetime); self.now = now; self.execute = execute
        self.notify = notify; self.operation = operation
    }

    func load() throws -> Record? {
        lock.lock()
        if let cached = cached {
            let age = now().timeIntervalSince(cached.recordedAt)
            if age >= 0 && age < lifetime {
                lock.unlock()
                return try cached.result.get()
            }
        }
        let shouldStart = !inFlight
        let startedGeneration = generation
        if shouldStart { inFlight = true }
        lock.unlock()
        if shouldStart {
            execute { [weak self] in
                guard let self = self else { return }
                let result = Result { try self.operation() }
                self.complete(result,generation:startedGeneration)
            }
        }
        throw GmailAPIError(code:"keychain_read_pending",message:"The saved Gmail connection is being checked. Optional sync is paused until that check completes.")
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        cached = nil
        // Security calls cannot be canceled. Retain this admission slot until
        // the old operation actually returns, rather than piling up workers.
        lock.unlock()
    }

    private func complete(_ result: Result<Record?,Error>, generation completedGeneration: UInt64) {
        lock.lock()
        inFlight = false
        let current = generation == completedGeneration
        if current { cached = (result,now()) }
        let shouldNotify: Bool
        if current,case .success(let value) = result { shouldNotify = value != nil }
        else { shouldNotify = false }
        lock.unlock()
        if shouldNotify {
            notify { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let stillCurrent = self.generation == completedGeneration
                self.lock.unlock()
                if stillCurrent { self.onReady?() }
            }
        }
    }
}
