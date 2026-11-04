import Foundation
import CryptoKit
import CoreFoundation

// Native-only Gmail evidence reconciliation. Every mutation is called inside
// Store.command's transaction; no OAuth token or client secret is stored here.
extension Store {
    private static func gmailHash(_ value:String)->String { SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined() }
    static func gmailEmail(_ value:String) throws -> String {
        let address=value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard address.count<=320,address.range(of:"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$",options:.regularExpression) != nil else { throw StoreError(message:"Gmail sync requires an exact email address.") }
        return address
    }
    private func gmailText(_ value:Any?,_ label:String,_ maximum:Int=500) throws -> String {
        guard let text=value as? String,!text.isEmpty,text.count<=maximum,!text.contains("\0") else { throw StoreError(message:"Gmail sync returned an invalid \(label).") }; return text
    }
    private func gmailInteger(_ value:Any?) throws -> Int {
        guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue>=0,number.doubleValue.rounded()==number.doubleValue,number.doubleValue<Double(Int.max) else { throw StoreError(message:"Gmail sync returned an invalid count or revision.") }; return number.intValue
    }
    private func gmailEmptyState()->Record { ["id":"gmail-sync","connected":false,"enabled":false,"status":"disabled","generation":0,"revision":0,"cursor":Record(),"since":NSNull(),"historyMode":NSNull(),"accountAddress":NSNull(),"contactFingerprint":"","importedMessages":0,"importedReplies":0,"importedMeetingResponses":0,"importedSent":0,"automaticNotices":0,"heldMessages":0,"newReplyCount":0,"pendingScanReplies":0,"schemaVersion":1] }
    private func gmailSaved() throws -> Record { try all("settings").first { $0["id"] as? String == "gmail-sync" } ?? gmailEmptyState() }
    private func gmailContacts() throws -> (map:[String:[Record]],fingerprint:String) {
        var map:[String:[Record]]=[:]
        for agent in try all("agents") {
            let id=agent["id"] as? String ?? "",source=(agent["source"] as? String ?? "").lowercased()
            guard !id.isEmpty,agent["datasetId"] as? String == "live",agent["sample"] as? Bool != true,agent["dataset"] as? String != "sample",!id.hasPrefix("sample-"),!source.contains("sample"),!source.contains("fictional"),let email=try? Self.gmailEmail(agent["email"] as? String ?? "") else { continue }
            map[email,default:[]].append(agent)
        }
        let identities=map.keys.sorted().flatMap { email in (map[email] ?? []).compactMap{$0["id"] as? String}.sorted().map{email+"\0"+$0} }
        return (map,Self.gmailHash(identities.joined(separator:"\n")))
    }
    func gmailSyncStatus() throws -> Record {
        var state=try gmailSaved(); let contacts=try gmailContacts()
        let client=try gmailClientConfiguration()["clientId"] as? String ?? ""
        state["configuredClientId"]=client;state["clientConfigured"] = !client.isEmpty
        if state["importedMeetingResponses"]==nil { state["importedMeetingResponses"]=0 }
        state["uniqueCandidateCount"]=contacts.map.values.filter{$0.count==1}.count
        state["ambiguousCandidateCount"]=contacts.map.values.filter{$0.count>1}.reduce(0){$0+$1.count}
        for key in ["lastSuccessAt","lastAttemptAt","lastAppliedAt","lastError","errorCode"] where state[key]==nil { state[key]=NSNull() }
        return state
    }
    func setGmailSyncConnection(_ p:Record) throws {
        guard Set(p.keys).isSubset(of:["connected","accountAddress"]),let connected=p["connected"] as? Bool else { throw StoreError(message:"Use a verified native Gmail connection result.") }
        var state=try gmailSaved(); let generation=(state["generation"] as? Int ?? 0)+1
        if connected {
            let account=try Self.gmailEmail(gmailText(p["accountAddress"],"mailbox",320))
            if let old=state["accountAddress"] as? String,old != account {
                var archived=state;archived["id"]="gmail-sync-account-"+Self.gmailHash(old);archived["enabled"]=false;archived["connected"]=false
                try put("settings",archived)
                state=try all("settings").first{$0["id"] as? String == "gmail-sync-account-"+Self.gmailHash(account)} ?? gmailEmptyState()
                state["id"]="gmail-sync"
            }
            state["accountAddress"]=account
        }
        state["connected"]=connected;state["enabled"]=false;state["status"]="disabled";state["generation"]=generation
        state["revision"]=(state["revision"] as? Int ?? 0)+1;state["updatedAt"]=Store.now();state["lastError"]=NSNull();state["errorCode"]=NSNull()
        try put("settings",state)
    }
    func configureGmailSync(_ p:Record) throws {
        guard Set(p.keys).isSubset(of:["enabled","confirmed","historyMode"]),let enabled=p["enabled"] as? Bool else { throw StoreError(message:"Choose whether Gmail sync is enabled.") }
        var state=try gmailSaved()
        if enabled {
            guard p["confirmed"] as? Bool == true,state["connected"] as? Bool == true,state["accountAddress"] is String else { throw StoreError(message:"Connect and explicitly confirm the Gmail mailbox before enabling sync.") }
            if !(state["since"] is String) {
                guard let mode=p["historyMode"] as? String,["newonly","last60days","all"].contains(mode) else { throw StoreError(message:"Choose the Gmail history scope explicitly before the first sync.") }
                let start:Date = mode=="all" ? Date(timeIntervalSince1970:0) : Date().addingTimeInterval(mode=="last60days" ? -60*86400 : 0)
                let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
                state["since"]=formatter.string(from:start);state["historyMode"]=mode;state["cursor"]=Record();state["contactFingerprint"]=try gmailContacts().fingerprint
            } else if let mode=p["historyMode"] as? String,mode != state["historyMode"] as? String { throw StoreError(message:"Resuming Gmail preserves the original history scope; it cannot silently expand it.") }
        }
        if enabled != (state["enabled"] as? Bool == true) { state["generation"]=(state["generation"] as? Int ?? 0)+1 }
        state["enabled"]=enabled;state["status"]=enabled ? "ready" : "disabled";state["updatedAt"]=Store.now();state["newReplyCount"]=0
        if !enabled { state["lastError"]=NSNull();state["errorCode"]=NSNull() }
        try put("settings",state)
    }
    func gmailSyncReadRequest() throws -> Record {
        let state=try gmailSaved(),contacts=try gmailContacts()
        guard state["enabled"] as? Bool == true,state["connected"] as? Bool == true,let account=state["accountAddress"] as? String,let since=state["since"] as? String,Store.activityEventDate(since) != nil else { throw StoreError(message:"Enable the connected Gmail mailbox before scanning.") }
        // Duplicate addresses are deliberate: the reader can hold ambiguous
        // envelopes before fetching their bodies, while Store rechecks owners.
        let emails=contacts.map.keys.sorted().flatMap{Array(repeating:$0,count:contacts.map[$0]!.count)}
        return ["accountAddress":account,"generation":state["generation"] ?? 0,"revision":state["revision"] ?? 0,"since":since,"historyMode":state["historyMode"] ?? "","contactFingerprint":contacts.fingerprint,"emails":emails,"cursor":state["contactFingerprint"] as? String == contacts.fingerprint ? (state["cursor"] as? Record ?? [:]) : [:]]
    }
    func resetGmailSyncCursor(_ p:Record) throws {
        guard Set(p.keys)==["confirmed"],p["confirmed"] as? Bool==true else { throw StoreError(message:"Confirm a rescan within the already approved Gmail history scope.") }
        var state=try gmailSaved()
        guard state["connected"] as? Bool==true,state["since"] is String else { throw StoreError(message:"Reconnect the same mailbox and choose its initial scope before rescanning.") }
        state["cursor"]=Record();state["generation"]=(state["generation"] as? Int ?? 0)+1;state["revision"]=(state["revision"] as? Int ?? 0)+1
        state["status"]=(state["enabled"] as? Bool==true) ? "ready" : "disabled";state["contactFingerprint"]=try gmailContacts().fingerprint
        state["pendingScanReplies"]=0;state["newReplyCount"]=0;state["hasMore"]=true;state["updatedAt"]=Store.now()
        try put("settings",state)
    }
    private func gmailCursor(_ input:Any?) throws -> Record {
        guard let cursor=input as? Record,Set(cursor.keys).isSubset(of:["mode","historyId","baselineHistoryId","pageToken"]) else { throw StoreError(message:"Gmail sync returned an invalid cursor.") }
        if cursor.isEmpty { return cursor }
        guard let mode=cursor["mode"] as? String,["history","full"].contains(mode) else { throw StoreError(message:"Gmail sync returned an invalid scan mode.") }
        let key=mode=="history" ? "historyId" : "baselineHistoryId"
        let history=try gmailText(cursor[key],"history ID",30)
        guard history.range(of:"^[0-9]+$",options:.regularExpression) != nil,UInt64(history) != nil,cursor[mode=="history" ? "baselineHistoryId" : "historyId"]==nil else { throw StoreError(message:"Gmail sync returned an invalid history ID.") }
        if let token=cursor["pageToken"] { _=try gmailText(token,"page token",4096) }
        return cursor
    }
    private func gmailSame(_ a:Record,_ b:Record)->Bool { NSDictionary(dictionary:a).isEqual(to:b) }
    @discardableResult private func gmailTask(_ key:String,title:String,description:String,agentId:String?=nil,extra:Record=[:]) throws -> String {
        var task=try all("tasks").first{$0["reviewKey"] as? String == key && $0["completed"] as? Bool != true} ?? ["id":UUID().uuidString,"createdAt":Store.now(),"completed":false,"assignee":try operatorName(),"repeatDays":0]
        task["reviewKey"]=key;task["title"]=String(title.prefix(200));task["description"]=description;task["type"]="Review";task["priority"]="High";task["dueDate"]=Store.day();task["updatedAt"]=Store.now()
        if let agentId { task["agentId"]=agentId };for (key,value) in extra { task[key]=value };try put("tasks",task)
        let id=task["id"] as! String;guard try get("tasks",id)["completed"] as? Bool == false else { throw StoreError(message:"The Gmail review task could not be verified.") };return id
    }
    @discardableResult private func gmailPause(_ aid:String,time:String,messageID:String,reason:String="inbound_reply") throws -> Bool {
        guard let received=Store.activityEventDate(time) else { throw StoreError(message:"Gmail reply time is invalid.") }
        try pauseSequencesForImportedReply(agentId:aid,occurredAt:time,messageId:messageID)
        try holdOutboxForImportedReply(agentId:aid,occurredAt:time,messageId:messageID)
        var held=try all("sequences").contains{$0["agentId"] as? String==aid && $0["replyMessageId"] as? String==messageID} || all("outboxJobs").contains{$0["agentId"] as? String==aid && $0["replyMessageId"] as? String==messageID && $0["state"] as? String=="held"}
        for var draft in try all("drafts") where draft["agentId"] as? String == aid && draft["state"] as? String == "draft" && draft["approvalState"] as? String != "rejected" {
            if let created=Store.activityEventDate(draft["createdAt"] as? String ?? ""),created>received { continue }
            draft["approvalState"]="paused_reply";draft["replyMessageId"]=messageID;draft["pauseReason"]=reason;draft["updatedAt"]=Store.now();try put("drafts",draft);held=true
        }
        for var task in try all("tasks") where task["agentId"] as? String == aid && task["completed"] as? Bool != true && ["Call","Message","Email","Check-in"].contains(task["type"] as? String ?? "") {
            if let created=Store.activityEventDate(task["createdAt"] as? String ?? ""),created>received { continue }
            task["followUpState"]="paused_reply";task["pauseReason"]=reason;task["replyMessageId"]=messageID;task["updatedAt"]=Store.now();try put("tasks",task);held=true
        }
        if reason=="meeting_accepted" {
            for kind in ["sequences","outboxJobs"] {
                for var record in try all(kind) where record["agentId"] as? String==aid && record["replyMessageId"] as? String==messageID {
                    record["pauseReason"]=reason
                    if kind=="outboxJobs" { record["reason"]="A meeting acceptance needs review before further outreach." }
                    try put(kind,record)
                }
            }
        }
        return held
    }
    private func gmailPauseIdentity(_ ids:[String],holdID:String,taskID:String) throws {
        let candidates=Set(ids),now=Store.now()
        let drafts=try all("drafts").filter{candidates.contains($0["agentId"] as? String ?? "") && $0["state"] as? String=="draft" && $0["approvalState"] as? String != "rejected"}
        let sequences=Set(drafts.compactMap{$0["sequenceId"] as? String})
        for var sequence in try all("sequences") where candidates.contains(sequence["agentId"] as? String ?? "") && (sequence["state"] as? String=="active" || (sequence["state"] as? String=="completed" && sequences.contains(sequence["id"] as? String ?? ""))) {
            if sequence["state"] as? String=="active" { sequence["state"]="paused" }
            sequence["pendingOutputState"]="paused_identity";sequence["pauseReason"]="gmail_identity_review";sequence["identityReviewTaskId"]=taskID;sequence["identityHoldId"]=holdID;sequence["updatedAt"]=now;try put("sequences",sequence)
        }
        for var draft in drafts { draft["approvalState"]="blocked_contact";draft["pauseReason"]="gmail_identity_review";draft["identityReviewTaskId"]=taskID;draft["identityHoldId"]=holdID;draft["updatedAt"]=now;try put("drafts",draft) }
        for var task in try all("tasks") where candidates.contains(task["agentId"] as? String ?? "") && task["completed"] as? Bool != true && ["Call","Message","Email","Check-in"].contains(task["type"] as? String ?? "") {
            task["followUpState"]="paused_identity";task["pauseReason"]="gmail_identity_review";task["identityReviewTaskId"]=taskID;task["identityHoldId"]=holdID;task["updatedAt"]=now;try put("tasks",task)
        }
    }
    func gmailSyncHoldReason(agentId:String) throws -> String? {
        if try all("settings").contains(where:{ ($0["id"] as? String ?? "").hasPrefix("gmail-sync-held-") && $0["state"] as? String == "pending" && ($0["candidateIds"] as? [String] ?? []).contains(agentId) && $0["possibleReply"] as? Bool == true }) { return "Gmail evidence for this contact needs identity review. Resolve the held email before further outreach." };return nil
    }
    private func gmailHold(_ evidence:Record,account:String,contacts:[String:[Record]],reason:String) throws {
        let guid=try gmailText(evidence["providerMessageId"],"held message ID",250)
        let thread:String?
        if evidence["providerThreadId"]==nil,reason=="message_unavailable" { thread=nil }
        else { thread=try gmailText(evidence["providerThreadId"],"held conversation ID",250) }
        guard !guid.contains(where:{$0.isWhitespace}),thread?.contains(where:{$0.isWhitespace}) != true else { throw StoreError(message:"Held Gmail evidence requires exact provider IDs.") }
        let participants=(evidence["participantEmails"] as? [String] ?? []).compactMap{try? Self.gmailEmail($0)}
        let ids=Set(participants.flatMap{contacts[$0] ?? []}.compactMap{$0["id"] as? String}).sorted()
        let id="gmail-sync-held-"+Self.gmailHash(account+"\0"+guid)
        let possible=evidence["direction"] as? String != "outbound"
        let source=["gmail:"+account+":"+guid]+(thread.map{["Gmail thread "+$0]} ?? [])
        let taskID=try gmailTask(id,title:"Review unlinked Gmail evidence",description:"This Gmail message was not attached to a contact because its identity or content could not be safely reconciled. Review the exact message in Gmail and correct saved contact identities, then rescan the approved scope. Possible reply matches have outreach held for identity review. No CRM status was changed.\n\nMailbox: \(account)\nMessage: \(guid)\nThread: \(thread ?? "Unavailable")\nReason: \(reason)\nCandidate IDs: \(ids.joined(separator:", "))",extra:["reviewKind":"gmail-sync-held","providerMessageId":guid,"sourceRefs":source,"relatedMessageIds":[guid],"candidateIds":ids,"decisionOptions":["Correct contact identity and rescan","Keep evidence unlinked and outreach held"]])
        var hold:Record=["id":id,"state":"pending","accountAddress":account,"providerMessageId":guid,"providerThreadId":thread as Any? ?? NSNull(),"reasonCode":reason,"candidateIds":ids,"possibleReply":possible,"reviewTaskId":taskID,"updatedAt":Store.now()]
        if let old=try all("settings").first(where:{$0["id"] as? String==id}) { hold["createdAt"]=old["createdAt"] ?? Store.now();hold["candidateIds"]=Array(Set((old["candidateIds"] as? [String] ?? [])+ids)).sorted() } else { hold["createdAt"]=Store.now() }
        try put("settings",hold)
        if possible { try gmailPauseIdentity(ids,holdID:id,taskID:taskID) }
    }
    private func gmailClearHold(_ account:String,_ guid:String,_ messageID:String) throws {
        let id="gmail-sync-held-"+Self.gmailHash(account+"\0"+guid)
        guard var hold=try all("settings").first(where:{$0["id"] as? String==id}) else { return }
        hold["state"]="resolved";hold["resolvedAt"]=Store.now();hold["externalMessageId"]=messageID;try put("settings",hold)
    }

