import Foundation

func runTests() throws {
    try runCandidateProvenanceTests()
    try runAgentIdentityTests()
    try runProfessionalProfileTests()
    try runTeamTests()
    try runProspectingTests()
    try runSourcingRulesTests()
    try runMessagesHistoryReaderTests()
    try runGmailAPIClientTests()
    try runNonblockingCredentialReadTests()
    try runGmailOAuthTests()
    try runCalendarAuthorizationTests()
    try runGoogleCalendarClientTests()
    try runCalendarConnectionTests()
    try runMeetingsTests()
    try runMeetingProposalsTests()
    try runGmailSyncTests()
    try runGmailSyncCoordinatorTests()
    try runReplySyncDispatchGateTests()
    try runMessagesSyncTests()
    try runMessagesSyncCoordinatorTests()
    try runOutboxTests()
    try runActivityEventsTests()
    try runIMessageTransportTests()
    try runOutboxCoordinatorTests()
    try runWorkspaceLocationTests()
    try runOnboardingTests()
    try runHistoricalAuditTests()
    try runRecoveryTests()
    try runTaskEditTests()
    try runCourtedTaskTests()
    try runSchemaUpgradeTests()
    try runMigrationTests()
    try runCourtedImportTests()
    try runGenericImportTests()
    try runPhotoTests()
    try runAIContextTests()
    try runAIJobsTests()
    try runPerformanceTests()
    try runWorkflowTests()
    try runCommunicationsTests()
    try runExternalMessagesTests()
    try runTelnyxMessageTests()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-tests-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:dir) }
    let path = dir.appendingPathComponent("test.sqlite").path
    var store: Store? = try Store(path:path,seedSamples:true)
    func check(_ ok: Bool,_ message: String) throws { if !ok { throw StoreError(message:"Test failed: "+message) } }
    try check(try store!.all("agents").count == 24,"seed creates 24 fictional agents")
    let initialVersion = try store!.dataVersion()
    let secondConnection = try Store(path:path,seed:false)
    _ = try secondConnection.command("agent.create",["name":"External refresh fixture"])
    try check(try store!.dataVersion() != initialVersion,"external commits change the lightweight database version")
    try check(try store!.snapshot()["agents"] as? [Record] != nil,"snapshot remains available after an external commit")
    try check(try store!.all("agents").count == 25,"external contact is visible without reopening the store")
    let aid = "sample-01"
    _ = try store!.command("agent.update",["agentId":aid,"status":"Connected","liked":true])
    _ = try store!.command("activity.create",["agentId":aid,"kind":"note","body":"A durable note","task":["title":"Follow up","dueDate":Store.plusDays(1),"repeatDays":7]])
    let task = try store!.all("tasks").first(where:{$0["title"] as? String == "Follow up"})!
    let count = try store!.all("tasks").count
    _ = try store!.command("task.complete",["id":task["id"]!]); _ = try store!.command("task.complete",["id":task["id"]!])
    try check(try store!.all("tasks").count == count+1,"recurring task completion is idempotent")
    let before = try store!.all("activities").count
    do {
        _ = try store!.command("activity.create",["agentId":aid,"body":"Must roll back","task":["title":"Invalid date","dueDate":"2026-02-31"]])
        throw StoreError(message:"Expected invalid date rejection")
    } catch let error as StoreError { try check(error.message != "Expected invalid date rejection","reject invalid date") }
    try check(try store!.all("activities").count == before,"linked note and task rollback atomically")
    _ = try store!.command("watchlist.save",["name":"A test list","agentIds":[aid,aid]])
    _ = try store!.command("search.save",["name":"Austin","filters":["city":"Austin","move":"High"]])
    _ = try store!.command("draft.save",["agentId":aid,"body":"Unsent draft","channel":"Message"])
    let savedDraft = try store!.all("drafts").first(where: { $0["agentId"] as? String == aid })!
    let reviewTask = try store!.all("tasks").first(where: { $0["draftId"] as? String == savedDraft["id"] as? String })!
    try check(reviewTask["type"] as? String == "Message" && reviewTask["completed"] as? Bool == false,
              "an unsent Message draft creates an open review task")
    try check((reviewTask["description"] as? String ?? "").contains("Unsent draft"),
              "the task explains that no text was sent")
    let taskCountAfterDraft = try store!.all("tasks").count
    _ = try store!.command("draft.save",["id":savedDraft["id"]!,"agentId":aid,"body":"Revised unsent draft","channel":"Message"])
    try check(try store!.all("tasks").count == taskCountAfterDraft,
              "revising a draft updates its linked task without creating a duplicate")
    let revisedTask = try store!.get("tasks",reviewTask["id"] as! String)
    try check((revisedTask["description"] as? String ?? "").contains("Revised unsent draft"),
              "the linked task reflects the latest saved text")
    _ = try store!.command("preferences.save",["minVolume":3000000,"dailyLimit":15])
    let rejected = "sample-02"
    _ = try store!.command("candidate.reject",["agentId":rejected,"reason":"Production too low","detail":"Below the level I want to review."])
    try check(try store!.get("agents",rejected)["disposition"] as? String == "skipped","rejected candidate is excluded")
    try check(try store!.all("candidateFeedback").count == 1,"reason is recorded separately")
    let activitiesBeforeDraftRead = try store!.all("activities").count
    try check(try store!.get("agents",aid)["lastInteraction"] == nil,"saving draft does not imply contact")
    let start = Date()
    for _ in 0..<100 { _ = try store!.snapshot() }
    let ms = Date().timeIntervalSince(start)*1000/100
    store = nil
    store = try Store(path:path,seedSamples:true)
    try check(try store!.get("agents",aid)["status"] as? String == "Connected","status survives reopen")
    try check(try store!.all("agents").count == 25,"no duplicate seed on reopen")
    try check(try store!.all("activities").count == activitiesBeforeDraftRead,"history survives reopen")
    try check(try store!.all("watchlists").count == 2,"watchlist persists")
    try check(try store!.all("searches").count == 1,"saved search persists")
    try check(try store!.all("drafts").first?["state"] as? String == "draft","draft remains unsent")
    try check(try store!.get("settings","preferences")["minVolume"] as? Int == 3000000,"preferences persist")
    try check(try store!.get("agents",rejected)["rejectionReason"] as? String == "Production too low","feedback survives reopen")
    _ = try store!.command("candidate.restore",["agentId":rejected])
    try check(try store!.get("agents",rejected)["disposition"] as? String == "","restored candidate returns")
    try check(try store!.all("candidateFeedback").count == 1,"restoring preserves feedback history")
    let activityClock = DateFormatter()
    activityClock.locale = Locale(identifier:"en_US_POSIX")
    activityClock.dateFormat = "yyyy-MM-dd'T'HH:mm"
    _ = try store!.command("activity.create",["agentId":aid,"kind":"interaction","title":"Call — Left voicemail","body":"Manually recorded test call.","dateTime":activityClock.string(from:Date())])
    try check(try store!.get("agents",aid)["lastInteraction"] as? String == Store.day(),"manual interaction updates contact date")
    _ = try store!.command("activity.create",["agentId":aid,"kind":"interaction","title":"Call — Connected","body":"An older test interaction.","dateTime":activityClock.string(from:Calendar.current.date(byAdding:.day,value:-7,to:Date())!)])
    try check(try store!.get("agents",aid)["lastInteraction"] as? String == Store.day(),"older interactions do not move last contact backward")
    print("PASS: persistence, seed idempotency, linked-action rollback, recurring-task idempotency, drafts, interactions, watchlists, searches and preferences.")
    print(String(format:"Local snapshot average (24 sample agents, 100 reads): %.2f ms",ms))
}
