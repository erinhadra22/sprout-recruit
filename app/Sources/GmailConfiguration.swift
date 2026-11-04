import Foundation

extension Store {
    func gmailClientConfiguration() throws -> Record {
        try all("settings").first { $0["id"] as? String == "gmail-client-configuration" } ?? ["id":"gmail-client-configuration","clientId":""]
    }
    func saveGmailClientConfiguration(_ payload: Record) throws {
        guard Set(payload.keys) == ["clientId"], let raw = payload["clientId"] as? String else { throw StoreError(message:"Supply the public Google Desktop client ID.") }
        let client = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard client.count <= 250, client.range(of:"^[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$",options:.regularExpression) != nil else { throw StoreError(message:"Enter a Google Desktop OAuth client ID ending in .apps.googleusercontent.com.") }
        guard try gmailSyncStatus()["connected"] as? Bool != true else { throw StoreError(message:"Disconnect Gmail before changing its app configuration.") }
        try put("settings",["id":"gmail-client-configuration","clientId":client,"updatedAt":Store.now()])
    }
}
