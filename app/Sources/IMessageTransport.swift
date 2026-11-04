import Cocoa

// AppleScript runs on the helper process's main thread. Message text crosses stdin
// as JSON and Apple event descriptors; it is never executable source or argv.
enum IMessageWorker {
    static let systemMessagesPath = "/System/Applications/Messages.app"
    static let diagnosticPhases: Set<String> = ["enumerate_accounts", "account_id", "service_type", "account_enabled", "account_selection", "selected_account_id", "connection_status"]
    static let dispatchPreflightPhases:Set<String> = ["account_lookup","account_identity","account_service","account_enabled","account_connection","recipient_lookup","recipient_handle","recipient_account"]
    static let source = """
    on inspectaccount(expectedID, expectedService)
        set diagnosticPhase to "enumerate_accounts"
        try
            with timeout of 20 seconds
                tell application "\(systemMessagesPath)"
                    set desiredType to iMessage
                    if expectedService is "SMS" then set desiredType to SMS
                    set accountList to every account
                    set usableAccounts to {}
                    repeat with candidateReference in accountList
                        set candidateAccount to contents of candidateReference
                        set diagnosticPhase to "account_id"
                        set candidateID to id of candidateAccount as text
                        if expectedID is "" or candidateID is expectedID then
                            set diagnosticPhase to "service_type"
                            set candidateType to missing value
                            try
                                set candidateType to service type of candidateAccount
                            on error ignoredMessage number originalNumber
                                -- Discovery cannot qualify an unreadable account.
                                -- A saved, explicitly selected identity must fail closed.
                                if expectedID is not "" then error ignoredMessage number originalNumber
                            end try
                            if candidateType is desiredType then
                                set diagnosticPhase to "account_enabled"
                                if enabled of candidateAccount is true then set end of usableAccounts to candidateAccount
                            end if
                        end if
                    end repeat
                    set diagnosticPhase to "account_selection"
                    if (count usableAccounts) is not 1 then error "One matching enabled account is required." number -1700
                    set chosenAccount to item 1 of usableAccounts
                    set diagnosticPhase to "selected_account_id"
                    set selectedID to id of chosenAccount as text
                    if selectedID is "" then error "The selected account has no identifier." number -1700
                    if expectedID is not "" and selectedID is not expectedID then error "The selected account changed." number -1700
                    set diagnosticPhase to "connection_status"
                    if connection status of chosenAccount is not connected then error "Messages is not connected." number -1700
                    set accountLabel to "Messages default sending identity"
                    try
                        set candidateLabel to description of chosenAccount as text
                        if candidateLabel is not "" then set accountLabel to candidateLabel
                    end try
                    return {selectedID, accountLabel, expectedService}
                end tell
            end timeout
        on error ignoredMessage number originalNumber
            error "SPROUT_PHASE:" & diagnosticPhase number originalNumber
        end try
    end inspectaccount
    on diagnoseaccounts()
        -- Diagnostic reads never select an account or change connection eligibility.
        -- Five accounts, four getters each and a count: at most 21 one-second events.
        -- This stays within the helper watchdog after the primary 20-second check.
        set diagnosticRows to {}
        with timeout of 1 second
            tell application "\(systemMessagesPath)"
                try
                    set accountCount to count accounts
                on error ignoredMessage number originalNumber
                    return {"error:" & originalNumber, -1, diagnosticRows}
                end try
                set probeCount to accountCount
                if probeCount > 5 then set probeCount to 5
                repeat with accountIndex from 1 to probeCount
                    set candidateAccount to account accountIndex
                    set idStatus to "not_probed"
                    set typeStatus to "not_probed"
                    set enabledStatus to "not_probed"
                    set connectionStatus to "not_probed"
                    try
                        set privateID to id of candidateAccount as text
                        if privateID is "" then
                            set idStatus to "empty"
                        else
                            set idStatus to "ok"
                        end if
                    on error ignoredMessage number originalNumber
                        set idStatus to "error:" & originalNumber
                    end try
                    try
                        set observedType to service type of candidateAccount
                        set typeStatus to "other"
                        if observedType is iMessage then set typeStatus to "iMessage"
                        if observedType is SMS then set typeStatus to "SMS"
                        if observedType is RCS then set typeStatus to "RCS"
                    on error ignoredMessage number originalNumber
                        set typeStatus to "error:" & originalNumber
                    end try
                    try
                        set observedEnabled to enabled of candidateAccount
                        set enabledStatus to "other"
                        if observedEnabled is true then set enabledStatus to "true"
                        if observedEnabled is false then set enabledStatus to "false"
                    on error ignoredMessage number originalNumber
                        set enabledStatus to "error:" & originalNumber
                    end try
                    try
                        set observedConnection to connection status of candidateAccount
                        set connectionStatus to "other"
                        if observedConnection is connected then set connectionStatus to "connected"
                        if observedConnection is connecting then set connectionStatus to "connecting"
                        if observedConnection is disconnected then set connectionStatus to "disconnected"
                        if observedConnection is disconnecting then set connectionStatus to "disconnecting"
                    on error ignoredMessage number originalNumber
                        set connectionStatus to "error:" & originalNumber
                    end try
                    set end of diagnosticRows to {accountIndex as integer, idStatus, typeStatus, enabledStatus, connectionStatus}
                end repeat
                return {"ok", accountCount, diagnosticRows}
            end tell
        end timeout
    end diagnoseaccounts
    on dispatchmessage(accountID, expectedService, destination, messageBody)
        set dispatchStarted to false
        set dispatchPhase to "account_lookup"
        try
            with timeout of 20 seconds
                tell application "\(systemMessagesPath)"
                    set desiredType to iMessage
                    if expectedService is "SMS" then set desiredType to SMS
                    set chosenAccount to account id accountID
                    set dispatchPhase to "account_identity"
                    if (id of chosenAccount as text) is not accountID then error "The selected account changed." number -1700
                    set dispatchPhase to "account_service"
                    if service type of chosenAccount is not desiredType then error "The selected service changed." number -1700
                    set dispatchPhase to "account_enabled"
                    if enabled of chosenAccount is not true then error "The selected account is unavailable." number -1700
                    set dispatchPhase to "account_connection"
                    if connection status of chosenAccount is not connected then error "Messages is not connected." number -1700
                    set dispatchPhase to "recipient_lookup"
                    set recipientHandle to participant destination of chosenAccount
                    set dispatchPhase to "recipient_handle"
                    if (handle of recipientHandle as text) is not destination then error "The recipient changed." number -1700
                    set dispatchPhase to "recipient_account"
                    if (id of account of recipientHandle as text) is not accountID then error "The recipient account changed." number -1700
                    set dispatchStarted to true
                    send messageBody to recipientHandle
                end tell
            end timeout
            return {"submitted", "started", "dispatch_send", 0}
        on error ignoredMessage number originalNumber
            if dispatchStarted then return {"unknown", "started", "dispatch_send", originalNumber}
            return {"failed", "not_started", dispatchPhase, originalNumber}
        end try
    end dispatchmessage
    """

