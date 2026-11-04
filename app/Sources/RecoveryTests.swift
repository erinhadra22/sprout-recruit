import Foundation
import SQLite3

func runRecoveryTests() throws {
    let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("sprout-recovery-fixture-" + UUID().uuidString)
    let fm = FileManager.default
    try fm.createDirectory(at:temp,withIntermediateDirectories:true)
    defer { try? fm.removeItem(at:temp) }
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message:"Recovery fixture failed: " + message) }
    }
    func rejects(_ label: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try check(rejected,label)
    }
    func sql(_ path: String, _ statement: String) throws {
        let db = try WorkspaceRecovery.openDB(path,write:true); defer { sqlite3_close(db) }
        guard sqlite3_exec(db,statement,nil,nil,nil) == SQLITE_OK else { throw StoreError(message:"Recovery fixture SQL failed.") }
    }
    func value(_ path: String) throws -> String {
        let db = try WorkspaceRecovery.openDB(path); defer { sqlite3_close(db) }
        return try WorkspaceRecovery.scalar(db,"SELECT json_extract(body,'$.value') FROM records WHERE kind='settings' AND id='fixture'")
    }
    func fixture(_ name: String, value: String = "original") throws -> String {
        let path = temp.appendingPathComponent(name).appendingPathComponent("SproutRecruit.sqlite").path
        let store = try Store(path:path,seed:false)
        try store.put("settings",["id":"fixture","value":value])
        return path
    }
    // A quiescent WAL database can lack sidecars while its main header remains
    // in WAL mode. Some VFS builds retain empty sidecars after final close, so
    // construct that valid state explicitly only inside this disposable fixture.
    let quiescent=try fixture("quiescent-wal",value:"retained without sidecars")
    do {
        let writer=try WorkspaceRecovery.openDB(quiescent,write:true)
        var writerClosed=false;defer{if !writerClosed{sqlite3_close(writer)}}
        // Load the pager before checkpointing a newly opened connection.
        try check(try WorkspaceRecovery.scalar(writer,"PRAGMA journal_mode").lowercased()=="wal","quiescent fixture uses WAL")
        _=try WorkspaceRecovery.scalar(writer,"SELECT count(*) FROM records")
        var persist:Int32=0
        _=sqlite3_file_control(writer,nil,SQLITE_FCNTL_PERSIST_WAL,&persist)
        let checkpoint=sqlite3_wal_checkpoint_v2(writer,nil,SQLITE_CHECKPOINT_TRUNCATE,nil,nil)
        let closed=sqlite3_close(writer)
        writerClosed=closed==SQLITE_OK
        try check(checkpoint==SQLITE_OK && closed==SQLITE_OK,"quiescent fixture checkpoints and closes normally")
    }
    func removeEmptyClosedFixtureSidecars() throws {
        let wal=URL(fileURLWithPath:quiescent+"-wal"),shm=URL(fileURLWithPath:quiescent+"-shm")
        if fm.fileExists(atPath:wal.path){
            try WorkspaceRecovery.regular(wal)
            try check(try WorkspaceRecovery.status(wal).st_size==0,"only an empty checkpointed fixture WAL may be removed")
        }
        if fm.fileExists(atPath:shm.path){try WorkspaceRecovery.regular(shm)}
        // All fixture handles are closed; no committed WAL frames remain.
        for sidecar in [wal,shm] where fm.fileExists(atPath:sidecar.path){try fm.removeItem(at:sidecar)}
    }
    try removeEmptyClosedFixtureSidecars()
    try check(!fm.fileExists(atPath:quiescent+"-wal") && !fm.fileExists(atPath:quiescent+"-shm"),"quiescent WAL fixture has no sidecar files")
    let originalBytes=try Data(contentsOf:URL(fileURLWithPath:quiescent))
    try check(originalBytes.count>20 && originalBytes[18]==2 && originalBytes[19]==2,"fixture retains a WAL-mode main header")
    _=try WorkspaceRecovery.compatibility(quiescent)
    _=try WorkspaceRecovery.compatibility(quiescent)
    do {
        let reader=try WorkspaceRecovery.openDB(quiescent);defer{sqlite3_close(reader)}
        try check(try WorkspaceRecovery.scalar(reader,"PRAGMA query_only")=="1","validation and backup readers are query-only")
        let writeAttempt=sqlite3_exec(reader,"UPDATE records SET body='{}' WHERE kind='settings' AND id='fixture'",nil,nil,nil)
        try check(writeAttempt==SQLITE_READONLY,"reader rejects SQL record writes despite sidecar initialization permission")
        try check(try WorkspaceRecovery.scalar(reader,"SELECT json_extract(body,'$.value') FROM records WHERE kind='settings' AND id='fixture'")=="retained without sidecars","attempted reader write preserves original record")
    }
    try check(try Data(contentsOf:URL(fileURLWithPath:quiescent))==originalBytes,"repeated validation leaves every main-database byte unchanged")
    // Sidecar retention after reads is VFS-dependent. Recreate the same absent-
    // sidecar state, with empty-WAL verification, before testing source backup.
    try removeEmptyClosedFixtureSidecars()
    let quiescentReceipt=try WorkspaceRecovery.snapshot(quiescent,reason:"quiescent-wal")
    let quiescentSnapshot=URL(fileURLWithPath:quiescentReceipt["snapshotPath"] as! String)
    let readonlyDB=quiescentSnapshot.appendingPathComponent("workspace.sqlite")
    try check(try value(readonlyDB.path)=="retained without sidecars","supported snapshot reads a quiescent WAL source")
    try check(try Data(contentsOf:URL(fileURLWithPath:quiescent))==originalBytes,"snapshot leaves quiescent source bytes unchanged")
    do {
        let reopened=try Store(path:quiescent,seed:false)
        try check(try reopened.get("settings","fixture")["value"] as? String=="retained without sidecars","normal Store startup succeeds after missing-sidecar validation")
    }
    let readonlyBytes=try Data(contentsOf:readonlyDB)
    try fm.setAttributes([.posixPermissions:0o400],ofItemAtPath:readonlyDB.path)
    try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:quiescentSnapshot.path)
    do {
        defer {
            try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:quiescentSnapshot.path)
            try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:readonlyDB.path)
        }
        _=try WorkspaceRecovery.validate(quiescentSnapshot)
        let reader=try WorkspaceRecovery.openDB(readonlyDB.path)
        let readonly=sqlite3_db_readonly(reader,"main")
        let queryOnly=try WorkspaceRecovery.scalar(reader,"PRAGMA query_only")
        sqlite3_close(reader)
        try check(readonly==1 && queryOnly=="1","genuinely read-only snapshot remains a read-only query source")
        let copied=temp.appendingPathComponent("copy-of-readonly.sqlite")
        try WorkspaceRecovery.copyDatabase(readonlyDB.path,copied.path)
        _=try WorkspaceRecovery.compatibility(copied.path)
        try check(try value(copied.path)=="retained without sidecars" && Data(contentsOf:readonlyDB)==readonlyBytes,"read-only backup source remains usable and unchanged")
    }
    let absent=temp.appendingPathComponent("must-not-create.sqlite").path
    try rejects("validation reader cannot create a missing database") { let db=try WorkspaceRecovery.openDB(absent);sqlite3_close(db) }
    try check(!fm.fileExists(atPath:absent),"read-intent open never creates a database")
    let path = try fixture("workspace")
    let parent = URL(fileURLWithPath:path).deletingLastPathComponent()
    for folder in ["Knowledge","Attachments"] {
        try fm.createDirectory(at:parent.appendingPathComponent(folder),withIntermediateDirectories:true)
        try Data((folder + " original").utf8).write(to:parent.appendingPathComponent(folder + "/fixture.txt"))
    }
    let lease = try WorkspaceLease(path)
    try rejects("concurrent restore/app ownership rejects duplicate lease") { _ = try WorkspaceLease(path) }
    if path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") {
        let alias = String(path.dropFirst("/private".count))
        try rejects("system path alias cannot acquire a second lease") { _ = try WorkspaceLease(alias) }
    }
    try withExtendedLifetime(lease) {
        let receipt = try WorkspaceRecovery.snapshot(path,reason:"fixture")
        let snapshot = URL(fileURLWithPath:receipt["snapshotPath"] as! String)
        _ = try WorkspaceRecovery.validate(snapshot)
        try check(try value(snapshot.appendingPathComponent("workspace.sqlite").path) == "original","SQLite snapshot contains saved records")
        // A snapshot must include WAL commits even while the reader's Store is open.
        var open: Store? = try Store(path:path,seed:false)
        try open!.put("settings",["id":"fixture","value":"WAL value"])
        let walReceipt = try WorkspaceRecovery.snapshot(path,reason:"wal-fixture")
        try check(try value((walReceipt["snapshotPath"] as! String) + "/workspace.sqlite") == "WAL value","consistent snapshot includes committed WAL data")
        open = nil
        try Data("changed attachment".utf8).write(to:parent.appendingPathComponent("Knowledge/fixture.txt"))
        let restored = try WorkspaceRecovery.restore(snapshot,to:path)
        try check(restored["restored"] as? Bool == true && (try value(path)) == "original","valid restore restores original CRM values")
        try check(try String(contentsOf:parent.appendingPathComponent("Knowledge/fixture.txt"),encoding:.utf8) == "Knowledge original","restore recovers managed attachment contents")
        try check(fm.fileExists(atPath:restored["previousWorkspace"] as! String),"restore preserves prior workspace directory")

        let wrong = try fixture("other-workspace",value:"other")
        try rejects("snapshot from another workspace is rejected") { _ = try WorkspaceRecovery.restore(snapshot,to:wrong) }
        try check(try value(wrong) == "other","wrong-destination rejection preserves records")

        let tampered = temp.appendingPathComponent("tampered")
        try fm.copyItem(at:snapshot,to:tampered)
        try Data("tampered".utf8).write(to:tampered.appendingPathComponent("Knowledge/fixture.txt"))
        try rejects("tampered attachment hash is rejected") { _ = try WorkspaceRecovery.validate(tampered) }
        try check(try value(path) == "original","tamper rejection leaves workspace untouched")

        let traversal = temp.appendingPathComponent("traversal")
        try fm.copyItem(at:snapshot,to:traversal)
        var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:traversal.appendingPathComponent("manifest.json"))) as! Record
        var entries = manifest["files"] as! [Record]
        entries[0]["path"] = "../workspace.sqlite"; manifest["files"] = entries
        try JSONSerialization.data(withJSONObject:manifest).write(to:traversal.appendingPathComponent("manifest.json"))
        try rejects("path traversal manifest is rejected") { _ = try WorkspaceRecovery.validate(traversal) }

        let linked = temp.appendingPathComponent("linked")
        try fm.copyItem(at:snapshot,to:linked)
        let linkedFile = linked.appendingPathComponent("Knowledge/fixture.txt")
        try fm.removeItem(at:linkedFile)
        try fm.createSymbolicLink(at:linkedFile,withDestinationURL:parent.appendingPathComponent("Knowledge/fixture.txt"))
        try rejects("snapshot symlink is rejected") { _ = try WorkspaceRecovery.validate(linked) }

        // A valid recovery point must recover a damaged current SQLite main file.
        try Data("deliberately corrupt SQLite fixture".utf8).write(to:URL(fileURLWithPath:path))
        let recovered = try WorkspaceRecovery.restore(snapshot,to:path)
        try check(try value(path) == "original","verified snapshot can recover corrupt current database")
        let damaged = URL(fileURLWithPath:recovered["previousWorkspace"] as! String).appendingPathComponent("SproutRecruit.sqlite")
        try check(try Data(contentsOf:damaged) == Data("deliberately corrupt SQLite fixture".utf8),"damaged original is retained unchanged for investigation")

        try sql(path,"PRAGMA user_version=999")
        try rejects("newer workspace schema is not downgraded") { _ = try WorkspaceRecovery.restore(snapshot,to:path) }
        do {
            let future = try WorkspaceRecovery.openDB(path);defer { sqlite3_close(future) }
            try check(try WorkspaceRecovery.scalar(future,"PRAGMA user_version") == "999","future schema is unchanged after rejection")
        }
        try sql(path,"PRAGMA user_version=0")

        let unexpected = parent.appendingPathComponent("unrelated-private-file.txt")
        try Data("unrelated".utf8).write(to:unexpected)
        try rejects("directory-swap restore rejects unrelated parent contents") { _ = try WorkspaceRecovery.restore(snapshot,to:path) }
        try check(fm.fileExists(atPath:unexpected.path),"unrelated file stays in its original location")
        try fm.removeItem(at:unexpected)

        // Simulate interruption between directory renames, using a valid preserved old folder.
        let old = temp.appendingPathComponent(".sprout-before-fixture"), stage = temp.appendingPathComponent(".sprout-restore-fixture")
        try fm.copyItem(at:parent,to:stage)
        let journal = WorkspaceRecovery.journal(path)
        try fm.moveItem(at:parent,to:old)
        try JSONSerialization.data(withJSONObject:["previous":old.path,"staged":stage.path]).write(to:journal)
        try WorkspaceRecovery.recoverInterrupted(path)
        try check(try value(path) == "original","interrupted rename restores preserved valid workspace")
        try check(!fm.fileExists(atPath:journal.path),"successful interruption recovery removes only journal")
        try fm.removeItem(at:stage)

        // Simulate a completed swap whose staged database is invalid.
        try fm.copyItem(at:parent,to:stage)
        try Data("bad staged SQLite".utf8).write(to:stage.appendingPathComponent("SproutRecruit.sqlite"))
        try fm.moveItem(at:parent,to:old)
        try fm.moveItem(at:stage,to:parent)
        try JSONSerialization.data(withJSONObject:["previous":old.path,"staged":stage.path]).write(to:journal)
        try WorkspaceRecovery.recoverInterrupted(path)
        try check(try value(path) == "original","invalid completed swap rolls back to verified old workspace")

        try WorkspaceRecovery.daily(path)
        let dailyBefore = try (WorkspaceRecovery.list(path)["snapshots"] as! [Record]).filter { $0["reason"] as? String == "daily" }
        try check(dailyBefore.count == 1,"first daily call creates one recovery point")
        try WorkspaceRecovery.daily(path)
        try check(try (WorkspaceRecovery.list(path)["snapshots"] as! [Record]).filter { $0["reason"] as? String == "daily" }.count == 1,"verified same-day recovery point is reused")
        try Data("damaged daily copy".utf8).write(to:URL(fileURLWithPath:dailyBefore[0]["path"] as! String).appendingPathComponent("Knowledge/fixture.txt"))
        try WorkspaceRecovery.daily(path)
        let renewed=try (WorkspaceRecovery.list(path)["snapshots"] as! [Record]).filter { $0["reason"] as? String == "daily" }
        try check(renewed.count == 1 && renewed[0]["path"] as? String != dailyBefore[0]["path"] as? String,"damaged daily snapshot does not suppress a new verified copy; only valid points are listed")
    }
    print("PASS: recovery missing-sidecar WAL validation and backup, query-only/read-only preservation, WAL consistency, managed attachments, corruption restore, prior workspace retention, wrong target, schema refusal, tamper/link/path rejection and interrupted-swap recovery.")
}
