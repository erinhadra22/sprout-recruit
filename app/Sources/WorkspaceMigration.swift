import Foundation
import SQLite3

/// Explicit offline copy into a new workspace. Caller owns source and destination leases.
/// The source, original attachments, provenance and Keychain entries remain untouched.
enum WorkspaceMigration {
    private static let fm = FileManager.default
    private static let pathKeys:Set<String> = ["path","filePath","localPath","resolvedPath","sourcePath"]
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw StoreError(message:"Workspace migration transaction failed.") }
    }
    private static func save(_ db: OpaquePointer, kind: String, id: String, body: Record, insert: Bool = false) throws {
        var statement:OpaquePointer?;defer { sqlite3_finalize(statement) }
        let sql = insert ? "INSERT INTO records(body,kind,id) VALUES(?,?,?)" : "UPDATE records SET body=? WHERE kind=? AND id=?"
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else { throw StoreError(message:"Unable to prepare migrated record.") }
        let json=String(decoding:try JSONSerialization.data(withJSONObject:body,options:.sortedKeys),as:UTF8.self)
        for (index,value) in [json,kind,id].enumerated() { sqlite3_bind_text(statement,Int32(index+1),value,-1,Store.transient) }
        guard sqlite3_step(statement)==SQLITE_DONE,sqlite3_changes(db)==1 else { throw StoreError(message:"Unable to save migrated record.") }
    }
    private static func rows(_ db: OpaquePointer) throws -> [(String,String,Record)] {
        var statement:OpaquePointer?;defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db,"SELECT kind,id,body FROM records ORDER BY kind,id",-1,&statement,nil)==SQLITE_OK else { throw StoreError(message:"Unable to read migration records.") }
        var result:[(String,String,Record)]=[]
        var status=sqlite3_step(statement)
        while status==SQLITE_ROW {
            guard let k=sqlite3_column_text(statement,0),let id=sqlite3_column_text(statement,1),let b=sqlite3_column_text(statement,2),
                  let body=try JSONSerialization.jsonObject(with:Data(String(cString:b).utf8)) as? Record else { throw StoreError(message:"Migration encountered an invalid record.") }
            result.append((String(cString:k),String(cString:id),body));status=sqlite3_step(statement)
        }
        guard status==SQLITE_DONE else { throw StoreError(message:"Migration could not finish reading records.") }
        return result
    }
    private static func rewrite(_ value:Any, source:URL, destination:URL, staged:URL, changed:inout Int) throws -> Any {
        if let dictionary=value as? Record {
            var result=dictionary
            for (key,child) in dictionary {
                // Evidence remains an honest record of the original location.
                if key.lowercased().contains("provenance") { continue }
                if pathKeys.contains(key),let text=child as? String {
                    let fileURL=text.hasPrefix("file://") ? URL(string:text) : nil
                    if let host=fileURL?.host,!host.isEmpty,host.lowercased() != "localhost" { continue }
                    let original=fileURL?.path ?? text
                    for folder in ["Knowledge","Attachments"] {
                        let base=source.appendingPathComponent(folder).path
                        if original==base || original.hasPrefix(base+"/") {
                            let relative=String(original.dropFirst(source.path.count+1))
                            guard !relative.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0==".." || $0=="." || $0.isEmpty}) else { throw StoreError(message:"Managed document path contains traversal; migration stopped.") }
                            let stagedFile=staged.appendingPathComponent(relative)
                            guard fm.fileExists(atPath:stagedFile.path) else { throw StoreError(message:"A managed document referenced by the workspace is missing. Migration stopped without changing the source.") }
                            let newURL=destination.appendingPathComponent(relative)
                            result[key]=fileURL == nil ? newURL.path : newURL.absoluteString
                            changed += 1
                            break
                        }
                    }
                } else {
                    result[key]=try rewrite(child,source:source,destination:destination,staged:staged,changed:&changed)
                }
            }
            return result
        }
        if let array=value as? [Any] { return try array.map { try rewrite($0,source:source,destination:destination,staged:staged,changed:&changed) } }
        return value
    }
    static func migrate(_ sourcePath:String, to destinationPath:String) throws -> Record {
        guard sourcePath.hasPrefix("/"),destinationPath.hasPrefix("/"),!sourcePath.split(separator:"/").contains(".."),!destinationPath.split(separator:"/").contains("..") else { throw StoreError(message:"Use absolute migration paths without parent traversal.") }
        let source=URL(fileURLWithPath:sourcePath).standardizedFileURL,destination=URL(fileURLWithPath:destinationPath).standardizedFileURL
        let sourceFolder=source.deletingLastPathComponent(),destinationFolder=destination.deletingLastPathComponent()
        try WorkspaceRecovery.safeDirectory(sourceFolder);try WorkspaceRecovery.safeDirectory(destinationFolder)
        let actualSource=sourceFolder.resolvingSymlinksInPath(),actualDestination=destinationFolder.resolvingSymlinksInPath()
        guard source.path != destination.path,!actualDestination.path.hasPrefix(actualSource.path+"/"),!actualSource.path.hasPrefix(actualDestination.path+"/"),actualSource != actualDestination else {
            throw StoreError(message:"Migration requires a separate destination outside the source workspace.")
        }
        guard destination.path.hasSuffix(".sqlite"),(try? WorkspaceRecovery.status(destinationFolder)) == nil else { throw StoreError(message:"Migration requires a new, nonexistent destination workspace folder. Existing folders are never overwritten.") }
        _ = try WorkspaceRecovery.compatibility(source.path)
        let backup=try WorkspaceRecovery.snapshot(source.path,reason:"before-workspace-migration")
        guard let backupPath=backup["snapshotPath"] as? String else { throw StoreError(message:"Migration backup did not complete.") }
        let snapshot=URL(fileURLWithPath:backupPath)
        _ = try WorkspaceRecovery.validate(snapshot)
        let container=destinationFolder.deletingLastPathComponent()
        try WorkspaceRecovery.privateDirectory(container)
        let stage=container.appendingPathComponent(".sprout-migration-"+UUID().uuidString)
        try WorkspaceRecovery.privateDirectory(stage)
        var published=false
        defer { if !published { try? fm.removeItem(at:stage) } }
        let stagedDB=stage.appendingPathComponent(destination.lastPathComponent)
        try WorkspaceRecovery.copyDatabase(snapshot.appendingPathComponent("workspace.sqlite").path,stagedDB.path)
        for folder in ["Knowledge","Attachments"] {
            let original=snapshot.appendingPathComponent(folder)
            if fm.fileExists(atPath:original.path) { _ = try WorkspaceRecovery.files(original);try fm.copyItem(at:original,to:stage.appendingPathComponent(folder)) }
        }
        let db=try WorkspaceRecovery.openDB(stagedDB.path,write:true)
        var sourceCount=0,changedPaths=0
        let migrationID="workspaceMigration-"+UUID().uuidString
        do {
            defer { sqlite3_close(db) }
            let originalRows=try rows(db);sourceCount=originalRows.count
            try execute(db,"BEGIN IMMEDIATE")
            do {
                for (kind,id,body) in originalRows {
                    var changes=0
                    guard let rewritten=try rewrite(body,source:sourceFolder,destination:destinationFolder,staged:stage,changed:&changes) as? Record else { throw StoreError(message:"Migration record rewrite failed.") }
                    if changes>0 { try save(db,kind:kind,id:id,body:rewritten);changedPaths += changes }
                }
                let migration:Record=["id":migrationID,"sourceDatabase":source.path,"database":destination.path,"migratedAt":Store.now(),"backupPath":backupPath,"managedPathsRewritten":changedPaths,"sourceRecordCount":sourceCount,"reconnectRequired":true,"credentials":"Credentials remain in the source Keychain scope; reconnect your own external accounts when integrations are enabled."]
                try save(db,kind:"settings",id:migrationID,body:migration,insert:true)
                guard Int(try WorkspaceRecovery.scalar(db,"SELECT count(*) FROM records"))==sourceCount+1 else { throw StoreError(message:"Migration record count verification failed.") }
                try execute(db,"COMMIT")
            } catch { try? execute(db,"ROLLBACK");throw error }
        }
        _ = try WorkspaceRecovery.compatibility(stagedDB.path)
        // A second manifest check ensures copied attachments still match the recovery point.
        for folder in ["Knowledge","Attachments"] {
            let original=snapshot.appendingPathComponent(folder),copy=stage.appendingPathComponent(folder)
            if fm.fileExists(atPath:original.path) {
                let from=try WorkspaceRecovery.files(original),to=try WorkspaceRecovery.files(copy)
                guard from.count==to.count else { throw StoreError(message:"Migration attachment count changed.") }
                for (a,b) in zip(from,to) { guard try WorkspaceRecovery.fileHash(a)==WorkspaceRecovery.fileHash(b) else { throw StoreError(message:"Migration attachment validation failed.") } }
            }
        }
        // Do not overwrite a destination created while staging was in progress.
        guard (try? WorkspaceRecovery.status(destinationFolder)) == nil else { throw StoreError(message:"Destination appeared during migration. Nothing was overwritten.") }
        try fm.moveItem(at:stage,to:destinationFolder);published=true
        _ = try WorkspaceRecovery.compatibility(destination.path)
        return ["verified":true,"sourceDatabase":source.path,"database":destination.path,"backupPath":backupPath,"reconnectRequired":true,"sourcePreserved":true,"sourceRecordCount":sourceCount,"targetRecordCount":sourceCount+1,"managedPathsRewritten":changedPaths,"migrationRecordID":migrationID]
    }
}
