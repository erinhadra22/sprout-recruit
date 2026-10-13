import Foundation
import SQLite3
import CryptoKit
import Darwin

/// Recovery is local and offline. Never replace an open workspace or export Keychain secrets.
final class WorkspaceLease {
    private var fd: Int32 = -1
    init(_ database: String) throws {
        let target = URL(fileURLWithPath:database).standardizedFileURL.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let file = dir.appendingPathComponent(".sprout-lock-" + WorkspaceRecovery.digest(Data(target.path.utf8)).prefix(20))
        fd = Darwin.open(file.path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0, flock(fd,LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
            throw StoreError(message:"This workspace is already open. Quit Sprout Recruit before restoring or migrating it.")
        }
    }
    deinit { if fd >= 0 { flock(fd,LOCK_UN); Darwin.close(fd) } }
}

enum WorkspaceRecovery {
    static let supportedSchema = 1
    static let fm = FileManager.default
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    static func status(_ url:URL) throws -> stat {
        var value=stat()
        guard lstat(url.path,&value)==0 else { throw StoreError(message:"Cannot inspect local file: " + url.lastPathComponent) }
        return value
    }
    static func regular(_ url: URL) throws {
        guard try status(url).st_mode & S_IFMT == S_IFREG else { throw StoreError(message:"Recovery requires regular files, not links or devices.") }
    }
    static func safeDirectory(_ url: URL) throws {
        var u = url.standardizedFileURL
        // macOS system aliases are legitimate; arbitrary user-created links remain rejected.
        if u.path == "/tmp" || u.path.hasPrefix("/tmp/") || u.path == "/var" || u.path.hasPrefix("/var/") { u = URL(fileURLWithPath:"/private"+u.path) }
        while u.path != "/" {
            if fm.fileExists(atPath:u.path) {
                let a = try status(u)
                guard a.st_mode & S_IFMT == S_IFDIR else { throw StoreError(message:"Recovery folders cannot contain symbolic links.") }
            }
            u.deleteLastPathComponent()
        }
    }
    static func privateDirectory(_ url: URL) throws {
        try safeDirectory(url)
        try fm.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    static func openDB(_ path: String, write: Bool = false) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = write ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path,&db,flags,nil) == SQLITE_OK, let result = db else {
            if db != nil { sqlite3_close(db) }
            throw StoreError(message:"Recovery could not open the database.")
        }
        sqlite3_busy_timeout(result,5000); return result
    }
    static func scalar(_ db: OpaquePointer, _ sql: String) throws -> String {
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt,0) else { throw StoreError(message:"Recovery database validation failed.") }
        return String(cString:text)
    }
    static func compatibility(_ path: String) throws -> Record {
        try regular(URL(fileURLWithPath:path)); let db = try openDB(path); defer { sqlite3_close(db) }
        let version = Int(try scalar(db,"PRAGMA user_version")) ?? -1
        guard (0...supportedSchema).contains(version) else { throw StoreError(message:"This workspace needs a newer Sprout version. Its schema is \(version); this app supports \(supportedSchema).") }
        guard try scalar(db,"PRAGMA integrity_check") == "ok" else { throw StoreError(message:"Workspace integrity failed. Restore a verified snapshot.") }
        _ = try scalar(db,"SELECT count(*) FROM records WHERE kind IS NOT NULL AND id IS NOT NULL AND body IS NOT NULL")
        _ = try scalar(db,"SELECT count(*) FROM meta")
        guard try scalar(db,"SELECT count(*) FROM records WHERE NOT json_valid(body) OR json_type(body) != 'object'") == "0" else { throw StoreError(message:"Workspace contains unreadable records.") }
        return ["compatible":true,"schemaVersion":version,"supportedSchemaVersion":supportedSchema]
    }
    static func copyDatabase(_ source: String, _ destination: String) throws {
        guard !fm.fileExists(atPath:destination) else { throw StoreError(message:"Recovery destination already exists.") }
        let src=try openDB(source); defer { sqlite3_close(src) }
        let dst=try openDB(destination,write:true); var destinationClosed=false; defer { if !destinationClosed { sqlite3_close(dst) } }
        guard let b=sqlite3_backup_init(dst,"main",src,"main") else { throw StoreError(message:"Cannot begin a consistent SQLite backup.") }
        var result: Int32 = SQLITE_OK, attempts=0
        repeat {
            result=sqlite3_backup_step(b,256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { usleep(50000); attempts += 1 }
        } while result == SQLITE_OK || ((result == SQLITE_BUSY || result == SQLITE_LOCKED) && attempts < 100)
        let finish=sqlite3_backup_finish(b)
        guard result == SQLITE_DONE && finish == SQLITE_OK else { throw StoreError(message:"Backup did not complete; no restore point was published.") }
        // Reopen after backup: the copied WAL header can differ from the destination
        // connection's cached mode. A same-connection pragma may falsely report DELETE.
        guard sqlite3_close(dst)==SQLITE_OK else { throw StoreError(message:"Could not close copied database.") }
        destinationClosed=true
        let standalone=try openDB(destination,write:true)
        do {
            defer { sqlite3_close(standalone) }
            guard try scalar(standalone,"PRAGMA journal_mode=DELETE").lowercased()=="delete" else { throw StoreError(message:"Could not finalize standalone snapshot database.") }
        }
        // macOS SQLite can retain an unused SHM file after switching to DELETE.
        // All destination handles are closed, and this unpublished copy no longer
        // uses WAL; stale destination sidecars must not enter the snapshot manifest.
        for suffix in ["-wal","-shm"] {
            let sidecar=URL(fileURLWithPath:destination+suffix)
            if fm.fileExists(atPath:sidecar.path) { try regular(sidecar);try fm.removeItem(at:sidecar) }
        }
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination)
    }
    static func root(_ path: String) -> URL {
        URL(fileURLWithPath:path).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sprout Recovery",isDirectory:true)
            .appendingPathComponent(String(digest(Data(URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath().path.utf8)).prefix(20)),isDirectory:true)
    }
    static func files(_ directory: URL) throws -> [URL] {
        try safeDirectory(directory)
        var result:[URL]=[]
        for f in try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {
            let type=try status(f).st_mode & S_IFMT
            if type == S_IFDIR { result += try files(f) }
            else { try regular(f); result.append(f) }
        }
        return result.sorted{$0.path<$1.path}
    }
    static func relative(_ file:URL,to folder:URL) throws -> String {
        let base=folder.standardizedFileURL.resolvingSymlinksInPath().path
        let value=file.standardizedFileURL.resolvingSymlinksInPath().path
        guard value.hasPrefix(base+"/") else { throw StoreError(message:"Snapshot file escaped its folder.") }
        return String(value.dropFirst(base.count+1))
    }
    static func fileHash(_ url: URL) throws -> String {
        try regular(url); let handle=try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var hash=SHA256()
        while let part=try handle.read(upToCount:1024*1024), !part.isEmpty { hash.update(data:part) }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func snapshot(_ path: String, at explicitRoot: URL? = nil, reason: String) throws -> Record {
        let source=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath(), parent=source.deletingLastPathComponent()
        try safeDirectory(parent); _ = try compatibility(path)
        let destRoot=explicitRoot ?? root(path); try privateDirectory(destRoot)
        guard destRoot.standardizedFileURL.path != parent.path, !destRoot.standardizedFileURL.path.hasPrefix(parent.path+"/") else { throw StoreError(message:"Keep recovery snapshots outside the live workspace folder.") }
        let name="snapshot-"+UUID().uuidString
        let staging=destRoot.appendingPathComponent(".pending-"+name), destination=destRoot.appendingPathComponent(name)
        try privateDirectory(staging); var published=false
        defer { if !published { try? fm.removeItem(at:staging) } }
        try copyDatabase(path,staging.appendingPathComponent("workspace.sqlite").path)
        for folder in ["Knowledge","Attachments"] {
            let from=parent.appendingPathComponent(folder)
            if fm.fileExists(atPath:from.path) {
                _ = try files(from); try fm.copyItem(at:from,to:staging.appendingPathComponent(folder))
                // Detect concurrent edits to managed files instead of declaring partial copies recoverable.
                let before=try files(from), after=try files(staging.appendingPathComponent(folder))
                guard before.count==after.count else { throw StoreError(message:"Attachments changed during backup. Try again.") }
                for (a,b) in zip(before,after) { guard try fileHash(a)==fileHash(b) else { throw StoreError(message:"Attachment changed during backup. Try again.") } }
            }
        }
        var entries:[Record]=[]
        for f in try files(staging) {
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:f.path)
            entries.append(["path":try relative(f,to:staging),"sha256":try fileHash(f)])
        }
        let manifest:Record=["format":1,"createdAt":Store.now(),"reason":reason,"sourceDatabase":source.path,
            "schemaVersion":try compatibility(staging.appendingPathComponent("workspace.sqlite").path)["schemaVersion"]!,
            "files":entries,"externalDependencies":try externalDependencies(staging.appendingPathComponent("workspace.sqlite").path,sourceFolder:parent),"externalFiles":"Only managed Knowledge and Attachments folders included. External linked documents remain at their original paths; credentials stay in Keychain."]
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.prettyPrinted]).write(to:staging.appendingPathComponent("manifest.json"),options:.atomic)
        _ = try validate(staging)
        try fm.moveItem(at:staging,to:destination);published=true
        return ["snapshotPath":destination.path,"sourceDatabase":source.path,"verified":true,"createdAt":manifest["createdAt"]!]
    }
    static func readManifest(_ folder: URL) throws -> Record {
        try safeDirectory(folder);try regular(folder.appendingPathComponent("manifest.json"))
        let manifestURL=folder.appendingPathComponent("manifest.json")
        let size=try status(manifestURL).st_size
        guard size<5_000_000 else { throw StoreError(message:"Recovery manifest is too large.") }
        let handle=try FileHandle(forReadingFrom:manifestURL);defer { try? handle.close() }
        let data=try handle.read(upToCount:5_000_000) ?? Data()
        guard data.count<5_000_000,let m=try JSONSerialization.jsonObject(with:data) as? Record,m["format"] as? Int==1,
              let entries=m["files"] as? [Record],!entries.isEmpty else { throw StoreError(message:"Unsupported recovery manifest.") }
        return m
    }
    static func validate(_ folder: URL) throws -> Record {
        let m=try readManifest(folder)
        let entries=m["files"] as! [Record]
        var expected=Set<String>()
        for entry in entries {
            guard let path=entry["path"] as? String, let hash=entry["sha256"] as? String,
                  path=="workspace.sqlite" || path.hasPrefix("Knowledge/") || path.hasPrefix("Attachments/"),
                  !path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0==".." || $0=="." || $0.isEmpty}),expected.insert(path).inserted else {
                throw StoreError(message:"Unsafe or duplicate recovery path: \(entry["path"] as? String ?? "missing").")
            }
            guard try fileHash(folder.appendingPathComponent(path))==hash else { throw StoreError(message:"A snapshot file is missing or changed. Nothing was restored.") }
        }
        let actual=Set(try files(folder).map{try relative($0,to:folder)}.filter{$0 != "manifest.json"})
        guard expected==actual,expected.contains("workspace.sqlite") else { throw StoreError(message:"Snapshot contains unexpected or missing files.") }
        let info=try compatibility(folder.appendingPathComponent("workspace.sqlite").path)
        guard info["schemaVersion"] as? Int == m["schemaVersion"] as? Int else { throw StoreError(message:"Snapshot schema does not match its manifest.") }
        return m
    }
    static func list(_ path: String) throws -> Record {
        let folder=root(path)
        guard fm.fileExists(atPath:folder.path) else { return ["root":folder.path,"snapshots":[]] }
        let entries=try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("snapshot-")}.compactMap { url -> Record? in
            guard let m=try? validate(url) else { return nil }
            return ["path":url.path,"createdAt":m["createdAt"] ?? "","reason":m["reason"] ?? ""]
        }.sorted{($0["createdAt"] as? String ?? "") > ($1["createdAt"] as? String ?? "")}
        return ["root":folder.path,"snapshots":entries]
    }
    static func daily(_ path: String) throws {
        let folder=root(path),today=String(Store.now().prefix(10))
        if fm.fileExists(atPath:folder.path) {
            // Read small manifests first. Old retained snapshots do not add full-file
            // hashing and SQLite integrity work to every app launch.
            for url in try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) where url.lastPathComponent.hasPrefix("snapshot-") {
                if let m=try? readManifest(url),m["reason"] as? String=="daily",(m["createdAt"] as? String ?? "").hasPrefix(today),
                   (try? validate(url)) != nil { return }
            }
        }
        _ = try snapshot(path,reason:"daily")
    }
    static func journal(_ path: String) -> URL { root(path).appendingPathComponent("restore-journal.json") }
    /// Recover a crash between the two directory renames before any Store handle opens.
    static func recoverInterrupted(_ path: String) throws {
        let j=journal(path)
        guard fm.fileExists(atPath:j.path) else { return }
        guard let m=try JSONSerialization.jsonObject(with:Data(contentsOf:j)) as? Record,
              let previous=m["previous"] as? String,let staged=m["staged"] as? String else { throw StoreError(message:"Invalid restore recovery journal.") }
        let parent=URL(fileURLWithPath:path).deletingLastPathComponent()
        let old=URL(fileURLWithPath:previous),stage=URL(fileURLWithPath:staged)
        guard old.deletingLastPathComponent()==parent.deletingLastPathComponent(),stage.deletingLastPathComponent()==parent.deletingLastPathComponent(),old.lastPathComponent.hasPrefix(".sprout-before-"),stage.lastPathComponent.hasPrefix(".sprout-restore-") else { throw StoreError(message:"Unsafe restore journal paths.") }
        if !fm.fileExists(atPath:parent.path) {
            guard fm.fileExists(atPath:old.path) else { throw StoreError(message:"Restore interrupted; the preserved workspace is missing. No empty workspace was created.") }
            try fm.moveItem(at:old,to:parent)
        }
        do { _ = try compatibility(path) }
        catch {
            guard fm.fileExists(atPath:old.path) else { throw error }
            _ = try compatibility(old.appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent).path)
            let failed=parent.deletingLastPathComponent().appendingPathComponent(".sprout-failed-"+UUID().uuidString)
            try fm.moveItem(at:parent,to:failed);try fm.moveItem(at:old,to:parent)
        }
        try fm.removeItem(at:j)
    }
    static func restore(_ snapshot: URL, to path: String) throws -> Record {
        let manifest=try validate(snapshot)
        let database=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath(),parent=database.deletingLastPathComponent()
        try safeDirectory(parent)
        guard database.lastPathComponent=="SproutRecruit.sqlite" || database.lastPathComponent.hasSuffix(".sqlite") else { throw StoreError(message:"Choose a SQLite workspace destination.") }
        guard fm.fileExists(atPath:path),!snapshot.path.hasPrefix(parent.path+"/") else { throw StoreError(message:"Restore requires an existing workspace and an external recovery snapshot.") }
        let allowed=Set([database.lastPathComponent,database.lastPathComponent+"-wal",database.lastPathComponent+"-shm","Knowledge","Attachments","Backups"])
        let children=try fm.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil)
        guard children.allSatisfy({allowed.contains($0.lastPathComponent)}) else { throw StoreError(message:"Restore needs a dedicated workspace folder; unrelated files were found. No files were moved.") }
        // A damaged current DB must remain recoverable. Keep its complete original directory.
        if let current=try? openDB(path) {
            let version=Int((try? scalar(current,"PRAGMA user_version")) ?? "0") ?? 0;sqlite3_close(current)
            guard version<=supportedSchema else { throw StoreError(message:"Restore with the newer app that owns this workspace.") }
        }
        if (try? compatibility(path)) != nil { _ = try self.snapshot(path,reason:"before-restore") }
        let container=parent.deletingLastPathComponent(),id=UUID().uuidString
        let stage=container.appendingPathComponent(".sprout-restore-"+id),old=container.appendingPathComponent(".sprout-before-"+id)
        // Preserve unrelated local files and existing backups. The old folder is retained after success.
        _ = try files(parent);try fm.copyItem(at:parent,to:stage)
        var journalWritten=false
        defer { if !journalWritten { try? fm.removeItem(at:stage) } }
        for suffix in ["","-wal","-shm"] {
            let f=stage.appendingPathComponent(database.lastPathComponent+suffix)
            if fm.fileExists(atPath:f.path) { try fm.removeItem(at:f) }
        }
        try copyDatabase(snapshot.appendingPathComponent("workspace.sqlite").path,stage.appendingPathComponent(database.lastPathComponent).path)
        for folder in ["Knowledge","Attachments"] {
            let dst=stage.appendingPathComponent(folder),src=snapshot.appendingPathComponent(folder)
            if fm.fileExists(atPath:dst.path) { try fm.removeItem(at:dst) }
            if fm.fileExists(atPath:src.path) { try fm.copyItem(at:src,to:dst) }
        }
        // Absolute managed-document references are only valid when restoring to the original workspace.
        guard manifest["sourceDatabase"] as? String==database.path else { throw StoreError(message:"This snapshot belongs to a different workspace. Use the migration procedure to preserve document links.") }
        _ = try compatibility(stage.appendingPathComponent(database.lastPathComponent).path)
        let j=journal(path);try privateDirectory(j.deletingLastPathComponent())
        try JSONSerialization.data(withJSONObject:["previous":old.path,"staged":stage.path],options:.sortedKeys).write(to:j,options:.atomic);journalWritten=true
        do {
            try fm.moveItem(at:parent,to:old)
            try fm.moveItem(at:stage,to:parent)
            _ = try compatibility(path)
            try fm.removeItem(at:j)
        } catch {
            if !fm.fileExists(atPath:parent.path),fm.fileExists(atPath:old.path) { try? fm.moveItem(at:old,to:parent) }
            throw error
        }
        return ["restored":true,"database":path,"previousWorkspace":old.path,"credentials":"Keychain unchanged"]
    }
}