    static func event(_ name: String, _ args: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass:0x61736372, eventID:0x70736272,
            targetDescriptor:nil, returnID:-1, transactionID:0)
        event.setParam(NSAppleEventDescriptor(string:name), forKeyword:0x736e616d)
        let list = NSAppleEventDescriptor.list()
        for (index,value) in args.enumerated() { list.insert(NSAppleEventDescriptor(string:value), at:index+1) }
        event.setParam(list,forKeyword:0x2d2d2d2d)
        return event
    }
    // Only fixed phase names and the numeric error code can leave the helper.
    // Raw AppleScript errors can include account identifiers or message text.
    static func diagnosticMessage(_ error:NSDictionary) -> String {
        let code=(error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        let number=code.map(String.init) ?? "unknown"
        let raw=error[NSAppleScript.errorMessage] as? String ?? ""
        let phase=diagnosticPhases.sorted().first { raw.contains("SPROUT_PHASE:"+$0) }
        if let phase { return "Messages connection check failed at \(phase) (error \(number)). Check the signed-in account and Automation permission." }
        return "Messages returned error \(number). Check Automation permission and the signed-in iMessage account."
    }
    static func invoke(_ script:NSAppleScript,_ name:String,_ args:[String]) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let value=script.executeAppleEvent(event(name,args),error:&error)
        if let error=error { throw StoreError(message:diagnosticMessage(error)) }
        return value
    }
    // Allowlist the complete diagnostic payload even though the producer is fixed.
    // Account identifiers, descriptions and raw error messages never leave it.
    static func accountDiagnostics(_ value:NSAppleEventDescriptor) -> Record {
        func status(_ descriptor:NSAppleEventDescriptor?, allowed:Set<String>) -> String {
            guard let text=descriptor?.stringValue else { return "malformed" }
            if allowed.contains(text) { return text }
            if text.range(of:"^error:-?[0-9]{1,10}$",options:.regularExpression) != nil { return text }
            return "malformed"
        }
        let enumeration=status(value.atIndex(1),allowed:["ok"])
        let countText=value.atIndex(2)?.stringValue ?? ""
        let count=Int(countText).flatMap { $0 >= 0 && $0 <= 100_000 ? $0 : nil }
        let list=value.atIndex(3)
        var rows:[Record]=[]
        for index in 1...min(10,max(1,list?.numberOfItems ?? 0)) {
            guard let row=list?.atIndex(index) else { continue }
            rows.append(["index":index,
                "id":status(row.atIndex(2),allowed:["ok","empty","not_probed"]),
                "serviceType":status(row.atIndex(3),allowed:["iMessage","SMS","RCS","other","not_probed"]),
                "enabled":status(row.atIndex(4),allowed:["true","false","other","not_probed"]),
                "connection":status(row.atIndex(5),allowed:["connected","connecting","disconnected","disconnecting","other","not_probed"])])
        }
        var result:Record=["enumeration":enumeration,"accounts":rows]
        if let count { result["accountCount"]=count;result["truncated"]=count>rows.count }
        return result
    }
    static func accountDiagnosticSummary(_ diagnostics:Record) -> String {
        let enumeration=diagnostics["enumeration"] as? String ?? "malformed"
        let count=(diagnostics["accountCount"] as? Int).map(String.init) ?? "unknown"
        let rows=(diagnostics["accounts"] as? [Record] ?? []).map { row in
            "#\(row["index"] as? Int ?? 0) id=\(row["id"] as? String ?? "malformed"), type=\(row["serviceType"] as? String ?? "malformed"), enabled=\(row["enabled"] as? String ?? "malformed"), connection=\(row["connection"] as? String ?? "malformed")"
        }
        return "Account diagnostics (read-only): enumeration=\(enumeration), count=\(count)" + (rows.isEmpty ? "." : "; " + rows.joined(separator:"; ") + ".")
    }
    static func dispatchOutcome(_ value:NSAppleEventDescriptor) -> Record {
        let state=value.atIndex(1)?.stringValue, started=value.atIndex(2)?.stringValue, phase=value.atIndex(3)?.stringValue
        if state == "submitted", started == "started", phase == "dispatch_send" {
            return ["state":"submitted","dispatchStarted":true]
        }
        if state == "failed", started == "not_started", let phase, dispatchPreflightPhases.contains(phase) {
            return ["state":"failed","dispatchStarted":false,"errorCode":"messages_"+phase+"_failed"]
        }
        return ["state":"unknown","dispatchStarted":true,"errorCode":"messages_outcome_unknown"]
    }
    static func run(_ input:Record) -> Record {
        guard let mode=input["mode"] as? String,["check","send"].contains(mode),
              input["service"] == nil || input["service"] is String,
              let script=NSAppleScript(source:source) else { return ["state":"failed","dispatchStarted":false,"errorCode":"invalid_request"] }
        let service=input["service"] as? String ?? "iMessage"
        guard ["iMessage","SMS"].contains(service) else { return ["state":"failed","dispatchStarted":false,"errorCode":"invalid_service"] }
        let expected=input["accountId"] as? String ?? ""
        if mode == "check" {
            do {
                let account=try invoke(script,"inspectaccount",[expected,service])
                guard let id=account.atIndex(1)?.stringValue,!id.isEmpty,account.atIndex(3)?.stringValue == service else { throw StoreError(message:"No matching Messages account was found.") }
                return ["state":"ready","accountId":id,"accountLabel":account.atIndex(2)?.stringValue ?? "Messages default sending identity","service":service,"checkedAt":Store.now()]
            } catch {
                var result:Record=["state":"failed","dispatchStarted":false,"errorCode":"connection_unavailable","message":error.localizedDescription]
                if let value=try? invoke(script,"diagnoseaccounts",[]) {
                    let diagnostics=accountDiagnostics(value)
                    result["accountDiagnostics"]=diagnostics
                    result["message"]=error.localizedDescription+" "+accountDiagnosticSummary(diagnostics)
                }
                return result
            }
        }
        let id=expected
        guard !id.isEmpty,let phone=input["phone"] as? String,let body=input["body"] as? String,
              phone.range(of:"^\\+[1-9][0-9]{7,14}$",options:.regularExpression) != nil,
              !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,body.count<=1600 else {
            return ["state":"failed","dispatchStarted":false,"errorCode":"invalid_destination"]
        }
        do {
            return dispatchOutcome(try invoke(script,"dispatchmessage",[id,service,phone,body]))
        } catch { return ["state":"unknown","dispatchStarted":true,"errorCode":"messages_outcome_unknown","message":error.localizedDescription] }
    }
}

