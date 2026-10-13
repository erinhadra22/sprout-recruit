import Foundation
import SQLite3

func runTaskEditTests() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("sprout-task-edit-" + UUID().uuidString)
    defer { try? fm.removeItem(at:dir) }
    let store = try Store(path:dir.appendingPathComponent("workspace/SproutRecruit.sqlite").path)
    _ = try store.command("onboarding.save",["name":"Fixture Recruiter","company":"Sprout Realty","role":"Recruiter","timezone":"America/Chicago"])
    _ = try store.command("agent.create",["name":"Fixture Contact"])
    let agentId = try store.all("agents")[0]["id"] as! String
    func check(_ result: Bool, _ message: String) throws {
        if !result { throw StoreError(message:"Task edit fixture failed: " + message) }
    }
    func rejects(_ message: String, _ operation: () throws -> Void) throws {
        var rejected=false;do { try operation() } catch { rejected=true };try check(rejected,message)
    }
    _ = try store.command("task.create",["agentId":agentId,"title":"Fixture task","dueDate":Store.day(),"type":"Check-in","priority":"None","repeatDays":7,"description":"Original note"])
    let id = try store.all("tasks")[0]["id"] as! String
    _ = try store.command("task.update",["id":id,"title":"Revised fixture","dueDate":Store.plusDays(2),"type":"To-do","priority":"High","description":"Revised note","repeatDays":14])
    let updated = try store.get("tasks",id)
    try check(updated["title"] as? String == "Revised fixture" && updated["dueDate"] as? String == Store.plusDays(2),"edit and reschedule persist")
    try check(updated["type"] as? String == "To-do" && updated["priority"] as? String == "High" && updated["repeatDays"] as? Int == 14,"supported task controls persist")
    try check(updated["updatedAt"] as? String != nil,"edit has a recording timestamp")
    // WKWebView and CLI JSON bridge numeric values as NSNumber. Swift literal
    // fixtures alone miss the NSNumber(0/1)-to-Bool bridging behavior.
    for interval in [0,1] {
        let encoded = try JSONSerialization.data(withJSONObject:["id":id,"repeatDays":interval])
        let bridged = try JSONSerialization.jsonObject(with:encoded) as! Record
        _ = try store.command("task.update",bridged)
        try check(try store.get("tasks",id)["repeatDays"] as? Int == interval,"JSON numeric zero and one remain valid recurrence values")
    }
    let booleanJSON = try JSONSerialization.data(withJSONObject:["id":id,"repeatDays":true])
    let bridgedBoolean = try JSONSerialization.jsonObject(with:booleanJSON) as! Record
    try rejects("JSON boolean must not become a recurrence integer") { _ = try store.command("task.update",bridgedBoolean) }
    try check(try store.get("tasks",id)["repeatDays"] as? Int == 1,"boolean rejection preserves the existing recurrence")
    _ = try store.command("task.update",["id":id,"repeatDays":14])
    for patch: Record in [["dueDate":"2026-02-31"],["dueDate":42],["type":"Other"],["type":false],["priority":17],["repeatDays":5],["repeatDays":"7"],["title":""],["description":42],["agentId":"different"]] {
        var payload=patch;payload["id"]=id
        let before=try JSONSerialization.data(withJSONObject:store.get("tasks",id),options:.sortedKeys)
        try rejects("invalid edit is rejected") { _ = try store.command("task.update",payload) }
        try check(before == JSONSerialization.data(withJSONObject:store.get("tasks",id),options:.sortedKeys),"invalid edit does not partially change task")
    }
    _ = try store.command("task.complete",["id":id])
    let countAfterCompletion = try store.all("tasks").count
    try check(countAfterCompletion == 2,"recurring completion creates one next task")
    let next = try store.all("tasks").first { $0["id"] as? String != id }!
    try check(next["recurrenceSourceId"] as? String == id && next["completed"] as? Bool == false,"next task retains source identity and remains open")
    _ = try store.command("task.complete",["id":id])
    try check(try store.all("tasks").count == countAfterCompletion,"repeated completion is idempotent")
    try rejects("completed task cannot be edited before reopening") { _ = try store.command("task.update",["id":id,"title":"Cannot change yet"]) }
    let activitiesBefore = try store.all("activities").count
    _ = try store.command("task.reopen",["id":id])
    let reopened = try store.get("tasks",id)
    try check(reopened["completed"] as? Bool == false && reopened["completedAt"] == nil && reopened["reopenedAt"] as? String != nil,"reopen preserves history and clears current completion")
    _ = try store.command("task.reopen",["id":id])
    try check(try store.all("activities").count == activitiesBefore + 1,"repeated reopen creates no duplicate activity")
    _ = try store.command("task.complete",["id":id])
    try check(try store.all("tasks").count == countAfterCompletion,"reopen and recomplete does not duplicate recurrence")
    _ = try store.command("task.complete",["id":next["id"]!])
    try check(try store.all("tasks").count == countAfterCompletion + 1,"next recurrence can create its own successor")

    _ = try store.command("draft.save",["agentId":agentId,"channel":"Message","body":"Fixture unsent text"])
    let draftTask = try store.all("tasks").first { $0["draftId"] != nil }!
    let draftTaskId=draftTask["id"] as! String
    _ = try store.command("task.update",["id":draftTaskId,"dueDate":Store.plusDays(4),"priority":"Low"])
    try rejects("draft wording is edited through its source draft") { _ = try store.command("task.update",["id":draftTaskId,"description":"Replace text silently"]) }
    try check(try store.get("tasks",draftTaskId)["draftBody"] as? String == "Fixture unsent text","reschedule preserves exact saved draft wording")
    print("PASS: task edit/reschedule/reopen, validation rollback, draft linkage and recurrence idempotency.")
}

