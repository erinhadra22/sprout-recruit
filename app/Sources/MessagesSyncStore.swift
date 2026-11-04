import Foundation
import CryptoKit
import CoreFoundation

// Native-only reconciliation of a read-only Messages database page. The caller
// wraps apply/configure/failure in Store.command's transaction; UI cannot submit
// reader evidence or advance cursors directly.
extension Store {
    private func messagesSyncSaved() throws -> Record {
        try all("settings").first { $0["id"] as? String == "messages-reply-sync" } ?? [
            "id":"messages-reply-sync", "enabled":false, "status":"disabled", "generation":0,
            "cursor":0, "sourceID":"", "contactFingerprint":"", "since":NSNull(),
            "newReplyCount":0, "importedReplies":0, "totals":[String:Int](), "schemaVersion":1]
    }

    private func messagesSyncContacts() throws -> (byPhone: [String:[Record]], fingerprint: String) {
        var byPhone: [String:[Record]] = [:]
        for agent in try all("agents") {
            let id = agent["id"] as? String ?? "", source = (agent["source"] as? String ?? "").lowercased()
            guard !id.isEmpty, agent["datasetId"] as? String == "live", agent["sample"] as? Bool != true,
                  !id.hasPrefix("sample-"), agent["dataset"] as? String != "sample",
                  !source.contains("sample"), !source.contains("fictional"),
                  let phone = try? Store.normalizedCommunicationPhone(agent["phone"] as? String ?? "") else { continue }
            byPhone[phone,default:[]].append(agent)
        }
        let identities = byPhone.keys.sorted().flatMap { phone in
            (byPhone[phone] ?? []).compactMap { $0["id"] as? String }.sorted().map { phone + "\u{0}" + $0 }
        }
        return (byPhone, Self.messagesSyncHash(identities.joined(separator:"\n")))
    }

    private static func messagesSyncHash(_ text: String) -> String {
        SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
    }

    private func messagesSyncInteger(_ value: Any?, _ label: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded() == number.doubleValue, number.doubleValue <= Double(Int.max - 1) else {
            throw StoreError(message:"Messages sync returned an invalid \(label).")
        }
        return number.intValue
    }

