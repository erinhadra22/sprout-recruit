import Foundation

// Persistence only. Network requests and system handoffs belong to the native adapter.
// Invoke these methods through Store.command so the attempt and any activity commit together.
extension Store {
    static func normalizedCommunicationPhone(_ input: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.\u{00a0}")
        guard input.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw StoreError(message: "Use a phone number with its country code, such as +1 512 555 0123.")
        }
        var value = input.filter { "+0123456789".contains($0) }
        // This personal US workspace accepts familiar domestic formatting; other countries need +.
        if !value.contains("+") {
            if value.count == 10 { value = "+1" + value }
            else if value.count == 11 && value.hasPrefix("1") { value = "+" + value }
        }
        guard value.range(of: "^\\+[1-9][0-9]{7,14}$", options: .regularExpression) != nil else {
            throw StoreError(message: "Enter a valid phone number beginning with + and its country code.")
        }
        return value
    }

    private func communicationString(_ p: Record, _ key: String, limit: Int = 200) throws -> String {
        guard let value = p[key] as? String, !value.isEmpty, value.count <= limit else {
            throw StoreError(message: "A valid \(key) is required for this communication.")
        }
        return value
    }

    private func communicationAttemptID(_ p: Record) throws -> String {
        let id = try communicationString(p, "id", limit: 36)
        guard UUID(uuidString: id) != nil else { throw StoreError(message: "Use a stable UUID for this communication attempt.") }
        return id
    }

    private func existingCommunication(_ id: String) throws -> Record? {
        try all("communications").first { ($0["id"] as? String)?.lowercased() == id.lowercased() }
    }

    private func validateCommunicationTarget(_ target: String, agentId: String?, phone: String) throws {
        if target == "test" { return }
        guard target == "agent", let aid = agentId else { throw StoreError(message: "Choose a test recipient or a manual contact.") }
        let agent = try get("agents", aid)
        let source = (agent["source"] as? String ?? "").lowercased()
        let sample = aid.lowercased().hasPrefix("sample-") || source.contains("fictional") || source.contains("sample")
            || agent["sample"] as? Bool == true || agent["dataset"] as? String == "sample" || agent["datasetId"] as? String == "sample"
        guard !sample else {
            throw StoreError(message: "Sample agents cannot receive calls or messages.")
        }
        let verification = agent["communicationVerification"] as? Record
        let reviewedImported = agent["datasetId"] as? String == "live"
            && verification?["confirmed"] as? Bool == true
            && verification?["name"] as? String == agent["name"] as? String
            && verification?["source"] as? String == agent["source"] as? String
            && verification?["phone"] as? String == phone
        guard agent["manual"] as? Bool == true || reviewedImported else {
            throw StoreError(message: "Review this imported contact and its exact phone before communication.")
        }
        let status = (agent["status"] as? String ?? "").lowercased()
        guard !["do not contact", "not interested"].contains(status), agent["doNotContact"] as? Bool != true else {
            throw StoreError(message: "This contact is marked not to receive recruiting outreach.")
        }
        guard let currentPhone = agent["phone"] as? String,
              try Store.normalizedCommunicationPhone(currentPhone) == phone else {
            throw StoreError(message: "The recipient must match the phone number saved on this contact.")
        }
    }

    static func communicationOccurrence(_ raw: Any) throws -> (timestamp: String, day: String) {
        guard let value = raw as? String, value.count <= 40 else { throw StoreError(message:"Use the actual interaction date and time.") }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        guard let date = fractional.date(from:value) ?? ISO8601DateFormatter().date(from:value), date <= Date() else {
            throw StoreError(message:"The interaction date and time must be valid and cannot be in the future.")
        }
        return (ISO8601DateFormatter().string(from:date),Store.day(date))
    }

    private func validateCommunicationDraft(_ request: Record) throws {
        guard let raw = request["draftId"] else { return }
        guard let id = raw as? String, !id.isEmpty,
              request["target"] as? String == "agent", request["channel"] as? String == "message" else {
            throw StoreError(message:"A linked draft requires an exact contact message.")
        }
        let draft = try get("drafts",id)
        guard draft["agentId"] as? String == request["agentId"] as? String,
              draft["channel"] as? String == "Message", draft["state"] as? String == "draft",
              draft["body"] as? String == request["body"] as? String,
              !["paused_reply","rejected","blocked_contact"].contains(draft["approvalState"] as? String ?? "") else {
            throw StoreError(message:"This draft changed, was rejected, or is paused. Review the current saved draft before sending.")
        }
    }

    private func reconcileSentDraft(_ communication: inout Record, at recordedAt: String) throws {
        guard ["user_confirmed_sent","delivered"].contains(communication["state"] as? String ?? ""),
              let draftId = communication["draftId"] as? String else { return }
        guard var draft = try? get("drafts",draftId) else {
            communication["draftReconciliationState"] = "missing_draft"; return
        }
        guard draft["agentId"] as? String == communication["agentId"] as? String,
              draft["channel"] as? String == "Message", draft["body"] as? String == communication["body"] as? String else {
            communication["draftReconciliationState"] = "changed_draft"; return
        }
        guard draft["state"] as? String == "draft",
              !["paused_reply","rejected","blocked_contact"].contains(draft["approvalState"] as? String ?? "") else {
            communication["draftReconciliationState"] = "held_draft"; return
        }
        let communicationId = communication["id"] as? String ?? ""
        draft["state"] = "sent"; draft["communicationId"] = communicationId
        draft["sentRecordedAt"] = recordedAt; draft["updatedAt"] = recordedAt
        draft["sentOn"] = communication["occurredOn"]
        if let sentAt = communication["occurredAt"] { draft["sentAt"] = sentAt }
        try put("drafts",draft)
        communication["draftReconciliationState"] = "sent"
        // Sending and reviewing the outcome are separate actions. Keep review
        // tasks open, but remove the stale claim that their exact draft is unsent.
        for var task in try all("tasks") where task["draftId"] as? String == draftId && task["completed"] as? Bool != true {
            guard task["agentId"] as? String == draft["agentId"] as? String,
                  task["draftBody"] as? String == draft["body"] as? String else { continue }
            let name = (try? get("agents",draft["agentId"] as? String ?? ""))?["name"] as? String ?? "contact"
            task["title"] = String("Message sent — review outcome: \(name)".prefix(200))
            let occurrence = communication["occurredAt"] as? String ?? ((communication["occurredOn"] as? String ?? "") + " (time not recorded)")
            task["description"] = "This exact message was sent at \(occurrence). Review its outcome separately; this task remains open.\n\n" + (draft["body"] as? String ?? "")
            task["sentCommunicationId"] = communicationId; task["draftState"] = "sent"; task["updatedAt"] = recordedAt
            if let sentAt = communication["occurredAt"] { task["sentAt"] = sentAt }
            try put("tasks",task)
        }
    }

    private func communicationProviderID(_ value: Any?) throws -> String? {
        guard let value = value else { return nil }
        guard let id = value as? String, UUID(uuidString: id) != nil else {
            throw StoreError(message: "The provider response needs a valid message UUID.")
        }
        return id.lowercased()
    }

    func prepareCommunication(_ p: Record) throws {
        let allowed: Set<String> = ["id", "channel", "transport", "target", "agentId", "phone", "sender", "body", "consentConfirmed", "draftId"]
        guard Set(p.keys).isSubset(of: allowed) else { throw StoreError(message: "Unexpected communication fields were supplied.") }
        let id = try communicationAttemptID(p)
        let channel = try communicationString(p, "channel")
        let transport = try communicationString(p, "transport")
        let target = try communicationString(p, "target")
        guard ["message", "call"].contains(channel), ["test", "agent"].contains(target),
              (channel == "message" && ["apple-messages", "telnyx"].contains(transport))
                || (channel == "call" && transport == "system-phone") else {
            throw StoreError(message: "Choose a supported communication channel and transport.")
        }
        let phone = try Store.normalizedCommunicationPhone(communicationString(p, "phone", limit: 50))
        let body = p["body"] as? String ?? ""
        guard body.count <= 1600,
              channel == "message" ? !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : body.isEmpty else {
            throw StoreError(message: "Messages require text of up to 1,600 characters; calls do not have a message body.")
        }
        if let supplied = p["body"], !(supplied is String) { throw StoreError(message: "Message text must be a string.") }
        var request: Record = ["channel": channel, "transport": transport, "target": target, "phone": phone, "body": body]
        if let draftId = p["draftId"] { request["draftId"] = draftId }
        if transport == "telnyx" {
            request["sender"] = try Store.normalizedCommunicationPhone(communicationString(p, "sender", limit: 50))
        } else if p["sender"] != nil { throw StoreError(message: "The system chooses the outgoing line for this handoff.") }
        if target == "test" {
            guard p["consentConfirmed"] as? Bool == true, p["agentId"] == nil else {
                throw StoreError(message: "Confirm this is a test number you control or have permission to use.")
            }
            request["consentConfirmed"] = true
        } else {
            request["agentId"] = try communicationString(p, "agentId")
            guard p["consentConfirmed"] == nil else { throw StoreError(message: "Test consent is only used for test recipients.") }
        }
        if let old = try existingCommunication(id) {
            guard let original = old["request"] as? Record,
                  NSDictionary(dictionary: original).isEqual(to: request) else {
                throw StoreError(message: "This attempt ID already belongs to different communication content. Start a new attempt.")
            }
            return // In particular, never reset submitting/unknown to prepared on replay.
        }
        try validateCommunicationTarget(target, agentId: request["agentId"] as? String, phone: phone)
        try validateCommunicationDraft(request)
        let now = Store.now()
        var record = request
        record["id"] = id
        record["request"] = request
        record["state"] = "prepared"
        record["createdAt"] = now
        record["updatedAt"] = now
        record["schemaVersion"] = 1
        record["history"] = [["state": "prepared", "at": now]]
        try put("communications", record)

    }

    func updateCommunication(_ p: Record) throws {
        let allowed: Set<String> = ["id", "state", "providerId", "errorCode", "phone", "body", "confirmed", "occurredOn", "occurredAt"]
        guard Set(p.keys).isSubset(of: allowed) else { throw StoreError(message: "Unexpected communication update fields were supplied.") }
        let requestedID = try communicationAttemptID(p)
        guard var record = try existingCommunication(requestedID),
              let id = record["id"] as? String, let old = record["state"] as? String,
              let channel = record["channel"] as? String, let transport = record["transport"] as? String,
              let target = record["target"] as? String, let phone = record["phone"] as? String else {
            throw StoreError(message: "That communication attempt is unavailable or invalid.")
        }
        let state = try communicationString(p, "state")
        let confirmationStates: Set<String> = ["user_confirmed_sent", "user_confirmed_call"]
        let providerStates: Set<String> = ["submitting", "accepted", "delivered", "failed", "unknown"]
        let handoffStates: Set<String> = ["handoff_opened", "handoff_cancelled", "cancelled", "user_confirmed_sent", "user_confirmed_call"]
        guard providerStates.contains(state) || handoffStates.contains(state) else {
            throw StoreError(message: "Unsupported communication state.")
        }
        if transport == "telnyx" {
            guard providerStates.contains(state) else { throw StoreError(message: "Provider messages require a provider result, not a system handoff result.") }
        } else {
            guard handoffStates.contains(state), p["providerId"] == nil else {
                throw StoreError(message: "A system handoff cannot prove provider acceptance or delivery.")
            }
        }
        if state == "user_confirmed_sent" && channel != "message" || state == "user_confirmed_call" && channel != "call" {
            throw StoreError(message: "The confirmation does not match this communication channel.")
        }
        if state == "delivered" && channel != "message" { throw StoreError(message: "Message delivery does not establish a completed call.") }
        var providerId = try communicationProviderID(record["providerId"])
        if let supplied = try communicationProviderID(p["providerId"]) {
            guard providerId == nil || providerId == supplied else { throw StoreError(message: "The provider ID cannot change for an existing attempt.") }
            let duplicate = try all("communications").contains { row in
                (row["id"] as? String)?.lowercased() != id.lowercased() && (row["providerId"] as? String)?.lowercased() == supplied
            }
            guard !duplicate else { throw StoreError(message: "That provider result is already associated with another attempt.") }
            providerId = supplied
        }
        if ["accepted", "delivered"].contains(state), providerId == nil {
            throw StoreError(message: "A stable provider message ID is required before recording acceptance or delivery.")
        }
        if old == "unknown", state != old {
            guard record["providerId"] is String, ["accepted", "delivered", "failed"].contains(state) else {
                throw StoreError(message: "This uncertain attempt cannot be retried. Reconcile its existing provider result first.")
            }
        }
        let transitions: [String: Set<String>] = [
            "prepared": ["handoff_opened", "handoff_cancelled", "submitting"],
            "handoff_opened": ["user_confirmed_sent", "user_confirmed_call", "cancelled"],
            "submitting": ["accepted", "failed", "unknown"],
            "accepted": ["delivered", "failed"],
            "unknown": ["accepted", "delivered", "failed"]
        ]
        guard state == old || transitions[old]?.contains(state) == true else {
            throw StoreError(message: "Cannot change a communication from \(old) to \(state).")
        }
        if state == "submitting" || state == "handoff_opened" {
            try validateCommunicationTarget(target, agentId: record["agentId"] as? String, phone: phone)
            try validateCommunicationDraft(record)
        }
        var event: Record = ["state": state]
        if let providerId = providerId { event["providerId"] = providerId }
        if let rawError = p["errorCode"] {
            guard ["failed", "unknown", "handoff_cancelled", "cancelled"].contains(state), let code = rawError as? String,
                  code.range(of: "^[A-Za-z0-9_.-]{1,80}$", options: .regularExpression) != nil else {
                throw StoreError(message: "Use a short error code without private response details.")
            }
            event["errorCode"] = code
        }
        if confirmationStates.contains(state) {
            guard p["confirmed"] as? Bool == true,
                  try Store.normalizedCommunicationPhone(communicationString(p, "phone", limit: 50)) == phone else {
                throw StoreError(message: "Explicitly confirm the exact recipient before recording this interaction.")
            }
            if channel == "message" {
                guard let echo = p["body"] as? String, echo == record["body"] as? String else {
                    throw StoreError(message: "Confirm the exact text that was sent. Changed text needs a separate, correctly recorded attempt.")
                }
            } else if p["body"] != nil { throw StoreError(message: "Call confirmation does not include message text.") }
            event["confirmationSource"] = "user"
        } else {
            guard p["confirmed"] == nil, p["phone"] == nil, p["body"] == nil else {
                throw StoreError(message: "Recipient confirmation is only used for user-confirmed system handoffs.")
            }
            if ["accepted", "delivered"].contains(state) { event["confirmationSource"] = "provider" }
        }
        let logsInteraction = confirmationStates.contains(state) || state == "delivered"
        if logsInteraction {
            let occurrence = try (p["occurredAt"] ?? (state == old ? record["occurredAt"] : nil)).map { try Store.communicationOccurrence($0) }
            let date = p["occurredOn"] as? String ?? occurrence?.day ?? (state == old ? record["occurredOn"] as? String : nil) ?? Store.day()
            guard Store.parseDay(date) != nil, date <= Store.day(), occurrence == nil || occurrence?.day == date else { throw StoreError(message: "The interaction date must be today or earlier and match its timestamp.") }
            if let raw = p["occurredOn"], !(raw is String) { throw StoreError(message: "The interaction date must be a calendar date.") }
            event["occurredOn"] = date
            if let occurrence { event["occurredAt"] = occurrence.timestamp }
        } else if p["occurredOn"] != nil || p["occurredAt"] != nil { throw StoreError(message: "Only a completed interaction has an occurrence date.") }

        // An exact repeated update is harmless; a different receipt under the same state is not silently accepted.
        if state == old {
            guard let previous = record["lastUpdate"] as? Record, NSDictionary(dictionary: previous).isEqual(to: event) else {
                throw StoreError(message: "This state was already recorded with different details. Reconcile the existing receipt.")
            }
            return
        }
        let now = Store.now()
        record["state"] = state
        record["updatedAt"] = now
        record["lastUpdate"] = event
        if let providerId = providerId { record["providerId"] = providerId }
        if let date = event["occurredOn"] { record["occurredOn"] = date }
        if let timestamp = event["occurredAt"] { record["occurredAt"] = timestamp }
        if let source = event["confirmationSource"] { record["confirmationSource"] = source }
        if let error = event["errorCode"] { record["errorCode"] = error }
        var history = record["history"] as? [Record] ?? []
        var historyEvent = event; historyEvent["at"] = now; history.append(historyEvent)
        record["history"] = history
        if logsInteraction, target == "agent", let aid = record["agentId"] as? String, let date = event["occurredOn"] as? String {
            let activityID = "communication-" + id.lowercased()
            let alreadyLogged = try all("activities").contains { $0["id"] as? String == activityID }
            if !alreadyLogged {
                var agent = try get("agents", aid)
                let title = state == "delivered" ? "Message — provider-confirmed delivered"
                    : state == "user_confirmed_sent" ? "Message — user-confirmed sent" : "Call — user-confirmed completed"
                var activity: Record = ["id": activityID, "agentId": aid, "kind": "interaction", "title": title,
                    "body": channel == "message" ? record["body"] as? String ?? "" : "Call completion was confirmed by Erin; connection, recording and transcript were not independently verified.",
                    "date": event["occurredAt"] ?? date, "createdAt": now, "recordedAt": now, "author": "Erin Hadra", "pinned": false,
                    "communicationId": id, "confirmationSource": event["confirmationSource"] ?? "user", "phone": phone]
                if let providerId = providerId { activity["providerId"] = providerId }
                try put("activities", activity)
                agent["lastInteraction"] = max(date, agent["lastInteraction"] as? String ?? "")
                try put("agents", agent) // Deliberately preserves recruiting status.
            }
            record["interactionId"] = activityID
        }
        try reconcileSentDraft(&record,at:now)
        try put("communications", record)
        if state == "user_confirmed_call", target == "agent", let aid = record["agentId"] as? String {
            var call: Record = ["eventId":"communication-" + id + "-completed", "callId":id, "agentId":aid, "source":"user_confirmed", "outcome":"completed", "occurredOn":event["occurredOn"] ?? Store.day(), "confirmed":true, "interactionId":record["interactionId"] ?? ""]
            if let timestamp = event["occurredAt"] { call["occurredAt"] = timestamp }
            try recordWorkflowCall(call)
        }
    }
}
