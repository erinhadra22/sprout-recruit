import Foundation
import CryptoKit

// Deterministic persistence only. Every entry point must run inside Store.command's
// transaction. Provider trust is a native argument, never a value in a web payload.
enum WorkflowValidation {
    static func text(_ p: Record, _ key: String, _ limit: Int = 10000) throws -> String {
        guard let s = p[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count <= limit else {
            throw StoreError(message: "Please provide valid \(key).")
        }; return s
    }
    static func id(_ p: Record, _ key: String) throws -> String {
        let s = try text(p,key,180)
        guard s.range(of:"^[A-Za-z0-9_.:-]+$",options:.regularExpression) != nil else { throw StoreError(message:"Invalid \(key).") }; return s
    }
    static func digest(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    static func transcriptHash(_ text: String) -> String { SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
    static func blocked(_ agent: Record) -> Bool {
        agent["doNotContact"] as? Bool == true || ["Do not contact","Not interested","Not qualified","Lost"].contains(agent["status"] as? String ?? "")
    }
}

extension Store {
    private func workflowReplay(_ p: Record, type: String) throws -> Bool {
        let id = try WorkflowValidation.id(p,"eventId"), hash = try WorkflowValidation.digest(p)
        if let old = try all("workflowEvents").first(where:{$0["id"] as? String == id}) {
            guard old["payloadHash"] as? String == hash, old["type"] as? String == type else { throw StoreError(message:"This workflow event ID already has different content.") }; return true
        }; return false
    }
    private func workflowAudit(_ p: Record, type: String, workflowId: String? = nil) throws {
        var event: Record = ["id":try WorkflowValidation.id(p,"eventId"),"type":type,"payloadHash":try WorkflowValidation.digest(p),"recordedAt":Store.now(),"source":p["source"] as? String ?? "local","schemaVersion":1]
        if let wid=workflowId { event["workflowId"]=wid }
        if let aid=p["agentId"] { event["agentId"]=aid }
        try put("workflowEvents",event)
    }
    private func workflowContextRevision() throws -> Int {
        try all("settings").first(where:{$0["id"] as? String == "ai-context"})?["revision"] as? Int ?? 0
    }
    func recordWorkflowCall(_ p: Record, trustedProvider: Bool = false) throws {
        let source=try WorkflowValidation.text(p,"source",40)
        guard (source == "provider" && trustedProvider) || (source == "user_confirmed" && p["confirmed"] as? Bool == true) else { throw StoreError(message:"A verified provider receipt or your explicit call confirmation is required.") }
        let callId=try WorkflowValidation.id(p,"callId"), aid=try WorkflowValidation.id(p,"agentId"), outcome=try WorkflowValidation.text(p,"outcome",30)
        guard ["completed","connected","no_answer","voicemail","failed"].contains(outcome) else { throw StoreError(message:"Choose the actual terminal call outcome.") }
        let day=try WorkflowValidation.text(p,"occurredOn",10)
        guard Store.parseDay(day) != nil, day <= Store.day() else { throw StoreError(message:"Choose the actual call date, today or earlier.") }
        let occurrence = try p["occurredAt"].map { try Store.communicationOccurrence($0) }
        guard occurrence == nil || occurrence?.day == day else { throw StoreError(message:"The call date and timestamp must match.") }
        if try workflowReplay(p,type:"call") { return }
        var agent=try get("agents",aid)
        let wid="call-"+callId
        if let prior=try all("workflows").first(where:{$0["id"] as? String == wid}) {
            guard prior["agentId"] as? String == aid, prior["outcome"] as? String == outcome, prior["occurredOn"] as? String == day, prior["occurredAt"] as? String == occurrence?.timestamp else { throw StoreError(message:"That call already has a different final outcome. Reconcile it before changing the workflow.") }
            try workflowAudit(p,type:"call",workflowId:wid); return
        }
        let now=Store.now(), connected=["completed","connected"].contains(outcome)
        let notes=p["notes"] as? String ?? ""
        guard notes.count <= 10000 else { throw StoreError(message:"Call notes are too long.") }
        var activityId="workflow-"+wid+"-interaction"
        if let existing=p["interactionId"] as? String {
            let activity=try get("activities",existing)
            guard activity["agentId"] as? String == aid, activity["kind"] as? String == "interaction" else { throw StoreError(message:"The existing interaction belongs to a different contact.") }; activityId=existing
        } else {
            try put("activities",["id":activityId,"agentId":aid,"kind":"interaction","title":"Call — "+outcome.replacingOccurrences(of:"_",with:" "),"body":notes.isEmpty ? "Outcome confirmed; no conversation content inferred." : notes,"date":occurrence?.timestamp ?? day,"createdAt":now,"recordedAt":now,"author":"Erin Hadra","pinned":false,"workflowId":wid,"confirmationSource":source])
        }
        let before=agent["status"] as? String ?? ""
        // Advance only early stages. Closed, advanced and suppression states are never regressed.
        if connected && !WorkflowValidation.blocked(agent) && ["","Identified","Contacted"].contains(before) { agent["status"]="Called"; agent["statusAt"]=now }
        if connected { agent["lastInteraction"]=max(day,agent["lastInteraction"] as? String ?? "") }
        try put("agents",agent)
        var workflow: Record = ["id":wid,"callId":callId,"agentId":aid,"outcome":outcome,"occurredOn":day,"source":source,"notes":notes,"interactionId":activityId,"state":connected ? "waiting_for_transcript" : "no_conversation","recordingState":connected ? "unavailable" : "not_applicable","transcriptState":connected ? "unavailable" : "not_applicable","summaryState":connected ? "blocked_missing_transcript" : "not_applicable","contextRevision":try workflowContextRevision(),"createdAt":now,"updatedAt":now,"schemaVersion":1]
        if let occurrence { workflow["occurredAt"] = occurrence.timestamp }
        try put("workflows",workflow)
        try workflowAudit(p,type:"call",workflowId:wid)
    }
    func recordWorkflowArtifact(_ p: Record, trustedProvider: Bool = false) throws {
        let source=try WorkflowValidation.text(p,"source",40)
        guard trustedProvider || (source == "user_transcript" && p["confirmed"] as? Bool == true) else { throw StoreError(message:"A verified adapter or explicitly supplied transcript is required.") }
        if try workflowReplay(p,type:"artifact") { return }
        let wid=try WorkflowValidation.id(p,"workflowId"); var w=try get("workflows",wid)
        guard ["completed","connected"].contains(w["outcome"] as? String ?? ""), w["appliedResultId"] == nil else { throw StoreError(message:"This call cannot accept another transcript or recording result.") }
        let kind=try WorkflowValidation.text(p,"kind",40), ref=try WorkflowValidation.text(p,"sourceRef",500)
        guard p["callId"] as? String == w["callId"] as? String else { throw StoreError(message:"Recording/transcript call identity does not match.") }
        if kind == "transcript_ready" {
            guard source == "user_transcript" || w["recordingState"] as? String == "ready" else { throw StoreError(message:"Verify and associate the recording before adding its transcript.") }
            let transcript=try WorkflowValidation.text(p,"transcript",200000)
            if let old=w["transcript"] as? String, old != transcript { throw StoreError(message:"A different transcript is already attached; review it before replacing evidence.") }
            w["transcript"]=transcript; w["transcriptHash"]=WorkflowValidation.transcriptHash(transcript)
            w["transcriptState"]="ready"; w["transcriptSource"]=source; w["transcriptSourceRef"]=ref
            w["summaryState"]="ready"; w["state"]="ready_for_summary"; w["contextRevision"]=try workflowContextRevision()
        } else if kind == "recording_ready" {
            guard trustedProvider, let channels=p["channels"] as? Int, channels == 2, p["bothSpeakersVerified"] as? Bool == true else { throw StoreError(message:"Associate a verified recording and confirm that both speakers are audible.") }
            let rid=try WorkflowValidation.id(p,"recordingId")
            if let old=w["recordingId"] as? String, old != rid { throw StoreError(message:"A different recording is already associated with this call.") }
            w["recordingId"]=rid; w["recordingState"]="ready"; w["recordingSourceRef"]=ref; w["channels"]=channels
        } else if ["recording_failed","transcript_failed","ai_failed"].contains(kind) {
            guard trustedProvider else { throw StoreError(message:"Only a native job can report provider/model failures.") }
            let key=kind == "recording_failed" ? "recordingState" : kind == "transcript_failed" ? "transcriptState" : "summaryState"
            if kind == "ai_failed" || w[key] as? String != "ready" { w[key]="failed" }
            if w["summaryState"] as? String != "ready" { w["state"]="needs_attention" }
            w["lastError"]=try WorkflowValidation.text(p,"error",500)
        } else { throw StoreError(message:"Unsupported recording/transcript job result.") }
        w["updatedAt"]=Store.now(); try put("workflows",w); try workflowAudit(p,type:"artifact",workflowId:wid)
    }
    func applyWorkflowResult(_ p: Record) throws {
        if try workflowReplay(p,type:"result") { return }
        let wid=try WorkflowValidation.id(p,"workflowId"); var w=try get("workflows",wid)
        guard w["appliedResultId"] == nil, w["transcriptState"] as? String == "ready", let transcript=w["transcript"] as? String,
              p["transcriptHash"] as? String == w["transcriptHash"] as? String else { throw StoreError(message:"A matching available transcript is required, and results may be applied only once.") }
        guard let revision=p["contextRevision"] as? Int, revision == w["contextRevision"] as? Int, revision == (try workflowContextRevision()) else { throw StoreError(message:"AI instructions changed. Prepare a new result using the current instructions.") }
        let summary=try WorkflowValidation.text(p,"summary",10000), model=try WorkflowValidation.text(p,"model",200)
        guard let quotes=p["evidenceQuotes"] as? [String], !quotes.isEmpty, quotes.count <= 20, quotes.allSatisfy({!$0.isEmpty && $0.count <= 2000 && transcript.contains($0)}) else { throw StoreError(message:"Summary evidence must quote the exact attached transcript.") }
        guard let steps=p["nextSteps"] as? [Record], steps.count <= 10 else { throw StoreError(message:"Provide a valid list of up to ten next steps.") }
        // Validate the whole result before any output writes, then rely on the enclosing transaction.
        for step in steps {
            _=try WorkflowValidation.text(step,"title",200)
            let due=try WorkflowValidation.text(step,"dueDate",10), quote=try WorkflowValidation.text(step,"evidenceQuote",2000)
            guard Store.parseDay(due) != nil, transcript.contains(quote) else { throw StoreError(message:"Next steps require valid dates and exact transcript evidence.") }
        }
        for key in ["textDraft","emailDraft"] {
            if let value=p[key] { guard let body=value as? String, body.count <= 10000 else { throw StoreError(message:"Invalid follow-up draft.") } }
        }
        let aid=w["agentId"] as! String, agent=try get("agents",aid), now=Store.now(), resultId=try WorkflowValidation.id(p,"eventId")
        try put("activities",["id":wid+"-summary","agentId":aid,"kind":"note","title":"Call summary — review generated content","body":summary,"date":now,"author":"Sprout local workflow","pinned":false,"workflowId":wid,"resultId":resultId,"model":model,"transcriptHash":w["transcriptHash"]!,"evidenceQuotes":quotes,"contextRevision":revision])
        for (index,step) in steps.enumerated() {
            try put("tasks",["id":wid+"-step-\(index)","agentId":aid,"title":step["title"]!,"description":"Suggested from call transcript: "+(step["evidenceQuote"] as! String),"dueDate":step["dueDate"]!,"type":"To-do","priority":"None","repeatDays":0,"completed":false,"createdAt":now,"workflowId":wid,"needsReview":true])
        }
        var draftIds:[String]=[]
        for (key,channel) in [("textDraft","Message"),("emailDraft","Email")] {
            if let body=p[key] as? String, !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let id=wid+"-"+key; draftIds.append(id)
                try put("drafts",["id":id,"agentId":aid,"channel":channel,"body":body,"state":"draft","approvalState":WorkflowValidation.blocked(agent) ? "blocked_contact" : "pending_review","updatedAt":now,"workflowId":wid,"resultId":resultId,"transcriptHash":w["transcriptHash"]!,"contextRevision":revision,"model":model])
            }
        }
        w["summaryState"]="applied"; w["state"]="review_required"; w["appliedResultId"]=resultId; w["draftIds"]=draftIds; w["updatedAt"]=now
        try put("workflows",w); try workflowAudit(p,type:"result",workflowId:wid)
    }
    func reviewWorkflowDraft(_ p: Record) throws {
        if try workflowReplay(p,type:"review") { return }
        let id=try WorkflowValidation.id(p,"draftId"); var d=try get("drafts",id)
        guard d["workflowId"] != nil || d["sequenceId"] != nil, p["confirmed"] as? Bool == true,
              let decision=p["decision"] as? String, ["approved","rejected"].contains(decision),
              d["body"] as? String == p["body"] as? String else { throw StoreError(message:"Review the exact current draft before approving or rejecting it.") }
        let agent=try get("agents",d["agentId"] as! String)
        if decision == "approved" {
            guard !WorkflowValidation.blocked(agent), d["approvalState"] as? String != "paused_reply" else { throw StoreError(message:"This contact or sequence is paused. Review the reply before approving outreach.") }
        }
        guard !["approved","rejected"].contains(d["approvalState"] as? String ?? "") else { throw StoreError(message:"This draft already has a review decision.") }
        d["approvalState"]=decision; d["reviewedAt"]=Store.now(); d["reviewedBodyHash"]=WorkflowValidation.transcriptHash(d["body"] as! String)
        // Approval is stored evidence, not authorization for an automatic send.
        try put("drafts",d); try workflowAudit(p,type:"review",workflowId:d["workflowId"] as? String)
    }
    func saveWorkflowSequence(_ p: Record) throws {
        if try workflowReplay(p,type:"sequence.save") { return }
        let id=try WorkflowValidation.id(p,"id"), aid=try WorkflowValidation.id(p,"agentId"), name=try WorkflowValidation.text(p,"name",120)
        let agent=try get("agents",aid)
        guard !WorkflowValidation.blocked(agent), p["confirmed"] as? Bool == true else { throw StoreError(message:"Confirm the sequence for an eligible contact.") }
        guard !(try all("sequences").contains(where:{$0["id"] as? String == id})), let steps=p["steps"] as? [Record], !steps.isEmpty, steps.count <= 8 else { throw StoreError(message:"Use a new sequence ID and one to eight steps.") }
        let prepared=try validatedSequenceSteps(steps,agentId:aid,sequenceId:id)
        try put("sequences",["id":id,"agentId":aid,"name":name,"steps":prepared,"state":"active","mode":"drafts_only","createdAt":Store.now(),"startDate":Store.day(),"completedSteps":[Int](),"schemaVersion":2])
        try workflowAudit(p,type:"sequence.save")
    }
    private func validatedSequenceSteps(_ steps: [Record], agentId: String, sequenceId: String, previous: [Record] = []) throws -> [Record] {
        var result: [Record]=[]
        for (index,s) in steps.enumerated() {
            guard let delay=s["delayDays"] as? Int, (0...365).contains(delay), let channel=s["channel"] as? String,
                  ["Message","Email","To-do"].contains(channel) else { throw StoreError(message:"Sequence steps need a delay and a supported channel.") }
            if channel == "To-do" || s["variants"] == nil {
                let body=try WorkflowValidation.text(s,"body",10000)
                result.append(["delayDays":delay,"channel":channel,"body":body]); continue
            }
            guard let variants=s["variants"] as? [Record], (1...5).contains(variants.count) else { throw StoreError(message:"Use one to five variants per message or email step.") }
            var clean: [Record]=[], seen=Set<String>()
            for variant in variants {
                let id=try WorkflowValidation.id(variant,"id"), label=try WorkflowValidation.text(variant,"label",80)
                guard seen.insert(id).inserted else { throw StoreError(message:"Variant IDs must be unique within a step.") }
                let body=try WorkflowValidation.text(variant,"body",10000)
                let instruction=(variant["instructions"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                guard instruction.count <= 3000 else { throw StoreError(message:"Variant instructions are too long.") }
                guard let references=variant["references"] as? [String], references.count <= 8,
                      references.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count <= 1000 }) else { throw StoreError(message:"Use up to eight nonempty references per variant.") }
                clean.append(["id":id,"label":label,"body":body,"instructions":instruction,"references":references])
            }
            let prior=previous.indices.contains(index) ? previous[index] : [:]
            let priorChoice=prior["selectedVariantId"] as? String
            let choice: String
            if let priorChoice, clean.contains(where:{$0["id"] as? String == priorChoice}) { choice=priorChoice }
            else {
                let digest=SHA256.hash(data:Data("\(agentId)|\(sequenceId)|\(index)".utf8))
                let number=digest.prefix(4).reduce(UInt32(0)){($0 << 8) | UInt32($1)}
                choice=clean[Int(number % UInt32(clean.count))]["id"] as! String
            }
            result.append(["delayDays":delay,"channel":channel,"variants":clean,"selectedVariantId":choice])
        }
        return result
    }
    func updateWorkflowSequence(_ p: Record) throws {
        if try workflowReplay(p,type:"sequence.update") { return }
        let id=try WorkflowValidation.id(p,"id"), name=try WorkflowValidation.text(p,"name",120)
        guard p["confirmed"] as? Bool == true, let steps=p["steps"] as? [Record], !steps.isEmpty, steps.count <= 8 else { throw StoreError(message:"Confirm one to eight sequence steps.") }
        var sequence=try get("sequences",id)
        guard let aid=sequence["agentId"] as? String, !WorkflowValidation.blocked(try get("agents",aid)) else { throw StoreError(message:"This contact cannot receive outreach.") }
        guard sequence["state"] as? String != "completed", let old=sequence["steps"] as? [Record], old.count == steps.count else { throw StoreError(message:"Completed sequences cannot be edited; keep the existing step count.") }
        let completed=sequence["completedSteps"] as? [Int] ?? []
        for index in completed {
            guard old.indices.contains(index), try WorkflowValidation.digest(old[index]) == WorkflowValidation.digest(steps[index]) else { throw StoreError(message:"Prepared steps cannot be changed. Edit future steps only.") }
        }
        var prepared=try validatedSequenceSteps(steps,agentId:aid,sequenceId:id,previous:old)
        for index in completed { prepared[index]=old[index] }
        sequence["name"]=name; sequence["steps"]=prepared; sequence["updatedAt"]=Store.now(); sequence["schemaVersion"]=2
        try put("sequences",sequence); try workflowAudit(p,type:"sequence.update")
    }
    func workflowSequenceEvent(_ p: Record, trustedProvider: Bool = false) throws {
        if try workflowReplay(p,type:"sequence.event") { return }
        guard trustedProvider || p["confirmed"] as? Bool == true else { throw StoreError(message:"Confirm the reply, pause or resume action.") }
        let aid=try WorkflowValidation.id(p,"agentId"), kind=try WorkflowValidation.text(p,"kind",30)
        guard ["inbound_reply","pause","resume"].contains(kind) else { throw StoreError(message:"Unsupported sequence event.") }
        let agent=try get("agents",aid)
        guard kind != "resume" || (!WorkflowValidation.blocked(agent) && p["confirmed"] as? Bool == true) else { throw StoreError(message:"A contact under a stop instruction cannot resume.") }
        for var s in try all("sequences").filter({$0["agentId"] as? String == aid}) {
            if s["state"] as? String == "completed" { continue }
            s["state"]=kind == "resume" ? "active" : "paused"; s["pauseReason"]=kind == "resume" ? "" : kind; s["updatedAt"]=Store.now(); try put("sequences",s)
        }
        if kind != "resume" {
            // Pause unsent outputs too: a reply can arrive after a due draft was prepared.
            for var d in try all("drafts").filter({$0["agentId"] as? String == aid && ($0["sequenceId"] != nil || $0["workflowId"] != nil) && $0["state"] as? String != "sent"}) {
                if d["approvalState"] as? String == "rejected" { continue }
                d["approvalState"]="paused_reply"; d["updatedAt"]=Store.now(); try put("drafts",d)
            }
        }
        try workflowAudit(p,type:"sequence.event")
    }
    func evaluateWorkflowSequences(_ p: Record) throws {
        // Explicit evaluation while the app is open; never a global scheduler or sender.
        let today=Store.day()
        for var s in try all("sequences").filter({$0["state"] as? String == "active"}) {
            let aid=s["agentId"] as! String, agent=try get("agents",aid), sid=s["id"] as! String
            if WorkflowValidation.blocked(agent) { s["state"]="paused"; s["pauseReason"]="contact_suppressed"; try put("sequences",s); continue }
            let steps=s["steps"] as? [Record] ?? [], start=Store.parseDay(s["startDate"] as? String ?? "") ?? Date()
            var completed=s["completedSteps"] as? [Int] ?? []
            // At most one newly due step per sequence per explicit review. Overdue never burst-sends.
            if let (index,step)=steps.enumerated().first(where:{!completed.contains($0.offset) && Store.plusDays($0.element["delayDays"] as? Int ?? 0,from:start) <= today}) {
                let id=sid+"-step-\(index)", channel=step["channel"] as! String
                let variants=step["variants"] as? [Record] ?? []
                let selected=variants.first(where:{$0["id"] as? String == step["selectedVariantId"] as? String})
                let body=selected?["body"] as? String ?? step["body"] as? String ?? ""
                if channel == "To-do" {
                    try put("tasks",["id":id,"agentId":aid,"title":String(body.prefix(200)),"description":body,"dueDate":today,"type":"To-do","priority":"None","repeatDays":0,"completed":false,"createdAt":Store.now(),"sequenceId":sid])
                } else {
                    var draft: Record=["id":id,"agentId":aid,"body":body,"channel":channel,"state":"draft","approvalState":"pending_review","sequenceId":sid,"sequenceStep":index,"updatedAt":Store.now(),"origin":"User-written sequence variant; not AI generated"]
                    if let selected { draft["variantId"]=selected["id"]; draft["variantLabel"]=selected["label"]; draft["variantInstructions"]=selected["instructions"]; draft["variantReferences"]=selected["references"] }
                    try put("drafts",draft)
                }
                completed.append(index); s["completedSteps"]=completed; s["updatedAt"]=Store.now()
                if completed.count == steps.count { s["state"]="completed" }
                try put("sequences",s)
                try workflowAudit(["eventId":id,"source":"local"],type:"sequence.step")
            }
        }
    }
}
