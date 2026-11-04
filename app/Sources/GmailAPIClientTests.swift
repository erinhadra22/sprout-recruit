import Foundation

func runGmailAPIClientTests() throws {
    func check(_ value:Bool,_ name:String) throws { if !value { throw StoreError(message:"Gmail client fixture: "+name) } }
    let rejected=try JSONSerialization.data(withJSONObject:["error":"invalid_grant","error_description":"private-fixture-code must never be surfaced"])
    let classified=GmailHTTPTransport.authorizationFailure(status:400,body:rejected)
    try check(classified?.code=="authorization_expired" && classified?.message.contains("private-fixture-code")==false,"token rejection classified without provider text")
    let missingSecret=try JSONSerialization.data(withJSONObject:["error":"invalid_request","error_description":"client_secret is missing."])
    try check(GmailHTTPTransport.authorizationFailure(status:400,body:missingSecret)?.code=="oauth_client_secret_required","specific configuration failure is actionable")
    try check(GmailHTTPTransport.authorizationFailure(status:500,body:rejected)==nil,"non-token-response status not reclassified")
    let unknown=try JSONSerialization.data(withJSONObject:["error":"unknown-private-fixture","error_description":"private-fixture-code"])
    try check(GmailHTTPTransport.authorizationFailure(status:400,body:unknown)==nil,"unknown provider data remains redacted")
    let diagnosticFolder=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-gmail-diagnostics-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:diagnosticFolder,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:diagnosticFolder)}
    let diagnosticDB=diagnosticFolder.appendingPathComponent("fixture.sqlite").path
    GmailConnectionDiagnostics.record(databasePath:diagnosticDB,stage:"connection.failed",code:"oauth_client_secret_required")
    try check((GmailConnectionDiagnostics.status(databasePath:diagnosticDB)["lastError"] as? String)?.contains("configuration secret")==true,"connection failure survives status reads")
    GmailConnectionDiagnostics.record(databasePath:diagnosticDB,stage:"private-fixture-code",code:"private-fixture-token")
    let diagnosticBytes=try Data(contentsOf:diagnosticFolder.appendingPathComponent("GmailConnectionDiagnostics.json"))
    try check(!String(decoding:diagnosticBytes,as:UTF8.self).contains("private-fixture"),"diagnostics reject unrecognized stages")
    GmailConnectionDiagnostics.record(databasePath:diagnosticDB,stage:"authorization.started",code:nil)
    try check(GmailConnectionDiagnostics.status(databasePath:diagnosticDB)["lastError"]==nil,"explicit retry clears prior durable error")
    let account="recruiter@example.com",candidate="agent@example.com"
    try check(GmailAPIClient.email(" Agent@Example.com ")==candidate,"exact normalized email")
    try check(GmailAPIClient.mailboxes("\"Agent, One\" <agent@example.com>, other@example.com")==[candidate,"other@example.com"],"quoted comma mailbox list")
    for input in ["Team: agent@example.com;","agent@example.com\r\nBcc: other@example.com","Bad <agent@example.com> trailing","agent@example.com,","Name (comment) <agent@example.com>"] { try check(GmailAPIClient.mailboxes(input)==nil,"unsupported envelopes fail closed") }
    let plain="A real plain-text reply. 🏡"
    let payload:Record=["mimeType":"multipart/alternative","parts":[["mimeType":"text/html","body":["data":GmailOAuth.base64(Data("<b>other</b>".utf8))]],["mimeType":"text/plain","body":["data":GmailOAuth.base64(Data(plain.utf8))]]]]
    try check(GmailAPIClient.body(payload).text==plain,"MIME chooses actual plain text")
    try check(GmailAPIClient.body(["mimeType":"text/html","body":["data":"invalid!"]]).kind=="unavailable","unsupported HTML remains explicit")
    try check(GmailAPIClient.body(["mimeType":"text/plain","filename":"attachment.txt","body":["data":GmailOAuth.base64(Data("attached text".utf8))]]).kind=="unavailable","attachment text not mistaken for email body")
    try check(GmailAPIClient.body(["mimeType":"text/plain","body":["data":GmailOAuth.base64(Data(String(repeating:"a",count:50001).utf8))]]).kind=="unavailable","body cap")
    try check(GmailAPIClient.body(["mimeType":"text/plain","body":["data":GmailOAuth.base64(Data("reply\0value".utf8))]]).kind=="unavailable","NUL body becomes explicit unavailable placeholder")
    let now=Date().addingTimeInterval(-10),milliseconds=String(Int64(now.timeIntervalSince1970*1000))
    func message(_ id:String,from:String=candidate,to:String=account,labels:[String]=["INBOX"],full:Bool=false,cc:String?=nil)->Record {
        var headers:[Record]=[["name":"From","value":from],["name":"To","value":to],["name":"Subject","value":"Hello"],["name":"Auto-Submitted","value":"no"]]
        if let cc {headers.append(["name":"Cc","value":cc])}
        var p:Record=["mimeType":"text/plain","headers":headers]
        if full {p["body"]=["data":GmailOAuth.base64(Data(plain.utf8))]}
        return ["id":id,"threadId":"thread1","internalDate":milliseconds,"labelIds":labels,"payload":p]
    }
    var calls:[URLRequest]=[]
    let client=GmailAPIClient { request,completion in
        calls.append(request)
        let path=request.url!.path,query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems ?? []
        let full=query.contains{$0.name=="format" && $0.value=="full"}
        let value:Record
        if path.hasSuffix("/profile") {value=["emailAddress":account,"historyId":"900"]}
        else if path.hasSuffix("/messages") {value=["messages":[["id":"matched"],["id":"unmatched"],["id":"alias"],["id":"group"],["id":"comment"]],"nextPageToken":"opaque/page+token"]}
        else if path.hasSuffix("/matched") {value=message("matched",full:full)}
        else if path.hasSuffix("/unmatched") {value=message("unmatched",from:"unknown@example.com",full:full)}
        else if path.hasSuffix("/alias") {value=message("alias",from:"alias@example.com",to:candidate,labels:["SENT"],full:full)}
        else if path.hasSuffix("/group") {value=message("group",full:full,cc:"other@example.com")}
        else {value=message("comment",from:"Agent (Broker) <agent@example.com>",full:full)}
        completion(.success(try! JSONSerialization.data(withJSONObject:value)))
    }
    var result:Result<Record,Error>?
    client.readSyncPage(request:["accountAddress":account,"since":GmailAPIClient.iso(now.addingTimeInterval(-10)),"emails":[candidate],"cursor":Record()],token:"fixture-token") {result=$0}
    let batch=try result!.get(),rows=batch["messages"] as! [Record],held=batch["held"] as! [Record],cursor=batch["nextCursor"] as! Record
    try check(rows.count==1 && rows[0]["body"] as? String==plain && rows[0]["direction"] as? String=="inbound","exact candidate body receipt")
    try check(held.count==3 && held.allSatisfy{$0["body"]==nil},"alias, multi-recipient and comment envelopes held without bodies")
    try check(calls.filter{(URLComponents(url:$0.url!,resolvingAgainstBaseURL:false)!.queryItems ?? []).contains{$0.name=="format" && $0.value=="full"}}.count==1,"only matched envelope fetches body")
    try check(cursor["mode"] as? String=="full" && cursor["baselineHistoryId"] as? String=="900" && batch["hasMore"] as? Bool==true,"full scan retains pre-scan baseline across pages")
    try check(calls.allSatisfy{$0.httpMethod=="GET" && $0.url?.host=="gmail.googleapis.com" && $0.value(forHTTPHeaderField:"Authorization")=="Bearer fixture-token"},"read-only fixed-host requests")
    let callCount=calls.count
    client.readSyncPage(request:["accountAddress":account,"since":GmailAPIClient.iso(now.addingTimeInterval(-10)),"emails":[candidate,candidate],"cursor":Record()],token:"fixture-token") {result=$0}
    let ambiguousBatch=try result!.get()
    try check((ambiguousBatch["messages"] as! [Record]).isEmpty && (ambiguousBatch["held"] as! [Record]).contains{$0["reasonCode"] as? String=="ambiguous_identity"},"duplicate candidate address holds without attribution")
    try check(calls.dropFirst(callCount).allSatisfy{!(URLComponents(url:$0.url!,resolvingAgainstBaseURL:false)!.queryItems ?? []).contains{$0.name=="format" && $0.value=="full"}},"ambiguous candidate never fetches body")
    try check(held.first{$0["providerMessageId"] as? String=="alias"}?["direction"] as? String=="outbound","sent alias hold preserves outbound direction")
    let expired=GmailAPIClient { _,done in done(.failure(GmailAPIError(code:"not_found",message:"fixture"))) }
    var failure:Error?;expired.history(token:"fixture",historyId:"100") {if case .failure(let error)=$0 {failure=error}}
    try check((failure as? GmailAPIError)?.code=="history_expired","expired history cannot silently advance")
    let history=GmailAPIClient { _,done in done(.success(try! JSONSerialization.data(withJSONObject:["historyId":"902","history":[["messagesAdded":[["message":["id":"matched"]],["message":["id":"matched"]]]]]]))) }
    history.history(token:"fixture",historyId:"900") {result=$0}
    let page=try result!.get();try check(page["messageIds"] as? [String]==["matched"] && page["historyId"] as? String=="902","history deduplicates provider IDs")
    let mismatched=GmailAPIClient { _,done in done(.success(try! JSONSerialization.data(withJSONObject:["emailAddress":"wrong@example.com","historyId":"1"]))) }
    mismatched.readSyncPage(request:["accountAddress":account,"since":GmailAPIClient.iso(now),"emails":[candidate],"cursor":Record()],token:"fixture") {result=$0}
    if case .failure(let error)=result! {try check((error as? GmailAPIError)?.code=="account_changed","wrong mailbox rejected")} else {try check(false,"wrong mailbox accepted")}
    // Calendar responses are provider evidence, not subject-line sentiment.
    func calendar(_ response:String="ACCEPTED",attendee:String=candidate,organizer:String?=account,method:String="REPLY")->String {
        var lines=["BEGIN:VCALENDAR","VERSION:2.0","PRODID:-//Sprout Fixture//EN","METHOD:"+method,"BEGIN:VEVENT","UID:fixture-meeting-123","DTSTAMP:20261030T120000Z","DTSTART:20261102T180000Z"]
        if let organizer {lines.append("ORGANIZER:mailto:"+organizer)}
        lines += ["ATTENDEE;CN=Agent;PARTSTAT="+response+":mailto:"+attendee,"END:VEVENT","END:VCALENDAR"]
        return lines.joined(separator:"\r\n")+"\r\n"
    }
    for (partstat,response) in [("ACCEPTED","accepted"),("DECLINED","declined"),("TENTATIVE","tentative")] {
        let evidence=GmailAPIClient.meetingResponse(calendarText:calendar(partstat),sender:candidate,recipient:account)
        try check(evidence?["method"] as? String=="REPLY" && evidence?["response"] as? String==response && evidence?["attendee"] as? String==candidate && evidence?["uid"] as? String=="fixture-meeting-123","exact attendee calendar "+response)
        try check((evidence?["calendarSHA256"] as? String)?.count==64,"calendar source fingerprint retained")
    }
    let acceptedCalendar=calendar()
    let foldedCalendar=acceptedCalendar.replacingOccurrences(of:"ATTENDEE;CN=Agent;PARTSTAT=ACCEPTED",with:"ATTENDEE;CN=Agent;\r\n PARTSTAT=ACCEPTED")
    try check(GmailAPIClient.meetingResponse(calendarText:foldedCalendar,sender:candidate,recipient:account)?["response"] as? String=="accepted","folded calendar property retains exact RSVP")
    try check(GmailAPIClient.meetingResponse(calendarText:calendar(organizer:nil),sender:candidate,recipient:account)?["response"] as? String=="accepted","optional absent organizer does not invent an identity")
    let invalidCalendars:[(String,String)]=[
        (calendar(method:"REQUEST"),"invitation is not a response"),
        (calendar(attendee:"other@example.com"),"wrong attendee is not attributed to sender"),
        (calendar(organizer:"other@example.com"),"wrong organizer is not attributed to recipient"),
        (acceptedCalendar.replacingOccurrences(of:"END:VEVENT",with:"ATTENDEE;PARTSTAT=ACCEPTED:mailto:other@example.com\r\nEND:VEVENT"),"multiple attendees cannot prove this sender response"),
        (acceptedCalendar.replacingOccurrences(of:";PARTSTAT=ACCEPTED",with:";SENT-BY=\"mailto:assistant@example.com\";PARTSTAT=ACCEPTED"),"sent-by delegation is unsupported"),
        (acceptedCalendar.replacingOccurrences(of:";PARTSTAT=ACCEPTED",with:";DELEGATED-FROM=\"mailto:other@example.com\";PARTSTAT=ACCEPTED"),"delegated attendee is unsupported"),
        (acceptedCalendar.replacingOccurrences(of:";PARTSTAT=ACCEPTED",with:";PARTSTAT=ACCEPTED;PARTSTAT=DECLINED"),"conflicting response parameters are rejected"),
        (acceptedCalendar.replacingOccurrences(of:"METHOD:REPLY",with:"METHOD:REPLY\r\nMETHOD:REQUEST"),"duplicate conflicting method is rejected"),
        (acceptedCalendar.replacingOccurrences(of:"END:VEVENT\r\n",with:""),"unterminated event is rejected"),
        (acceptedCalendar.replacingOccurrences(of:"END:VCALENDAR",with:"BEGIN:VEVENT\r\nUID:other-event\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:agent@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR"),"multiple events cannot supply one response"),
        (acceptedCalendar.replacingOccurrences(of:"UID:fixture-meeting-123",with:"UID:"+String(repeating:"x",count:4097)),"unfolded line budget enforced"),
        (acceptedCalendar.replacingOccurrences(of:"UID:fixture-meeting-123",with:"UID:fixture-meeting-123\r\n"+String(repeating:"COMMENT:x\r\n",count:1025)),"calendar line budget enforced"),
        (acceptedCalendar+String(repeating:"🏡",count:17000),"calendar budget is UTF8 bytes"),
        ("Accepted: Friday conversation\r\nThanks, I will attend.","subject and prose do not establish calendar response")
    ]
    for (text,name) in invalidCalendars { try check(GmailAPIClient.meetingResponse(calendarText:text,sender:candidate,recipient:account)==nil,name) }

    func scanCalendar(_ calendarText:String?,attachment:Bool=false,declaredSize:Int?=nil,attachmentText:String?=nil,duplicate:Bool=false,attachmentFails:Bool=false,plainBody:String=plain)->(Result<Record,Error>,[URLRequest]) {
        var requests:[URLRequest]=[],answer:Result<Record,Error>?
        let responseClient=GmailAPIClient { request,done in
            requests.append(request)
            let path=request.url!.path,query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems ?? []
            if path.contains("/attachments/") {
                if attachmentFails {done(.failure(GmailAPIError(code:"network_unavailable",message:"fixture attachment unavailable")));return}
                let raw=attachmentText ?? calendarText ?? ""
                done(.success(try! JSONSerialization.data(withJSONObject:["size":raw.utf8.count,"data":GmailOAuth.base64(Data(raw.utf8))])));return
            }
            let value:Record
            if path.hasSuffix("/profile") {value=["emailAddress":account,"historyId":"930"]}
            else if path.hasSuffix("/messages") {value=["messages":[["id":"meeting1"]]]}
            else {
                let full=query.contains{$0.name=="format" && $0.value=="full"}
                var record=message("meeting1",full:false),envelope=record["payload"] as! Record,headers=envelope["headers"] as! [Record]
                for i in headers.indices where headers[i]["name"] as? String=="Subject" {headers[i]["value"]="Accepted: Friday conversation"}
                envelope["headers"]=headers
                if full {
                    var parts:[Record]=[["mimeType":"text/plain","body":["data":GmailOAuth.base64(Data(plainBody.utf8))]]]
                    if let calendarText {
                        var part:Record=["mimeType":"text/calendar","filename":attachment ? "invite.ics":"","headers":[["name":"Content-Type","value":"text/calendar; method=REPLY; charset=UTF-8"]]]
                        part["body"]=attachment ? ["attachmentId":"calendar_attachment-1","size":declaredSize ?? calendarText.utf8.count] : ["data":GmailOAuth.base64(Data(calendarText.utf8)),"size":declaredSize ?? calendarText.utf8.count]
                        parts.append(part);if duplicate {parts.append(part)}
                    }
                    envelope["mimeType"]="multipart/mixed";envelope["parts"]=parts
                }
                record["payload"]=envelope;value=record
            }
            done(.success(try! JSONSerialization.data(withJSONObject:value)))
        }
        responseClient.readSyncPage(request:["accountAddress":account,"since":GmailAPIClient.iso(now.addingTimeInterval(-10)),"emails":[candidate],"cursor":Record()],token:"fixture-token") {answer=$0}
        return (answer ?? .failure(StoreError(message:"Calendar fixture did not complete synchronously.")),requests)
    }
    for response in ["ACCEPTED","DECLINED","TENTATIVE"] {
        let text=calendar(response),scan=scanCalendar(text),receipt=try scan.0.get(),records=receipt["messages"] as! [Record]
        try check(records.count==1 && records[0]["calendarText"] as? String==text && records[0]["body"] as? String==plain,"inline calendar preserved without replacing actual body: "+response)
        try check((receipt["held"] as? [Record])?.isEmpty==true && scan.1.allSatisfy{$0.httpMethod=="GET"},"inline recognized calendar uses readonly evidence")
    }
    let attached=scanCalendar(acceptedCalendar,attachment:true),attachedReceipt=try attached.0.get(),attachmentRows=attachedReceipt["messages"] as! [Record]
    try check(attachmentRows.count==1 && attachmentRows[0]["calendarText"] as? String==acceptedCalendar && attachmentRows[0]["body"] as? String==plain,"bounded calendar attachment becomes evidence not message body")
    let attachmentRequests=attached.1.filter{$0.url?.path.contains("/attachments/")==true}
    try check(attachmentRequests.count==1 && attachmentRequests[0].url?.path.hasSuffix("/messages/meeting1/attachments/calendar_attachment-1")==true && attachmentRequests[0].httpMethod=="GET" && attachmentRequests[0].url?.host=="gmail.googleapis.com","attachment fetched once from exact message and fixed Gmail host")
    let subjectOnly=try scanCalendar(nil).0.get(),subjectRows=subjectOnly["messages"] as! [Record]
    try check(subjectRows.count==1 && subjectRows[0]["calendarText"]==nil,"Accepted subject alone stays ordinary email")
    let proseCalendar=try scanCalendar(nil,plainBody:acceptedCalendar).0.get()
    try check((proseCalendar["messages"] as! [Record]).first?["calendarText"]==nil,"calendar-looking plain text is not MIME calendar evidence")
    for (scan,name) in [(scanCalendar(calendar(attendee:"other@example.com")),"wrong-attendee MIME calendar"),(scanCalendar(acceptedCalendar,duplicate:true),"multiple MIME calendar parts"),(scanCalendar(acceptedCalendar,attachment:true,declaredSize:65537),"declared oversized calendar attachment"),(scanCalendar(acceptedCalendar,attachment:true,attachmentText:String(repeating:"x",count:65537)),"decoded oversized calendar attachment")] {
        let receipt=try scan.0.get(),heldCalendar=receipt["held"] as! [Record]
        try check((receipt["messages"] as! [Record]).isEmpty && heldCalendar.contains{$0["reasonCode"] as? String=="calendar_response_unverified"},name+" is held rather than treated as a genuine reply")
        try check(heldCalendar.allSatisfy{$0["body"]==nil && $0["calendarText"]==nil},name+" hold contains no body or calendar text")
    }
    let rejectedAttachment=scanCalendar(acceptedCalendar,attachment:true,declaredSize:65537)
    try check(rejectedAttachment.1.allSatisfy{$0.url?.path.contains("/attachments/") != true},"oversized declared attachment is rejected before download")
    let unavailableAttachment=scanCalendar(acceptedCalendar,attachment:true,attachmentFails:true)
    if case .failure = unavailableAttachment.0 {} else {try check(false,"attachment network failure cannot advance the scan cursor")}
    print("PASS: Gmail calendar REPLY evidence, exact attendee/method checks, malformed and subject-only boundaries, bounded inline/attachment reads and body preservation; no network.")
    print("PASS: Gmail fixed read-only requests, MIME/identity bounds, metadata-before-body filtering, alias/group holds, pagination, expired history and mailbox mismatch; no network.")
}
