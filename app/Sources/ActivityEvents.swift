import Foundation
import CryptoKit

// Stable, versioned templates for contact lifecycle facts. Call within the
// transaction that changes the contact; historical times must be explicit.
extension Store {
    @discardableResult
    func recordContactEvent(agentId: String, type: String, source: String,
                            sourceRecordId: String = "", batchId: String = "",
                            fileNames: [String] = [], occurredAt: String?,
                            recordedAt: String = Store.now(), dedupeKey: String,
                            details: String = "") throws -> String {
        _ = try get("agents", agentId)
        let templates: [String: (String, String)] = [
            "contact.created": ("Contact created", "Contact created in Sprout Recruit."),
            "contact.imported": ("Contact imported", "Contact added from \(source)."),
            "contact.import_updated": ("Contact updated from import", "Contact refreshed from \(source). Local edits and recruiting status are preserved by the import rules."),
            "contact.reviewed": ("Contact details reviewed", "Saved contact details were reviewed. No message or call was made.")
        ]
        guard let template = templates[type], !source.isEmpty, !dedupeKey.isEmpty,
              Self.activityEventDate(recordedAt) != nil,
              occurredAt == nil || Self.activityEventDate(occurredAt!) != nil else {
            throw StoreError(message: "A contact event needs a supported template, source, stable key and valid timestamps.")
        }
        let digest = SHA256.hash(data: Data((agentId + "\u{0}" + dedupeKey).utf8))
        let id = "contact-event-" + digest.map { String(format: "%02x", $0) }.joined()
        let evidence: Record = ["type": type, "agentId": agentId, "source": source,
            "sourceRecordId": sourceRecordId, "batchId": batchId, "fileNames": fileNames.sorted(),
            "occurredAt": occurredAt as Any? ?? NSNull(), "details": details]
        if let existing = try? get("activities", id) {
            guard let original = existing["eventEvidence"] as? Record,
                  NSDictionary(dictionary: original).isEqual(to: evidence) else {
                throw StoreError(message: "This contact event already has different evidence. Reconcile it before retrying.")
            }
            return id
        }
        try put("activities", ["id": id, "agentId": agentId, "kind": "contact",
            "type": type, "templateId": type, "templateVersion": 1, "schemaVersion": 1,
            "title": template.0, "body": details.isEmpty ? template.1 : details,
            "date": occurredAt as Any? ?? NSNull(), "occurredAt": occurredAt as Any? ?? NSNull(),
            "recordedAt": recordedAt, "createdAt": recordedAt,
            "timeBasis": occurredAt == nil ? "unknown" : "observed_local_event",
            "source": source, "sourceRecordId": sourceRecordId, "batchId": batchId,
            "fileNames": fileNames.sorted(), "eventEvidence": evidence,
            "author": try operatorName(), "pinned": false])
        return id
    }

    static func activityEventDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
