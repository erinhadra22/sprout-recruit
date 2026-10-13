import Foundation

extension Store {
    /// Attribution for new records only. Legacy records are never rewritten on a profile change.
    func operatorName() throws -> String {
        let value = try all("settings").first(where: { $0["id"] as? String == "workspace" })?["name"] as? String ?? ""
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Local recruiter" : name
    }

    func validatedWorkspaceSettings(_ payload: Record, existing: Record) throws -> Record {
        let editable: Set<String> = ["name", "company", "role", "timezone", "instructions", "columns"]
        guard Set(payload.keys).isSubset(of: editable) else {
            throw StoreError(message: "Unsupported workspace setting. Reload the settings page.")
        }
        var updated = existing
        for (key, value) in payload {
            if key == "columns" {
                guard let columns = value as? [String], columns.count <= 100,
                      Set(columns).count == columns.count,
                      columns.allSatisfy({ !$0.isEmpty && $0.count <= 180 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
                    throw StoreError(message: "Choose valid, distinct contact columns.")
                }
                updated[key] = columns
                continue
            }
            guard let text = value as? String else { throw StoreError(message: "Enter text for \(key).") }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let maximum = key == "instructions" ? 10_000 : key == "company" ? 160 : key == "timezone" ? 100 : 120
            guard normalized.count <= maximum else { throw StoreError(message: "\(key.capitalized) is too long.") }
            if ["name", "company", "timezone"].contains(key), normalized.isEmpty {
                throw StoreError(message: "\(key.capitalized) is required.")
            }
            if key != "instructions", normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw StoreError(message: "Use a single line for \(key).")
            }
            if key == "timezone", !(TimeZone.knownTimeZoneIdentifiers.contains(normalized) || normalized == "UTC") {
                throw StoreError(message: "Enter a valid IANA time zone, such as America/Chicago.")
            }
            updated[key] = normalized
        }
        updated["id"] = "workspace"
        updated["updatedAt"] = Store.now()
        return updated
    }

    func saveOnboarding(_ payload: Record) throws {
        guard Set(["name", "company", "timezone"]).isSubset(of: Set(payload.keys)) else {
            throw StoreError(message: "Enter your name, company and time zone to finish setup.")
        }
        let existing = try get("settings", "workspace")
        var updated = try validatedWorkspaceSettings(payload, existing: existing)
        updated["onboardingRequired"] = false
        updated["onboardingCompletedAt"] = existing["onboardingCompletedAt"] ?? Store.now()
        try put("settings", updated)
    }
}
