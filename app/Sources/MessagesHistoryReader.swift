import Foundation
import SQLite3
import CryptoKit

struct MessagesHistoryReadError: LocalizedError {
    let code:String
    let message:String
    var errorDescription:String? { message }
}

// Local, read-only provider evidence. This adapter never changes permissions,
// executes Messages commands, or mutates a cursor; Store commits the whole batch.
final class MessagesHistoryReader {
    static let defaultPath=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    private let path:String
    private static let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private static let maxBodyBytes=262_144
    private final class Budget {
        let deadline=ProcessInfo.processInfo.systemUptime+3
        var calls=10_000
        func interrupted()->Bool { calls -= 1;return calls<=0 || ProcessInfo.processInfo.systemUptime>deadline }
    }
    init(path:String=MessagesHistoryReader.defaultPath) { self.path=path }
    private func fail(_ code:String,_ message:String)->MessagesHistoryReadError { .init(code:code,message:message) }
    private func sourceIdentity() throws -> String {
        guard let attrs=try? FileManager.default.attributesOfItem(atPath:path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let device=attrs[.systemNumber] as? NSNumber,
              let inode=attrs[.systemFileNumber] as? NSNumber,
              let created=attrs[.creationDate] as? Date,
              FileManager.default.isReadableFile(atPath:path) else {
            throw fail("access_unavailable","Messages history is not readable. Review Sprout Recruit's Full Disk Access permission and retry.")
        }
        let identity=URL(fileURLWithPath:path).standardizedFileURL.path+"|"+device.stringValue+"|"+inode.stringValue+"|"+String(created.timeIntervalSince1970)
        return SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func sqliteFailure(_ db:OpaquePointer?,_ code:Int32)->MessagesHistoryReadError {
        switch code & 0xff {
        case SQLITE_BUSY,SQLITE_LOCKED:return fail("busy","Messages history is busy. The saved reply cursor was not changed.")
        case SQLITE_INTERRUPT:return fail("read_budget_exceeded","Messages history exceeded this read's time budget. The saved reply cursor was not changed.")
        case SQLITE_CANTOPEN,SQLITE_PERM,SQLITE_AUTH:return fail("access_unavailable","Messages history is not readable. Review Sprout Recruit's Full Disk Access permission and retry.")
        default:return fail("read_failed","Messages history could not be read safely. The saved reply cursor was not changed.")
        }
    }
    private func query(_ db:OpaquePointer,_ sql:String,_ values:[Any]=[],_ visit:(OpaquePointer)throws->Void) throws {
        var stmt:OpaquePointer?
        let prepared=sqlite3_prepare_v2(db,sql,-1,&stmt,nil)
        guard prepared==SQLITE_OK,let stmt else { throw sqliteFailure(db,prepared) }
        defer { sqlite3_finalize(stmt) }
        for (index,value) in values.enumerated() {
            let result:Int32
            if let integer=value as? Int64 { result=sqlite3_bind_int64(stmt,Int32(index+1),integer) }
            else if let double=value as? Double { result=sqlite3_bind_double(stmt,Int32(index+1),double) }
            else { throw fail("read_failed","Messages history query parameter types were rejected.") }
            guard result==SQLITE_OK else { throw fail("read_failed","Messages history query parameters were rejected.") }
        }
        while true {
            let result=sqlite3_step(stmt)
            if result==SQLITE_DONE { return }
            guard result==SQLITE_ROW else { throw sqliteFailure(db,result) }
            try visit(stmt)
        }
    }
    private func execute(_ db:OpaquePointer,_ sql:String) throws {
        let result=sqlite3_exec(db,sql,nil,nil,nil)
        guard result==SQLITE_OK else { throw sqliteFailure(db,result) }
    }
    private func text(_ stmt:OpaquePointer,_ column:Int32,maximum:Int=4096) -> String? {
        guard sqlite3_column_type(stmt,column) != SQLITE_NULL else { return nil }
        let count=Int(sqlite3_column_bytes(stmt,column))
        guard count<=maximum,let bytes=sqlite3_column_text(stmt,column) else { return nil }
        return String(bytes:UnsafeBufferPointer(start:bytes,count:count),encoding:.utf8)
    }
    private func columns(_ db:OpaquePointer,_ table:String) throws -> Set<String> {
        var names=Set<String>()
        try query(db,"PRAGMA table_info(\(table))") { stmt in if let name=self.text(stmt,1) { names.insert(name.lowercased()) } }
        return names
    }
    private func schema(_ db:OpaquePointer) throws -> (message:Set<String>,chat:Set<String>) {
        let required:[String:Set<String>]=[
            "message":["guid","date","is_from_me","handle_id","item_type","text","attributedbody","service","cache_has_attachments","associated_message_type"],
            "handle":["id"],"chat":["guid"],"chat_message_join":["chat_id","message_id"],"chat_handle_join":["chat_id","handle_id"]]
        var messageColumns=Set<String>(),chatColumns=Set<String>()
        for (table,fields) in required {
            let actual=try columns(db,table)
            guard fields.isSubset(of:actual) else { throw fail("schema_unsupported","This Messages database schema is not supported. Reply sync remains paused without changing its cursor.") }
            if table=="message" { messageColumns=actual }
            if table=="chat" { chatColumns=actual }
        }
        return (messageColumns,chatColumns)
    }
    private static func isoDate(_ value:String)->Date? {
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return formatter.date(from:value) ?? ISO8601DateFormatter().date(from:value)
    }
    private func occurredAt(_ raw:Int64) throws -> Date {
        // Messages uses seconds on older schemas and nanoseconds on modern ones.
        let magnitude=Double(raw).magnitude
        guard magnitude<=10_000_000_000 || magnitude>=1_000_000_000_000_000 else { throw fail("invalid_message","A matching Messages timestamp has an unsupported unit. The reply cursor was not changed.") }
        let seconds=magnitude>=1_000_000_000_000_000 ? Double(raw)/1_000_000_000 : Double(raw)
        let result=Date(timeIntervalSince1970:seconds+978_307_200)
        guard result.timeIntervalSince1970>=0,result.timeIntervalSince1970<32_503_680_000 else { throw fail("invalid_message","A matching Messages timestamp is invalid. The reply cursor was not changed.") }
        return result
    }
    private func callerAddress(_ raw:String?)->String? {
        guard let value=raw?.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty,value.utf8.count<=320 else { return nil }
        if let phone=try? Store.normalizedCommunicationPhone(value) { return phone }
        return value.range(of:"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$",options:.regularExpression) != nil ? value : nil
    }
    static func decodedBody(text:String?,archive:Data?,hasAttachments:Bool,reaction:Bool)->(body:String,kind:String) {
        if reaction { return ("[Reaction received. Open Messages to review the reaction.]","reaction") }
        func usable(_ value:String?)->String? {
            guard let value,value.utf8.count<=maxBodyBytes,value.count<=50_000,!value.contains("\0") else { return nil }
            return value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : value
        }
        if let plain=usable(text),plain != "\u{fffc}" { return (plain,"text") }
        if let archive,let plain=usable(MessagesTypedstreamDecoder.text(archive)),plain != "\u{fffc}" { return (plain,"text") }
        // Secure keyed archives remain separate from the byte-only typedstream
        // parser. Never invoke NSUnarchiver on an arbitrary object graph.
        if let archive,archive.count<=maxBodyBytes,archive.starts(with:Data("bplist00".utf8)),
           let decoder=try? NSKeyedUnarchiver(forReadingFrom:archive) {
            decoder.requiresSecureCoding=true
            decoder.decodingFailurePolicy = .setErrorAndReturn
            let attributed=decoder.decodeObject(of:[NSAttributedString.self,NSString.self,NSDictionary.self,NSArray.self,NSNumber.self],forKey:NSKeyedArchiveRootObjectKey) as? NSAttributedString
            decoder.finishDecoding()
            if decoder.error==nil,let plain=usable(attributed?.string),plain != "\u{fffc}" { return (plain,"text") }
        }
        if hasAttachments { return ("[Attachment received. Open Messages to review it.]","attachment") }
        return ("[Message received. Its text could not be decoded safely; open Messages to review it.]","unavailable")
    }
    func read(phones:[String],since:String,afterRowID:Int64,limit:Int=200,expectedSourceID:String?=nil) throws -> Record {
        guard afterRowID>=0,(1...500).contains(limit),phones.count<=10_000,let startDate=Self.isoDate(since) else { throw fail("invalid_request","A valid reply start time, cursor, phone list and bounded page size are required.") }
        var wanted=Set<String>()
        for phone in phones {
            guard let normalized=try? Store.normalizedCommunicationPhone(phone) else { throw fail("invalid_request","Reply sync accepts exact candidate phone numbers only.") }
            wanted.insert(normalized)
        }
        let sourceID=try sourceIdentity(),startRow=(expectedSourceID != nil && expectedSourceID != sourceID) ? 0 : afterRowID
        var opened:OpaquePointer?
        let openResult=sqlite3_open_v2(path,&opened,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)
        guard openResult==SQLITE_OK,let db=opened else { if let opened { sqlite3_close(opened) };throw sqliteFailure(nil,openResult) }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db,"main")==1 else { throw fail("read_failed","Messages history did not open read-only.") }
        sqlite3_busy_timeout(db,250)
        let budget=Budget()
        sqlite3_progress_handler(db,1000,{ context in
            guard let context else { return 1 }
            return Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue().interrupted() ? 1 : 0
        },Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(db,0,nil,nil);withExtendedLifetime(budget) {} }
        try execute(db,"PRAGMA query_only=ON")
        try execute(db,"PRAGMA trusted_schema=OFF")
        try execute(db,"BEGIN")
        var committed=false
        defer { if !committed { sqlite3_exec(db,"ROLLBACK",nil,nil,nil) } }
        let capabilities=try schema(db),fields=capabilities.message
        if wanted.isEmpty {
            guard try sourceIdentity()==sourceID else { throw fail("source_changed_during_read","Messages history changed files during the read. Retry without advancing the cursor.") }
            try execute(db,"COMMIT");committed=true
            return ["sourceID":sourceID,"scannedFromRowID":startRow,"nextRowID":startRow,"hasMore":false,"messages":[Record](),"scannedCount":0]
        }
        var maximum:Int64=0
        try query(db,"SELECT COALESCE(MAX(ROWID),0) FROM message") { maximum=sqlite3_column_int64($0,0) }
        guard maximum>=startRow else { throw fail("cursor_regression","Messages history is older than its saved cursor. Reply sync is paused for review.") }
        var rows:[Int64]=[]
        let appleStart=startDate.timeIntervalSince1970-978_307_200
        let dateFloor="(CASE WHEN ABS(date)>=1000000000000000 THEN date/1000000000.0 ELSE date END)>=?"
        try query(db,"SELECT ROWID FROM message WHERE ROWID>? AND \(dateFloor) ORDER BY ROWID LIMIT ?",[startRow,appleStart,Int64(limit+1)]) { rows.append(sqlite3_column_int64($0,0)) }
        let hasMore=rows.count>limit
        if hasMore { rows.removeLast() }
        let next=hasMore ? (rows.last ?? startRow) : maximum
        var messages:[Record]=[]
        let systemFilter=fields.contains("is_system_message") ? " AND COALESCE(m.is_system_message,0)=0" : ""
        let styleFilter=capabilities.chat.contains("style") ? " AND c.style=45" : ""
        let caller=fields.contains("destination_caller_id") ? "m.destination_caller_id" : "NULL"
        // No body column is projected here. A row must first pass all identity,
        // membership and time checks before the second query fetches its body.
        let metadata="""
        SELECT m.ROWID,m.guid,m.date,hs.id,hm.id,c.guid,m.service,m.associated_message_type,m.cache_has_attachments,\(caller)
        FROM message m
        JOIN handle hs ON hs.ROWID=m.handle_id
        JOIN chat_message_join cm ON cm.message_id=m.ROWID
        JOIN chat c ON c.ROWID=cm.chat_id
        JOIN chat_handle_join ch ON ch.chat_id=c.ROWID
        JOIN handle hm ON hm.ROWID=ch.handle_id
        WHERE m.ROWID>? AND m.ROWID<=? AND (CASE WHEN ABS(m.date)>=1000000000000000 THEN m.date/1000000000.0 ELSE m.date END)>=?
          AND m.is_from_me=0 AND m.item_type=0\(systemFilter)\(styleFilter)
          AND (SELECT COUNT(*) FROM chat_handle_join members WHERE members.chat_id=c.ROWID)=1
          AND (SELECT COUNT(*) FROM chat_message_join links WHERE links.message_id=m.ROWID)=1
        ORDER BY m.ROWID
        """
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        if let windowLast=rows.last {
            try query(db,metadata,[startRow,windowLast,appleStart]) { stmt in
                guard let sender=self.text(stmt,3,maximum:320),let member=self.text(stmt,4,maximum:320),
                      let phone=try? Store.normalizedCommunicationPhone(sender),wanted.contains(phone),
                      let participant=try? Store.normalizedCommunicationPhone(member),participant==phone else { return }
                guard let chat=self.text(stmt,5,maximum:512) else { return }
                let identity=chat.split(separator:";",omittingEmptySubsequences:false)
                guard identity.count==3,identity[1]=="-",
                      let threadPhone=try? Store.normalizedCommunicationPhone(String(identity[2])),threadPhone==phone else { return }
                guard sqlite3_column_type(stmt,2)==SQLITE_INTEGER else { throw self.fail("invalid_message","A matching Messages timestamp is not an integer. The cursor was not changed.") }
                let occurred=try self.occurredAt(sqlite3_column_int64(stmt,2))
                guard occurred>=startDate else { return }
                guard let guid=self.text(stmt,1,maximum:512),!guid.isEmpty,
                      let service=self.text(stmt,6,maximum:40),["iMessage","SMS","RCS"].contains(service) else { throw self.fail("invalid_message","A matching Messages row lacks verifiable provider identity or service. The cursor was not changed.") }
                let rowID=sqlite3_column_int64(stmt,0),association=sqlite3_column_int64(stmt,7)
                let reaction=(2000...3999).contains(association)
                let hasAttachments=sqlite3_column_int64(stmt,8)>0
                var plain:String?,archive:Data?
                if !reaction {
                    try self.query(db,"SELECT CASE WHEN length(CAST(text AS BLOB))<=? THEN text ELSE NULL END,CASE WHEN length(attributedBody)<=? THEN CAST(attributedBody AS BLOB) ELSE NULL END FROM message WHERE ROWID=?",[Int64(Self.maxBodyBytes),Int64(Self.maxBodyBytes),rowID]) { body in
                        plain=self.text(body,0,maximum:Self.maxBodyBytes)
                        let size=Int(sqlite3_column_bytes(body,1))
                        if size>0,size<=Self.maxBodyBytes,let bytes=sqlite3_column_blob(body,1) { archive=Data(bytes:bytes,count:size) }
                    }
                }
                let decoded=Self.decodedBody(text:plain,archive:archive,hasAttachments:hasAttachments,reaction:reaction)
                var message:Record=["providerMessageId":guid,"providerThreadId":chat,"phone":phone,"occurredAt":formatter.string(from:occurred),"body":decoded.body,"bodyKind":decoded.kind,"service":service,"sourceRowID":rowID,"direction":"inbound","isGroup":false]
                if let address=self.callerAddress(self.text(stmt,9,maximum:320)) { message["accountAddress"]=address }
                messages.append(message)
            }
        }
        guard try sourceIdentity()==sourceID else { throw fail("source_changed_during_read","Messages history changed files during the read. Retry without advancing the cursor.") }
        try execute(db,"COMMIT");committed=true
        return ["sourceID":sourceID,"scannedFromRowID":startRow,"nextRowID":next,"hasMore":hasMore,"messages":messages,"scannedCount":rows.count]
    }
}
