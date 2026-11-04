import Cocoa

func runIMessageTransportTests() throws {
    func check(_ condition:Bool,_ message:String) throws { if !condition { throw StoreError(message:"iMessage transport test: "+message) } }
    // Execute a local echo handler only. Never contact Messages in automated tests.
    let echo=NSAppleScript(source:"on echovalue(value)\nreturn value\nend echovalue")!
    let text="A quote \" and newline\nend tell\ndo shell script \"never executed\"\n🌱"
    let result=try IMessageWorker.invoke(echo,"echovalue",[text])
    try check(result.stringValue==text,"message text is data, even when it resembles executable code")
    let event=IMessageWorker.event("dispatchmessage",["account","SMS","+15555550101",text])
    try check(event.paramDescriptor(forKeyword:0x2d2d2d2d)?.atIndex(4)?.stringValue==text,"body survives descriptor encoding exactly")
    try check(!IMessageWorker.source.contains("activate"),"background transport does not bring Messages forward")
    try check(!IMessageWorker.source.contains("do shell script"),"transport has no shell execution")
    try check(IMessageWorker.source.components(separatedBy:"tell application \"/System/Applications/Messages.app\"").count == 4,"connection, diagnostic and send target the exact system Messages app")
    try check(!IMessageWorker.source.contains("com.apple.iChat") && !IMessageWorker.source.contains("whose"),"connection lookup does not depend on a retired identifier or compound object predicate")
    let phaseError:NSDictionary=[NSAppleScript.errorNumber:NSNumber(value:-1728),NSAppleScript.errorMessage:"Messages got an error: SPROUT_PHASE:account_enabled. private@example.test"]
    let phaseMessage=IMessageWorker.diagnosticMessage(phaseError)
    try check(phaseMessage.contains("account_enabled") && phaseMessage.contains("-1728") && !phaseMessage.contains("private@example.test"),"connection diagnostics retain only bounded phase and error number")
    let unknownError:NSDictionary=[NSAppleScript.errorNumber:NSNumber(value:-1728),NSAppleScript.errorMessage:"SPROUT_PHASE:private@example.test body text"]
    try check(!IMessageWorker.diagnosticMessage(unknownError).contains("private@example.test"),"unrecognized diagnostic text cannot escape the helper")
    let labelFallback=IMessageWorker.source.range(of:"set accountLabel to \"Messages default sending identity\"")!
    let requiredConnection=IMessageWorker.source.range(of:"if connection status of chosenAccount is not connected")!
    try check(requiredConnection.lowerBound<labelFallback.lowerBound,"optional label fallback follows mandatory connection validation")
    // Error wrapping is exercised with a local handler, never the Messages script.
    let localFailure=NSAppleScript(source:"on failcheck()\nerror \"SPROUT_PHASE:enumerate_accounts\" number -1728\nend failcheck")!
    do { _=try IMessageWorker.invoke(localFailure,"failcheck",[]);throw StoreError(message:"Expected local diagnostic error") }
    catch { try check(error.localizedDescription.contains("enumerate_accounts") && error.localizedDescription.contains("-1728"),"local script errors preserve the bounded lookup phase") }
    // Local fixture exercises independent getter outcomes and output sanitization.
    // Its data is deliberately shaped like diagnostics; it never targets an app.
    let diagnosticFixture=NSAppleScript(source:"""
    on diagnosticfixture()
        set rows to {{1, "ok", "error:-10000", "true", "connected"}, {2, "private@example.test", "SMS", "error:-1728", "not_probed"}}
        repeat with i from 3 to 12
            set end of rows to {i, "ok", "iMessage", "true", "connected"}
        end repeat
        return {"ok", 12, rows}
    end diagnosticfixture
    """)!
    let diagnostics=IMessageWorker.accountDiagnostics(try IMessageWorker.invoke(diagnosticFixture,"diagnosticfixture",[]))
    let diagnosticRows=diagnostics["accounts"] as? [Record] ?? []
    try check(diagnosticRows.count==10 && diagnostics["truncated"] as? Bool == true,"account diagnostics cap output at ten accounts")
    try check(diagnosticRows.first?["serviceType"] as? String == "error:-10000" && diagnosticRows.first?["enabled"] as? String == "true" && diagnosticRows.first?["connection"] as? String == "connected","one failed getter does not hide independent getter results")
    try check(diagnosticRows[1]["id"] as? String == "malformed" && !IMessageWorker.accountDiagnosticSummary(diagnostics).contains("private@example.test"),"diagnostics never expose account identities or arbitrary strings")
    let failedEnumeration=NSAppleEventDescriptor.list()
    failedEnumeration.insert(NSAppleEventDescriptor(string:"error:-1712"),at:1)
    failedEnumeration.insert(NSAppleEventDescriptor(int32:-1),at:2)
    failedEnumeration.insert(NSAppleEventDescriptor.list(),at:3)
    let unavailable=IMessageWorker.accountDiagnostics(failedEnumeration)
    try check(unavailable["enumeration"] as? String == "error:-1712" && unavailable["accountCount"] == nil && (unavailable["accounts"] as? [Record])?.isEmpty == true,"enumeration failure preserves only its numeric status")
    try check(IMessageWorker.source.contains("if probeCount > 5 then set probeCount to 5") && IMessageWorker.source.contains("with timeout of 1 second") && !IMessageWorker.source.contains("current date"),"native account probing bounds every getter without requiring scripting additions")
    // The exact catch policy is local: discovery skips an unreadable type;
    // selection of a saved identity propagates the original numeric failure.
    let failurePolicy=NSAppleScript(source:"""
    on failurepolicy(expectedID)
        set candidateType to missing value
        try
            error "fixture getter failed" number -10000
        on error ignoredMessage number originalNumber
            if expectedID is not "" then error ignoredMessage number originalNumber
        end try
        return candidateType is missing value
    end failurepolicy
    """)!
    try check(try IMessageWorker.invoke(failurePolicy,"failurepolicy",[""]).booleanValue,"discovery keeps unreadable account types ineligible")
    do { _=try IMessageWorker.invoke(failurePolicy,"failurepolicy",["saved-account"]);throw StoreError(message:"Expected selected-account failure") }
    catch { try check(error.localizedDescription.contains("-10000"),"an explicitly selected account propagates its failed service getter") }
    try check(IMessageWorker.source.contains("if expectedID is not \"\" then error ignoredMessage number originalNumber") && IMessageWorker.source.contains("if (count usableAccounts) is not 1"),"real discovery uses the tested catch policy and still requires one verified account")
    func outcome(_ state:String,_ started:String,_ phase:String) -> Record {
        let descriptor=NSAppleEventDescriptor.list()
        for (index,value) in [state,started,phase].enumerated() { descriptor.insert(NSAppleEventDescriptor(string:value),at:index+1) }
        descriptor.insert(NSAppleEventDescriptor(int32:-1700),at:4)
        return IMessageWorker.dispatchOutcome(descriptor)
    }
    try check(outcome("submitted","started","dispatch_send")["state"] as? String == "submitted","only a send-command acceptance becomes submitted")
    let rejected=outcome("failed","not_started","recipient_handle")
    try check(rejected["state"] as? String == "failed" && rejected["dispatchStarted"] as? Bool == false && rejected["errorCode"] as? String == "messages_recipient_handle_failed","pre-send failures preserve only a fixed, useful phase code")
    try check(outcome("failed","not_started","account_service")["state"] as? String == "failed","a wrong-service rejection is certain non-dispatch")
    try check(outcome("failed","started","recipient_handle")["state"] as? String == "unknown" && outcome("failed","not_started","private@example.test")["state"] as? String == "unknown","ambiguous or unrecognized failure receipts remain unknown")
    let recipientGuard=IMessageWorker.source.range(of:"if (id of account of recipientHandle as text) is not accountID")!.lowerBound
    let beginsSend=IMessageWorker.source.range(of:"set dispatchStarted to true")!.lowerBound
    let sendCommand=IMessageWorker.source.range(of:"send messageBody to recipientHandle")!.lowerBound
    try check(recipientGuard < beginsSend && beginsSend < sendCommand && IMessageWorker.source.contains("if (handle of recipientHandle as text) is not destination"),"the exact resolved participant is verified before marking send started and used by that send")
    try check(IMessageWorker.run(["mode":"send","service":"RCS"])["errorCode"] as? String == "invalid_service","unsupported service is rejected before any script execution")
    try check(IMessageWorker.run(["mode":"send","service":true])["errorCode"] as? String == "invalid_request","a malformed service never defaults to iMessage")
    try check(OutboxCoordinator.transportOutcome(["state":"failed","dispatchStarted":true])["state"] as? String == "unknown","ambiguous failure cannot be retried as not dispatched")
    try check(OutboxCoordinator.transportOutcome(["state":"ready"])["state"] as? String == "unknown","malformed worker result becomes durable unknown")
    print("iMessage transport descriptor tests passed (no live Messages calls)")
}
