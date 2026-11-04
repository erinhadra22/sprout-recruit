import Foundation
import CryptoKit

private struct OutboxEligibilityError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

// Persistence only. Call mutations inside Store.transaction; dispatch runs after
// the claim commits. A successful local Apple event is not a delivery receipt.
extension Store {
    private func outboxString(_ p: Record, _ key: String, limit: Int = 200) throws -> String {
        guard let value = p[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= limit else { throw StoreError(message: "A valid \(key) is required for this text job.") }
        return value
    }

    private func outboxFields(_ p: Record, _ allowed: Set<String>) throws {
        guard Set(p.keys).isSubset(of: allowed) else { throw StoreError(message: "Unexpected text job fields were supplied.") }
    }

    private func outboxID(_ p: Record) throws -> String {
        let id = try outboxString(p, "id", limit: 36)
        guard UUID(uuidString: id) != nil else { throw StoreError(message: "A stable UUID is required for a text job.") }
        return id.lowercased()
    }

    private func outboxDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func outboxRow(_ kind: String, _ id: String) throws -> Record? {
        try all(kind).first { $0["id"] as? String == id }
    }

    private func outboxJob(_ p: Record) throws -> Record {
        guard let job = try outboxRow("outboxJobs", outboxID(p)) else { throw StoreError(message: "That text job no longer exists.") }
        return job
    }

    private func outboxDeny(_ code: String, _ message: String) throws -> Never {
        throw OutboxEligibilityError(code: code, message: message)
    }

    private func outboxConnection() throws -> Record {
        var connection = try outboxRow("settings", "imessage") ?? ["id":"imessage", "enabled":false]
        if connection["service"] == nil { connection["service"] = "iMessage" }
        return connection
    }

    private func outboxService(_ value: Any?) throws -> String {
        guard let value else { return "iMessage" }
        guard let service = value as? String, ["iMessage", "SMS"].contains(service) else {
            throw StoreError(message: "Choose the exact supported Messages service: iMessage or SMS.")
        }
        return service
    }

    func setOutboxConnection(_ p: Record) throws {
        try outboxFields(p, ["enabled", "accountId", "accountLabel", "checkedAt", "service"])
        guard let enabled = p["enabled"] as? Bool else { throw StoreError(message: "Choose whether the Apple Messages connection is enabled.") }
        let service = try outboxService(p["service"])
        let now = Store.now()
        var connection: Record = ["id":"imessage", "enabled":enabled, "service":service, "checkedAt":now, "updatedAt":now, "schemaVersion":1]
        if enabled {
            connection["accountId"] = try outboxString(p, "accountId", limit: 320)
            connection["accountLabel"] = try outboxString(p, "accountLabel", limit: 320)
        } else {
            let old = try outboxConnection()
            connection["accountId"] = old["accountId"] ?? ""
            connection["accountLabel"] = old["accountLabel"] ?? ""
        }
        if let raw = p["checkedAt"] {
            let time = try Store.communicationOccurrence(raw)
            connection["checkedAt"] = time.timestamp
        }
        try put("settings", connection)
    }

    // Recheck current facts, rather than trusting the snapshots in an old job.
    // A held job cannot silently become dispatchable when those facts change.
    private func validateOutbox(_ request: Record, excluding jobID: String? = nil, snapshot: Record? = nil) throws -> (Record, Record, Record) {
        let agentID = try outboxString(request, "agentId")
        let draftID = try outboxString(request, "draftId")
        let phone = try outboxString(request, "phone", limit: 50)
        let body = try outboxString(request, "body", limit: 1600)
        guard let agent = try outboxRow("agents", agentID) else { try outboxDeny("contact_missing", "The contact is unavailable. Review this text before sending.") }
        let source = agent["source"] as? String ?? ""
        guard !agentID.hasPrefix("sample-"), agent["sample"] as? Bool != true,
              agent["datasetId"] as? String != "sample", agent["dataset"] as? String != "sample",
              !source.lowercased().contains("fictional"), !source.lowercased().contains("sample") else {
            try outboxDeny("sample_contact", "Sample contacts cannot receive messages.")
        }
        let name = agent["name"] as? String ?? ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let currentPhone = try? Store.normalizedCommunicationPhone(agent["phone"] as? String ?? ""), currentPhone == phone else {
            try outboxDeny("contact_changed", "The contact name, source or phone needs review. The queued recipient must match the saved contact.")
        }
        let verification = agent["communicationVerification"] as? Record ?? [:]
        let reviewed = agent["datasetId"] as? String == "live" && verification["confirmed"] as? Bool == true
            && verification["name"] as? String == name && verification["source"] as? String == source
            && verification["phone"] as? String == phone
        guard agent["manual"] as? Bool == true || reviewed else {
            try outboxDeny("contact_unreviewed", "Review the exact imported contact name, source and phone before sending.")
        }
        if let snapshot {
            guard snapshot["contactName"] as? String == name, snapshot["contactSource"] as? String == source else {
                try outboxDeny("contact_changed", "The contact identity changed after this text was authorized. Cancel it and review a new send.")
            }
        }
        let terminal = ["do not contact", "not interested", "not qualified", "lost", "recruited"]
        guard !terminal.contains((agent["status"] as? String ?? "").lowercased()), agent["doNotContact"] as? Bool != true,
              agent["disposition"] as? String != "skipped" else {
            try outboxDeny("contact_suppressed", "This contact is closed or suppressed. Outreach is paused.")
        }
        guard let draft = try outboxRow("drafts", draftID), draft["agentId"] as? String == agentID,
              draft["channel"] as? String == "Message", draft["state"] as? String == "draft",
              draft["body"] as? String == body else {
            try outboxDeny("draft_changed", "The saved draft changed or is no longer editable. Review the current text before sending.")
        }
        if let expected = request["expectedUpdatedAt"] as? String,
           expected != ((draft["updatedAt"] as? String) ?? (draft["createdAt"] as? String)) {
            try outboxDeny("draft_changed", "The saved draft revision changed. Reload and review it before sending.")
        }
        guard !["paused_reply", "rejected", "blocked_contact"].contains(draft["approvalState"] as? String ?? "") else {
            try outboxDeny("draft_paused", "This draft is paused, rejected or blocked. Review it before sending.")
        }
        if let sequenceID = draft["sequenceId"] as? String, let sequence = try outboxRow("sequences", sequenceID),
           ["paused", "cancelled", "canceled", "stopped"].contains(sequence["state"] as? String ?? "") {
            try outboxDeny("sequence_paused", "This text belongs to a paused or stopped outreach sequence.")
        }
        guard let draftTime = (snapshot?["draftCreatedAt"] as? String) ?? (draft["createdAt"] as? String) ?? (draft["updatedAt"] as? String),
              let created = outboxDate(draftTime) else {
            try outboxDeny("draft_time_unknown", "Save and review the draft before sending so reply timing can be checked.")
        }
        if let snapshot, let updated = snapshot["draftUpdatedAt"] as? String,
           updated != ((draft["updatedAt"] as? String) ?? (draft["createdAt"] as? String)) {
            try outboxDeny("draft_changed", "The saved draft revision changed after authorization. Cancel it and review a new send.")
        }
        if let reason = try gmailSyncHoldReason(agentId:agentID) { try outboxDeny("gmail_reply_review",reason) }
        if let reason = try messagesSyncHoldReason(phone: phone, draftCreatedAt: draftTime) {
            try outboxDeny("ambiguous_reply_identity", reason)
        }
        let external = try all("externalMessages")
        if external.contains(where: { row in
            row["agentId"] as? String == agentID && row["direction"] as? String == "inbound"
                && !(row["provider"] as? String == "gmail" && row["syncSource"] as? String == "gmail-native" && (row["messageClass"] as? String == "automatic_notice" || (row["messageClass"] as? String == "meeting_response" && ["declined","tentative"].contains(row["meetingResponse"] as? String ?? ""))))
                && outboxDate(row["occurredAt"] as? String ?? "").map { $0 >= created } == true
        }) { try outboxDeny("inbound_reply", "A reply arrived after this draft was prepared. Review the conversation before further outreach.") }
        let blockingStates: Set<String> = ["queued", "held", "paused_restart", "sending", "submitted", "unknown", "user_confirmed_sent"]
        if try all("outboxJobs").contains(where: { row in
            row["id"] as? String != jobID && blockingStates.contains(row["state"] as? String ?? "")
                && (row["draftId"] as? String == draftID || (row["phone"] as? String == phone && row["body"] as? String == body))
        }) { try outboxDeny("duplicate_job", "This draft or exact recipient and text already has a pending or sent job. Reconcile that job first.") }
        let legacyStates: Set<String> = ["prepared", "handoff_opened", "submitting", "accepted", "delivered", "unknown", "user_confirmed_sent"]
        if try all("communications").contains(where: { row in
            row["channel"] as? String == "message" && row["phone"] as? String == phone && row["body"] as? String == body
                && legacyStates.contains(row["state"] as? String ?? "")
        }) { try outboxDeny("legacy_attempt", "This exact text has an earlier communication attempt. Confirm its outcome before sending again.") }
        if external.contains(where: { row in
            row["provider"] as? String == "apple-messages" && row["direction"] as? String == "outbound"
                && row["to"] as? String == phone && row["body"] as? String == body
        }) { try outboxDeny("message_already_recorded", "This exact recipient and text already appears in imported Messages history.") }
        let connection = try outboxConnection()
        guard connection["enabled"] as? Bool == true,
              let account = connection["accountId"] as? String, !account.isEmpty,
              let label = connection["accountLabel"] as? String, !label.isEmpty else {
            try outboxDeny("connection_unavailable", "Connect and verify your Apple Messages identity before sending.")
        }
        guard let service = try? outboxService(connection["service"]),
              let expectedService = try? outboxService(request["expectedService"]) else {
            try outboxDeny("unsupported_service", "This text uses an unsupported Messages service. Review a new send with iMessage or SMS.")
        }
        if let snapshot {
            guard let frozenService = try? outboxService(snapshot["senderService"]), frozenService == service else {
                try outboxDeny("service_changed", "The Messages service changed after authorization. Cancel this job and review a new send.")
            }
        }
        guard expectedService == service else {
            try outboxDeny("service_changed", "The selected Messages service changed. Review the exact iMessage or SMS service before sending.")
        }
        if let snapshot {
            guard snapshot["senderAccountId"] as? String == account,
                  snapshot["senderAccountLabel"] as? String == label else {
                try outboxDeny("sender_changed", "The Messages sender identity changed. Cancel this job and review a new send.")
            }
        }
        return (agent, draft, connection)
    }

    private func outboxTransition(_ input: Record, state: String, extra: Record = [:]) throws -> Record {
        var job = input
        if job["senderService"] == nil { job["senderService"] = "iMessage" }
        let now = Store.now(), revision = (job["revision"] as? Int ?? 0) + 1
        job["state"] = state; job["updatedAt"] = now; job["revision"] = revision
        job.removeValue(forKey: "reasonCode"); job.removeValue(forKey: "reason")
        for (key, value) in extra { job[key] = value }
        let id = job["id"] as! String
        var event: Record = ["id":"outbox-" + id + "-" + String(revision), "jobId":id,
            "agentId":job["agentId"] ?? "", "draftId":job["draftId"] ?? "", "contactName":job["contactName"] ?? "Contact",
            "state":state, "senderService":job["senderService"] ?? "iMessage", "revision":revision, "createdAt":now, "schemaVersion":1]
        for key in ["reasonCode", "reason", "confirmationSource", "occurredAt"] where extra[key] != nil { event[key] = extra[key] }
        try put("outboxJobs", job)
        try put("outboxEvents", event)
        return job
    }

    func enqueueOutbox(_ p: Record) throws {
        try outboxFields(p, ["id", "draftId", "agentId", "phone", "body", "confirmed", "expectedUpdatedAt", "expectedService"])
        let id = try outboxID(p)
        guard p["confirmed"] as? Bool == true else { throw StoreError(message: "Confirm the exact recipient and text before adding it to the send queue.") }
        let phone = try Store.normalizedCommunicationPhone(outboxString(p, "phone", limit: 50))
        var request: Record = ["draftId":try outboxString(p, "draftId"), "agentId":try outboxString(p, "agentId"),
            "phone":phone, "body":try outboxString(p, "body", limit: 1600), "confirmed":true,
            "expectedService":try outboxService(p["expectedService"])]
        if p["expectedUpdatedAt"] != nil { request["expectedUpdatedAt"] = try outboxString(p, "expectedUpdatedAt", limit: 40) }
        if let old = try outboxRow("outboxJobs", id) {
            guard var saved = old["request"] as? Record else {
                throw StoreError(message: "This job is missing its authorized request. Reconcile it before sending.")
            }
            // Older requests predate SMS support and authorize iMessage only.
            // Normalize for comparison without rewriting their immutable history.
            if saved["expectedService"] == nil { saved["expectedService"] = "iMessage" }
            guard NSDictionary(dictionary: saved).isEqual(to: request) else {
                throw StoreError(message: "This job ID already belongs to different text. Use a new reviewed send.")
            }
            return // A replay never resets submitted, unknown, canceled, or paused.
        }
        let (agent, draft, connection): (Record, Record, Record)
        do { (agent, draft, connection) = try validateOutbox(request) }
        catch let error as OutboxEligibilityError { throw StoreError(message: error.message) }
        let sequence = (try all("outboxJobs").compactMap { $0["sequenceNumber"] as? Int }.max() ?? 0) + 1
        let now = Store.now()
        var job = request
        job["id"] = id; job["request"] = request; job["schemaVersion"] = 1
        job["createdAt"] = now; job["authorizedAt"] = now; job["authorizationSource"] = "user_exact_text"
        job["sequenceNumber"] = sequence; job["revision"] = 0; job["attemptCount"] = 0
        job["channel"] = "Message"; job["transport"] = "apple-messages"
        job["contactName"] = agent["name"]; job["contactSource"] = agent["source"]
        job["senderAccountId"] = connection["accountId"]; job["senderAccountLabel"] = connection["accountLabel"]
        job["senderService"] = connection["service"] ?? "iMessage"
        job["draftCreatedAt"] = draft["createdAt"] ?? draft["updatedAt"]
        job["draftUpdatedAt"] = draft["updatedAt"] ?? draft["createdAt"]
        job["bodyHash"] = SHA256.hash(data: Data((request["body"] as! String).utf8)).map { String(format: "%02x", $0) }.joined()
        _ = try outboxTransition(job, state: "queued")
    }

    func cancelOutbox(_ p: Record) throws {
        try outboxFields(p, ["id"])
        let job = try outboxJob(p), state = job["state"] as? String ?? ""
        if state == "cancelled" { return }
        guard ["queued", "held", "paused_restart"].contains(state) else { throw StoreError(message: "This text may already have been dispatched. Review its outcome instead of canceling it.") }
        _ = try outboxTransition(job, state: "cancelled", extra: ["reasonCode":"user_cancelled", "reason":"Canceled before dispatch."])
    }

    func resumeOutbox(_ p: Record) throws {
        try outboxFields(p, ["id", "phone", "body", "confirmed"])
        let job = try outboxJob(p)
        try validateOutboxConfirmation(p, job: job)
        guard ["held", "paused_restart"].contains(job["state"] as? String ?? "") else {
            throw StoreError(message: "Only a text held before dispatch can be resumed. An uncertain text must be reconciled.")
        }
        do { _ = try validateOutbox(job["request"] as? Record ?? job, excluding: job["id"] as? String, snapshot: job) }
        catch let error as OutboxEligibilityError { throw StoreError(message: error.message) }
        _ = try outboxTransition(job, state: "queued", extra: ["resumedAt":Store.now()])
    }

    func claimNextOutbox() throws -> Record? {
        let jobs = try all("outboxJobs")
        guard !jobs.contains(where: { $0["state"] as? String == "sending" }) else { return nil }
        for job in jobs.filter({ $0["state"] as? String == "queued" }).sorted(by: outboxOrder) {
            do { _ = try validateOutbox(job["request"] as? Record ?? job, excluding: job["id"] as? String, snapshot: job) }
            catch let error as OutboxEligibilityError {
                _ = try outboxTransition(job, state: "held", extra: ["reasonCode":error.code, "reason":error.message])
                continue
            }
            return try outboxTransition(job, state: "sending", extra: ["claimToken":UUID().uuidString.lowercased(),
                "startedAt":Store.now(), "attemptCount":(job["attemptCount"] as? Int ?? 0) + 1])
        }
        return nil
    }

    // The worker performs permission/account preflight outside the transaction.
    // Recheck once more afterward, immediately before the irreversible send.
    func revalidateOutboxClaim(_ p: Record) throws {
        try outboxFields(p, ["id", "claimToken"])
        let job = try outboxJob(p)
        guard job["state"] as? String == "sending",
              try outboxString(p, "claimToken") == job["claimToken"] as? String else {
            throw StoreError(message: "This text job no longer belongs to the active native dispatcher.")
        }
        do { _ = try validateOutbox(job["request"] as? Record ?? job, excluding: job["id"] as? String, snapshot: job) }
        catch let error as OutboxEligibilityError { throw StoreError(message: error.message) }
    }

    func finishOutbox(_ p: Record) throws {
        try outboxFields(p, ["id", "claimToken", "state", "errorCode", "dispatchStarted"])
        let job = try outboxJob(p)
        let state = try outboxString(p, "state"), token = try outboxString(p, "claimToken")
        guard ["submitted", "failed", "unknown"].contains(state), token == job["claimToken"] as? String else {
            throw StoreError(message: "The native dispatch result does not match this text job.")
        }
        var result: Record = ["state":state, "claimToken":token]
        if let started = p["dispatchStarted"] {
            guard let flag = started as? Bool else { throw StoreError(message: "Dispatch status must be a boolean.") }
            result["dispatchStarted"] = flag
        }
        if state == "failed", p["dispatchStarted"] as? Bool != false {
            throw StoreError(message: "A failure is certain only when dispatch did not start. Record an unknown outcome otherwise.")
        }
        if let raw = p["errorCode"] {
            guard state != "submitted", let code = raw as? String,
                  code.range(of: "^[A-Za-z0-9_.-]{1,80}$", options: .regularExpression) != nil else {
                throw StoreError(message: "Use a short error code without private response details.")
            }
            result["errorCode"] = code
        }
        if job["state"] as? String == state {
            guard let saved = job["dispatchResult"] as? Record, NSDictionary(dictionary:saved).isEqual(to:result) else {
                throw StoreError(message: "This dispatch result was already recorded with different details.")
            }
            return
        }
        guard job["state"] as? String == "sending" else { throw StoreError(message: "This text job is no longer being dispatched. Reconcile its saved outcome.") }
        let reason = state == "submitted" ? "Submitted to Messages. Send and delivery are not independently verified."
            : state == "failed" ? (result["errorCode"] as? String == "reply_sync_unavailable" ? "Text not sent: reply syncing needs attention. Check enabled Messages and Gmail connections, then review the conversation before a new send." : "Dispatch did not start. Review the issue before creating a new send.")
            : "Messages may have accepted this text. Check the exact conversation before deciding its outcome."
        let updated = try outboxTransition(job, state: state, extra: ["dispatchResult":result, "finishedAt":Store.now(),
            "reasonCode":result["errorCode"] ?? state, "reason":reason])
        try outboxReviewTask(updated)
    }

    func recoverOutbox() throws {
        for job in try all("outboxJobs").sorted(by: outboxOrder) {
            if job["state"] as? String == "sending" {
                let updated = try outboxTransition(job, state: "unknown", extra: ["reasonCode":"interrupted_dispatch",
                    "reason":"The app stopped during dispatch. Check Messages before any retry.", "recoveredAt":Store.now()])
                try outboxReviewTask(updated)
            } else if job["state"] as? String == "queued" {
                _ = try outboxTransition(job, state: "paused_restart", extra: ["reasonCode":"restart_review",
                    "reason":"Paused after the app restarted or a backup was restored. Review the exact text before resuming."])
            }
        }
    }

    func holdOutboxForImportedReply(agentId: String, occurredAt: String, messageId: String) throws {
        guard let reply = outboxDate(occurredAt) else { throw StoreError(message: "Invalid reply timestamp for text queue reconciliation.") }
        for job in try all("outboxJobs") where job["agentId"] as? String == agentId {
            guard ["queued", "held", "paused_restart"].contains(job["state"] as? String ?? ""),
                  let prepared = outboxDate(job["draftCreatedAt"] as? String ?? ""), reply >= prepared,
                  job["replyMessageId"] as? String != messageId else { continue }
            _ = try outboxTransition(job, state: "held", extra: ["reasonCode":"inbound_reply", "replyMessageId":messageId,
                "reason":"A reply arrived after this draft was prepared. Review the conversation before further outreach."])
        }
    }

    private func validateOutboxConfirmation(_ p: Record, job: Record) throws {
        guard p["confirmed"] as? Bool == true,
              try Store.normalizedCommunicationPhone(outboxString(p, "phone", limit: 50)) == job["phone"] as? String,
              p["body"] as? String == job["body"] as? String else {
            throw StoreError(message: "Confirm the exact recipient and unchanged text for this job.")
        }
    }

    func confirmOutbox(_ p: Record) throws {
        try outboxFields(p, ["id", "state", "confirmed", "phone", "body", "occurredAt"])
        var job = try outboxJob(p)
        try validateOutboxConfirmation(p, job: job)
        let state = try outboxString(p, "state")
        guard ["user_confirmed_sent", "not_sent"].contains(state) else { throw StoreError(message: "Choose sent or not sent after checking the exact Messages conversation.") }
        let occurred = try Store.communicationOccurrence(p["occurredAt"] ?? "")
        let confirmation: Record = ["state":state, "phone":job["phone"]!, "body":job["body"]!, "occurredAt":occurred.timestamp, "confirmationSource":"user"]
        if job["state"] as? String == state {
            guard let saved = job["confirmation"] as? Record, NSDictionary(dictionary:saved).isEqual(to:confirmation) else {
                throw StoreError(message: "This outcome was already confirmed with different details.")
            }
            return
        }
        guard ["submitted", "unknown"].contains(job["state"] as? String ?? "") else {
            throw StoreError(message: "Only a submitted or uncertain text can have its outcome confirmed.")
        }
        if state == "user_confirmed_sent" {
            let aid = job["agentId"] as! String, id = job["id"] as! String, now = Store.now()
            var agent = try get("agents", aid)
            let activityID = "outbox-" + id + "-sent"
            let activity: Record = ["id":activityID, "agentId":aid, "kind":"interaction", "activityType":"message.user_confirmed_sent",
                "templateVersion":1, "title":"Text sent — confirmed by you", "body":job["body"]!, "phone":job["phone"]!,
                "date":occurred.timestamp, "occurredAt":occurred.timestamp, "createdAt":now, "recordedAt":now,
                "author":try operatorName(), "pinned":false, "outboxJobId":id, "confirmationSource":"user",
                "evidence":"Operator checked the exact conversation; no provider delivery or read receipt is asserted."]
            guard try outboxRow("activities", activityID) == nil else { throw StoreError(message: "This text already has an activity receipt. Reconcile it before changing the outcome.") }
            try put("activities", activity)
            agent["lastInteraction"] = max(occurred.day, agent["lastInteraction"] as? String ?? "")
            try put("agents", agent)
            if var draft = try outboxRow("drafts", job["draftId"] as! String), draft["agentId"] as? String == aid,
               draft["channel"] as? String == "Message", draft["body"] as? String == job["body"] as? String,
               draft["state"] as? String == "draft" {
                draft["state"] = "sent"; draft["sentAt"] = occurred.timestamp; draft["sentOn"] = occurred.day
                draft["sentRecordedAt"] = now; draft["updatedAt"] = now; draft["outboxJobId"] = id
                draft["confirmationSource"] = "user"; try put("drafts", draft)
            }
            job["interactionId"] = activityID
        }
        job = try outboxTransition(job, state: state, extra: ["confirmation":confirmation, "confirmationSource":"user",
            "occurredAt":occurred.timestamp, "reasonCode":state,
            "reason":state == "not_sent" ? "You confirmed this text was not sent. A new send requires a new explicit decision." : "You confirmed this exact text was sent; delivery and read status are unknown."])
        try outboxReviewTask(job)
    }

    private func outboxReviewTask(_ job: Record) throws {
        let id = job["id"] as! String, aid = job["agentId"] as! String, draftID = job["draftId"] as! String
        let state = job["state"] as? String ?? "unknown", now = Store.now()
        var linked = try all("tasks").filter { $0["agentId"] as? String == aid && $0["completed"] as? Bool != true
            && ($0["outboxJobId"] as? String == id || $0["draftId"] as? String == draftID && $0["draftBody"] as? String == job["body"] as? String) }
        if linked.isEmpty {
            // A later outcome may require a new review after the operator completed
            // an earlier one. Never replace that saved completion with an open row.
            linked = [["id":"outbox-review-" + id + "-" + state, "agentId":aid, "draftId":draftID, "draftBody":job["body"]!,
                "completed":false, "createdAt":now, "dueDate":Store.day(), "type":"Review", "priority":"High", "repeatDays":0, "assignee":try operatorName()]]
        }
        for var task in linked {
            task["outboxJobId"] = id; task["outboxState"] = state; task["updatedAt"] = now
            task["title"] = String((state == "user_confirmed_sent" ? "Text sent — review outcome: " : "Review text outcome: ") .appending(job["contactName"] as? String ?? "Contact").prefix(200))
            task["description"] = (job["reason"] as? String ?? "Review this text job.") + "\n\nRecipient: " + (job["phone"] as? String ?? "")
                + "\nJob: " + id + "\n\n" + (job["body"] as? String ?? "") + "\n\nCompleting this review task does not send or retry the message."
            if state == "user_confirmed_sent" { task["draftState"] = "sent"; task["sentAt"] = job["occurredAt"] }
            try put("tasks", task)
        }
    }

    private func outboxOrder(_ a: Record, _ b: Record) -> Bool {
        let left = a["sequenceNumber"] as? Int ?? 0, right = b["sequenceNumber"] as? Int ?? 0
        return left == right ? (a["id"] as? String ?? "") < (b["id"] as? String ?? "") : left < right
    }

    func outboxStatus() throws -> Record {
        let events = try all("outboxEvents").sorted {
            let left = $0["createdAt"] as? String ?? "", right = $1["createdAt"] as? String ?? ""
            if left != right { return left < right }
            if $0["jobId"] as? String == $1["jobId"] as? String { return ($0["revision"] as? Int ?? 0) < ($1["revision"] as? Int ?? 0) }
            return ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
        }
        return ["jobs":try all("outboxJobs").sorted(by: outboxOrder), "events":events, "connection":try outboxConnection()]
    }

    func acknowledgeOutboxEvents(_ p: Record) throws {
        try outboxFields(p, ["ids"])
        guard let ids = p["ids"] as? [String], ids.count <= 500, ids.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else {
            throw StoreError(message: "Choose valid text notification IDs to acknowledge.")
        }
        for id in Set(ids) {
            guard var event = try outboxRow("outboxEvents", id) else { throw StoreError(message: "A text notification no longer exists.") }
            if event["acknowledgedAt"] == nil { event["acknowledgedAt"] = Store.now(); try put("outboxEvents", event) }
        }
    }
}