    // Changes classification metadata only. The original provider body/envelope,
    // external ID and existing review task (including completion) remain intact.
    private func gmailApplyMeetingResponse(_ original:Record,evidence:Record) throws -> Record {
        var record=original
        let id=record["id"] as! String,aid=record["agentId"] as! String,response=evidence["response"] as! String
        if record["messageClass"] as? String=="meeting_response" {
            guard record["meetingResponse"] as? String==response,let old=record["meetingResponseEvidence"] as? Record,gmailSame(old,evidence) else { throw StoreError(message:"Saved meeting-response evidence conflicts with this classification. Review the original message.") }
            return record
        }
        let account=record["accountAddress"] as! String,guid=record["providerMessageId"] as! String,thread=record["providerThreadId"] as! String,time=record["occurredAt"] as! String
        let held=response=="accepted" ? try gmailPause(aid,time:time,messageID:id,reason:"meeting_accepted") : false
        record["messageClass"]="meeting_response";record["meetingResponse"]=response;record["meetingResponseEvidence"]=evidence
        record["followUpsPaused"] = held || record["followUpsPaused"] as? Bool==true
        record["classificationUpdatedAt"]=Store.now()
        let title="Review meeting response — "+response.capitalized
        let policy=response=="accepted" ? "This verified calendar acceptance pauses eligible outreach for review." : "This verified calendar response does not add an acceptance pause. Existing holds are preserved."
        let description="\(policy) Review the meeting and decide the next step. No CRM status was changed. Completing this task does not authorize a send.\n\nMailbox: \(account)\nMessage: \(guid)\nThread: \(thread)\nReceived: \(time)\nSaved correspondence: \(id)\nCalendar response: \(response)\nCalendar UID: \(evidence["uid"] as! String)"
        let extra:Record=["reviewKind":"gmail-sync-meeting-response","externalMessageId":id,"providerMessageId":guid,"sourceRefs":["externalMessages:"+id,"gmail:"+account+":"+guid],"relatedMessageIds":[guid],"decisionOptions":["Review meeting details and next step","Keep existing outreach holds","Prepare a response for review"],"meetingResponse":response]
        let tasks=try all("tasks")
        let existing=tasks.first{$0["id"] as? String==record["reviewTaskId"] as? String && record["reviewTaskId"] is String} ?? tasks.first{$0["externalMessageId"] as? String==id && ($0["reviewKind"] as? String ?? "").hasPrefix("gmail-sync-")}
        if var task=existing {
            task["title"]=title;task["description"]=description;task["updatedAt"]=Store.now()
            for (key,value) in extra { task[key]=value };try put("tasks",task);record["reviewTaskId"]=task["id"]
        } else {
            record["reviewTaskId"]=try gmailTask("gmail-sync-reply:"+id,title:title,description:description,agentId:aid,extra:extra)
        }
        try put("externalMessages",record);return record
    }
    func reclassifyGmailMeetingResponse(_ p:Record) throws {
        guard Set(p.keys)==["confirmed","externalMessageId","accountAddress","providerMessageId","providerThreadId","calendarText"],p["confirmed"] as? Bool==true else { throw StoreError(message:"Confirm the exact saved Gmail message and verified calendar evidence before reclassifying it.") }
        let id=try gmailText(p["externalMessageId"],"saved message ID",250),record=try get("externalMessages",id)
        let account=try Self.gmailEmail(gmailText(p["accountAddress"],"mailbox",320))
        guard record["provider"] as? String=="gmail",record["syncSource"] as? String=="gmail-native",record["channel"] as? String=="Email",record["direction"] as? String=="inbound",record["accountAddress"] as? String==account,record["to"] as? String==account,
              record["providerMessageId"] as? String==p["providerMessageId"] as? String,record["providerThreadId"] as? String==p["providerThreadId"] as? String,
              let sender=record["from"] as? String,let aid=record["agentId"] as? String else { throw StoreError(message:"The saved Gmail identity does not match this classification request.") }
        let contacts=try gmailContacts(),matches=contacts.map[sender] ?? []
        guard matches.count==1,matches[0]["id"] as? String==aid,let text=p["calendarText"] as? String,
              let evidence=GmailAPIClient.meetingResponse(calendarText:text,sender:sender,recipient:account) else { throw StoreError(message:"A unique contact and exact calendar reply attendee are required; subject text is not sufficient.") }
        let previous=record["messageClass"] as? String
        _=try gmailApplyMeetingResponse(record,evidence:evidence)
        if previous != "meeting_response" {
            let key=(try gmailSaved()["accountAddress"] as? String)==account ? "gmail-sync" : "gmail-sync-account-"+Self.gmailHash(account)
            if var state=try all("settings").first(where:{$0["id"] as? String==key}) {
                let rows=try all("externalMessages").filter{$0["syncSource"] as? String=="gmail-native" && $0["accountAddress"] as? String==account}
                for pair in [("importedReplies","received_reply"),("importedMeetingResponses","meeting_response"),("automaticNotices","automatic_notice"),("importedSent","sent_copy")] { state[pair.0]=rows.filter{$0["messageClass"] as? String==pair.1}.count }
                // Reclassification is not newly received mail and must not replay a toast.
                state["newReplyCount"]=0
                if previous=="received_reply" { state["pendingScanReplies"]=max(0,(state["pendingScanReplies"] as? Int ?? 0)-1) }
                state["classificationUpdatedAt"]=Store.now();try put("settings",state)
            }
        }
    }

