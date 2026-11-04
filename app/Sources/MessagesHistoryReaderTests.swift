import Foundation
import SQLite3

// Disposable provider-shaped databases only; never opens ~/Library/Messages.
func runMessagesHistoryReaderTests() throws {
    try runMessagesTypedstreamDecoderTests()
    func check(_ condition:Bool,_ message:String) throws { if !condition { throw StoreError(message:"Messages history reader test: "+message) } }
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-messages-reader-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let path=root.appendingPathComponent("chat.db").path
    var database:OpaquePointer?
    guard sqlite3_open(path,&database)==SQLITE_OK,let db=database else { throw StoreError(message:"Cannot create reader fixture.") }
    defer { sqlite3_close(db) }
    func sql(_ source:String) throws { guard sqlite3_exec(db,source,nil,nil,nil)==SQLITE_OK else { throw StoreError(message:"Reader fixture SQL failed.") } }
    try sql("""
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY,guid TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER,item_type INTEGER DEFAULT 0,text TEXT,attributedBody BLOB,service TEXT,cache_has_attachments INTEGER DEFAULT 0,associated_message_type INTEGER DEFAULT 0,is_system_message INTEGER DEFAULT 0,destination_caller_id TEXT);
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY,id TEXT);
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY,guid TEXT);
    CREATE TABLE chat_message_join (chat_id INTEGER,message_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER,handle_id INTEGER);
    INSERT INTO handle VALUES (1,'+12025550101'),(2,'+12025550102'),(3,'person@example.test');
    INSERT INTO chat VALUES (1,'SMS;-;+12025550101'),(2,'group-fixture'),(3,'SMS;-;+12025550102'),(4,'iMessage;-;person@example.test');
    INSERT INTO chat_handle_join VALUES (1,1),(2,1),(2,2),(3,2),(4,3);
    """)
    let formatter=ISO8601DateFormatter(),since="2026-10-28T12:00:00Z",start=formatter.date(from:since)!
    let recent=Int64((start.addingTimeInterval(60).timeIntervalSince1970-978_307_200)*1_000_000_000)
    let old=Int64((start.addingTimeInterval(-60).timeIntervalSince1970-978_307_200)*1_000_000_000)
    let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    func insert(_ id:Int64,_ body:String?="Reply",_ archive:Data?=nil,_ sender:Int64=1,_ chat:Int64=1,_ outbound:Bool=false,_ date:Int64?=nil,_ attachment:Bool=false,_ reaction:Int64=0,_ system:Bool=false,_ caller:String?=nil) throws {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,"INSERT INTO message (ROWID,guid,date,is_from_me,handle_id,text,attributedBody,service,cache_has_attachments,associated_message_type,is_system_message,destination_caller_id) VALUES (?,?,?,?,?,?,?,'SMS',?,?,?,?)",-1,&statement,nil)==SQLITE_OK,let statement else { throw StoreError(message:"Cannot prepare reader fixture row.") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement,1,id)
        sqlite3_bind_text(statement,2,"guid-\(id)",-1,transient)
        sqlite3_bind_int64(statement,3,date ?? recent)
        sqlite3_bind_int(statement,4,outbound ? 1 : 0)
        sqlite3_bind_int64(statement,5,sender)
        if let body { sqlite3_bind_text(statement,6,body,-1,transient) } else { sqlite3_bind_null(statement,6) }
        if let archive { _=archive.withUnsafeBytes { sqlite3_bind_blob(statement,7,$0.baseAddress,Int32(archive.count),transient) } } else { sqlite3_bind_null(statement,7) }
        sqlite3_bind_int(statement,8,attachment ? 1 : 0)
        sqlite3_bind_int64(statement,9,reaction)
        sqlite3_bind_int(statement,10,system ? 1 : 0)
        if let caller { sqlite3_bind_text(statement,11,caller,-1,transient) } else { sqlite3_bind_null(statement,11) }
        guard sqlite3_step(statement)==SQLITE_DONE else { throw StoreError(message:"Cannot insert reader fixture row.") }
        try sql("INSERT INTO chat_message_join VALUES (\(chat),\(id))")
    }
    try insert(1,"Before enable",nil,1,1,false,old)
    try insert(2,"Exact reply\nwith second line",nil,1,1,false,nil,false,0,false,"+12025550999")
    try insert(3,"OUTGOING_SECRET",nil,1,1,true)
    try insert(4,"GROUP_SECRET",nil,1,2)
    try insert(5,"SENDER_MISMATCH_SECRET",nil,2,1)
    let archived=try NSKeyedArchiver.archivedData(withRootObject:NSAttributedString(string:"Archived reply 🌱"),requiringSecureCoding:true)
    try insert(6,nil,archived,1,1,false,nil,false,0,false,"operator@example.test")
    try sql("UPDATE message SET service='RCS' WHERE ROWID=6")
    try insert(7,nil,Data([4,11])+Data("streamtyped unsupported fixture".utf8))
    try insert(8,nil,nil,1,1,false,nil,true)
    try insert(9,"Do not present reaction storage as reply words",nil,1,1,false,nil,false,2001)
    try insert(10,"SYSTEM_SECRET",nil,1,1,false,nil,false,0,true)
    try insert(11,"EMAIL_IDENTITY_SECRET",nil,3,4)
    try insert(12,"UNMATCHED_SECRET",nil,2,3)
    try insert(13,"AMBIGUOUS_CHAT_SECRET")
    try sql("INSERT INTO chat_message_join VALUES (3,13)")
    try insert(14,"OLD_TRAILING_SECRET",nil,1,1,false,old)
    let reader=MessagesHistoryReader(path:path)
    let beforeBytes=try Data(contentsOf:URL(fileURLWithPath:path))
    let first=try reader.read(phones:["(202) 555-0101"],since:since,afterRowID:0,limit:3)
    try check(first["nextRowID"] as? Int64==4 && first["scannedCount"] as? Int==3 && first["hasMore"] as? Bool==true,"page scans only a bounded window since enable time, including excluded incoming/outgoing rows")
    let sourceID=first["sourceID"] as! String
    var all=first["messages"] as! [Record],cursor=first["nextRowID"] as! Int64,more=true
    while more {
        let page=try reader.read(phones:["+12025550101"],since:since,afterRowID:cursor,limit:3,expectedSourceID:sourceID)
        try check(page["sourceID"] as? String==sourceID && page["scannedFromRowID"] as? Int64==cursor,"source identity stays stable and page begins at supplied cursor")
        all += page["messages"] as! [Record];cursor=page["nextRowID"] as! Int64;more=page["hasMore"] as! Bool
    }
    try check(all.compactMap{$0["providerMessageId"] as? String}==["guid-2","guid-6","guid-7","guid-8","guid-9"],"only new incoming exact one-to-one candidate messages are returned")
    try check(all[0]["body"] as? String=="Exact reply\nwith second line" && all[0]["accountAddress"] as? String=="+12025550999","plain text and actual destination are preserved")
    try check(all[1]["body"] as? String=="Archived reply 🌱" && all[1]["bodyKind"] as? String=="text" && all[1]["accountAddress"] as? String=="operator@example.test","secure attributed text and an actual Apple-ID destination are preserved")
    try check(all[1]["service"] as? String=="RCS","incoming RCS replies are readable without enabling any outgoing RCS transport")
    try check(all[2]["bodyKind"] as? String=="unavailable" && all[2]["accountAddress"]==nil,"unsupported archive remains explicit and missing destination is not invented")
    try check(all[3]["bodyKind"] as? String=="attachment" && all[4]["bodyKind"] as? String=="reaction","attachments and reactions retain honest distinct kinds")
    try check(all.allSatisfy{$0["direction"] as? String=="inbound" && $0["isGroup"] as? Bool==false},"every row includes exact incoming one-to-one proof")
    try check(!(String(data:try JSONSerialization.data(withJSONObject:all),encoding:.utf8) ?? "").contains("SECRET"),"excluded communication bodies never leave the reader")
    try check(try Data(contentsOf:URL(fileURLWithPath:path))==beforeBytes,"reader does not change provider database bytes")
    try check(cursor==14,"final page advances across a trailing old row without importing it")
    let noNew=try reader.read(phones:["+12025550101"],since:"2026-10-29T00:00:00Z",afterRowID:0)
    try check(noNew["nextRowID"] as? Int64==14 && noNew["scannedCount"] as? Int==0 && (noNew["messages"] as? [Record])?.isEmpty==true,"empty new-only window advances to snapshot maximum without fetching historical bodies")
    let empty=try reader.read(phones:[],since:since,afterRowID:999,expectedSourceID:sourceID)
    try check(empty["scannedCount"] as? Int==0 && empty["nextRowID"] as? Int64==999 && (empty["messages"] as? [Record])?.isEmpty==true,"empty candidate set probes schema without reading history or advancing cursor")
    func expect(_ code:String,_ body:()throws->Void) throws {
        do { try body();throw StoreError(message:"Expected reader error "+code) }
        catch let error as MessagesHistoryReadError { try check(error.code==code,"expected "+code+", received "+error.code) }
    }
    try expect("cursor_regression") { _=try reader.read(phones:["+12025550101"],since:since,afterRowID:999,expectedSourceID:sourceID) }
    try expect("invalid_request") { _=try reader.read(phones:["person@example.test"],since:since,afterRowID:0) }
    try expect("invalid_request") { _=try reader.read(phones:["+12025550101"],since:"not a date",afterRowID:0) }
    let replacement=try reader.read(phones:["+12025550101"],since:since,afterRowID:999,limit:3,expectedSourceID:"different-source")
    try check(replacement["scannedFromRowID"] as? Int64==0 && replacement["nextRowID"] as? Int64==4,"changed source identity restarts at zero while retaining the enable-time filter")
    let copyPath=root.appendingPathComponent("replaceable.db").path,heldPath=root.appendingPathComponent("original.db").path
    try FileManager.default.copyItem(atPath:path,toPath:copyPath)
    let replacementReader=MessagesHistoryReader(path:copyPath)
    let oldSource=try replacementReader.read(phones:[],since:since,afterRowID:cursor)["sourceID"] as! String
    try FileManager.default.moveItem(atPath:copyPath,toPath:heldPath)
    try FileManager.default.copyItem(atPath:path,toPath:copyPath)
    let actualReplacement=try replacementReader.read(phones:["+12025550101"],since:since,afterRowID:cursor,limit:3,expectedSourceID:oldSource)
    try check(actualReplacement["sourceID"] as? String != oldSource && actualReplacement["scannedFromRowID"] as? Int64==0,"replacing a database at the same path changes source identity and resets the scan")
    try sql("BEGIN EXCLUSIVE")
    try expect("busy") { _=try reader.read(phones:["+12025550101"],since:since,afterRowID:cursor,expectedSourceID:sourceID) }
    try sql("ROLLBACK")
    let missing=root.appendingPathComponent("missing.db").path
    try expect("access_unavailable") { _=try MessagesHistoryReader(path:missing).read(phones:[],since:since,afterRowID:0) }
    try check(!FileManager.default.fileExists(atPath:missing),"read-only open never creates a missing provider database")
    let permissionPath=root.appendingPathComponent("unreadable.db").path
    try FileManager.default.copyItem(atPath:path,toPath:permissionPath)
    try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:permissionPath)
    if !FileManager.default.isReadableFile(atPath:permissionPath) {
        try expect("access_unavailable") { _=try MessagesHistoryReader(path:permissionPath).read(phones:[],since:since,afterRowID:0) }
    }
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:permissionPath)
    try sql("ALTER TABLE message RENAME COLUMN handle_id TO unsupported_sender")
    try expect("schema_unsupported") { _=try reader.read(phones:["+12025550101"],since:since,afterRowID:cursor,expectedSourceID:sourceID) }
    try sql("ALTER TABLE message RENAME COLUMN unsupported_sender TO handle_id")
    try insert(15,"New valid message after failed read")
    let resumed=try reader.read(phones:["+12025550101"],since:since,afterRowID:cursor,expectedSourceID:sourceID)
    try check((resumed["messages"] as? [Record])?.first?["providerMessageId"] as? String=="guid-15","failed reads do not mutate or consume the supplied cursor")
    try sql("INSERT INTO chat VALUES (5,'SMS;+;former-group');INSERT INTO chat_handle_join VALUES (5,1)")
    try insert(16,"SINGLE_MEMBER_GROUP_SECRET",nil,1,5)
    let formerGroup=try reader.read(phones:["+12025550101"],since:since,afterRowID:15,expectedSourceID:sourceID)
    try check((formerGroup["messages"] as? [Record])?.isEmpty==true && formerGroup["nextRowID"] as? Int64==16,"a group with only one remaining member is still excluded by thread identity")
    try sql("ALTER TABLE chat ADD COLUMN style INTEGER DEFAULT 45;UPDATE chat SET style=43 WHERE ROWID=1")
    try insert(17,"GROUP_STYLE_SECRET")
    let groupStyle=try reader.read(phones:["+12025550101"],since:since,afterRowID:16,expectedSourceID:sourceID)
    try check((groupStyle["messages"] as? [Record])?.isEmpty==true,"an available group style blocks a row even if its thread ID resembles a direct chat")
    try sql("UPDATE chat SET style=45 WHERE ROWID=1")
    let typed=NSArchiver.archivedData(withRootObject:NSAttributedString(string:"Typedstream reply body"))
    try insert(18,nil,typed)
    let typedPage=try reader.read(phones:["+12025550101"],since:since,afterRowID:17,expectedSourceID:sourceID)
    let typedMessage=(typedPage["messages"] as? [Record])?.first
    try check(typedMessage?["body"] as? String=="Typedstream reply body" && typedMessage?["bodyKind"] as? String=="text","text-null provider rows decode their structurally validated typedstream body")
    let unknownArchive=try NSKeyedArchiver.archivedData(withRootObject:URL(string:"https://example.test/")!,requiringSecureCoding:true)
    try check(MessagesHistoryReader.decodedBody(text:nil,archive:unknownArchive,hasAttachments:false,reaction:false).kind=="unavailable","an unexpected secure archive root is not accepted as message text")
    try check(MessagesHistoryReader.decodedBody(text:String(repeating:"x",count:262_145),archive:nil,hasAttachments:false,reaction:false).kind=="unavailable","oversized body is not silently truncated into an apparent full reply")
    try check(MessagesHistoryReader.decodedBody(text:String(repeating:"x",count:50_001),archive:nil,hasAttachments:false,reaction:false).kind=="unavailable","body respects the Store character cap without poisoning an import page")
    let decodedTyped=MessagesHistoryReader.decodedBody(text:nil,archive:typed,hasAttachments:false,reaction:false)
    try check(decodedTyped.body=="Typedstream reply body" && decodedTyped.kind=="text","reader uses structural typedstream decoding when text is null")
    print("PASS: read-only Messages history identity, pagination, attribution, safe bodies, schema/access and cursor fixtures; no live Messages history accessed.")
}
