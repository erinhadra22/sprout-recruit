import Cocoa
import Security
import CryptoKit

struct TelnyxCredentials: Codable {
    let key: String
    let sender: String
}

final class CommunicationsController: NSObject, NSSharingServiceDelegate {
    let store: Store
    weak var window: NSWindow?
    private let transport = TelnyxTransport()
    private var sharing: [ObjectIdentifier:(NSSharingService,String)] = [:]
    private var inFlight = Set<String>()
    private let keychainAccount: String
    init(store: Store) {
        self.store = store
        self.keychainAccount = SHA256.hash(data:Data(store.path.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private var keyQuery: [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.sprout.recruit.local.telnyx",kSecAttrAccount as String:keychainAccount]
    }
    private func credentials() throws -> TelnyxCredentials? {
        var q = keyQuery; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary,&result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw StoreError(message:"Sprout could not read its Telnyx key from this Mac’s Keychain.") }
        return try JSONDecoder().decode(TelnyxCredentials.self,from:data)
    }
    private func save(_ credentials: TelnyxCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attrs: [String:Any] = [kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var code = SecItemUpdate(keyQuery as CFDictionary,attrs as CFDictionary)
        if code == errSecItemNotFound { var q = keyQuery; q.merge(attrs) { _,new in new }; code = SecItemAdd(q as CFDictionary,nil) }
        guard code == errSecSuccess else { throw StoreError(message:"Sprout could not save the Telnyx settings in Keychain.") }
    }
    func status() throws -> Record {
        let c = try credentials()
        return ["telnyxConfigured":c != nil,"sender":c?.sender ?? "","recordingReady":false,"iphoneBuildReady":false]
    }
    private func result(_ status: String,_ message: String) throws -> Record {
        ["snapshot":try store.snapshot(),"status":status,"message":message]
    }
    private func configure() throws -> Record {
        let old = try credentials()
        let alert = NSAlert(); alert.messageText = "Connect Telnyx for test texts"
        alert.informativeText = "Enter an API key and a messaging-enabled number from your Telnyx account. These stay in this Mac’s Keychain. This does not buy or transfer a number. Carrier fees and Telnyx messaging approval may apply."
        let view = NSView(frame:NSRect(x:0,y:0,width:420,height:132))
        let keyLabel = NSTextField(labelWithString:"Telnyx API key"); keyLabel.frame = NSRect(x:0,y:112,width:420,height:20)
        let key = NSSecureTextField(frame:NSRect(x:0,y:80,width:420,height:26)); key.placeholderString = old == nil ? "Paste key here" : "Leave blank to keep saved key"
        let senderLabel = NSTextField(labelWithString:"Telnyx sending number (with country code)"); senderLabel.frame = NSRect(x:0,y:49,width:420,height:20)
        let sender = NSTextField(frame:NSRect(x:0,y:16,width:420,height:26)); sender.placeholderString = "+1…"; sender.stringValue = old?.sender ?? ""
        for v in [keyLabel,key,senderLabel,sender] { view.addSubview(v) }
        alert.accessoryView = view; alert.addButton(withTitle:"Save settings"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return try result("cancelled","Settings unchanged.") }
        let token = key.stringValue.isEmpty ? (old?.key ?? "") : key.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard token.count >= 12, token.count <= 4096, !token.contains("\n"), !token.contains("\r") else { throw StoreError(message:"Enter a valid Telnyx API key.") }
        let phone = try Store.normalizedCommunicationPhone(sender.stringValue)
        try save(TelnyxCredentials(key:token,sender:phone))
        key.stringValue = ""
        return try result("configured","Settings saved in Keychain. The live connection still needs a test.")
    }
    private func prepare(_ payload: Record, channel: String, transport: String, sender: String? = nil) throws -> Record {
        var p = payload; p["channel"] = channel; p["transport"] = transport
        if let sender = sender { p["sender"] = sender }
        _ = try store.command("communication.prepare",p)
        return try store.get("communications",p["id"] as? String ?? "")
    }
    private func update(_ id: String,_ state: String, values: Record = [:]) throws {
        var p = values; p["id"] = id; p["state"] = state
        _ = try store.command("communication.update",p)
    }
    private func receiptEvidence(_ receipt: TelnyxReceipt,_ record: Record) throws -> Record {
        var evidence: Record = ["providerId":receipt.id]
        if receipt.state == "delivered" {
            guard let date = receipt.sentAt else { throw StoreError(message:"The provider receipt has no send timestamp. Reconcile its actual send time before logging this interaction.") }
            evidence["occurredAt"] = ISO8601DateFormatter().string(from:date)
        }
        return evidence
    }
    func handle(_ action: String,_ p: Record, reply: @escaping (Any?,String?) -> Void) {
        do {
            switch action {
            case "communications.status": reply(try status(),nil)
            case "communications.configure": reply(try configure(),nil)
            case "communications.disconnect":
                guard inFlight.isEmpty else { throw StoreError(message:"Wait for the current message check before disconnecting.") }
                let code = SecItemDelete(keyQuery as CFDictionary)
                guard code == errSecSuccess || code == errSecItemNotFound else { throw StoreError(message:"Could not remove the local Telnyx key.") }
                reply(try result("disconnected","Telnyx settings removed from this Mac. Your provider account is unchanged."),nil)
            case "communications.appleMessage":
                let record = try prepare(p,channel:"message",transport:"apple-messages")
                guard let id = record["id"] as? String, record["state"] as? String == "prepared" else {
                    reply(try result("existing","This attempt is already in the history. Review it before opening another message."),nil); return
                }
                let body = record["body"] as? String ?? "", phone = record["phone"] as? String ?? ""
                guard let service = NSSharingService(named:.composeMessage), service.canPerform(withItems:[body]) else {
                    try update(id,"handoff_cancelled")
                    reply(try result("unavailable","Messages sharing is unavailable on this Mac. No message was sent."),nil); return
                }
                // Reserve before handing off; a crash must never cause an automatic retry.
                try update(id,"handoff_opened")
                service.recipients = [phone]; service.delegate = self
                sharing[ObjectIdentifier(service)] = (service,id)
                service.perform(withItems:[body])
                reply(try result("handoff_opened","Review and send in Messages. Sprout has not confirmed a send."),nil)
            case "communications.phone":
                let record = try prepare(p,channel:"call",transport:"system-phone")
                guard let id = record["id"] as? String, record["state"] as? String == "prepared" else {
                    reply(try result("existing","This call attempt is already in the history."),nil); return
                }
                let phone = record["phone"] as? String ?? ""
                guard let url = URL(string:"tel:"+phone), NSWorkspace.shared.urlForApplication(toOpen:url) != nil else {
                    try update(id,"handoff_cancelled"); throw StoreError(message:"No Phone app is available on this Mac.")
                }
                try update(id,"handoff_opened")
                if !NSWorkspace.shared.open(url) { try update(id,"cancelled"); throw StoreError(message:"The Phone app did not open. No completed call was logged.") }
                reply(try result("handoff_opened","Continue in Phone. This route does not record the call in Sprout."),nil)
            case "communications.confirm":
                guard let state = p["state"] as? String, ["user_confirmed_sent","user_confirmed_call","cancelled"].contains(state) else { throw StoreError(message:"Choose a confirmation from the communications history.") }
                guard p["confirmed"] as? Bool == true else { throw StoreError(message:"Review the exact communication and confirm its outcome.") }
                var confirmation = p
                if state == "cancelled" { confirmation = ["id":p["id"] as? String ?? "","state":state] }
                if state == "user_confirmed_call" { confirmation.removeValue(forKey:"body") }
                _ = try store.command("communication.update",confirmation)
                reply(try result(state,state == "cancelled" ? "Attempt marked cancelled." : "Your confirmation was saved. It is separate from a provider delivery receipt."),nil)
            case "communications.telnyxMessage": try sendTelnyx(p,reply:reply)
            case "communications.refresh": try refresh(p,reply:reply)
            default: throw StoreError(message:"Unknown communications action.")
            }
        } catch { reply(nil,error.localizedDescription) }
    }
    private func sendTelnyx(_ p: Record, reply: @escaping (Any?,String?) -> Void) throws {
        guard let c = try credentials() else { throw StoreError(message:"Add your Telnyx key and sending number first.") }
        let record = try prepare(p,channel:"message",transport:"telnyx",sender:c.sender)
        guard let id = record["id"] as? String, record["state"] as? String == "prepared", !inFlight.contains(id) else {
            reply(try result("existing","This attempt already started. Check its status; Sprout will not send it again."),nil); return
        }
        let phone = record["phone"] as? String ?? "", body = record["body"] as? String ?? ""
        let request = try TelnyxMessageAPI.sendRequest(key:c.key,sender:c.sender,phone:phone,body:body)
        try update(id,"submitting"); inFlight.insert(id)
        transport.run(request) { [weak self] data,response,error in
            guard let self = self else { reply(nil,"Sprout closed before the result was recorded. Check Telnyx before resending."); return }
            defer { self.inFlight.remove(id) }
            do {
                guard error == nil, let response = response else {
                    try self.update(id,"unknown"); reply(try self.result("unknown","The connection ended without a reliable receipt. Check Telnyx before sending again."),nil); return
                }
                guard (200..<300).contains(response.statusCode), let data = data else {
                    let rejected = (400..<500).contains(response.statusCode) && response.statusCode != 408 && response.statusCode != 409
                    try self.update(id,rejected ? "failed" : "unknown")
                    reply(try self.result(rejected ? "failed" : "unknown","Telnyx returned HTTP \(response.statusCode). Check the account’s message log and messaging setup before retrying."),nil); return
                }
                do {
                    let receipt = try TelnyxMessageAPI.receipt(data,sender:c.sender,phone:phone,body:body)
                    try self.update(id,"accepted",values:["providerId":receipt.id])
                    if receipt.state != "accepted" { try self.update(id,receipt.state,values:self.receiptEvidence(receipt,record)) }
                    reply(try self.result(receipt.state,receipt.state == "delivered" ? "Telnyx reports this text delivered." : receipt.state == "failed" ? "Telnyx reports this text failed." : "Telnyx accepted the text. Check delivery status in the history."),nil)
                } catch {
                    // A malformed or mismatched response can still follow a successful POST.
                    // Preserve a receipt ID for safe read-only reconciliation when possible.
                    var evidence: Record = [:]
                    if let root = try? JSONSerialization.jsonObject(with:data) as? Record, let item = root["data"] as? Record, let providerID = item["id"] as? String, UUID(uuidString:providerID) != nil { evidence["providerId"] = providerID }
                    try self.update(id,"unknown",values:evidence)
                    reply(try self.result("unknown","The send result needs reconciliation. Check its status or Telnyx before trying another send."),nil)
                }
            } catch { reply(nil,"The message may have been sent, but Sprout could not save its result. Check Telnyx before sending again.") }
        }
    }
    private func refresh(_ p: Record, reply: @escaping (Any?,String?) -> Void) throws {
        let id = p["id"] as? String ?? "", record = try store.get("communications",id)
        guard record["transport"] as? String == "telnyx", let providerID = record["providerId"] as? String else { throw StoreError(message:"No Telnyx receipt ID is available. Check the provider’s message log before sending again.") }
        guard !inFlight.contains(id) else { throw StoreError(message:"A status check is already running.") }
        guard let c = try credentials() else { throw StoreError(message:"Reconnect the same Telnyx account to check this message.") }
        guard let sender = record["sender"] as? String, sender == c.sender else { throw StoreError(message:"Reconnect the original sending number to check this message.") }
        let phone = record["phone"] as? String ?? "", body = record["body"] as? String ?? ""
        let request = try TelnyxMessageAPI.receiptRequest(key:c.key,id:providerID)
        inFlight.insert(id)
        transport.run(request) { [weak self] data,response,error in
            guard let self = self else { reply(nil,"The app closed during the status check."); return }
            defer { self.inFlight.remove(id) }
            do {
                guard error == nil, response?.statusCode == 200, let data = data else { throw StoreError(message:"The status check failed. The saved outcome is unchanged. Telnyx message retrieval is available for 10 days.") }
                let receipt = try TelnyxMessageAPI.receipt(data,sender:sender,phone:phone,body:body,expectedID:providerID)
                let current = try self.store.get("communications",id)["state"] as? String ?? ""
                if ["delivered","failed"].contains(current), receipt.state != current { throw StoreError(message:"The provider returned a different outcome than the final receipt saved here. Check Telnyx; Sprout has preserved the recorded outcome.") }
                if !["delivered","failed"].contains(current) { try self.update(id,receipt.state,values:self.receiptEvidence(receipt,record)) }
                reply(try self.result(receipt.state,"Telnyx status: "+receipt.providerStatus.replacingOccurrences(of:"_",with:" ")+"."),nil)
            } catch { reply(nil,error.localizedDescription) }
        }
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        // AppKit sharing completion does not prove an unchanged recipient/body or carrier delivery.
        sharing.removeValue(forKey:ObjectIdentifier(sharingService))
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        // A generic sharing error can follow an ambiguous handoff. Preserve the pending
        // attempt until the user checks Messages and confirms the actual outcome.
        sharing.removeValue(forKey:ObjectIdentifier(sharingService))
    }
    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? { window }
}
