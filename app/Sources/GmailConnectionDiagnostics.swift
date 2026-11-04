import Foundation

// Bounded local connection stages, never OAuth URLs, codes, tokens or provider bodies.
enum GmailConnectionDiagnostics {
    private static let stages:Set<String>=["configuration.saved","authorization.started","authorization.received","token.requested","token.received","profile.requested","profile.verified","credentials.saved","workspace.save.started","connection.failed","connection.completed","connection.disconnected"]
    private static let codes:Set<String>=["authorization_busy","authorization_canceled","authorization_timed_out","authorization_declined","callback_unavailable","browser_unavailable","invalid_callback","state_mismatch","network_unavailable","invalid_response","request_rejected","authorization_required","access_denied","not_found","rate_limited","provider_unavailable","response_too_large","invalid_token_response","scope_mismatch","keychain_unavailable","invalid_configuration","missing_client_configuration","oauth_client_secret_required","authorization_expired","oauth_client_rejected"]
    private static func url(_ databasePath:String)->URL { URL(fileURLWithPath:databasePath).deletingLastPathComponent().appendingPathComponent("GmailConnectionDiagnostics.json") }
    static func record(databasePath:String,stage:String,code:String?) {
        guard stages.contains(stage) else { return }
        var value:[String:String]=["stage":stage,"at":ISO8601DateFormatter().string(from:Date())]
        if let code { value["code"]=(codes.contains(code) || code=="workspace_save_failed") ? code : "connection_failed" }
        let destination=url(databasePath)
        if let bytes=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]) {
            try? bytes.write(to:destination,options:.atomic)
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
        }
    }
    static func status(databasePath:String)->Record {
        guard let bytes=try? Data(contentsOf:url(databasePath)),bytes.count<=4096,
              let value=try? JSONSerialization.jsonObject(with:bytes) as? [String:String],
              let stage=value["stage"],stages.contains(stage) else { return [:] }
        var result:Record=["connectionPhase":stage]
        if stage=="connection.failed" {
            result["lastError"]="The Gmail connection could not finish. " + message(value["code"] ?? "")
        }
        return result
    }
    private static func message(_ code:String)->String {
        switch code {
        case "keychain_unavailable":return "Sprout could not save authorization in this Mac’s Keychain."
        case "network_unavailable":return "Google could not be reached during connection."
        case "request_rejected":return "Google rejected the authorization exchange."
        case "authorization_timed_out":return "The sign-in attempt timed out."
        case "authorization_declined","authorization_canceled":return "Sign-in was canceled or declined."
        case "scope_mismatch":return "The returned permission did not match read-only Gmail."
        case "invalid_token_response":return "Google did not return renewable authorization."
        case "oauth_client_secret_required":return "Google requires the Desktop client’s configuration secret. Check the app configuration before reconnecting."
        case "authorization_expired":return "Google rejected the sign-in code. A fresh sign-in is required after checking app configuration."
        case "oauth_client_rejected":return "Google rejected the Desktop client configuration."
        case "workspace_save_failed":return "Authorization was received, but Sprout could not save the connection in this workspace."
        default:return "The connection remains disconnected; no history sync has started."
        }
    }
}