func runSchemaUpgradeTests() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("sprout-schema-fixture-" + UUID().uuidString)
    try fm.createDirectory(at:dir.appendingPathComponent("workspace"),withIntermediateDirectories:true)
    defer { try? fm.removeItem(at:dir) }
    let path=dir.appendingPathComponent("workspace/SproutRecruit.sqlite").path
    func check(_ result: Bool,_ message: String) throws { if !result { throw StoreError(message:"Schema fixture failed: " + message) } }
    do {
        let db=try WorkspaceRecovery.openDB(path,write:true);defer { sqlite3_close(db) }
        let schema="CREATE TABLE records(kind TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(kind,id)); CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO records VALUES('settings','fixture','{\"id\":\"fixture\",\"value\":\"preserve\"}'); PRAGMA user_version=0;"
        guard sqlite3_exec(db,schema,nil,nil,nil)==SQLITE_OK else { throw StoreError(message:"Cannot create legacy schema fixture.") }
    }
    do {
        let upgraded=try Store(path:path,seed:false)
        try check(try upgraded.get("settings","fixture")["value"] as? String == "preserve","schema adoption preserves records")
        try check(try WorkspaceRecovery.compatibility(path)["schemaVersion"] as? Int == 1,"legacy schema adopts current version")
    }
    let snapshots=try WorkspaceRecovery.list(path)["snapshots"] as! [Record]
    let before=snapshots.first { $0["reason"] as? String == "before-schema-1" }
    try check(before != nil,"pre-upgrade recovery snapshot is created")
    let manifest=try WorkspaceRecovery.validate(URL(fileURLWithPath:before!["path"] as! String))
    try check(manifest["schemaVersion"] as? Int == 0,"pre-upgrade snapshot preserves exact prior schema")
    do { _ = try Store(path:path,seed:false) }
    try check(try (WorkspaceRecovery.list(path)["snapshots"] as! [Record]).filter { $0["reason"] as? String == "before-schema-1" }.count == 1,"current schema does not rerun upgrade")
    do {
        let db=try WorkspaceRecovery.openDB(path,write:true);defer { sqlite3_close(db) }
        guard sqlite3_exec(db,"PRAGMA user_version=999",nil,nil,nil)==SQLITE_OK else { throw StoreError(message:"Cannot prepare future schema fixture.") }
    }
    let beforeBytes=try Data(contentsOf:URL(fileURLWithPath:path))
    var rejected=false;do { _ = try Store(path:path,seed:false) } catch { rejected=true }
    try check(rejected,"newer schema refuses startup")
    try check(beforeBytes == Data(contentsOf:URL(fileURLWithPath:path)),"newer schema refusal leaves original database bytes unchanged")
    print("PASS: legacy schema adoption, verified pre-upgrade snapshot, replay-safe opening and future-schema refusal without mutation.")
}
