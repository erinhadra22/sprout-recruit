import Foundation
import SQLite3

func runMigrationTests() throws {
    let fm=FileManager.default
    let temp=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("sprout-migration-fixture-"+UUID().uuidString)
    try fm.createDirectory(at:temp,withIntermediateDirectories:true)
    defer { try? fm.removeItem(at:temp) }
    func check(_ condition:Bool,_ message:String) throws { if !condition { throw StoreError(message:"Migration fixture failed: "+message) } }
    func rejects(_ message:String,_ body:() throws -> Void) throws {
        var failed=false;do { try body() } catch { failed=true };try check(failed,message)
    }
    func fixture(_ name:String,missing:Bool=false) throws -> String {
        let directory=temp.appendingPathComponent(name),path=directory.appendingPathComponent("SproutRecruit.sqlite").path
        let store=try Store(path:path,seed:false)
        try store.put("settings",["id":"workspace","name":"Fixture Operator"])
        for folder in ["Knowledge","Attachments"] {
            try fm.createDirectory(at:directory.appendingPathComponent(folder),withIntermediateDirectories:true)
            try Data((folder+" fixture bytes").utf8).write(to:directory.appendingPathComponent(folder+"/file with space.txt"))
        }
        let knowledge=directory.appendingPathComponent("Knowledge/file with space.txt").path
        let attachment=directory.appendingPathComponent("Attachments/file with space.txt").path
        let external=temp.appendingPathComponent("external-reference.txt").path
        try store.put("settings",["id":"migration-fixture","documents":[["path":knowledge,"resolvedPath":knowledge,"filePath":attachment,"localPath":attachment,"sourcePath":knowledge],["path":external],["path":URL(fileURLWithPath:attachment).absoluteString]],"provenance":["path":knowledge,"original":"source supplied"],"notes":"Original document: "+knowledge,"connectedAccount":"fixture account; no secrets"])
        try store.put("agents",["id":"fixture-agent","name":"Fixture Recruiter","email":"fixture@example.com"])
        try store.put("drafts",["id":"fixture-draft","agentId":"fixture-agent","body":"Fixture unsent wording","state":"draft","createdAt":"2026-10-13T12:00:00Z"])
        if missing { try fm.removeItem(atPath:knowledge) }
        return path
    }
    func record(_ path:String,_ kind:String,_ id:String) throws -> Record {
        let db=try WorkspaceRecovery.openDB(path);defer { sqlite3_close(db) }
        let body=try WorkspaceRecovery.scalar(db,"SELECT body FROM records WHERE kind='\(kind)' AND id='\(id)'")
        return try JSONSerialization.jsonObject(with:Data(body.utf8)) as! Record
    }
    func count(_ path:String) throws -> Int {
        let db=try WorkspaceRecovery.openDB(path);defer { sqlite3_close(db) }
        return Int(try WorkspaceRecovery.scalar(db,"SELECT count(*) FROM records"))!
    }
    let source=try fixture("source"),destination=temp.appendingPathComponent("new-user-workspace/SproutRecruit.sqlite").path
    let initialHash=try WorkspaceRecovery.fileHash(URL(fileURLWithPath:source)),initialCount=try count(source)
    let sourceRecord=try record(source,"settings","migration-fixture")
    let sourceLease=try WorkspaceLease(source),destinationLease=try WorkspaceLease(destination)
    let receipt=try withExtendedLifetime((sourceLease,destinationLease)) { try WorkspaceMigration.migrate(source,to:destination) }
    try check(receipt["verified"] as? Bool == true && receipt["reconnectRequired"] as? Bool == true,"verified receipt requires reconnect")
    try check(try count(destination)==initialCount+1,"only migration settings record added")
    try check(try count(source)==initialCount && WorkspaceRecovery.fileHash(URL(fileURLWithPath:source))==initialHash,"source SQLite unchanged")
    let migrated=try record(destination,"settings","migration-fixture")
    let documents=migrated["documents"] as! [Record],first=documents[0]
    let targetFolder=URL(fileURLWithPath:destination).deletingLastPathComponent()
    for key in ["path","resolvedPath","sourcePath"] { try check(first[key] as? String == targetFolder.appendingPathComponent("Knowledge/file with space.txt").path,"managed Knowledge "+key+" rewritten") }
    for key in ["filePath","localPath"] { try check(first[key] as? String == targetFolder.appendingPathComponent("Attachments/file with space.txt").path,"managed Attachments "+key+" rewritten") }
    try check(documents[1]["path"] as? String == temp.appendingPathComponent("external-reference.txt").path,"external link preserved")
    try check(documents[2]["path"] as? String == targetFolder.appendingPathComponent("Attachments/file with space.txt").absoluteString,"file URL encoding preserved")
    try check((migrated["provenance"] as! Record)["path"] as? String == (sourceRecord["provenance"] as! Record)["path"] as? String,"provenance path unchanged")
    try check(migrated["notes"] as? String == sourceRecord["notes"] as? String,"freeform evidence unchanged")
    let sourceDraft=try record(source,"drafts","fixture-draft"),targetDraft=try record(destination,"drafts","fixture-draft")
    try check(NSDictionary(dictionary:sourceDraft).isEqual(to:targetDraft),"draft wording and state unchanged")
    try check(try String(contentsOf:targetFolder.appendingPathComponent("Knowledge/file with space.txt"),encoding:.utf8)=="Knowledge fixture bytes","managed bytes copied")
    let migration=try record(destination,"settings",receipt["migrationRecordID"] as! String)
    try check(migration["reconnectRequired"] as? Bool == true && migration["sourceDatabase"] as? String == source,"migration settings retain source and reconnect requirement")
    _ = try WorkspaceRecovery.validate(URL(fileURLWithPath:receipt["backupPath"] as! String))
    try rejects("existing target blocked") { _ = try WorkspaceMigration.migrate(source,to:destination) }
    try rejects("source overlap blocked") { _ = try WorkspaceMigration.migrate(source,to:URL(fileURLWithPath:source).deletingLastPathComponent().appendingPathComponent("nested/SproutRecruit.sqlite").path) }
    let empty=temp.appendingPathComponent("existing-empty");try fm.createDirectory(at:empty,withIntermediateDirectories:true)
    try rejects("existing empty directory blocked") { _ = try WorkspaceMigration.migrate(source,to:empty.appendingPathComponent("SproutRecruit.sqlite").path) }
    let link=temp.appendingPathComponent("linked");try fm.createSymbolicLink(at:link,withDestinationURL:targetFolder)
    try rejects("symlink destination blocked") { _ = try WorkspaceMigration.migrate(source,to:link.appendingPathComponent("child/SproutRecruit.sqlite").path) }
    let missing=try fixture("missing",missing:true),missingTarget=temp.appendingPathComponent("missing-target/SproutRecruit.sqlite")
    try rejects("missing managed references block publication") { _ = try WorkspaceMigration.migrate(missing,to:missingTarget.path) }
    try check(!fm.fileExists(atPath:missingTarget.deletingLastPathComponent().path),"failed migration leaves no destination")
    try check(try count(missing)>0,"failed migration leaves source readable")
    let db=try WorkspaceRecovery.openDB(missing,write:true);sqlite3_exec(db,"PRAGMA user_version=999",nil,nil,nil);sqlite3_close(db)
    try rejects("future schema blocked") { _ = try WorkspaceMigration.migrate(missing,to:missingTarget.path) }
    print("PASS: offline migration preserves source/drafts/provenance/external links, copies managed files, rewrites approved paths, verifies counts/backup, records reconnect requirement and rejects overwrite/overlap/symlink/missing-file/future-schema cases.")
}
