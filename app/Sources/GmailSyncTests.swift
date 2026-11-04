import Foundation

func runGmailSyncTests() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-gmail-store-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let account="operator@example.test",email="candidate@example.test",phone="+12025550123"
    let now=Date(),formatter=ISO8601DateFormatter()
    let received=formatter.string(from:now.addingTimeInterval(-60)),prepared=formatter.string(from:now.addingTimeInterval(-120))
    func check(_ condition:Bool,_ label:String) throws { if !condition { throw StoreError(message:"Gmail sync test: "+label) } }
    func rejects(_ label:String,_ body:()throws->Void) throws { do { try body() } catch { return };throw StoreError(message:"Gmail sync expected rejection: "+label) }
    func contact(_ store:Store,_ id:String="a",_ address:String?=nil) throws {
        try store.put("agents",["id":id,"name":"Fixture "+id,"email":address ?? email,"phone":phone,"datasetId":"live","manual":true,"source":"Manual contact","status":"Identified"])
    }
    func fixture(_ label:String,enable:Bool=true) throws -> Store {
        let store=try Store(path:directory.appendingPathComponent(label+".sqlite").path,seed:false);try contact(store)
        if enable { try store.transaction { try store.setGmailSyncConnection(["connected":true,"accountAddress":account]);try store.configureGmailSync(["enabled":true,"confirmed":true,"historyMode":"all"]) } }
        return store
    }
    func message(_ id:String="message-1",_ changes:Record=[:])->Record {
        var row:Record=["providerMessageId":id,"providerThreadId":"thread-1","direction":"inbound","from":email,"to":[account],"cc":[String](),"bcc":[String](),"occurredAt":received,"subject":"Fixture reply","body":"Exact private reply text.","bodyKind":"text","labels":["INBOX"],"autoSubmitted":"","precedence":"","returnPath":"","inReplyTo":""]
        for (key,value) in changes { row[key]=value };return row
    }
    func page(_ request:Record,_ rows:[Record],next:Record=["mode":"history","historyId":"100"],more:Bool=false,held:[Record]=[])->Record {
        ["accountAddress":request["accountAddress"]!,"fromCursor":request["cursor"]!,"nextCursor":next,"hasMore":more,"messages":rows,"held":held,"scannedCount":rows.count+held.count,"observedAt":Store.now()]
    }
    func apply(_ store:Store,_ request:Record,_ batch:Record) throws { try store.transaction { try store.applyGmailSyncBatch(request:request,batch:batch) } }
    func readyDraft(_ store:Store,_ id:String="draft-1",created:String?=nil,sequence:Bool=false) throws {
        var draft:Record=["id":id,"agentId":"a","channel":"Message","state":"draft","body":"Reviewed outbound draft.","createdAt":created ?? prepared,"updatedAt":created ?? prepared]
        if sequence { draft["sequenceId"]="sequence-1";try store.put("sequences",["id":"sequence-1","agentId":"a","state":"completed","createdAt":prepared]) }
        try store.put("drafts",draft)
    }

    let off=try fixture("off",enable:false)
    try check(try off.gmailSyncStatus()["enabled"] as? Bool==false && off.gmailSyncStatus()["connected"] as? Bool==false,"disabled and disconnected by default")
    try rejects("connection required") { try off.configureGmailSync(["enabled":true,"confirmed":true,"historyMode":"all"]) }
    try off.setGmailSyncConnection(["connected":true,"accountAddress":" OPERATOR@EXAMPLE.TEST "])
    try rejects("scope required") { try off.configureGmailSync(["enabled":true,"confirmed":true]) }
    try rejects("confirmation required") { try off.configureGmailSync(["enabled":true,"historyMode":"newonly"]) }
    try off.configureGmailSync(["enabled":true,"confirmed":true,"historyMode":"newonly"])
    let floor=try off.gmailSyncStatus()["since"] as! String
    try check(Store.activityEventDate(floor)!>=now.addingTimeInterval(-1),"new-only starts when enabled")
    try apply(off,off.gmailSyncReadRequest(),page(off.gmailSyncReadRequest(),[message()]))
    try check(try off.all("externalMessages").isEmpty,"pre-floor history is excluded")
    try off.configureGmailSync(["enabled":false]);try off.configureGmailSync(["enabled":true,"confirmed":true])
    try check(try off.gmailSyncStatus()["since"] as? String==floor,"resume retains original floor")
    try rejects("scope cannot expand on resume") { try off.configureGmailSync(["enabled":true,"confirmed":true,"historyMode":"all"]) }
    let sixty=try fixture("sixty",enable:false);try sixty.setGmailSyncConnection(["connected":true,"accountAddress":account]);try sixty.configureGmailSync(["enabled":true,"confirmed":true,"historyMode":"last60days"])
    let sixtyFloor=Store.activityEventDate(try sixty.gmailSyncStatus()["since"] as! String)!
    try check(abs(sixtyFloor.timeIntervalSinceNow+60*86400)<5,"explicit last-60-day floor is computed natively")

    let store=try fixture("reply");try readyDraft(store,sequence:true);try readyDraft(store,"independent")
    try store.put("tasks",["id":"follow-up","agentId":"a","type":"Call","createdAt":prepared,"completed":false,"repeatDays":7,"dueDate":Store.day(),"title":"Recurring fixture follow-up"])
    try store.setOutboxConnection(["enabled":true,"accountId":"fixture-account","accountLabel":"Fixture","checkedAt":Store.now()])
    let jobID=UUID().uuidString.lowercased()
    try store.enqueueOutbox(["id":jobID,"draftId":"draft-1","agentId":"a","phone":phone,"body":"Reviewed outbound draft.","confirmed":true])
    let request=try store.gmailSyncReadRequest(),batch=page(request,[message()])
    try apply(store,request,batch)
    let saved=try store.all("externalMessages")[0],savedID=saved["id"] as! String
    try check(saved["agentId"] as? String=="a" && saved["body"] as? String=="Exact private reply text." && saved["messageClass"] as? String=="received_reply","exact inbound body and identity preserved")
    try check(try store.get("agents","a")["status"] as? String=="Identified","CRM status unchanged")
    try check(try store.get("drafts","draft-1")["approvalState"] as? String=="paused_reply" && store.get("drafts","independent")["approvalState"] as? String=="paused_reply","final-sequence and independent drafts both paused")
    try check(try store.get("tasks","follow-up")["followUpState"] as? String=="paused_reply" && store.get("tasks","follow-up")["completed"] as? Bool==false,"manual follow-up remains open with explicit pause metadata")
    try check(try store.get("outboxJobs",jobID)["state"] as? String=="held","queued text held atomically")
    _=try store.command("task.complete",["id":"follow-up"])
    try check(try !store.all("tasks").contains{$0["recurrenceSourceId"] as? String=="follow-up"},"completing a paused recurring follow-up cannot create the next outreach task")
    try check(try store.all("tasks").filter{$0["reviewKind"] as? String=="gmail-sync-reply"}.count==1,"one review task per human reply")
    let task=try store.get("tasks",saved["reviewTaskId"] as! String)
    try check(!(task["description"] as! String).contains("Exact private reply text"),"task references rather than duplicates private email body")
    try apply(store,request,batch)
    let repeatRequest=try store.gmailSyncReadRequest();try apply(store,repeatRequest,page(repeatRequest,[message()]))
    try check(try store.all("externalMessages").count==1 && store.gmailSyncStatus()["importedReplies"] as? Int==1 && store.all("tasks").filter{$0["reviewKind"] as? String=="gmail-sync-reply"}.count==1,"batch replay and repeat provider message are idempotent")
    let reopened=try Store(path:store.path,seed:false)
    try check(try reopened.gmailSyncStatus()["importedMessages"] as? Int==1 && (reopened.gmailSyncReadRequest()["cursor"] as? Record)?["historyId"] as? String=="100","state persists after reopening")
    let conflict=try store.gmailSyncReadRequest();try apply(store,conflict,page(conflict,[message("message-1",["body":"Changed body"])]))
    try check(try store.get("externalMessages",savedID)["body"] as? String=="Exact private reply text." && store.gmailSyncHoldReason(agentId:"a") != nil,"changed immutable evidence is quarantined without rewriting saved body")

    let notices=try fixture("notices");try readyDraft(notices)
    let noticeRequest=try notices.gmailSyncReadRequest();try apply(notices,noticeRequest,page(noticeRequest,[message("auto",["autoSubmitted":"auto-replied"])]))
    try check(try notices.get("drafts","draft-1")["approvalState"]==nil && notices.gmailSyncStatus()["importedReplies"] as? Int==0 && notices.gmailSyncStatus()["automaticNotices"] as? Int==1,"automatic notice is distinguished and does not pause drafts")
    try check(try notices.all("externalMessages")[0]["messageClass"] as? String=="automatic_notice" && notices.all("tasks").filter{$0["reviewKind"] as? String=="gmail-sync-notice"}.count==1,"notice classification is explicit and reviewable")

    func calendar(_ response:String="ACCEPTED",sender:String=email)->String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nUID:fixture-event@example.test\r\nATTENDEE;CN=Fixture;PARTSTAT=\(response):mailto:\(sender)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    }
    for response in ["ACCEPTED","DECLINED","TENTATIVE"] {
        let meeting=try fixture("meeting-"+response);try readyDraft(meeting,sequence:true)
        try meeting.put("tasks",["id":"meeting-followup","agentId":"a","type":"Call","createdAt":prepared,"completed":false])
        let req=try meeting.gmailSyncReadRequest()
        try apply(meeting,req,page(req,[message("calendar-"+response,["calendarText":calendar(response),"autoSubmitted":"auto-generated"])]))
        let record=try meeting.all("externalMessages")[0],status=try meeting.gmailSyncStatus()
        try check(record["messageClass"] as? String=="meeting_response" && record["meetingResponse"] as? String==response.lowercased(),"calendar response overrides automatic classification with explicit evidence")
        try check(status["importedMeetingResponses"] as? Int==1 && status["importedReplies"] as? Int==0 && status["automaticNotices"] as? Int==0 && status["importedMessages"] as? Int==1,"meeting response is separately counted")
        try check(record["calendarText"]==nil && (record["meetingResponseEvidence"] as? Record)?["calendarSHA256"] is String && record["body"] as? String=="Exact private reply text.","calendar bytes do not replace or duplicate email body")
        if response=="ACCEPTED" {
            try check(try meeting.get("drafts","draft-1")["pauseReason"] as? String=="meeting_accepted" && meeting.get("tasks","meeting-followup")["pauseReason"] as? String=="meeting_accepted" && meeting.get("sequences","sequence-1")["pauseReason"] as? String=="meeting_accepted","acceptance pauses eligible draft task and final sequence")
            try check(record["followUpsPaused"] as? Bool==true,"acceptance badge reflects actual paused work")
        } else {
            try check(try meeting.get("drafts","draft-1")["approvalState"]==nil && meeting.get("tasks","meeting-followup")["followUpState"]==nil && record["followUpsPaused"] as? Bool==false,"declined and tentative do not add acceptance pauses")
        }
        try meeting.setOutboxConnection(["enabled":true,"accountId":"fixture-account","accountLabel":"Fixture","checkedAt":Store.now()])
        let send:Record=["id":UUID().uuidString.lowercased(),"draftId":"draft-1","agentId":"a","phone":phone,"body":"Reviewed outbound draft.","confirmed":true]
        if response=="ACCEPTED" { try rejects("accepted response gates text enqueue") { try meeting.enqueueOutbox(send) } }
        else { try meeting.enqueueOutbox(send);try check(try meeting.all("outboxJobs").count==1,"declined and tentative do not invoke accepted-response send gate") }
        let repeatReq=try meeting.gmailSyncReadRequest();try apply(meeting,repeatReq,page(repeatReq,[message("calendar-"+response,["calendarText":calendar(response),"autoSubmitted":"auto-generated"])]))
        try check(try meeting.all("externalMessages").count==1 && meeting.all("tasks").filter{$0["reviewKind"] as? String=="gmail-sync-meeting-response"}.count==1 && meeting.gmailSyncStatus()["importedMeetingResponses"] as? Int==1,"meeting replay is idempotent")
    }
    let wrongAttendee=try fixture("wrong-calendar-attendee");let wrongReq=try wrongAttendee.gmailSyncReadRequest()
    try apply(wrongAttendee,wrongReq,page(wrongReq,[message("wrong-calendar",["calendarText":calendar(sender:"another@example.test")])]))
    try check(try wrongAttendee.all("externalMessages").isEmpty && wrongAttendee.gmailSyncStatus()["importedReplies"] as? Int==0 && wrongAttendee.gmailSyncHoldReason(agentId:"a") != nil,"wrong calendar attendee is held without human-reply attribution")
    let subjectOnly=try fixture("subject-only");let subjectReq=try subjectOnly.gmailSyncReadRequest()
    try apply(subjectOnly,subjectReq,page(subjectReq,[message("subject-only",["subject":"Accepted: ordinary discussion"])]))
    try check(try subjectOnly.all("externalMessages")[0]["messageClass"] as? String=="received_reply","subject prefix alone never creates calendar classification")

    let repair=try fixture("calendar-repair");let repairReq=try repair.gmailSyncReadRequest()
    try apply(repair,repairReq,page(repairReq,[message("historic-calendar",["bodyKind":"unavailable","body":"Original unavailable-body placeholder."])]))
    let before=try repair.all("externalMessages")[0],beforeID=before["id"] as! String,beforeTask=before["reviewTaskId"] as! String
    var completedReview=try repair.get("tasks",beforeTask);completedReview["completed"]=true;completedReview["completedAt"]=Store.now();try repair.put("tasks",completedReview)
    let repairPayload:Record=["confirmed":true,"externalMessageId":beforeID,"accountAddress":account,"providerMessageId":"historic-calendar","providerThreadId":"thread-1","calendarText":calendar()]
    try repair.transaction { try repair.reclassifyGmailMeetingResponse(repairPayload) }
    let repaired=try repair.get("externalMessages",beforeID)
    for key in ["body","bodyKind","occurredAt","importedAt","providerMessageId","providerThreadId","agentId","reviewTaskId","subject","from","to"] { try check(repaired[key] as? String==before[key] as? String,"repair preserves immutable field "+key) }
    try check(NSDictionary(dictionary:repaired["content"] as! Record).isEqual(to:before["content"] as! Record),"repair preserves original content snapshot")
    try check(try repair.get("tasks",beforeTask)["completed"] as? Bool==true && repair.get("tasks",beforeTask)["reviewKind"] as? String=="gmail-sync-meeting-response" && repair.all("tasks").count==1,"existing completed review task updated in place")
    try check(try repair.gmailSyncStatus()["importedReplies"] as? Int==0 && repair.gmailSyncStatus()["importedMeetingResponses"] as? Int==1 && repair.gmailSyncStatus()["importedMessages"] as? Int==1,"repair corrects classification counters without another import")
    try repair.transaction { try repair.reclassifyGmailMeetingResponse(repairPayload) }
    try check(try repair.all("tasks").count==1 && repair.gmailSyncStatus()["importedMeetingResponses"] as? Int==1,"repair replay has no duplicate task or count")
    var badRepair=repairPayload;badRepair["providerMessageId"]="different-message"
    try rejects("repair exact provider identity") { try repair.transaction { try repair.reclassifyGmailMeetingResponse(badRepair) } }
    badRepair=repairPayload;badRepair["calendarText"]=calendar("DECLINED")
    try rejects("repair cannot rewrite established calendar evidence") { try repair.transaction { try repair.reclassifyGmailMeetingResponse(badRepair) } }
    badRepair=repairPayload;badRepair["confirmed"]=false
    try rejects("repair requires confirmation") { try repair.transaction { try repair.reclassifyGmailMeetingResponse(badRepair) } }

    let sent=try fixture("sent");try readyDraft(sent)
    let sentRequest=try sent.gmailSyncReadRequest();try apply(sent,sentRequest,page(sentRequest,[message("sent",["direction":"outbound","from":account,"to":[email],"labels":["SENT"]])]))
    try check(try sent.gmailSyncStatus()["importedSent"] as? Int==1 && !sent.all("tasks").contains{($0["reviewKind"] as? String ?? "").hasPrefix("gmail-sync")} && sent.get("drafts","draft-1")["state"] as? String=="draft","sent copy logged without asserting delivery or changing draft state")
    let legacy=try fixture("legacy")
    try legacy.importExternalMessage(["agentId":"a","channel":"Email","provider":"gmail","accountAddress":account,"providerMessageId":"legacy-guid","providerThreadId":"thread-1","direction":"outbound","from":account,"to":email,"occurredAt":received,"subject":"Fixture reply","body":"Exact private reply text."])
    let legacyRequest=try legacy.gmailSyncReadRequest();try apply(legacy,legacyRequest,page(legacyRequest,[message("legacy-guid",["direction":"outbound","from":account,"to":[email],"labels":["SENT"]])]))
    try check(try legacy.all("externalMessages").count==1,"existing manually imported Gmail copy deduplicates")

    let ambiguous=try fixture("ambiguous");try contact(ambiguous,"b");try readyDraft(ambiguous,sequence:true)
    let ambiguityRequest=try ambiguous.gmailSyncReadRequest()
    try check(ambiguityRequest["emails"] as? [String]==[email,email],"reader receives duplicate email scope to avoid fetching ambiguous bodies")
    try apply(ambiguous,ambiguityRequest,page(ambiguityRequest,[message()]))
    try check(try ambiguous.all("externalMessages").isEmpty && ambiguous.gmailSyncHoldReason(agentId:"a") != nil && ambiguous.gmailSyncHoldReason(agentId:"b") != nil,"shared email is unlinked and holds both possible contacts")
    let hold=try ambiguous.all("settings").first{($0["id"] as? String ?? "").hasPrefix("gmail-sync-held-")}!
    try check(try hold["body"]==nil && hold["agentId"]==nil && ambiguous.get("drafts","draft-1")["replyMessageId"]==nil,"unlinked evidence never assigns reply contents or claimed reply identity")
    try contact(ambiguous,"b","other@example.test")
    let remap=try ambiguous.gmailSyncReadRequest();try check((remap["cursor"] as? Record)?.isEmpty==true,"changed email mapping triggers scoped rescan")
    try apply(ambiguous,remap,page(remap,[message()]))
    try check(try ambiguous.all("externalMessages").count==1 && ambiguous.gmailSyncHoldReason(agentId:"a")==nil && ambiguous.gmailSyncStatus()["heldMessages"] as? Int==0,"exact unique import resolves held GUID without silently completing human review")
    let mixed=try fixture("mixed");let mixedRequest=try mixed.gmailSyncReadRequest()
    try apply(mixed,mixedRequest,page(mixedRequest,[message("group",["cc":["third@example.test"]]),message("alias",["direction":"outbound","from":"alias@example.test","to":[email],"labels":["SENT"]])]))
    try check(try mixed.all("externalMessages").isEmpty && mixed.gmailSyncStatus()["heldMessages"] as? Int==2,"multi-party and unverified sender aliases remain unlinked")
    let malformed=try fixture("malformed"),malformedRequest=try malformed.gmailSyncReadRequest()
    try rejects("malformed page rolls back") { try apply(malformed,malformedRequest,page(malformedRequest,[message("valid"),message("bad",["to":"not an array"])])) }
    try check(try malformed.all("externalMessages").isEmpty && malformed.all("tasks").isEmpty && (malformed.gmailSyncStatus()["cursor"] as? Record)?.isEmpty==true,"failed page rolls back messages tasks and cursor")
    let heldRequest=try malformed.gmailSyncReadRequest()
    try apply(malformed,heldRequest,page(heldRequest,[],held:[["providerMessageId":"bad-header","providerThreadId":"bad-thread","reasonCode":"malformed_headers","participantEmails":[email]]]))
    try check(try malformed.gmailSyncHoldReason(agentId:"a") != nil && malformed.all("externalMessages").isEmpty,"metadata-only malformed evidence creates hold without body import")
    let missingRequest=try malformed.gmailSyncReadRequest()
    try apply(malformed,missingRequest,page(missingRequest,[],held:[["providerMessageId":"deleted-message","reasonCode":"message_unavailable","participantEmails":[String]()]]))
    let unavailable=try malformed.all("settings").first{$0["providerMessageId"] as? String=="deleted-message"}!
    try check(unavailable["providerThreadId"] is NSNull && (unavailable["candidateIds"] as? [String])?.isEmpty==true,"deleted message evidence never invents a thread or candidate identity")

    let paging=try fixture("paging"),first=try paging.gmailSyncReadRequest()
    try apply(paging,first,page(first,[message("page-1")],next:["mode":"full","baselineHistoryId":"80","pageToken":"next"],more:true))
    try check(try !(paging.gmailSyncStatus()["lastSuccessAt"] is String) && paging.gmailSyncStatus()["newReplyCount"] as? Int==0,"partial page cannot announce complete coverage")
    let partial=try paging.gmailSyncReadRequest()
    try paging.recordGmailSyncFailure(["generation":partial["generation"]!,"errorCode":"network_failed","message":"Fixture network failure."])
    try check((try paging.gmailSyncReadRequest()["cursor"] as? Record)?["pageToken"] as? String=="next","network failure preserves exact page cursor")
    try rejects("baseline mismatch") { try apply(paging,partial,page(partial,[],next:["mode":"history","historyId":"81"])) }
    try apply(paging,partial,page(partial,[message("page-2")],next:["mode":"history","historyId":"80"]))
    try check(try !(paging.gmailSyncStatus()["lastSuccessAt"] is String) && paging.gmailSyncStatus()["newReplyCount"] as? Int==0,"full listing waits for history catch-up before claiming completion")
    let catchup=try paging.gmailSyncReadRequest();try apply(paging,catchup,page(catchup,[],next:["mode":"history","historyId":"80"]))
    try check(try paging.gmailSyncStatus()["newReplyCount"] as? Int==2 && paging.all("tasks").first{$0["reviewKind"] as? String=="gmail-sync-error"}?["completed"] as? Bool==true,"terminal history page aggregates counts and resolves error task")
    let history=try paging.gmailSyncReadRequest()
    try rejects("history regression") { try apply(paging,history,page(history,[],next:["mode":"history","historyId":"79"])) }
    try rejects("premature history advance") { try apply(paging,history,page(history,[],next:["mode":"history","historyId":"81","pageToken":"next"],more:true)) }
    try paging.configureGmailSync(["enabled":false])
    try rejects("paused in-flight batch") { try apply(paging,history,page(history,[])) }
    try paging.recordGmailSyncFailure(["generation":history["generation"]!,"errorCode":"stale","message":"Old callback"])
    try check(try paging.gmailSyncStatus()["status"] as? String=="disabled","late failure cannot override disabled state")
    let savedScope=try paging.gmailSyncStatus()["since"] as! String
    try rejects("rescan requires explicit confirmation") { try paging.resetGmailSyncCursor([:]) }
    try paging.resetGmailSyncCursor(["confirmed":true])
    try check(try paging.gmailSyncStatus()["since"] as? String==savedScope && paging.gmailSyncStatus()["historyMode"] as? String=="all" && (paging.gmailSyncStatus()["cursor"] as? Record)?.isEmpty==true && paging.gmailSyncStatus()["enabled"] as? Bool==false,"rescan preserves scope mailbox and paused state")

    let mailbox=try fixture("mailbox"),mailRequest=try mailbox.gmailSyncReadRequest()
    try apply(mailbox,mailRequest,page(mailRequest,[message("same-id")]))
    try mailbox.setGmailSyncConnection(["connected":true,"accountAddress":"second@example.test"])
    try check(try mailbox.gmailSyncStatus()["enabled"] as? Bool==false && !(mailbox.gmailSyncStatus()["since"] is String),"different mailbox has no inherited enablement or scope")
    try mailbox.configureGmailSync(["enabled":true,"confirmed":true,"historyMode":"all"])
    let second=try mailbox.gmailSyncReadRequest();try apply(mailbox,second,page(second,[message("same-id",["to":["second@example.test"]])]))
    try check(try mailbox.all("externalMessages").count==2,"Gmail IDs are deduplicated within mailbox, not globally")
    try mailbox.setGmailSyncConnection(["connected":true,"accountAddress":account]);try mailbox.configureGmailSync(["enabled":true,"confirmed":true])
    try check((try mailbox.gmailSyncReadRequest()["cursor"] as? Record)?["historyId"] as? String=="100","returning mailbox resumes its own retained scope and cursor")
    print("PASS: Gmail opt-in scopes, mailbox isolation, atomic pages, exact identity, human/automatic notices, follow-up holds, duplicate reconciliation and durable cursors; fixture databases only.")
}
