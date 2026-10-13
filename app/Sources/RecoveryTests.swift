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
    print("PASS: recovery WAL consistency, managed attachments, corruption restore, prior workspace retention, wrong target, schema refusal, tamper/link/path rejection and interrupted-swap recovery.")
}
