import Foundation

extension Store {
    // Acquisition time describes the source evidence, not the database insert.
    // Unknown historical times stay absent; date-only evidence keeps its precision.
    static func validatedCandidateSource(_ p: Record, defaultType: String = "manual", now: String) throws -> Record {
        func text(_ key: String, _ max: Int) throws -> String {
            guard p[key] == nil || p[key] is String else { throw StoreError(message:"Candidate \(key) must be text.") }
            let value = (p[key] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard value.count <= max else { throw StoreError(message:"Candidate \(key) is too long.") }
            return value
        }
        let suppliedType = try text("sourceType",40)
        let type = suppliedType.isEmpty ? defaultType : suppliedType
        let labels = ["manual":"Manual contact", "ai_agent":"AI agent", "email_import":"Email import", "csv_import":"CSV import", "courted_import":"Courted CSV export", "provider_import":"Provider import"]
        guard let label = labels[type] else { throw StoreError(message:"Choose a supported candidate source type.") }
        let actor = try text("sourceActor",150), reference = try text("sourceReference",2000)
        guard type != "ai_agent" || (!actor.isEmpty && !reference.isEmpty) else { throw StoreError(message:"AI candidate intake requires the sourcing agent's name and an evidence reference.") }
        guard type != "email_import" || !reference.isEmpty else { throw StoreError(message:"Email candidate intake requires the original provider message ID.") }
        let suppliedLabel = try text("source",250)
        var result: Record = ["sourceType":type,"source":suppliedLabel.isEmpty ? (type == "ai_agent" ? "AI agent — " + actor : label) : suppliedLabel]
        if !actor.isEmpty { result["sourceActor"] = actor }
        if !reference.isEmpty { result["sourceReference"] = reference }
        let sourcedAt = try text("sourcedAt",50)
        if !sourcedAt.isEmpty {
            guard parseDay(sourcedAt) != nil || (parseDay(String(sourcedAt.prefix(10))) != nil && activityEventDate(sourcedAt) != nil) else { throw StoreError(message:"Source date must be a valid calendar day or ISO timestamp with a time zone.") }
            result["sourcedAt"] = sourcedAt
        } else if type == "manual" {
            result["sourcedAt"] = now
        }
        return result
    }
}
