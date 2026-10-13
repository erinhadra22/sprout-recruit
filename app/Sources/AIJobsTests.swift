import Foundation
func runAIJobsTests() throws {
    func check(_ value: Bool) throws { if !value { throw StoreError(message:"AI job test failed") } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-ai-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let path = root.appendingPathComponent("test.sqlite").path
    let store = try Store(path:path,seed:false)
    _ = try store.command("agent.create",["name":"Fixture contact"])
    let aid = try store.all("agents")[0]["id"] as! String
    _ = try store.command("ai.prepare",["agentId":aid,"purpose":"email_followup","instruction":"Prepare a check-in."])
    try check(try store.all("drafts").isEmpty)
    let job = try store.all("aiJobs")[0]
    try check(job["state"] as? String == "awaiting_connection")
    let result:Record = ["id":job["id"]!,"reviewed":true,"body":"Reviewed fixture draft","source":"Fixture model result","subject":"Checking in"]
    _ = try store.command("ai.result",result)
    do { _ = try store.command("ai.result",result);throw StoreError(message:"Duplicate AI result accepted") } catch let e as StoreError { if e.message == "Duplicate AI result accepted" { throw e } }
    let reopen = try Store(path:path,seed:false)
    let draft = try reopen.all("drafts")[0]
    try check(draft["channel"] as? String == "Email" && draft["subject"] as? String == "Checking in")
    try check(try reopen.get("agents",aid)["status"] as? String == "Identified")
    _ = try reopen.command("draft.save",["id":draft["id"]!,"agentId":aid,"channel":"Email","body":"Edited fixture draft"])
    try check(try reopen.all("contextSuggestions").count == 1)
    try check(try reopen.all("drafts")[0]["aiJobId"] as? String == job["id"] as? String)
    print("PASS AI job persistence, draft-only results, replay prevention and edit learning")
}
