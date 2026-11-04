import Foundation

// Local, bounded startup stages only. No message bodies, tokens or record data.
enum StartupDiagnostics {
    static func record(databasePath:String,event:String,details:[String:String]=[:],reset:Bool=false) {
        let url=URL(fileURLWithPath:databasePath).deletingLastPathComponent().appendingPathComponent("SproutStartupDiagnostics.json")
        var entries:[[String:String]]=[]
        if !reset,let bytes=try? Data(contentsOf:url),bytes.count<100000,
           let saved=try? JSONSerialization.jsonObject(with:bytes) as? [[String:String]] { entries=Array(saved.suffix(63)) }
        var entry=details;entry["event"]=event;entry["at"]=ISO8601DateFormatter().string(from:Date());entries.append(entry)
        if let bytes=try? JSONSerialization.data(withJSONObject:entries,options:[.prettyPrinted,.sortedKeys]) {
            try? bytes.write(to:url,options:.atomic)
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
    }
}
