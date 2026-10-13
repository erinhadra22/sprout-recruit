import Foundation
import CryptoKit

// A verified copy of an external one-to-one conversation. Importing it never
// changes recruiting status or asserts that an outbound message was delivered.
extension Store {
    private func externalRequired(_ payload: Record, _ key: String, max: Int = 50000) throws -> String {
        guard let value = payload[key] as? String, !value.isEmpty, value.count <= max else {
            throw StoreError(message: "A valid \(key) is required for external correspondence.")
        }
        return value
    }

    private func externalEmail(_ value: String) throws -> String {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.count <= 320,
              address.range(of: "^[^\\s@<>]+@[^\\s@<>]+\\.[^\\s@<>]+$", options: .regularExpression) != nil else {
            throw StoreError(message: "Use an exact email address without a display name.")
        }
        return address
    }

    private func externalTimestamp(_ value: String) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date = parsed, date <= Date().addingTimeInterval(300) else {
            throw StoreError(message: "Use a valid past ISO 8601 message timestamp.")
        }
        return ISO8601DateFormatter().string(from: date)
    }

    func importExternalMessage(_ payload: Record) throws {
        let allowed: Set<String> = ["agentId", "channel", "provider", "accountAddress", "providerMessageId", "providerThreadId", "direction", "from", "to", "occurredAt", "subject", "body"]
        guard Set(payload.keys).isSubset(of: allowed) else { throw StoreError(message: "Unexpected external correspondence fields were supplied.") }
        let agentId = try externalRequired(payload, "agentId", max: 200)
        let agent = try get("agents", agentId)
        guard agent["datasetId"] as? String == "live", agent["sample"] as? Bool != true else {
            throw StoreError(message: "External correspondence requires an exact live contact.")
        }
        let channel = try externalRequired(payload, "channel", max: 20)
        let provider = try externalRequired(payload, "provider", max: 40)
        guard (channel == "Email" && provider == "gmail") || (channel == "Message" && provider == "apple-messages") else {
            throw StoreError(message: "Choose Gmail email or Apple Messages correspondence.")
        }
        let direction = try externalRequired(payload, "direction", max: 10)
        guard ["outbound", "inbound"].contains(direction) else { throw StoreError(message: "Direction must be inbound or outbound.") }
        let messageId = try externalRequired(payload, "providerMessageId", max: 250)
        let threadId = try externalRequired(payload, "providerThreadId", max: 250)
        guard !messageId.contains(where: { $0.isWhitespace }), !threadId.contains(where: { $0.isWhitespace }) else {
            throw StoreError(message: "Provider IDs must be exact and contain no whitespace.")
        }
        let body = try externalRequired(payload, "body")
        let subject = payload["subject"] as? String ?? ""
        guard subject.count <= 500, channel == "Email" || subject.isEmpty else { throw StoreError(message: "Only email correspondence may have a subject.") }
        let occurredAt = try externalTimestamp(externalRequired(payload, "occurredAt", max: 40))
        let rawAccount = try externalRequired(payload, "accountAddress", max: 320)
        let rawFrom = try externalRequired(payload, "from", max: 320)
        let rawTo = try externalRequired(payload, "to", max: 320)
        let account: String, from: String, to: String, contact: String
        if channel == "Email" {
            account = try externalEmail(rawAccount)
            from = try externalEmail(rawFrom)
            to = try externalEmail(rawTo)
            contact = try externalEmail(agent["email"] as? String ?? "")
        } else {
            account = try Store.normalizedCommunicationPhone(rawAccount)
            from = try Store.normalizedCommunicationPhone(rawFrom)
            to = try Store.normalizedCommunicationPhone(rawTo)
            contact = try Store.normalizedCommunicationPhone(agent["phone"] as? String ?? "")
        }
        guard contact != account,
              (direction == "outbound" && from == account && to == contact)
                || (direction == "inbound" && from == contact && to == account) else {
            throw StoreError(message: "Message sender and recipient must exactly match the account and selected contact.")
        }
        let digest = SHA256.hash(data: Data((provider + "\u{0}" + account + "\u{0}" + messageId).utf8))
        let id = "external-" + digest.map { String(format: "%02x", $0) }.joined()
        let content: Record = ["agentId": agentId, "channel": channel, "provider": provider,
                               "accountAddress": account, "providerMessageId": messageId,
                               "providerThreadId": threadId, "direction": direction,
                               "from": from, "to": to, "occurredAt": occurredAt,
                               "subject": subject, "body": body]
        // A provider message cannot silently move to a different account or agent.
        let existing = try all("externalMessages")
        if existing.contains(where: { $0["provider"] as? String == provider && $0["providerMessageId"] as? String == messageId && $0["id"] as? String != id }) {
            throw StoreError(message: "This provider message is already linked to another account or contact.")
        }
        if let saved = existing.first(where: { $0["id"] as? String == id }) {
            guard let original = saved["content"] as? Record,
                  NSDictionary(dictionary: original).isEqual(to: content) else {
                throw StoreError(message: "This provider message ID already has different saved content. Reconcile before importing again.")
            }
            return
        }
        try put("externalMessages", ["id": id, "content": content, "agentId": agentId,
                                     "channel": channel, "provider": provider,
                                     "accountAddress": account, "providerMessageId": messageId,
                                     "providerThreadId": threadId, "direction": direction,
                                     "from": from, "to": to, "occurredAt": occurredAt,
                                     "subject": subject, "body": body, "importedAt": Store.now(),
                                     "schemaVersion": 1])
        if direction == "inbound" {
            try pauseSequencesForImportedReply(agentId:agentId,occurredAt:occurredAt,messageId:id)
        }
    }

    // Historical correspondence predating enrollment must not pause a newer
    // sequence. The message and its pause effects share the import transaction.
    private func pauseSequencesForImportedReply(agentId: String, occurredAt: String, messageId: String) throws {
        guard let replyDate = ISO8601DateFormatter().date(from:occurredAt) else { return }
        var affected = Set<String>()
        let now = Store.now()
        for var sequence in try all("sequences") where sequence["agentId"] as? String == agentId && sequence["state"] as? String == "active" {
            guard let id = sequence["id"] as? String,
                  let created = sequence["createdAt"] as? String,
                  let enrolledAt = ISO8601DateFormatter().date(from:created),
                  replyDate >= enrolledAt else { continue }
            sequence["state"] = "paused"; sequence["pauseReason"] = "inbound_reply"
            sequence["replyMessageId"] = messageId; sequence["updatedAt"] = now
            try put("sequences",sequence); affected.insert(id)
        }
        guard !affected.isEmpty else { return }
        for var draft in try all("drafts") where draft["agentId"] as? String == agentId && draft["state"] as? String == "draft" {
            guard let sequenceId = draft["sequenceId"] as? String, affected.contains(sequenceId),
                  draft["approvalState"] as? String != "rejected" else { continue }
            draft["approvalState"] = "paused_reply"; draft["updatedAt"] = now
            draft["replyMessageId"] = messageId
            try put("drafts",draft)
        }
        try put("workflowEvents",["id":"reply-pause-" + messageId,"type":"externalMessage.inbound_reply",
            "agentId":agentId,"messageId":messageId,"sequenceIds":affected.sorted(),
            "occurredAt":occurredAt,"recordedAt":now,"source":"verified_external_message","schemaVersion":1])
    }
}
