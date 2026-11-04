import Foundation

// Identity evidence is independent of recruiting eligibility. Never strip leading
// zeroes, punctuation or license-type suffixes to manufacture a match.
enum AgentIdentity {
    static let fields = ["license", "licenseRaw", "licenseJurisdiction", "licenseJurisdictionRaw", "licenseType", "licenseTypeRaw", "sourceAliases", "sourceProvider", "sourceAgentId", "mls", "mlsId", "courtedProfileURL"]

    static func text(_ record: Record, _ key: String) -> String {
        (record[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
    static func canonicalJurisdiction(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
        return normalized == "US-TX" ? "TX" : normalized
    }
    static func canonicalType(_ value: String, jurisdiction: String) -> String {
        let normalized = value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if canonicalJurisdiction(jurisdiction) == "TX", ["sales agent","sales-agent","salesperson"].contains(normalized) { return "sales-agent" }
        return normalized
    }
    static func licenseKey(_ record: Record) -> String? {
        let number = text(record, "license"), jurisdiction = text(record, "licenseJurisdiction"), type = text(record, "licenseType")
        guard !number.isEmpty, !jurisdiction.isEmpty, !type.isEmpty else { return nil }
        return "license:" + [canonicalJurisdiction(jurisdiction), canonicalType(type,jurisdiction:jurisdiction), number.uppercased()].map(component).joined(separator: ":")
    }
    static func aliasKey(_ alias: Record) -> String? {
        let provider = text(alias,"provider"), sourceID = text(alias,"sourceId")
        guard !provider.isEmpty, !sourceID.isEmpty else { return nil }
        return "alias:" + component(provider.lowercased()) + ":" + component(sourceID)
    }
    static func legacyAliases(_ record: Record) -> [Record] {
        var aliases: [Record] = []
        let mls = text(record,"mls"), id = text(record,"mlsId")
        if !mls.isEmpty && !id.isEmpty { aliases.append(["provider":"mls:"+mls.lowercased(),"sourceId":id]) }
        if let url = URLComponents(string:text(record,"courtedProfileURL")), url.scheme?.lowercased() == "https", url.host?.lowercased() == "brokerage.courted.io", !url.path.isEmpty, url.path != "/", url.user == nil, url.password == nil {
            aliases.append(["provider":"courted","sourceId":url.path.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"/"))])
        }
        return aliases
    }
    static func keys(_ record: Record) -> [String] {
        var result: [String] = []
        if let license = licenseKey(record) { result.append(license) }
        for alias in (record["sourceAliases"] as? [Record] ?? []) + legacyAliases(record) {
            if let key = aliasKey(alias), !result.contains(key) { result.append(key) }
        }
        let provider = text(record,"sourceProvider"), sourceID = text(record,"sourceAgentId")
        if let key = aliasKey(["provider":provider,"sourceId":sourceID]), !result.contains(key) { result.append(key) }
        let profile = text(record,"courtedProfileURL")
        if let url = URLComponents(string:profile), url.scheme?.lowercased() == "https", url.host?.lowercased() == "brokerage.courted.io", !url.path.isEmpty, url.path != "/", url.user == nil, url.password == nil {
            result.append("profile:" + (url.host! + url.path).lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"/")))
        }
        let mls = text(record,"mls"), id = text(record,"mlsId")
        if !mls.isEmpty && !id.isEmpty {
            // Raw strings are compared without discarding meaningful separators.
            result.append("mls:" + component(mls.lowercased()) + ":" + component(id))
        }
        return result
    }
    static func checkedText(_ value: Any, label: String, maximum: Int = 150) throws -> String {
        guard let raw = value as? String, raw.count <= maximum,
              !raw.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else {
            throw StoreError(message:"\(label) must be text without control characters (up to \(maximum) characters).")
        }
        return raw
    }
    static func normalized(_ input: Record, existing: Record? = nil) throws -> Record {
        var result: Record = [:]
        for pair in [("sourceProvider","sourceAgentId"),("mls","mlsId")] {
            let left = text(input,pair.0), right = text(input,pair.1)
            let changesLeft = !left.isEmpty && left != text(existing ?? [:],pair.0)
            let changesRight = !right.isEmpty && right != text(existing ?? [:],pair.1)
            if existing != nil && (changesLeft || changesRight) && (left.isEmpty || right.isEmpty) {
                throw StoreError(message:"Include both \(pair.0) and \(pair.1) when changing a source identity; an old ID cannot be assigned to a new provider.")
            }
        }
        for key in fields where key != "sourceAliases" {
            if let value = existing?[key] { result[key] = value }
            if let value = input[key] {
                let raw = try checkedText(value,label:key,maximum:key == "courtedProfileURL" ? 2000 : 150)
                if raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    // An ordinary refresh must not erase an established identifier.
                    if !text(result,key).isEmpty { continue }
                    result.removeValue(forKey:key)
                } else { result[key] = key.hasSuffix("Raw") ? raw : raw.trimmingCharacters(in:.whitespacesAndNewlines) }
            }
        }
        if let raw = input["license"] as? String, !raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            result["licenseRaw"] = input["licenseRaw"] as? String ?? raw
        } else if let raw = input["licenseRaw"] as? String, !raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            result["license"] = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        }
        if !text(result,"license").isEmpty && result["licenseRaw"] == nil { result["licenseRaw"] = result["license"] }
        if !text(result,"licenseRaw").isEmpty && !text(result,"license").isEmpty,
           text(result,"licenseRaw").uppercased() != text(result,"license").uppercased() {
            throw StoreError(message:"The raw license and license number disagree. Preserve the exact raw identifier and review its normalized value.")
        }
        for scope in ["licenseJurisdiction","licenseType"] {
            let rawKey = scope+"Raw"
            if let value = input[scope] as? String, !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                result[rawKey] = input[rawKey] as? String ?? value
            } else if let value = input[rawKey] as? String, !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                result[scope] = value.trimmingCharacters(in:.whitespacesAndNewlines)
            }
            if !text(result,scope).isEmpty && result[rawKey] == nil { result[rawKey] = result[scope] }
        }
        if let jurisdiction = result["licenseJurisdiction"] as? String {
            let value = canonicalJurisdiction(jurisdiction)
            guard value.range(of:"^[A-Z0-9][A-Z0-9._-]{1,31}$",options:.regularExpression) != nil else {
                throw StoreError(message:"Use a jurisdiction code such as TX; do not infer jurisdiction from an office city.")
            }
            result["licenseJurisdiction"] = value
        }
        if let type = result["licenseType"] as? String { result["licenseType"] = canonicalType(type,jurisdiction:text(result,"licenseJurisdiction")) }
        if !text(result,"licenseJurisdictionRaw").isEmpty && canonicalJurisdiction(text(result,"licenseJurisdictionRaw")) != text(result,"licenseJurisdiction") {
            throw StoreError(message:"Raw license jurisdiction disagrees with its canonical code.")
        }
        if !text(result,"licenseTypeRaw").isEmpty && canonicalType(text(result,"licenseTypeRaw"),jurisdiction:text(result,"licenseJurisdiction")) != text(result,"licenseType") {
            throw StoreError(message:"Raw license type disagrees with its canonical type.")
        }
        var aliases = (existing?["sourceAliases"] as? [Record] ?? []) + legacyAliases(existing ?? [:]) + legacyAliases(result)
        if let incoming = input["sourceAliases"] {
            guard let values = incoming as? [Record], values.count <= 100 else { throw StoreError(message:"Source aliases must be a list of at most 100 provider/source-ID pairs.") }
            aliases += values
        }
        let provider = text(result,"sourceProvider"), sourceID = text(result,"sourceAgentId")
        guard provider.isEmpty == sourceID.isEmpty else { throw StoreError(message:"Source aliases require both a provider and its agent ID.") }
        if !provider.isEmpty { aliases.append(["provider":provider,"sourceId":sourceID]) }
        var canonical: [Record] = [], seen = Set<String>()
        for alias in aliases {
            guard Set(alias.keys).isSubset(of:["provider","sourceId","reference","observedAt"]) else { throw StoreError(message:"Unexpected source alias fields.") }
            var normalized: Record = [:]
            for (key,value) in alias { normalized[key] = try checkedText(value,label:"Source alias \(key)",maximum:key == "reference" ? 2000 : 200) }
            if let observed = normalized["observedAt"] as? String, !observed.isEmpty {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let timestamp = formatter.date(from:observed) ?? ISO8601DateFormatter().date(from:observed)
                guard Store.parseDay(observed) != nil || timestamp != nil else { throw StoreError(message:"Source alias observedAt must be a valid YYYY-MM-DD date or ISO 8601 timestamp.") }
            }
            normalized["provider"] = text(normalized,"provider").lowercased()
            normalized["sourceId"] = text(normalized,"sourceId")
            guard let key = aliasKey(normalized) else { throw StoreError(message:"Each source alias needs a provider and source ID.") }
            if seen.insert(key).inserted { canonical.append(normalized) }
        }
        guard canonical.count <= 100 else { throw StoreError(message:"This contact has too many source aliases; review its identity history.") }
        if !canonical.isEmpty { result["sourceAliases"] = canonical }
        let hasLegacyKey = keys(result).contains { $0.hasPrefix("mls:") || $0.hasPrefix("profile:") }
        if !text(result,"license").isEmpty && licenseKey(result) == nil && !hasLegacyKey {
            // Old source-linked imports remain readable; new license-only intake is
            // explicit about scope, so two states/types cannot collide.
            let untouchedLegacy = existing != nil && !input.keys.contains(where:{ ["license","licenseRaw","licenseJurisdiction","licenseJurisdictionRaw","licenseType","licenseTypeRaw"].contains($0) })
            guard untouchedLegacy else { throw StoreError(message:"Add the license jurisdiction and license type, or review the existing source-linked identity. Courted is optional.") }
        }
        if let existing = existing { try ensureCompatible(result,existing:existing) }
        return result
    }
    static func ensureCompatible(_ incoming: Record, existing: Record) throws {
        if let old = licenseKey(existing), let new = licenseKey(incoming), old != new {
            throw StoreError(message:"License conflicts with existing contact \(text(existing,"id")). Review the identity; identifiers were not replaced.")
        }
        let oldNumber = text(existing,"license"), newNumber = text(incoming,"license")
        if !oldNumber.isEmpty && !newNumber.isEmpty && oldNumber.uppercased() != newNumber.uppercased() {
            throw StoreError(message:"License number differs from existing contact \(text(existing,"id")). Review leading zeroes, suffixes and source evidence before linking.")
        }
    }
    // Source refreshes must not infer a name change, nickname or married-name
    // relationship merely because a license/alias matched. Manual edits remain
    // explicit operator actions and deliberately do not call this source guard.
    static func sourceNameKey(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ").lowercased()
    }
    static func ensureSourceNameCompatible(_ incoming: Record, existing: Record?) throws {
        guard let existing = existing else { return }
        let incomingName = sourceNameKey(text(incoming,"name"))
        let savedName = sourceNameKey(text(existing,"name"))
        guard !incomingName.isEmpty, !savedName.isEmpty, incomingName != savedName else { return }
        // A prior source spelling is evidence already held by this contact, not
        // permission to invent a new alias. Keep explicit recruiter display edits.
        let overrides = Set(existing["localOverrides"] as? [String] ?? [])
        let prior = existing["importedCoreValues"] as? Record ?? [:]
        if overrides.contains("name"), incomingName == sourceNameKey(text(prior,"name")) { return }
        throw StoreError(message:"Source name \(text(incoming,"name")) differs from saved contact \(text(existing,"name")) (\(text(existing,"id"))). Review the identity evidence; no name-change or alias relationship was inferred.")
    }
    static func match(_ incoming: Record, among records: [Record], excluding excludedID: String? = nil) throws -> Record? {
        let inputKeys = Set(keys(incoming))
        let candidates = records.filter { text($0,"id") != excludedID }
        let matches = candidates.filter { !inputKeys.isDisjoint(with:keys($0)) }
        guard matches.count <= 1 else { throw StoreError(message:"Identity aliases point to multiple contacts: \(matches.map { text($0,"id") }.sorted().joined(separator:", ")). Review the conflict before importing.") }
        let match = matches.first
        if let match = match { try ensureCompatible(incoming,existing:match) }
        func oldMLSKey(_ row: Record) -> String? {
            func lossy(_ text: String) -> String { String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
            let mls = text(row,"mls"), id = text(row,"mlsId")
            return mls.isEmpty || id.isEmpty ? nil : lossy(mls)+":"+lossy(id)
        }
        if let oldKey = oldMLSKey(incoming) {
            let possible = candidates.filter { oldMLSKey($0) == oldKey && text($0,"id") != (match.map { text($0,"id") } ?? "") }
            guard possible.isEmpty else { throw StoreError(message:"MLS identifier formatting overlaps existing contact \(possible.map { text($0,"id") }.sorted().joined(separator:", ")). Review the exact provider identifiers; no punctuation or zeroes were discarded to merge them.") }
        }
        let number = text(incoming,"license").uppercased()
        if !number.isEmpty {
            let ambiguous = candidates.filter { row in
                !text(row,"license").isEmpty && text(row,"license").uppercased() == number &&
                (licenseKey(row) == nil || licenseKey(incoming) == nil) && text(row,"id") != (match.map { text($0,"id") } ?? "")
            }
            guard ambiguous.isEmpty else { throw StoreError(message:"License matches an unscoped legacy contact: \(ambiguous.map { text($0,"id") }.sorted().joined(separator:", ")). Review its jurisdiction/type and source aliases before linking.") }
        }
        return match
    }
}

extension Store {
    // Used by both manual create and update. Returns identity fields only, never
    // silently overwrites another contact or changes the existing contact ID.
    func prepareAgentIntake(_ fields: Record, existing: Record? = nil) throws -> Record {
        if let existing = existing, !fields.keys.contains(where:{ AgentIdentity.fields.contains($0) }) {
            return existing.filter { AgentIdentity.fields.contains($0.key) }
        }
        let identity = try AgentIdentity.normalized(fields,existing:existing)
        // Existing duplicate evidence is a review issue, but must not prevent an
        // unrelated contact edit or force a new identity claim.
        if let existing = existing, Set(AgentIdentity.keys(identity)) == Set(AgentIdentity.keys(existing)) { return identity }
        if let duplicate = try AgentIdentity.match(identity,among:all("agents"),excluding:existing?["id"] as? String) {
            throw StoreError(message:"Identity already belongs to contact \(AgentIdentity.text(duplicate,"id")). Open that contact or review the conflict; no duplicate was created.")
        }
        return identity
    }
}
