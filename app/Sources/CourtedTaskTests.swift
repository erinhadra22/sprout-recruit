import Foundation

func runCourtedTaskTests() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-courted-tasks-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=try Store(path:directory.appendingPathComponent("workspace/SproutRecruit.sqlite").path)
    _ = try store.command("onboarding.save",["name":"Fixture Recruiter","company":"Sprout Realty","timezone":"America/Chicago"])
    try store.put("agents",["id":"contact-a","name":"Fixture A","courtedProfileURL":"https://brokerage.courted.io/cts/dashboard/agent_0001_NTREIS"])
    try store.put("agents",["id":"contact-b","name":"Fixture B","sourceProvider":"courted","sourceAgentId":"agent_0002_NTREIS"])
    func check(_ condition: Bool,_ message: String) throws { if !condition { throw StoreError(message:"Courted tasks fixture failed: "+message) } }
    func rejects(_ message: String,_ body: () throws -> Void) throws { var rejected=false;do { try body() } catch { rejected=true };try check(rejected,message) }
    func capture(_ candidate: String = "agent_0001_NTREIS",_ title: String = "Call fixture") -> Record {
        ["taskId":UUID().uuidString,"candidateId":candidate,"title":title,"dueDate":"2026-11-03","type":"Call","priority":"High","description":"Source note\nExact second line.","sourceURL":"https://brokerage.courted.io/cts/tasks","capturedAt":"2026-11-04T12:00:00Z"]
    }
    let source=capture(),payload:Record=["tasks":[source]]
    let before=try JSONSerialization.data(withJSONObject:store.all("tasks"),options:.sortedKeys)
    let preview=try store.previewCourtedTasks(payload)
    try check(preview["newTasks"] as? Int == 1 && preview["held"] as? Int == 0,"exact Courted URL identity previews one task")
    try check(before == JSONSerialization.data(withJSONObject:store.all("tasks"),options:.sortedKeys),"preview changes nothing")
    let result=try store.commitCourtedTasks(["tasks":[source],"token":preview["token"]!])
    let taskID="courted-task-"+(source["taskId"] as! String).lowercased()
    let saved=try store.get("tasks",taskID)
    try check(saved["agentId"] as? String == "contact-a" && saved["description"] as? String == source["description"] as? String,"stable contact and exact source text persist")
    try check(saved["completed"] as? Bool == false && saved["dueDate"] as? String == "2026-11-03","source due date stays exact and task stays open")
    try check(saved["courtedTaskSource"] as? [String:String] == source as? [String:String],"original capture metadata retained")
    try check(FileManager.default.fileExists(atPath:result["backupPath"] as? String ?? ""),"consistent backup saved")
    _ = try store.command("task.update",["id":taskID,"title":"Local edited title","dueDate":"2026-11-09","description":"Local note"])
    let localEdits=try JSONSerialization.data(withJSONObject:store.get("tasks",taskID),options:.sortedKeys)
    let replay=try store.previewCourtedTasks(payload)
    try check(replay["duplicates"] as? Int == 1 && replay["newTasks"] as? Int == 0,"source identity deduplicates despite local edits")
    _ = try store.commitCourtedTasks(["tasks":[source],"token":replay["token"]!])
    try check(localEdits == JSONSerialization.data(withJSONObject:store.get("tasks",taskID),options:.sortedKeys),"replay preserves all local edits and original source metadata")

    var unknown=capture("missing-candidate"),badDate=capture(),badID=capture(),badSource=capture()
    badDate["dueDate"]="2026-02-31";badID["taskId"]="not-a-task-uuid";badSource["sourceURL"]="https://example.invalid/task"
    unknown["title"]="Never link by name"
    let held=try store.previewCourtedTasks(["tasks":[unknown,badDate,badID,badSource]])
    try check(held["held"] as? Int == 4 && held["newTasks"] as? Int == 0,"invalid or unmatched rows remain held")
    let duplicateSource=capture("agent_0002_NTREIS")
    let providerPreview=try store.previewCourtedTasks(["tasks":[duplicateSource]])
    try check(providerPreview["newTasks"] as? Int == 1,"exact saved provider identity links without a profile URL")
    let repeated=try store.previewCourtedTasks(["tasks":[duplicateSource,duplicateSource]])
    try check(repeated["held"] as? Int == 2,"duplicate task IDs within capture held for review")
    try store.put("agents",["id":"contact-duplicate","name":"Different Fixture","sourceAliases":[["provider":"courted","sourceId":"agent_0002_NTREIS"]]])
    let ambiguous=try store.previewCourtedTasks(["tasks":[capture("agent_0002_NTREIS")]])
    try check(ambiguous["held"] as? Int == 1,"ambiguous provider identity never silently links")
    _ = try store.command("task.create",["agentId":"contact-a","title":"Call semantic duplicate","dueDate":"2026-11-03","type":"Call","priority":"None"])
    let collision=try store.previewCourtedTasks(["tasks":[capture("agent_0001_NTREIS","  CALL   semantic duplicate  ")]])
    try check(collision["held"] as? Int == 1 && collision["newTasks"] as? Int == 0,"semantic local collision held rather than duplicate")

    let fresh=capture("agent_0001_NTREIS","Another real task"),freshPayload:Record=["tasks":[fresh]]
    let freshPreview=try store.previewCourtedTasks(freshPayload)
    var changed=fresh;changed["priority"]="Low"
    try rejects("changed capture invalidates token") { _ = try store.commitCourtedTasks(["tasks":[changed],"token":freshPreview["token"]!]) }
    _ = try store.command("task.update",["id":taskID,"priority":"Low"])
    try rejects("concurrent task edit invalidates token") { _ = try store.commitCourtedTasks(["tasks":[fresh],"token":freshPreview["token"]!]) }
    let oldCount=try store.all("tasks").count
    let partial=try store.previewCourtedTasks(["tasks":[fresh,unknown]])
    let partialResult=try store.commitCourtedTasks(["tasks":[fresh,unknown],"token":partial["token"]!])
    try check(partialResult["imported"] as? Int == 1 && partialResult["held"] as? Int == 1,"eligible tasks imported while unmatched capture remains explicit")
    try check(try store.all("tasks").count == oldCount+1,"partial commit creates only eligible task")
    _ = try store.command("task.delete",["id":taskID])
    let deletedReplay=try store.previewCourtedTasks(payload)
    try check(deletedReplay["held"] as? Int == 1 && deletedReplay["newTasks"] as? Int == 0,"deleted source task is not silently recreated")
    print("PASS: Courted task exact identity, held conflicts, stable source replay, local-edit preservation, stale tokens, backup and partial readback.")
}