    func applyGmailSyncBatch(request:Record,batch:Record) throws {
        var state=try gmailSaved();let contacts=try gmailContacts(),expected=try gmailSyncReadRequest()
        let replay=Self.gmailHash(String(decoding:try JSONSerialization.data(withJSONObject:["request":request,"batch":batch],options:.sortedKeys),as:UTF8.self))
        if state["enabled"] as? Bool==true,request["generation"] as? Int==state["generation"] as? Int,request["contactFingerprint"] as? String==contacts.fingerprint,state["lastAppliedBatchKey"] as? String==replay { return }
        guard gmailSame(request,expected) else { throw StoreError(message:"Gmail configuration, mailbox, cursor or contact identities changed during this scan. Retry without advancing the cursor.") }
        guard Set(batch.keys).isSubset(of:["accountAddress","fromCursor","nextCursor","hasMore","messages","scannedCount","observedAt","held"]),let rows=batch["messages"] as? [Record],rows.count<=500,let hasMore=batch["hasMore"] as? Bool else { throw StoreError(message:"Gmail sync returned an invalid batch.") }
        let account=try Self.gmailEmail(gmailText(batch["accountAddress"],"mailbox",320)),from=try gmailCursor(batch["fromCursor"]),next=try gmailCursor(batch["nextCursor"])
        let scanned=try gmailInteger(batch["scannedCount"]),held=batch["held"] as? [Record] ?? []
        guard account==state["accountAddress"] as? String,gmailSame(from,request["cursor"] as? Record ?? [:]),!next.isEmpty,scanned<=5000,rows.count+held.count<=scanned,held.count<=500,(next["pageToken"] is String)==hasMore,(!hasMore || !gmailSame(from,next)),(hasMore || next["mode"] as? String=="history") else { throw StoreError(message:"Gmail page does not match the connected mailbox or requested cursor.") }
        if from["mode"] as? String=="history",next["mode"] as? String=="history" {
            let oldID=UInt64(from["historyId"] as? String ?? "")!,newID=UInt64(next["historyId"] as? String ?? "")!
            guard newID>=oldID,(!hasMore || newID==oldID) else { throw StoreError(message:"Gmail history regressed or advanced before all pages were applied.") }
        }
        if from["mode"] as? String=="full" {
            let baseline=from["baselineHistoryId"] as? String
            guard next["mode"] as? String == (hasMore ? "full" : "history"),next[hasMore ? "baselineHistoryId" : "historyId"] as? String == baseline else { throw StoreError(message:"Gmail full-scan baseline changed during pagination.") }
        }
        let now=Store.now(),observed=try gmailText(batch["observedAt"] ?? now,"observation time",50)
        guard let observedDate=Store.activityEventDate(observed),observedDate<=Date().addingTimeInterval(1),let floor=Store.activityEventDate(state["since"] as? String ?? "") else { throw StoreError(message:"Gmail scan times are invalid.") }
        var incoming=0,outgoing=0,notices=0,meetings=0,reclassifiedReplies=0,reclassifiedNotices=0,heldCount=0,seen=Set<String>()
        for evidence in held {
            guard Set(evidence.keys).isSubset(of:["providerMessageId","providerThreadId","reasonCode","participantEmails","direction"]) else { throw StoreError(message:"Unexpected held Gmail evidence fields.") }
            let reason=try gmailText(evidence["reasonCode"],"hold reason",100)
            try gmailHold(evidence,account:account,contacts:contacts.map,reason:reason);heldCount+=1
        }
        for row in rows {
            guard Set(row.keys).isSubset(of:["providerMessageId","providerThreadId","accountAddress","direction","from","to","cc","bcc","occurredAt","subject","body","bodyKind","labels","autoSubmitted","precedence","returnPath","inReplyTo","calendarText"]) else { throw StoreError(message:"Unexpected Gmail message fields.") }
            let guid=try gmailText(row["providerMessageId"],"message ID",250),thread=try gmailText(row["providerThreadId"],"thread ID",250)
            guard !guid.contains(where:{$0.isWhitespace}),!thread.contains(where:{$0.isWhitespace}),seen.insert(guid).inserted else { throw StoreError(message:"Gmail returned repeated or invalid provider IDs.") }
            let sender=try Self.gmailEmail(gmailText(row["from"],"sender",320))
            guard let rawTo=row["to"] as? [String],let cc=row["cc"] as? [String],let bcc=row["bcc"] as? [String],let labels=row["labels"] as? [String],rawTo.count+cc.count+bcc.count<=100 else { throw StoreError(message:"Gmail recipient evidence is malformed.") }
            let to=try rawTo.map{try Self.gmailEmail($0)},others=try (cc+bcc).map{try Self.gmailEmail($0)}
            let direction=try gmailText(row["direction"],"direction",20),time=try gmailText(row["occurredAt"],"message time",50)
            guard ["inbound","outbound"].contains(direction),let date=Store.activityEventDate(time),date<=Date().addingTimeInterval(300) else { throw StoreError(message:"Gmail direction or message time is invalid.") }
            if date<floor { continue }
            let occurred=ISO8601DateFormatter().string(from:date)
            let participants=[sender]+to+others
            var hold:Record=["providerMessageId":guid,"providerThreadId":thread,"participantEmails":participants,"direction":direction]
            let candidate=direction=="inbound" ? sender : (to.first ?? "")
            let matches=contacts.map[candidate] ?? []
            let envelope=to.count==1 && others.isEmpty && sender != to.first && (direction=="inbound" ? (to.first==account && sender != account && !labels.contains("SENT")) : (sender==account && labels.contains("SENT"))) && !labels.contains("DRAFT")
            if !envelope || (row["accountAddress"] is String && row["accountAddress"] as? String != account) {
                hold["direction"]=direction;try gmailHold(hold,account:account,contacts:contacts.map,reason:"envelope_unverified");heldCount+=1;continue
            }
            if matches.isEmpty { continue }
            if matches.count != 1 { try gmailHold(hold,account:account,contacts:contacts.map,reason:"ambiguous_candidate_email");heldCount+=1;continue }
            guard let body=row["body"] as? String,body.count<=50000,!body.contains("\0"),let kind=row["bodyKind"] as? String,["text","unavailable"].contains(kind),kind != "text" || !body.isEmpty,let subject=row["subject"] as? String,subject.count<=500 else { throw StoreError(message:"Gmail content is malformed or too large.") }
            let auto=(row["autoSubmitted"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            let precedence=(row["precedence"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            let automatic=direction=="inbound" && ((!auto.isEmpty && auto != "no") || ["bulk","list","junk"].contains(precedence) || (row["returnPath"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines)=="<>")
            var meeting:Record?
            if row["calendarText"] != nil {
                guard direction=="inbound",let calendar=row["calendarText"] as? String,let parsed=GmailAPIClient.meetingResponse(calendarText:calendar,sender:sender,recipient:account) else {
                    try gmailHold(hold,account:account,contacts:contacts.map,reason:"calendar_response_unverified");heldCount+=1;continue
                }
                meeting=parsed
            }
            let aid=matches[0]["id"] as! String,id="external-"+Self.gmailHash("gmail\0"+account+"\0"+guid)
            let core:Record=["agentId":aid,"channel":"Email","provider":"gmail","accountAddress":account,"providerMessageId":guid,"providerThreadId":thread,"direction":direction,"from":sender,"to":to[0],"occurredAt":occurred,"subject":subject,"body":body]
            let existing=try all("externalMessages").filter{$0["provider"] as? String=="gmail" && $0["accountAddress"] as? String==account && $0["providerMessageId"] as? String==guid}
            if let saved=existing.first {
                let equal=existing.count==1 && core.allSatisfy { key,value in
                    if key=="occurredAt" { return Store.activityEventDate(saved[key] as? String ?? "").map{ISO8601DateFormatter().string(from:$0)}==occurred }
                    return (saved[key] as? String)==(value as? String)
                }
                if !equal { try gmailHold(hold,account:account,contacts:contacts.map,reason:"saved_evidence_conflict");heldCount+=1;continue }
                if let meeting {
                    _=try gmailApplyMeetingResponse(saved,evidence:meeting)
                    if saved["messageClass"] as? String != "meeting_response" {
                        meetings+=1
                        if saved["messageClass"] as? String=="received_reply" { reclassifiedReplies+=1 }
                        if saved["messageClass"] as? String=="automatic_notice" { reclassifiedNotices+=1 }
                    }
                }
                try gmailClearHold(account,guid,saved["id"] as! String);continue
            }
            var record=core;record["id"]=id;record["content"]=core;record["bodyKind"]=kind;record["syncSource"]="gmail-native";record["messageClass"]=automatic ? "automatic_notice" : (direction=="inbound" ? "received_reply" : "sent_copy")
            record["autoSubmitted"]=auto;record["precedence"]=precedence;record["labels"]=labels;record["importedAt"]=now;record["schemaVersion"]=2;record["sourceEvidence"]=["method":"gmail_api_readonly","accountAddress":account,"providerMessageId":guid,"providerThreadId":thread,"observedAt":observed]
            try put("externalMessages",record)
            if let meeting {
                record=try gmailApplyMeetingResponse(record,evidence:meeting);meetings+=1
            } else if direction=="inbound" {
                let followUpsPaused = automatic ? false : try gmailPause(aid,time:occurred,messageID:id)
                if !automatic { incoming+=1 } else { notices+=1 }
                let taskID=try gmailTask("gmail-sync-reply:"+id,title:automatic ? "Review automatic email notice" : "Review new email reply — "+(matches[0]["name"] as? String ?? "Contact"),description:"Review this exact Gmail \(automatic ? "automatic notice; it was not treated as a human reply and did not pause follow-ups" : "reply before resuming outreach; existing follow-ups were held where the reply is newer"). No CRM status was changed. Completing this task does not authorize a send.\n\nMailbox: \(account)\nMessage: \(guid)\nThread: \(thread)\nReceived: \(occurred)\nSaved correspondence: \(id)",agentId:aid,extra:["reviewKind":automatic ? "gmail-sync-notice" : "gmail-sync-reply","externalMessageId":id,"providerMessageId":guid,"sourceRefs":["externalMessages:"+id,"gmail:"+account+":"+guid],"relatedMessageIds":[guid],"decisionOptions":["Review and prepare a response","Update status after review","Keep follow-up paused"]])
                record["reviewTaskId"]=taskID;record["followUpsPaused"] = followUpsPaused;try put("externalMessages",record)
            } else { outgoing+=1 }
            try gmailClearHold(account,guid,id)
        }
        let complete = !hasMore && from["mode"] as? String=="history"
        state["cursor"]=next;state["contactFingerprint"]=contacts.fingerprint;state["revision"]=(state["revision"] as? Int ?? 0)+1;state["status"]=complete ? "ready" : "syncing";state["lastAttemptAt"]=now;state["lastAppliedAt"]=now;state["hasMore"] = !complete
        let scanReplies=max(0,(state["pendingScanReplies"] as? Int ?? 0)+incoming-reclassifiedReplies);state["pendingScanReplies"]=complete ? 0 : scanReplies;state["newReplyCount"]=complete ? scanReplies : 0
        for (key,amount) in [("importedReplies",incoming-reclassifiedReplies),("importedMeetingResponses",meetings),("importedSent",outgoing),("automaticNotices",notices-reclassifiedNotices),("importedMessages",incoming+outgoing+notices+meetings-reclassifiedReplies-reclassifiedNotices)] { state[key]=max(0,(state[key] as? Int ?? 0)+amount) }
        state["heldMessages"]=try all("settings").filter{($0["id"] as? String ?? "").hasPrefix("gmail-sync-held-") && $0["accountAddress"] as? String==account && $0["state"] as? String=="pending"}.count
        state["newHeldCount"]=heldCount
        if complete { state["lastSuccessAt"]=observed;state["lastError"]=NSNull();state["errorCode"]=NSNull() }
        state["lastAppliedBatchKey"]=replay;try put("settings",state)
        if complete { for var task in try all("tasks") where task["reviewKind"] as? String=="gmail-sync-error" && task["accountAddress"] as? String==account && task["completed"] as? Bool != true { task["completed"]=true;task["completedAt"]=now;task["resolution"]="A later Gmail scan completed successfully.";try put("tasks",task) } }
    }
    func recordGmailSyncFailure(_ p:Record) throws {
        guard Set(p.keys).isSubset(of:["generation","message","errorCode","status"]) else { throw StoreError(message:"Unexpected Gmail sync failure fields.") }
        var state=try gmailSaved();guard state["enabled"] as? Bool==true,try gmailInteger(p["generation"])==state["generation"] as? Int else { return }
        let message=try gmailText(p["message"],"failure explanation",1000),code=try gmailText(p["errorCode"],"error code",100)
        guard code.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil else { throw StoreError(message:"Gmail error code is invalid.") }
        state["status"]="blocked";state["lastAttemptAt"]=Store.now();state["lastError"]=message;state["errorCode"]=code;state["newReplyCount"]=0;try put("settings",state)
        let account=state["accountAddress"] as? String ?? "unknown"
        try gmailTask("gmail-sync-error:"+account,title:"Restore Gmail sync",description:"Gmail sync could not finish. The saved cursor and history scope were preserved. Review the error, reconnect the same mailbox if needed, and retry. No email was sent.\n\nMailbox: \(account)\nError: \(code)\n\(message)",extra:["reviewKind":"gmail-sync-error","accountAddress":account,"sourceRefs":["settings:gmail-sync"],"decisionOptions":["Reconnect the same Gmail mailbox and retry","Pause Gmail sync"]])
    }
}
