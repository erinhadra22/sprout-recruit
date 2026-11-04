import Foundation
import CryptoKit
import CoreFoundation

// Professional source observations, not proof of recruiting interest. Mutations
// are called inside Store.command's transaction and never fetch external data.
extension Store {
    static func professionalText(_ value: Any?, _ label: String, max: Int = 2000, optional: Bool = false) throws -> String {
        if optional && (value == nil || value is NSNull) { return "" }
        guard let string = value as? String else { throw StoreError(message:"Enter \(label).") }
        let text = string.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.count <= max, optional || !text.isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw StoreError(message:"Enter valid \(label) (up to \(max) characters).")
        }
        return text
    }

    static func professionalSource(_ value: Any?) throws -> Record {
        guard let source = value as? Record, Set(source.keys).isSubset(of:["label","reference"]) else {
            throw StoreError(message:"Add the professional source label and reference.")
        }
        return ["label":try professionalText(source["label"],"source label",max:200),
                "reference":try professionalText(source["reference"],"source reference")]
    }

    static func professionalCheckedDay(_ value: Any?) throws -> String {
        let checked = try professionalText(value,"checked date",max:10)
        guard parseDay(checked) != nil, checked <= day() else {
            throw StoreError(message:"Use a valid checked date no later than today.")
        }
        return checked
    }

    static func professionalRevision(_ value: Any?) throws -> Int {
        guard let number = (value ?? 0) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue <= 1_000_000,
              number.doubleValue.rounded() == number.doubleValue else {
            throw StoreError(message:"Reload the record before saving its revision.")
        }
        return number.intValue
    }

    static func professionalID(_ prefix: String, _ components: [String]) -> String {
        prefix + SHA256.hash(data:Data(components.joined(separator:"\u{0}").utf8)).map { String(format:"%02x",$0) }.joined()
    }

    static func professionalProfileURL(_ raw: String, platform: String) throws -> String {
        guard raw.count <= 2000, !raw.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              var components = URLComponents(string:raw), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), host.contains("."), !host.hasSuffix("."),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else {
            throw StoreError(message:"Enter a complete HTTPS professional profile URL without credentials.")
        }
        if platform == "linkedin" {
            components = URLComponents(string:try linkedInProfileURL(raw))!
        }
        let hostAliases: [String: [String:String]] = [
            "instagram":["instagram.com":"www.instagram.com","www.instagram.com":"www.instagram.com"],
            "facebook":["facebook.com":"www.facebook.com","www.facebook.com":"www.facebook.com","m.facebook.com":"www.facebook.com"],
            "youtube":["youtube.com":"www.youtube.com","www.youtube.com":"www.youtube.com","m.youtube.com":"www.youtube.com","youtu.be":"youtu.be"],
            "tiktok":["tiktok.com":"www.tiktok.com","www.tiktok.com":"www.tiktok.com"],
            "x":["x.com":"x.com","www.x.com":"x.com","twitter.com":"x.com","www.twitter.com":"x.com"]
        ]
        if let aliases = hostAliases[platform] {
            guard let canonical = aliases[host] else { throw StoreError(message:"The profile URL does not match the selected platform.") }
            components.host = canonical
        }
        components.scheme = "https"; components.host = components.host?.lowercased()
        components.port = nil; components.fragment = nil
        // Tracking parameters do not identify the profile. Keep meaningful query
        // parameters such as Facebook's profile.php?id=… rather than stripping all.
        if let query = components.queryItems {
            let filtered = query.filter {
                !$0.name.lowercased().hasPrefix("utm_") && !["fbclid","gclid","igsh","igshid"].contains($0.name.lowercased())
            }
            components.queryItems = filtered.isEmpty ? nil : filtered.sorted { ($0.name,$0.value ?? "") < ($1.name,$1.value ?? "") }
        }
        while components.path.count > 1 && components.path.hasSuffix("/") { components.path.removeLast() }
        guard let result = components.string, URL(string:result) != nil else { throw StoreError(message:"Enter a valid profile URL.") }
        return result
    }

    // Shared revision handling preserves observations and makes exact retries safe.
    // The caller owns a transaction covering any companion contact update.
    func persistProfessionalRecord(_ kind: String, _ record: Record, expectedRevision: Int) throws {
        guard let id = record["id"] as? String else { throw StoreError(message:"A stable record identity is required.") }
        let existing = try all(kind).first { $0["id"] as? String == id }
        if let existing = existing {
            var body = existing
            for key in ["revision","createdAt","updatedAt","revisions"] { body.removeValue(forKey:key) }
            if NSDictionary(dictionary:body).isEqual(to:record) { return }
        }
        guard (existing?["revision"] as? Int ?? 0) == expectedRevision else {
            throw StoreError(message:"This record changed. Reload it before saving.")
        }
        var result = record, revisions = existing?["revisions"] as? [Record] ?? []
        if var prior = existing { prior.removeValue(forKey:"revisions"); revisions.append(prior) }
        result["revision"] = expectedRevision + 1; result["createdAt"] = existing?["createdAt"] ?? Store.now()
        result["updatedAt"] = Store.now(); result["revisions"] = revisions
        try put(kind,result)
    }

    func saveProfessionalProfile(_ p: Record) throws {
        guard Set(p.keys).isSubset(of:["id","agentId","platform","url","source","checkedAt","matchStatus","evidence","expectedRevision"]) else {
            throw StoreError(message:"Unexpected professional profile fields.")
        }
        let aid = try Self.professionalText(p["agentId"],"contact",max:200)
        var agent = try get("agents",aid)
        let platform = try Self.professionalText(p["platform"],"platform",max:80).lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:" ._-"))
        guard platform.unicodeScalars.allSatisfy(allowed.contains) else { throw StoreError(message:"Enter a plain platform name.") }
        let url = try Self.professionalProfileURL(Self.professionalText(p["url"],"profile URL"),platform:platform)
        let id = Self.professionalID("profile-",[aid,platform,url])
        if let supplied = p["id"] as? String, !supplied.isEmpty, supplied != id {
            throw StoreError(message:"Profile identity changed. Add the new URL as a separate profile to retain prior evidence.")
        }
        let status = try Self.professionalText(p["matchStatus"],"identity-match status",max:30)
        guard ["unreviewed","possible","verified","rejected"].contains(status) else { throw StoreError(message:"Choose a valid identity-match status.") }
        let evidence = try Self.professionalText(p["evidence"],"identity evidence",max:4000,optional:true)
        guard !["verified","rejected"].contains(status) || !evidence.isEmpty else {
            throw StoreError(message:"Explain the evidence for a verified or rejected identity match.")
        }
        if status == "verified", let conflict = try all("professionalProfiles").first(where: {
            $0["agentId"] as? String != aid && $0["platform"] as? String == platform &&
            $0["url"] as? String == url && $0["matchStatus"] as? String == "verified"
        }) {
            throw StoreError(message:"This profile is already verified for contact \(conflict["agentId"] as? String ?? "another contact"). Review the conflicting identity before verifying it again.")
        }
        let record: Record = ["id":id,"agentId":aid,"platform":platform,"url":url,
            "source":try Self.professionalSource(p["source"]),"checkedAt":try Self.professionalCheckedDay(p["checkedAt"]),
            "matchStatus":status,"evidence":evidence,"schemaVersion":1]
        try persistProfessionalRecord("professionalProfiles",record,expectedRevision:Self.professionalRevision(p["expectedRevision"]))
        if platform == "linkedin", status == "verified" {
            let prior = agent["linkedinUrl"] as? String ?? ""
            let normalized = try? Self.professionalProfileURL(prior,platform:"linkedin")
            if prior.isEmpty || normalized == url {
                agent["linkedinUrl"] = url
                var overrides = Set(agent["localOverrides"] as? [String] ?? [])
                overrides.insert("linkedinUrl"); agent["localOverrides"] = overrides.sorted()
                try put("agents",agent)
            }
        }
    }

    // Legacy saved LinkedIn URLs remain visible without inventing verification or
    // a checked date. This projection does not migrate or modify the contact.
    func professionalProfilesForAgent(_ agentID: String) throws -> [Record] {
        let agent = try get("agents",agentID)
        var rows = try all("professionalProfiles").filter { $0["agentId"] as? String == agentID }
        if let legacy = agent["linkedinUrl"] as? String, !legacy.isEmpty,
           let url = try? Self.professionalProfileURL(legacy,platform:"linkedin"),
           !rows.contains(where: { $0["platform"] as? String == "linkedin" && $0["url"] as? String == url }) {
            rows.append(["id":Self.professionalID("profile-",[agentID,"linkedin",url]),"agentId":agentID,
                "platform":"linkedin","url":url,"matchStatus":"unreviewed","checkedAt":NSNull(),
                "source":["label":"Existing contact field","reference":"agent:"+agentID],
                "evidence":"Saved LinkedIn URL; identity match and checked date have not been recorded.",
                "legacy":true,"revision":0,"schemaVersion":1])
        }
        return rows.sorted { ($0["platform"] as? String ?? "",$0["url"] as? String ?? "") < ($1["platform"] as? String ?? "",$1["url"] as? String ?? "") }
    }
}