protocol IMessageTransporting {
    func perform(_ input:Record, completion:@escaping (Record)->Void)
}
final class IMessageTransport: IMessageTransporting {
    private let queue=DispatchQueue(label:"com.sprout.imessage.transport",qos:.utility)
    func perform(_ input:Record,completion:@escaping (Record)->Void) {
        queue.async {
            let process=Process(),stdin=Pipe(),stdout=Pipe(),stderr=Pipe()
            process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
            process.arguments=["--imessage-worker"]
            process.standardInput=stdin;process.standardOutput=stdout;process.standardError=stderr
            var result:Record=["state":"unknown","errorCode":"helper_interrupted"]
            do {
                let encoded=try JSONSerialization.data(withJSONObject:input)
                try process.run()
                let timeout=DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+50,execute:timeout)
                stdin.fileHandleForWriting.write(encoded);try? stdin.fileHandleForWriting.close()
                process.waitUntilExit();timeout.cancel()
                let output=stdout.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus==0,output.count<65536,
                   let parsed=try? JSONSerialization.jsonObject(with:output) as? Record { result=parsed }
            } catch { result=["state":"failed","dispatchStarted":false,"errorCode":"helper_unavailable"] }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// The Store is shared with CSV/recovery work. All coordinator access is on the
// main thread and waits until that work has released its exclusive busy flag.
final class OutboxCoordinator {
    let store:Store
    let transport:IMessageTransporting
    var storeAvailable:()->Bool = { true }
    var onChange:()->Void = {}
    var beforeDispatch: ((@escaping (Bool)->Void)->Void)?
    private(set) var inFlight=false
    private var checking=false
    private var timer:Timer?
    private var pendingFinish:Record?
    private var pendingPreflight:(Record,Record)?
    private var pendingConnection:(Record,String,(Any?,String?)->Void)?
    init(store:Store,transport:IMessageTransporting=IMessageTransport()) { self.store=store;self.transport=transport }
    static func transportOutcome(_ result:Record) -> Record {
        let state=result["state"] as? String ?? ""
        if state == "submitted",result["dispatchStarted"] as? Bool == true { return ["state":"submitted","dispatchStarted":true] }
        if state == "failed",result["dispatchStarted"] as? Bool == false { return ["state":"failed","dispatchStarted":false,"errorCode":result["errorCode"] as? String ?? "not_dispatched"] }
        return ["state":"unknown","dispatchStarted":true,"errorCode":state == "unknown" ? (result["errorCode"] as? String ?? "unknown") : "malformed_helper_result"]
    }
    func start() throws {
        _=try store.command("outbox.recover")
        timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.tick() }
    }
    func connect(service:String="iMessage",_ reply:@escaping (Any?,String?)->Void) {
        guard ["iMessage","SMS"].contains(service) else { reply(nil,"Choose iMessage or SMS explicitly.");return }
        guard !checking,!inFlight else { reply(nil,"Wait for the current Messages operation to finish.");return }
        checking=true
        transport.perform(["mode":"check","service":service]) { [weak self] result in
            self?.pendingConnection=(result,service,reply);self?.tick()
        }
    }
    func tick() {
        guard storeAvailable() else { return }
        if let (result,service,reply)=pendingConnection {
            pendingConnection=nil;checking=false
            do {
                guard result["state"] as? String == "ready",result["service"] as? String == service else { throw StoreError(message:result["message"] as? String ?? "The selected Messages service was not verified.") }
                _=try store.command("outbox.connection",["enabled":true,"accountId":result["accountId"] ?? "","accountLabel":result["accountLabel"] ?? "Messages default sending identity","service":service,"checkedAt":result["checkedAt"] ?? Store.now()])
                reply(try store.outboxStatus(),nil);onChange()
            } catch { reply(nil,error.localizedDescription) }
        }
        if let (job,result)=pendingPreflight {
            pendingPreflight=nil
            if result["state"] as? String == "ready", result["replySyncChecked"] as? Bool != true, let check = beforeDispatch {
                check { [weak self] allowed in
                    var checked = result; checked["replySyncChecked"] = true; checked["replySyncAllowed"] = allowed
                    self?.pendingPreflight = (job,checked); self?.tick()
                }
                return
            }
            let id=job["id"] ?? "",token=job["claimToken"] ?? ""
            let service=job["senderService"] as? String ?? "iMessage"
            do {
                guard result["replySyncAllowed"] as? Bool != false else { throw StoreError(message:"Reply sync needs attention before this text can be sent.") }
                guard result["state"] as? String == "ready",result["accountId"] as? String == job["senderAccountId"] as? String,
                      result["service"] as? String == service else { throw StoreError(message:"The selected Messages account or service is unavailable.") }
                _=try store.command("outbox.validateClaim",["id":id,"claimToken":token])
                transport.perform(["mode":"send","accountId":job["senderAccountId"] ?? "","service":service,"phone":job["phone"] ?? "","body":job["body"] ?? ""]) { [weak self] result in
                    var finish=Self.transportOutcome(result);finish["id"]=id;finish["claimToken"]=token
                    self?.pendingFinish=finish;self?.tick()
                }
            } catch { pendingFinish=["id":id,"claimToken":token,"state":"failed","dispatchStarted":false,"errorCode":result["replySyncAllowed"] as? Bool == false ? "reply_sync_unavailable" : "preflight_recheck_failed"] }
        }
        if let result=pendingFinish {
            do { _=try store.command("outbox.finish",result);pendingFinish=nil;inFlight=false;onChange() }
            catch { return } // Keep the result in memory and the durable claim unresolved.
        }
        guard !checking,!inFlight else { return }
        do {
            let claimed=try store.command("outbox.claim")
            guard let job=claimed["job"] as? Record else { return }
            inFlight=true;onChange()
            transport.perform(["mode":"check","accountId":job["senderAccountId"] ?? "","service":job["senderService"] ?? "iMessage"]) { [weak self] result in
                self?.pendingPreflight=(job,result);self?.tick()
            }
        } catch { /* A queued job remains durable and visible until validation succeeds. */ }
    }
    func disconnect() throws -> Record {
        guard !inFlight,!checking else { throw StoreError(message:"Wait for the current Messages operation to finish before disconnecting.") }
        let result=try store.command("outbox.connection",["enabled":false]);onChange();return result
    }
}
