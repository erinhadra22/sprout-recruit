import Foundation

func runProfessionalProfileTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message:"Professional profile test failed: \(message)") }
    }
    func fails(_ message: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try check(rejected,message)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-profiles-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let path = root.appendingPathComponent("fixture.sqlite").path
    let aid = "legacy-contact"
    var profileCount = 0
    do {
        let store = try Store(path:path,seed:false)
        try store.put("agents",["id":aid,"name":"Fixture Agent","status":"Do not contact",
            "linkedinUrl":"https://www.linkedin.com/in/fixture-original/", "phone":"+15125550100",
            "history":[["note":"Preserve this history"]],"localOverrides":["phone"]])
        func save(_ p: Record) throws { try store.transaction { try store.saveProfessionalProfile(p) } }
        var p: Record = ["agentId":aid,"platform":"Instagram","url":"https://www.instagram.com/fixture.business/?utm_source=test#bio",
            "source":["label":"Business website","reference":"https://example.test/team"],"checkedAt":"2025-01-31",
            "matchStatus":"possible","evidence":"Name and brokerage agree; identity still needs confirmation.","expectedRevision":0]
        try save(p)
        let first = try store.all("professionalProfiles").first!
        try check(first["url"] as? String == "https://www.instagram.com/fixture.business","tracking-free canonical URL")
        try check(first["platform"] as? String == "instagram","platform normalized")
        try save(p)
        try check(try store.all("professionalProfiles").count == 1,"exact retry deduplicates")
        try check((try store.get("professionalProfiles",first["id"] as! String))["revision"] as? Int == 1,"retry does not create revision")
        var sameProfile = p; sameProfile["url"] = "https://instagram.com/fixture.business/"
        try save(sameProfile)
        try check(try store.all("professionalProfiles").count == 1,"known host alias deduplicates")
        p["url"] = "https://www.instagram.com/fixture.team/"
        try save(p)
        try check(try store.all("professionalProfiles").count == 2,"two profiles on same platform retained")
        p["platform"] = "Mastodon"; p["url"] = "https://social.example.test/@fixture"
        try save(p)
        try check(try store.all("professionalProfiles").count == 3,"additional professional platforms supported")
        var unsafe = p; unsafe["url"] = "https://user:secret@example.test/fixture"
        try fails("credential URL rejected") { try save(unsafe) }
        unsafe["url"] = "http://example.test/fixture"
        try fails("HTTP URL rejected") { try save(unsafe) }
        unsafe["url"] = "javascript:alert(1)"
        try fails("non-HTTPS scheme rejected") { try save(unsafe) }
        unsafe = p; unsafe["platform"] = "instagram"; unsafe["url"] = "https://example.test/fixture"
        try fails("known platform host mismatch rejected") { try save(unsafe) }
        unsafe = p; unsafe["checkedAt"] = "2025-02-30"
        try fails("invalid checked date rejected") { try save(unsafe) }
        unsafe["checkedAt"] = Store.plusDays(1)
        try fails("future checked date rejected") { try save(unsafe) }
        unsafe = p; unsafe["matchStatus"] = "verified"; unsafe["evidence"] = ""
        try fails("verified needs identity evidence") { try save(unsafe) }
        unsafe = p; unsafe["source"] = ["label":"Unknown","reference":""]
        try fails("missing source reference rejected") { try save(unsafe) }
        let projected = try store.professionalProfilesForAgent(aid)
        let legacy = projected.first { $0["legacy"] as? Bool == true }!
        try check(legacy["checkedAt"] is NSNull && legacy["matchStatus"] as? String == "unreviewed","legacy LinkedIn does not gain invented verification")
        p["platform"] = "linkedin"; p["url"] = "https://linkedin.com/in/fixture-new/"
        p["matchStatus"] = "verified"; p["evidence"] = "Official brokerage biography links this professional profile."
        try save(p)
        try check((try store.get("agents",aid))["linkedinUrl"] as? String == "https://www.linkedin.com/in/fixture-original/","another LinkedIn observation does not overwrite legacy profile")
        p["url"] = "https://linkedin.com/in/fixture-original/"
        try save(p)
        try store.put("agents",["id":"another-contact","name":"Another Fixture"])
        var conflictingIdentity = p; conflictingIdentity["agentId"] = "another-contact"
        try fails("same social profile cannot verify two contacts") { try save(conflictingIdentity) }
        let agent = try store.get("agents",aid)
        try check(agent["linkedinUrl"] as? String == "https://www.linkedin.com/in/fixture-original","verified same LinkedIn is compatible")
        try check(agent["status"] as? String == "Do not contact" && (agent["history"] as? [Record])?.first?["note"] as? String == "Preserve this history","contact suppression and history preserved")
        try check(Set(agent["localOverrides"] as? [String] ?? []) == ["phone","linkedinUrl"],"existing overrides preserved")
        try check(!(try store.professionalProfilesForAgent(aid)).contains { $0["legacy"] as? Bool == true },"verified matching structured observation replaces only projection")
        let linkedinID = Store.professionalID("profile-",[aid,"linkedin","https://www.linkedin.com/in/fixture-original"])
        p["id"] = linkedinID; p["expectedRevision"] = 1; p["checkedAt"] = "2025-02-01"
        try save(p)
        let revised = try store.get("professionalProfiles",linkedinID)
        try check(revised["revision"] as? Int == 2 && (revised["revisions"] as? [Record])?.count == 1,"changed observation retains revision history")
        p["checkedAt"] = "2025-02-02"
        try fails("stale revision rejected") { try save(p) }
        p["expectedRevision"] = 2; p["url"] = "https://linkedin.com/in/different/"
        try fails("profile identity cannot be reassigned") { try save(p) }
        try check(try Store.professionalProfileURL("https://www.facebook.com/profile.php?id=123&utm_source=fixture",platform:"facebook") == "https://www.facebook.com/profile.php?id=123","meaningful profile query retained")
        profileCount = try store.all("professionalProfiles").count
        try fails("transaction failure rolls back new profile") {
            try store.transaction {
                var fresh = p; fresh.removeValue(forKey:"id"); fresh["expectedRevision"] = 0
                try store.saveProfessionalProfile(fresh)
                throw StoreError(message:"Fixture failure after save")
            }
        }
        try check(try store.all("professionalProfiles").count == profileCount,"profile rollback preserved count")
    }
    let reopened = try Store(path:path,seed:false)
    try check(try reopened.all("professionalProfiles").count == profileCount,"profiles survive restart")
    try check((try reopened.get("agents",aid))["status"] as? String == "Do not contact","suppression survives restart")
}
