import Foundation

/// A read-only evidence review. No finding changes timestamps, pauses a sequence,
/// or claims that a clock time can be recovered from a date-only source.
enum HistoricalAudit {
    private static func instant(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from:text) ?? ISO8601DateFormatter().date(from:text)
    }

    static func review(_ records: [String:[Record]], maxDetails: Int = 200) -> Record {
        var findings: [Record] = [], counts: [String:Int] = [:]
        let communications = Dictionary((records["communications"] ?? []).compactMap { record -> (String, Record)? in
            guard let id = record["id"] as? String else { return nil }; return (id,record)
        }, uniquingKeysWith: { first,_ in first })
        let workflows = Dictionary((records["workflows"] ?? []).compactMap { record -> (String, Record)? in
            guard let id = record["id"] as? String else { return nil }; return (id,record)
        }, uniquingKeysWith: { first,_ in first })
        func finding(_ code: String, _ kind: String, _ record: Record, _ recommendation: String, related: [String] = []) {
            counts[code,default:0] += 1
            if findings.count < maxDetails {
                var row: Record = ["code":code,"kind":kind,"recordId":record["id"] as? String ?? "missing-id",
                                   "recommendation":recommendation]
                if let agentId = record["agentId"] as? String { row["agentId"] = agentId }
                if !related.isEmpty { row["relatedRecordIds"] = related }
                findings.append(row)
            }
        }
        for kind in ["agents","tasks","drafts"] {
            for record in records[kind] ?? [] where instant(record["createdAt"]) == nil {
                finding("creation_time_unrecorded",kind,record,"Keep the original record. Creation time is unknown; import or modification time is not a substitute.")
            }
        }
        for activity in records["activities"] ?? [] {
            let date = activity["date"] as? String ?? ""
            let linked = (activity["communicationId"] as? String).flatMap { communications[$0] }
                ?? (activity["workflowId"] as? String).flatMap { workflows[$0] }
            if let evidence = linked, let day = evidence["occurredOn"] as? String,
               Store.parseDay(day) != nil, date == day + "T12:00:00", instant(evidence["occurredAt"]) == nil {
                // The pre-0.4.8 writers used precisely this timezone-free noon
                // string for date-only communication/workflow confirmations.
                finding("suspected_legacy_noon","activities",activity,"Linked evidence records only a date. Review the source before replacing the displayed noon with a date-only value; never infer an actual time.",related:[evidence["id"] as? String ?? "missing-id"])
            } else if Store.parseDay(date) != nil {
                finding("date_only_occurrence","activities",activity,"Date-only evidence is valid. Keep its time visibly unrecorded unless an exact source supplies it.")
            } else if instant(date) == nil {
                finding("occurrence_time_needs_review","activities",activity,"Occurrence timestamp is missing, invalid, or lacks a timezone. Verify source evidence; do not interpret it as a UTC instant.")
            }
            if instant(activity["recordedAt"]) == nil && instant(activity["createdAt"]) == nil {
                finding("recording_time_unrecorded","activities",activity,"Recording time is unknown. Preserve the occurrence evidence separately.")
            }
        }
        let replies = (records["externalMessages"] ?? []).filter { $0["direction"] as? String == "inbound" }
        let drafts = records["drafts"] ?? []
        for sequence in records["sequences"] ?? [] {
            guard let id = sequence["id"] as? String, let agentId = sequence["agentId"] as? String else { continue }
            let state = sequence["state"] as? String ?? ""
            let matching = replies.filter { $0["agentId"] as? String == agentId }
            if state == "active" && !matching.isEmpty {
                if let enrolled = instant(sequence["createdAt"]) {
                    let later = matching.filter { (instant($0["occurredAt"]).map { $0 >= enrolled }) ?? false }
                    if !later.isEmpty {
                        finding("active_sequence_after_reply","sequences",sequence,"Review the imported reply and current enrollment before preparing further follow-ups. Historical imports were not replayed automatically.",related:later.compactMap { $0["id"] as? String }.sorted())
                    }
                    let unknown = matching.filter { instant($0["occurredAt"]) == nil }
                    if !unknown.isEmpty {
                        finding("reply_chronology_unknown","sequences",sequence,"An inbound message lacks a valid timestamp. Verify chronology before deciding whether this enrollment should be held.",related:unknown.compactMap { $0["id"] as? String }.sorted())
                    }
                } else {
                    finding("reply_chronology_unknown","sequences",sequence,"Enrollment time is unknown. Compare actual source evidence before deciding whether the existing reply predates enrollment.",related:matching.compactMap { $0["id"] as? String }.sorted())
                }
            }
            if state == "paused" && sequence["pauseReason"] as? String == "inbound_reply" {
                for draft in drafts where draft["sequenceId"] as? String == id && draft["state"] as? String == "draft" {
                    if !["paused_reply","rejected"].contains(draft["approvalState"] as? String ?? "") {
                        finding("reply_hold_missing_on_draft","drafts",draft,"The linked enrollment is paused for a reply. Review this draft before any send authorization.",related:[id])
                    }
                }
            }
        }
        return ["schemaVersion":1,"readOnly":true,"generatedAt":Store.now(),
                "recordCounts":records.mapValues(\.count),"findingCounts":counts,
                "totalFindings":counts.values.reduce(0,+),"findings":findings,
                "detailsTruncated":counts.values.reduce(0,+) > findings.count,
                "privacy":"Contains record identifiers and review reasons only; no contact names, addresses, phones, or message bodies.",
                "interpretation":"A finding requests evidence review, not an automatic correction. No records were changed."]
    }
}

extension Store {
    func historicalAudit(_ payload: Record = [:]) throws -> Record {
        guard Set(payload.keys).isSubset(of:["maxDetails"]),
              payload["maxDetails"] == nil || payload["maxDetails"] is Int else {
            throw StoreError(message:"Use only an integer maxDetails for the read-only history audit.")
        }
        let limit = payload["maxDetails"] as? Int ?? 200
        guard (0...1000).contains(limit) else { throw StoreError(message:"maxDetails must be between zero and 1000.") }
        var records: [String:[Record]] = [:]
        for kind in ["agents","tasks","drafts","activities","communications","workflows","externalMessages","sequences"] {
            records[kind] = try all(kind)
        }
        return HistoricalAudit.review(records,maxDetails:limit)
    }
}