    private func messagesSyncText(_ value: Any?, _ label: String, max: Int = 250) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.count <= max else {
            throw StoreError(message:"Messages sync returned an invalid \(label).")
        }
        return text
    }

    func messagesSyncStatus() throws -> Record {
        var state = try messagesSyncSaved()
        let contacts = try messagesSyncContacts()
        state["uniqueCandidateCount"] = contacts.byPhone.values.filter { $0.count == 1 }.count
        state["ambiguousCandidateCount"] = contacts.byPhone.values.filter { $0.count > 1 }.reduce(0) { $0 + $1.count }
        state["ambiguousPhones"] = contacts.byPhone.values.filter { $0.count > 1 }.count
        for key in ["lastSuccessAt","lastAttemptAt","lastError","errorCode"] where state[key] == nil { state[key] = NSNull() }
        return state
    }

    func configureMessagesSync(_ p: Record) throws {
        guard Set(p.keys).isSubset(of:["enabled","confirmed"]), let enabled = p["enabled"] as? Bool else {
            throw StoreError(message:"Choose whether local Messages reply sync is enabled.")
        }
        var state = try messagesSyncSaved()
        let wasEnabled = state["enabled"] as? Bool == true
        if enabled {
            guard p["confirmed"] as? Bool == true else {
                throw StoreError(message:"Confirm local Messages access for new replies from now onward. Resuming keeps the original start time.")
            }
            if !(state["since"] is String) {
                let clock = ISO8601DateFormatter()
                clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                state["since"] = clock.string(from:Date()); state["cursor"] = 0
                state["sourceID"] = ""; state["contactFingerprint"] = try messagesSyncContacts().fingerprint
            }
        }
        if enabled != wasEnabled { state["generation"] = (state["generation"] as? Int ?? 0) + 1 }
        state["enabled"] = enabled; state["status"] = enabled ? "ready" : "disabled"
        state["updatedAt"] = Store.now(); state["newReplyCount"] = 0
        if !enabled { state["lastError"] = NSNull(); state["errorCode"] = NSNull() }
        try put("settings",state)
    }

    // Read-only. A changed mapping rewinds the next scan, retaining the first
    // opt-in floor; applying that page commits the new mapping and cursor.
    func messagesSyncReadRequest() throws -> Record {
        let state = try messagesSyncSaved(), contacts = try messagesSyncContacts()
        guard state["enabled"] as? Bool == true, let since = state["since"] as? String,
              Store.activityEventDate(since) != nil else { throw StoreError(message:"Enable Messages reply sync before scanning.") }
        let savedFingerprint = state["contactFingerprint"] as? String ?? ""
        let cursor = state["cursor"] as? Int ?? 0
        return ["phones":contacts.byPhone.keys.sorted(), "since":since,
            "afterRowID":savedFingerprint == contacts.fingerprint ? cursor : 0,
            "baseCursor":cursor, "baseContactFingerprint":savedFingerprint,
            "generation":state["generation"] as? Int ?? 0, "sourceID":state["sourceID"] as? String ?? "",
            "expectedSourceID":state["sourceID"] as? String ?? "", "contactFingerprint":contacts.fingerprint]
    }

    func applyMessagesSyncBatch(request: Record, batch: Record) throws {
        var state = try messagesSyncSaved()
        let contacts = try messagesSyncContacts()
        let batchKey = Self.messagesSyncHash(String(decoding:try JSONSerialization.data(withJSONObject:["request":request,"batch":batch],options:[.sortedKeys]),as:UTF8.self))
        if state["enabled"] as? Bool == true,
           request["generation"] as? Int == state["generation"] as? Int,
           request["contactFingerprint"] as? String == contacts.fingerprint,
           state["lastAppliedBatchKey"] as? String == batchKey { return }
        guard state["enabled"] as? Bool == true,
              try messagesSyncInteger(request["generation"],"generation") == state["generation"] as? Int,
              request["since"] as? String == state["since"] as? String,
              request["sourceID"] as? String == state["sourceID"] as? String,
              request["contactFingerprint"] as? String == contacts.fingerprint,
              request["baseContactFingerprint"] as? String == state["contactFingerprint"] as? String,
              try messagesSyncInteger(request["baseCursor"],"base cursor") == state["cursor"] as? Int,
              request["phones"] as? [String] == contacts.byPhone.keys.sorted() else {
            throw StoreError(message:"Messages sync configuration or contact identities changed during the scan. Scan again before applying this page.")
        }
        guard Set(batch.keys).isSubset(of:["sourceID","nextRowID","hasMore","messages","scannedCount","scannedFromRowID","observedAt"]),
              let rows = batch["messages"] as? [Record], rows.count <= 1000,
              let hasMore = batch["hasMore"] as? Bool else { throw StoreError(message:"Messages sync returned an invalid page.") }
        let sourceID = try messagesSyncText(batch["sourceID"],"source database identity",max:500)
        let next = try messagesSyncInteger(batch["nextRowID"],"next row"), scanned = try messagesSyncInteger(batch["scannedCount"],"scanned count")
        let requestedAfter = try messagesSyncInteger(request["afterRowID"],"requested row")
        let expectedAfter = (state["contactFingerprint"] as? String ?? "") == contacts.fingerprint ? (state["cursor"] as? Int ?? 0) : 0
        let actualAfter = try messagesSyncInteger(batch["scannedFromRowID"],"page starting row")
        let sourceChanged = sourceID != (state["sourceID"] as? String ?? "")
        guard requestedAfter == expectedAfter, actualAfter == (sourceChanged ? 0 : requestedAfter),
              next >= actualAfter, scanned <= 10000, rows.count <= scanned,
              !hasMore || next > actualAfter else { throw StoreError(message:"Messages source or cursor changed without a complete restart. The cursor was not advanced.") }
        guard let floor = Store.activityEventDate(state["since"] as? String ?? "") else { throw StoreError(message:"The Messages sync start time is unavailable.") }
        let now = Store.now()
        let observedAt = batch["observedAt"] as? String ?? now
        guard let observedDate = Store.activityEventDate(observedAt), observedDate <= Date().addingTimeInterval(1) else {
            throw StoreError(message:"Messages sync returned an invalid observation time.")
        }
        var imported = 0, duplicates = 0, ambiguous = 0, unmatched = 0, historical = 0
        var sourceRows = Set<Int>()
        for row in rows {
            guard Set(row.keys).isSubset(of:["providerMessageId","providerThreadId","phone","occurredAt","body","bodyKind","service","sourceRowID","direction","isGroup","accountAddress"]),
                  row["direction"] as? String == "inbound", row["isGroup"] as? Bool == false else {
                throw StoreError(message:"Only verified inbound, one-to-one Messages rows may be imported.")
            }
            let rowID = try messagesSyncInteger(row["sourceRowID"],"message row")
            guard rowID > actualAfter, rowID <= next, sourceRows.insert(rowID).inserted else { throw StoreError(message:"Messages sync returned repeated or out-of-page rows.") }
            let guid = try messagesSyncText(row["providerMessageId"],"message GUID")
            let chat = try messagesSyncText(row["providerThreadId"],"conversation GUID",max:500)
            guard !guid.contains(where:{$0.isWhitespace}), !chat.contains(where:{$0.isWhitespace}) else { throw StoreError(message:"Messages source GUIDs must be exact.") }
            let phone = try Store.normalizedCommunicationPhone(messagesSyncText(row["phone"],"sender",max:50))
            let time = try messagesSyncText(row["occurredAt"],"message time",max:50)
            guard let occurred = Store.activityEventDate(time), occurred <= Date().addingTimeInterval(300) else { throw StoreError(message:"Messages sync returned an invalid message time.") }
            let occurredAt = ISO8601DateFormatter().string(from:occurred)
            let bodyKind = try messagesSyncText(row["bodyKind"],"body type",max:30)
            let service = try messagesSyncText(row["service"],"service",max:30)
            guard ["text","attachment","unavailable","reaction"].contains(bodyKind), ["iMessage","SMS","RCS"].contains(service),
                  let body = row["body"] as? String, body.count <= 50000,
                  bodyKind != "text" || !body.isEmpty else { throw StoreError(message:"Messages sync returned unsupported message content.") }
            var account: String?
            if let raw = row["accountAddress"], !(raw is NSNull) {
                let value = try messagesSyncText(raw,"receiving handle",max:320).trimmingCharacters(in:.whitespacesAndNewlines)
                if value.contains("@") {
                    guard value.range(of:"^[^\\s@<>]+@[^\\s@<>]+\\.[^\\s@<>]+$",options:.regularExpression) != nil else { throw StoreError(message:"Messages returned an invalid receiving email handle.") }
                    account = value.lowercased()
                } else { account = try Store.normalizedCommunicationPhone(value) }
                guard account != phone else { throw StoreError(message:"Messages sender and receiving handle cannot be the same.") }
            }
            if occurred < floor { historical += 1; continue }
            let matches = contacts.byPhone[phone] ?? []
            if matches.isEmpty { unmatched += 1; continue }
            if matches.count > 1 {
                ambiguous += 1
                let taskID = try messagesSyncAmbiguityTask(phone:phone,agents:matches,guid:guid,sourceID:sourceID,rowID:rowID)
                try messagesSyncRecordIdentityHold(phone:phone,agents:matches,guid:guid,occurredAt:occurredAt,
                    sourceID:sourceID,rowID:rowID,taskID:taskID)
                continue
            }
            let agent = matches[0], aid = agent["id"] as! String
            let sourceEvidence: Record = ["sourceID":sourceID,"sourceRowID":rowID,"providerMessageId":guid,"providerThreadId":chat,
                "direction":"inbound","isGroup":false,"readAt":now,"method":"local_messages_database"]
            let existing = try all("externalMessages").filter { $0["provider"] as? String == "apple-messages" && $0["providerMessageId"] as? String == guid }
            if !existing.isEmpty {
                guard existing.count == 1 else { throw StoreError(message:"A Messages GUID has multiple saved owners. Reconcile the records before syncing.") }
                var saved = existing[0]
                guard saved["agentId"] as? String == aid, saved["direction"] as? String == "inbound",
                      saved["from"] as? String == phone, saved["body"] as? String == body,
                      Store.activityEventDate(saved["occurredAt"] as? String ?? "").map({ISO8601DateFormatter().string(from:$0)}) == occurredAt,
                      (saved["providerThreadId"] as? String == chat),
                      account == nil || !(saved["accountAddress"] is String) || saved["accountAddress"] as? String == account else {
                    throw StoreError(message:"A Messages GUID is already linked to different contact or content evidence. Nothing from this page was applied.")
                }
                var observations = saved["nativeSourceObservations"] as? [Record] ?? []
                if !observations.contains(where:{$0["sourceID"] as? String == sourceID && $0["sourceRowID"] as? Int == rowID}) {
                    observations.append(sourceEvidence); saved["nativeSourceObservations"] = Array(observations.suffix(20)); try put("externalMessages",saved)
                }
                try messagesSyncClearIdentityHold(phone:phone,guid:guid,externalMessageId:saved["id"] as! String)
                duplicates += 1; continue
            }
            let id = "external-" + Self.messagesSyncHash("apple-messages\u{0}local-messages\u{0}" + guid)
            let content: Record = ["agentId":aid,"channel":"Message","provider":"apple-messages","accountScope":"local-messages",
                "accountAddress":account as Any? ?? NSNull(),"providerMessageId":guid,"providerThreadId":chat,"direction":"inbound",
                "from":phone,"to":account as Any? ?? NSNull(),"occurredAt":occurredAt,"subject":"","body":body,"bodyKind":bodyKind,"service":service]
            var record = content; record["id"] = id; record["content"] = content; record["importedAt"] = now
            record["schemaVersion"] = 2; record["syncSource"] = "local-messages"; record["sourceEvidence"] = sourceEvidence; record["nativeSourceObservations"] = [sourceEvidence]
            try put("externalMessages",record)
            try pauseSequencesForImportedReply(agentId:aid,occurredAt:occurredAt,messageId:id)
            try holdOutboxForImportedReply(agentId:aid,occurredAt:occurredAt,messageId:id)
            let outcome = try messagesSyncReplyTask(agent:agent,message:record)
            for (key,value) in outcome { record[key] = value }
            try put("externalMessages",record)
            try messagesSyncClearIdentityHold(phone:phone,guid:guid,externalMessageId:id)
            imported += 1
        }
        var totals = state["totals"] as? [String:Int] ?? [:]
        for (key,value) in [("imported",imported),("duplicates",duplicates),("ambiguous",ambiguous),("unmatched",unmatched),("beforeStart",historical),("scanned",scanned)] { totals[key,default:0] += value }
        state["sourceID"] = sourceID; state["cursor"] = next; state["contactFingerprint"] = contacts.fingerprint
        state["status"] = hasMore ? "syncing" : "ready"; state["lastAttemptAt"] = now
        state["lastAppliedAt"] = now
        if !hasMore { state["lastSuccessAt"] = observedAt; state["lastError"] = NSNull(); state["errorCode"] = NSNull() }
        let scanImported = (state["pendingScanImported"] as? Int ?? 0) + imported
        state["pendingScanImported"] = hasMore ? scanImported : 0
        state["newReplyCount"] = hasMore ? 0 : scanImported
        state["importedReplies"] = (state["importedReplies"] as? Int ?? 0) + imported
        state["totals"] = totals; state["hasMore"] = hasMore; state["updatedAt"] = now
        state["lastAppliedBatchKey"] = batchKey
        try put("settings",state)
        if !hasMore {
            for var task in try all("tasks") where task["reviewKind"] as? String == "messages-sync-error" && task["completed"] as? Bool != true {
                task["completed"] = true; task["completedAt"] = now; task["resolution"] = "A later Messages reply scan completed successfully."; try put("tasks",task)
            }
        }
    }

    @discardableResult
    private func messagesSyncTask(_ key: String, title: String, description: String, agentId: String? = nil,
                                  sourceRefs: [String], relatedMessageIds: [String], extra: Record = [:]) throws -> String {
        var task = try all("tasks").first { $0["reviewKey"] as? String == key && $0["completed"] as? Bool != true }
            ?? ["id":UUID().uuidString,"createdAt":Store.now(),"completed":false,"assignee":try operatorName(),"repeatDays":0]
        task["reviewKey"] = key; task["title"] = String(title.prefix(200)); task["description"] = description
        task["dueDate"] = Store.day(); task["type"] = "Review"; task["priority"] = "High"; task["updatedAt"] = Store.now()
        if let agentId { task["agentId"] = agentId }
        task["sourceRefs"] = Array(Set((task["sourceRefs"] as? [String] ?? []) + sourceRefs)).sorted().suffix(20).map{$0}
        task["relatedMessageIds"] = Array(Set((task["relatedMessageIds"] as? [String] ?? []) + relatedMessageIds)).sorted().suffix(50).map{$0}
        for (field,value) in extra { task[field] = value }
        try put("tasks",task)
        guard let id = task["id"] as? String, try get("tasks",id)["completed"] as? Bool == false else { throw StoreError(message:"The Messages reply review task could not be verified.") }
        return id
    }

    private func messagesSyncAmbiguityTask(phone: String, agents: [Record], guid: String, sourceID: String, rowID: Int) throws -> String {
        let ids = agents.compactMap{$0["id"] as? String}.sorted()
        return try messagesSyncTask("messages-sync-ambiguity:" + phone,
            title:"Resolve shared phone number before importing replies",
            description:"A new one-to-one Messages reply matches more than one saved contact. No message was attached and no contact status was changed. Outbound texts to this phone are held pending identity review; active sequences for the possible contacts are paused with an ambiguous-identity reason. Verify which contact owns \(phone), correct the duplicate phone assignments, then run reply sync again. The scan will revisit replies from the original opt-in time. Review any paused sequences before explicitly resuming them.\n\nCandidate IDs: \(ids.joined(separator:", "))\nMessages GUID: \(guid)\nSource database: \(sourceID)\nSource row: \(rowID)",
            sourceRefs:["Messages database " + sourceID,"Messages row " + String(rowID)],relatedMessageIds:[guid],
            extra:["reviewKind":"messages-sync-ambiguous-phone","candidateIDs":ids,"phone":phone,
                   "decisionOptions":["Correct the duplicate phone assignments","Keep unresolved; do not attach this reply"]])
    }

    // A phone can be unsafe to send to without identifying who replied. This
    // metadata is deliberately separate from contact correspondence and contains
    // no message body. A newer draft never overrides unresolved ownership.
    func messagesSyncHoldReason(phone: String, draftCreatedAt: String) throws -> String? {
        let normalized = try Store.normalizedCommunicationPhone(phone)
        let id = "messages-sync-phone-hold-" + Self.messagesSyncHash(normalized)
        guard let hold = try all("settings").first(where:{$0["id"] as? String == id}),
              hold["state"] as? String == "pending",
              !(hold["pendingReplies"] as? [Record] ?? []).isEmpty else { return nil }
        return "A reply from this phone matches multiple contacts. Resolve the shared phone identity and sync the exact reply before sending further texts, including newly prepared drafts."
    }

    private func messagesSyncRecordIdentityHold(phone: String, agents: [Record], guid: String,
                                                occurredAt: String, sourceID: String, rowID: Int, taskID: String) throws {
        let id = "messages-sync-phone-hold-" + Self.messagesSyncHash(phone), now = Store.now()
        var hold = try all("settings").first(where:{$0["id"] as? String == id})
            ?? ["id":id,"phone":phone,"createdAt":now,"schemaVersion":1]
        var pending = hold["pendingReplies"] as? [Record] ?? []
        if !pending.contains(where:{$0["providerMessageId"] as? String == guid}) {
            pending.append(["providerMessageId":guid,"occurredAt":occurredAt,"sourceID":sourceID,
                "sourceRowID":rowID,"reviewTaskId":taskID])
        }
        hold["pendingReplies"] = pending; hold["state"] = "pending"; hold["updatedAt"] = now
        hold["reviewTaskId"] = taskID; hold["reasonCode"] = "ambiguous_reply_identity"
        try put("settings",hold)
        let ids = Set(agents.compactMap{$0["id"] as? String})
        var paused: [String] = []
        for var sequence in try all("sequences") where ids.contains(sequence["agentId"] as? String ?? "") && sequence["state"] as? String == "active" {
            guard let sid = sequence["id"] as? String else { continue }
            sequence["state"] = "paused"; sequence["pauseReason"] = "ambiguous_reply_identity"
            sequence["identityReviewTaskId"] = taskID; sequence["identityReviewPhone"] = phone; sequence["updatedAt"] = now
            try put("sequences",sequence); paused.append(sid)
        }
        if !paused.isEmpty {
            try put("workflowEvents",["id":"ambiguous-reply-pause-" + Self.messagesSyncHash(phone + "\u{0}" + guid),
                "type":"messagesSync.ambiguous_reply_identity","candidateIds":ids.sorted(),"sequenceIds":paused.sorted(),
                "phone":phone,"providerMessageId":guid,"identityReviewTaskId":taskID,
                "occurredAt":occurredAt,"recordedAt":now,"source":"local_messages_database","schemaVersion":1])
        }
    }

    private func messagesSyncClearIdentityHold(phone: String, guid: String, externalMessageId: String) throws {
        let id = "messages-sync-phone-hold-" + Self.messagesSyncHash(phone)
        guard var hold = try all("settings").first(where:{$0["id"] as? String == id}) else { return }
        let pending = hold["pendingReplies"] as? [Record] ?? []
        guard pending.contains(where:{$0["providerMessageId"] as? String == guid}) else { return }
        let remaining = pending.filter{$0["providerMessageId"] as? String != guid}
        hold["pendingReplies"] = remaining; hold["updatedAt"] = Store.now()
        hold["lastReconciledMessageId"] = externalMessageId; hold["lastReconciledProviderMessageId"] = guid
        if remaining.isEmpty { hold["state"] = "resolved"; hold["resolvedAt"] = Store.now() }
        try put("settings",hold)
        // Human identity review and paused sequences are not silently completed
        // or resumed just because the source row now has a unique match.
    }

    private func messagesSyncReplyTask(agent: Record, message: Record) throws -> Record {
        let aid = agent["id"] as! String, id = message["id"] as! String, guid = message["providerMessageId"] as! String
        let sequenceIDs = try all("sequences").filter { $0["agentId"] as? String == aid && $0["replyMessageId"] as? String == id }.compactMap{$0["id"] as? String}
        let jobIDs = try all("outboxJobs").filter { $0["agentId"] as? String == aid && $0["replyMessageId"] as? String == id && $0["state"] as? String == "held" }.compactMap{$0["id"] as? String}
        let kind = message["bodyKind"] as? String ?? "text"
        let taskID = try messagesSyncTask("messages-sync-reply:" + id,
            title:"Review new text reply — " + (agent["name"] as? String ?? "Contact"),
            description:"Review the imported \(kind) reply in this contact's conversation. Decide whether to reply, update recruiting status, or leave follow-up paused. No recruiting status was changed automatically.\n\nReceived: \(message["occurredAt"] ?? "")\nFrom: \(message["from"] ?? "")\nMessages GUID: \(guid)\nConversation GUID: \(message["providerThreadId"] ?? "")\nSaved correspondence: \(id)\nSequences paused or output held: \(sequenceIDs.count)\nQueued text jobs held: \(jobIDs.count)\n\nCompleting this review does not authorize sending or resuming outreach.",agentId:aid,
            sourceRefs:["externalMessages:" + id,"Messages GUID " + guid],relatedMessageIds:[guid],
            extra:["reviewKind":"messages-sync-reply","externalMessageId":id,"providerMessageId":guid,
                   "pausedSequenceIds":sequenceIDs,"heldOutboxJobIds":jobIDs,
                   "decisionOptions":["Review and prepare a reply","Update recruiting status","Keep follow-up paused"]])
        return ["reviewTaskId":taskID,"followUpsPaused":!sequenceIDs.isEmpty || !jobIDs.isEmpty,
                "pausedSequenceCount":sequenceIDs.count,"heldOutboxCount":jobIDs.count]
    }

    func recordMessagesSyncFailure(_ p: Record) throws {
        guard Set(p.keys).isSubset(of:["generation","errorCode","message","status"]) else { throw StoreError(message:"Unexpected Messages sync failure fields.") }
        var state = try messagesSyncSaved()
        guard state["enabled"] as? Bool == true, try messagesSyncInteger(p["generation"],"generation") == state["generation"] as? Int else { return }
        let code = try messagesSyncText(p["errorCode"],"error code",max:100)
        guard code.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil else { throw StoreError(message:"Invalid Messages sync error code.") }
        let message = try messagesSyncText(p["message"],"failure explanation",max:1000)
        let status = p["status"] as? String ?? "blocked"
        guard ["blocked","error"].contains(status) else { throw StoreError(message:"Invalid Messages sync failure status.") }
        state["status"] = status; state["lastAttemptAt"] = Store.now(); state["lastError"] = message; state["errorCode"] = code; state["newReplyCount"] = 0
        try put("settings",state)
        let accessAction = code.lowercased().contains("permission") || code.lowercased().contains("access")
            ? "If macOS denied access, first review that Full Disk Access is broad permission. If you choose to proceed, manually enable Sprout Recruit in System Settings → Privacy & Security → Full Disk Access, reopen Sprout Recruit, then run a new reply scan. The app will not grant this permission automatically."
            : "Review the reported source/schema or identity issue, resolve it, then run a new reply scan."
        try messagesSyncTask("messages-sync-error",title:"Restore Messages reply sync",
            description:"Messages reply sync could not complete. \(accessAction) The saved cursor and original start time were preserved.\n\n\(message)\nError code: \(code)",
            sourceRefs:["settings:messages-reply-sync"],relatedMessageIds:[],
            extra:["reviewKind":"messages-sync-error","errorCode":code,"decisionOptions":["Fix access and scan again","Disable reply sync explicitly"]])
    }
}
