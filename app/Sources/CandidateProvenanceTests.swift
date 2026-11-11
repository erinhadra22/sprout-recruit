import Foundation

func runCandidateProvenanceTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("candidate-provenance-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    var store: Store? = try Store(path:root.appendingPathComponent("fixture.sqlite").path,seed:false)
    func check(_ ok: Bool,_ message: String) throws { if !ok { throw StoreError(message:"Candidate provenance: "+message) } }
    func rejects(_ payload: Record) throws {
        do { _ = try store!.command("agent.intake",payload) }
        catch { return }
        throw StoreError(message:"Invalid intake was accepted")
    }
    _ = try store!.command("agent.create",["name":"Manual Fixture"])
    let manual = try store!.all("agents")[0]
    try check(manual["sourceType"] as? String == "manual" && manual["sourcedAt"] as? String == manual["createdAt"] as? String,"manual entry records acquisition and insertion")
    try rejects(["name":"Missing source","intakeKey":"bad-source"])
    try rejects(["name":"Missing actor","intakeKey":"bad-actor","sourceType":"ai_agent","sourceReference":"evidence-1"])
    try rejects(["name":"Missing email ID","intakeKey":"bad-email","sourceType":"email_import"])
    try rejects(["name":"Bad date","intakeKey":"bad-date","sourceType":"csv_import","sourcedAt":"2026-02-30"])
    try rejects(["name":"Bad timestamp","intakeKey":"bad-timestamp","sourceType":"csv_import","sourcedAt":"2026-02-30T15:00:00Z"])
    let payload: Record = ["name":"Agent Fixture","intakeKey":"fixture-ai-1","sourceType":"ai_agent","sourceActor":"Codex sourcing worker","sourceReference":"https://example.test/license/1","sourcedAt":"2026-11-03T23:30:00-06:00"]
    _ = try store!.command("agent.intake",payload)
    let ai = try store!.all("agents").first { $0["sourceType"] as? String == "ai_agent" }!
    let id = ai["id"] as! String
    try check(ai["manual"] as? Bool == false && ai["sourceActor"] as? String == "Codex sourcing worker","agent attribution is explicit and does not enable manual contact verification")
    _ = try store!.command("agent.intake",payload)
    try check(try store!.all("agents").count == 2,"same intake retry has one contact")
    var conflict = payload; conflict["email"] = "other@example.test"
    try rejects(conflict)
    _ = try store!.command("agent.update",["agentId":id,"city":"New city","source":"Wrong","createdAt":"2000-01-01"])
    let updated = try store!.get("agents",id)
    try check(updated["source"] as? String == ai["source"] as? String && updated["createdAt"] as? String == ai["createdAt"] as? String,"unrelated updates preserve provenance")
    _ = try store!.command("agent.intake",["name":"Email Fixture","intakeKey":"fixture-email-1","sourceType":"email_import","sourceReference":"gmail:message-id-1"])
    let email = try store!.all("agents").first { $0["sourceType"] as? String == "email_import" }!
    try check(email["sourcedAt"] == nil && email["source"] as? String == "Email import","unknown email time is not insertion time")
    _ = try store!.command("agent.intake",["name":"Fresh AI Fixture","intakeKey":"fresh-ai","sourceType":"ai_agent","sourceActor":"Codex","sourceReference":"fixture://fresh"])
    let fresh = try store!.all("agents").first { $0["name"] as? String == "Fresh AI Fixture" }!
    try check(fresh["sourcedAt"] as? String == fresh["createdAt"] as? String,"fresh direct agent intake timestamps acquisition automatically")
    _ = try store!.command("sourcingRules.save",["schemaVersion":1,"expectedRevision":0,"name":"Candidate provenance fixture","excludedBrokerages":["Blocked Brokerage"],"excludedTeams":["Blocked Team"]])
    try rejects(["name":"Excluded AI","intakeKey":"excluded-ai","sourceType":"ai_agent","sourceActor":"Codex","sourceReference":"fixture://excluded","office":"Blocked Brokerage","teamName":"Other Team"])
    try rejects(["name":"Unknown AI","intakeKey":"unknown-ai","sourceType":"ai_agent","sourceActor":"Codex","sourceReference":"fixture://unknown"])
    _ = try store!.command("agent.intake",["name":"Eligible AI","intakeKey":"eligible-ai","sourceType":"ai_agent","sourceActor":"Codex","sourceReference":"fixture://eligible","office":"Other Brokerage","teamName":"Other Team"])
    let eligible = try store!.all("agents").first { $0["name"] as? String == "Eligible AI" }!
    try check((eligible["sourcingRulesAssessment"] as? Record)?["state"] as? String == "eligible","direct agent intake checks the current live audience profile")
    store = nil
    store = try Store(path:root.appendingPathComponent("fixture.sqlite").path,seed:false)
    try check(try store!.get("agents",id)["sourcedAt"] as? String == payload["sourcedAt"] as? String,"source time and offset survive reopening")
    print("Candidate provenance tests passed")
}
