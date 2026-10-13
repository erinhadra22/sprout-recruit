import Foundation
import SQLite3

extension WorkspaceRecovery {
    /// Inventory linked paths without opening/copying external documents or credentials.
    static func externalDependencies(_ database:String,sourceFolder:URL) throws -> [Record] {
        let db=try openDB(database);defer { sqlite3_close(db) }
        var statement:OpaquePointer?;defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db,"SELECT body FROM records",-1,&statement,nil)==SQLITE_OK else { throw StoreError(message:"Cannot inventory recovery document links.") }
        let keys:Set<String>=["path","filePath","localPath","resolvedPath","sourcePath"]
        let roots=["Knowledge","Attachments"].map{sourceFolder.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath().path}
        var paths=Set<String>()
        func visit(_ value:Any) {
            if let dict=value as? Record {
                for (key,child) in dict where !key.lowercased().contains("provenance") {
                    if keys.contains(key),let text=child as? String {
                        let local=text.hasPrefix("file://") ? URL(string:text)?.path : text.hasPrefix("/") ? text : nil
                        if let local=local {
                            let path=URL(fileURLWithPath:local).standardizedFileURL.resolvingSymlinksInPath().path
                            if !roots.contains(where:{path==$0 || path.hasPrefix($0+"/")}) { paths.insert(path) }
                        }
                    } else { visit(child) }
                }
            } else if let array=value as? [Any] { array.forEach(visit) }
        }
        var status=sqlite3_step(statement)
        while status==SQLITE_ROW {
            if let body=sqlite3_column_text(statement,0) { visit(try JSONSerialization.jsonObject(with:Data(String(cString:body).utf8))) }
            status=sqlite3_step(statement)
        }
        guard status==SQLITE_DONE else { throw StoreError(message:"Cannot finish recovery document inventory.") }
        return paths.sorted().map{["path":$0,"included":false,"existsAtBackup":fm.fileExists(atPath:$0)]}
    }
}
