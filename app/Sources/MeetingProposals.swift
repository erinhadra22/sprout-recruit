import Foundation

extension Store {
    func meetingContext(_ p: Record) throws -> Record {
        guard Set(p.keys)==["agentId"],let aid=p["agentId"] as? String else {
            throw StoreError(message:"Select the contact before preparing a meeting.")
        }
        let agent=try get("agents",aid),settings=try meetingParticipantsSettings()
        let workspace=try all("settings").first { $0["id"] as? String=="workspace" }
        let zone=workspace?["timezone"] as? String ?? "America/Chicago"
        let email=try? MeetingValidation.email(agent["email"] as? String ?? "")
        var missing=["localDateTime"]
        if email==nil { missing.append("agentEmail") }
        let workflows=try all("workflows").filter { $0["agentId"] as? String==aid && $0["outcome"] as? String=="connected" }
        let linked=Set(workflows.compactMap { $0["interactionId"] as? String })
        var conversations=workflows.map { row -> Record in
            ["id":"workflow:"+(row["id"] as? String ?? ""),"occurredAt":row["occurredAt"] ?? row["occurredOn"] ?? ""]
        }
        for row in try all("activities") where row["agentId"] as? String==aid &&
            row["title"] as? String=="Call — Connected" && row["kind"] as? String=="interaction" {
            if let id=row["id"] as? String,!linked.contains(id) {
                conversations.append(["id":"activity:"+id,"occurredAt":row["date"] ?? ""])
            }
        }
        return ["agentId":aid,"agentName":agent["name"] ?? "Contact","agentEmail":email ?? "",
            "title":"Sprout recruiting meeting — "+(agent["name"] as? String ?? "Contact"),
            "timeZone":zone,"durationMinutes":settings["defaultDurationMinutes"] ?? 60,
            "internalParticipants":settings["participants"] ?? [String](),
            "participantsRevision":settings["revision"] ?? 0,"connectedConversations":conversations,
            "missingFields":missing,"reviewRequired":true]
    }

    func saveMeetingProposal(_ p: Record) throws {
        let allowed:Set<String>=["id","agentId","expectedRevision","sourceActor","sourceReference",
            "title","localDateTime","timeZone","durationMinutes","location","description","linkedConversationID"]
        guard Set(p.keys).isSubset(of:allowed),let raw=p["id"] as? String,let uuid=UUID(uuidString:raw),
              let aid=p["agentId"] as? String,
              let revision=MeetingValidation.integer(p["expectedRevision"],0...Int.max) else {
            throw StoreError(message:"Use a stable meeting request ID, contact and current request revision.")
        }
        let id=uuid.uuidString.lowercased(),context=try meetingContext(["agentId":aid])
        let old=try all("meetingProposals").first { $0["id"] as? String==id }
        guard revision==(old?["revision"] as? Int ?? 0),old==nil || old?["agentId"] as? String==aid else {
            throw StoreError(message:"This meeting request changed. Read its current details before saving.")
        }
        if let booking=try all("meetings").first(where: { $0["id"] as? String==id }),
           ["submitted","booked"].contains(booking["state"] as? String ?? "") {
            throw StoreError(message:"This request already has a Calendar submission. Reconcile its saved event.")
        }
        let actor=try MeetingValidation.text(p["sourceActor"],field:"source actor",limit:150)
        let reference=try MeetingValidation.text(p["sourceReference"],field:"source reference",limit:500)
        guard !actor.isEmpty,!reference.isEmpty else { throw StoreError(message:"Identify who prepared this request and its source.") }
        var record:Record=["id":id,"agentId":aid,"sourceActor":actor,"sourceReference":reference,
            "title":context["title"]!,"timeZone":context["timeZone"]!,"durationMinutes":context["durationMinutes"]!,
            "createdAt":old?["createdAt"] ?? Store.now(),"revision":revision+1,"updatedAt":Store.now()]
        // Only the explicit proposal fields can be shared. Contact notes and
        // conversation contents never become an invitation by default.
        for (key,limit) in [("title",500),("localDateTime",40),("timeZone",100),("location",500),("description",8000),("linkedConversationID",250)] {
            if let value=p[key] {
                let text=try MeetingValidation.text(value,field:key,limit:limit)
                if key=="title" && text.isEmpty { continue }
                record[key]=text
            } else if let value=old?[key] { record[key]=value }
        }
        if let value=p["durationMinutes"] {
            guard let duration=MeetingValidation.integer(value,5...240) else { throw StoreError(message:"Choose a meeting duration from 5 to 240 minutes.") }
            record["durationMinutes"]=duration
        } else if let value=old?["durationMinutes"] { record["durationMinutes"]=value }
        var missing=[String]()
        if (context["agentEmail"] as? String ?? "").isEmpty { missing.append("agentEmail") }
        guard let zone=record["timeZone"] as? String,TimeZone(identifier:zone) != nil else { throw StoreError(message:"Choose a valid meeting time zone.") }
        if let local=record["localDateTime"] as? String,!local.isEmpty {
            if try MeetingValidation.localDate(local,zone)<=Date() { missing.append("localDateTime") }
        } else { missing.append("localDateTime") }
        if let call=record["linkedConversationID"] as? String,!call.isEmpty { _ = try meetingConversation(call,aid) }
        record["missingFields"]=missing
        record["state"]=missing.isEmpty ? "ready" : "needs_details"
        let taskID="meeting-proposal-review-"+id
        record["reviewTaskId"]=taskID
        var task=try all("tasks").first { $0["id"] as? String==taskID } ?? [:]
        task.merge(["id":taskID,"agentId":aid,"type":"Review","priority":"High","dueDate":Store.day(),
            "title":missing.isEmpty ? "Review meeting invitation for "+(context["agentName"] as? String ?? "contact") :
                "Complete meeting details for "+(context["agentName"] as? String ?? "contact"),
            "description":"Open Outbox → Meeting requests → Review details. Confirm the contact, date, time, attendees and invitation details. Creating the reviewed event sends invitations.",
            "reviewKind":"meeting-proposal","sourceRefs":["meetingProposals:"+id,reference],
            "decisionOptions":["Complete or correct meeting details","Review the exact invitation before creating it","Defer booking"],
            "completed":false,"createdAt":task["createdAt"] ?? Store.now(),"updatedAt":Store.now()]) { _,new in new }
        task["title"]=String((task["title"] as? String ?? "").prefix(200))
        task.removeValue(forKey:"completedAt")
        try put("meetingProposals",record)
        try put("tasks",task)
    }

    func completeMeetingProposal(_ meeting:Record) throws {
        guard let id=meeting["proposalId"] as? String else { return }
        var proposal=try get("meetingProposals",id)
        guard proposal["agentId"] as? String==meeting["agentId"] as? String else {
            throw StoreError(message:"This booking belongs to a different meeting request.")
        }
        for key in ["title","localDateTime","timeZone","durationMinutes","description","location","linkedConversationID"] {
            proposal.removeValue(forKey:key)
            if let value=meeting[key] { proposal[key]=value }
        }
        proposal["missingFields"]=[String]()
        proposal["state"]="booked";proposal["meetingId"]=meeting["id"];proposal["bookedAt"]=meeting["bookedAt"]
        proposal["googleEventId"]=meeting["googleEventId"];proposal["updatedAt"]=Store.now()
        try put("meetingProposals",proposal)
        if let taskID=proposal["reviewTaskId"] as? String,
           var task=try all("tasks").first(where: { $0["id"] as? String==taskID && $0["agentId"] as? String==meeting["agentId"] as? String }) {
            task["completed"]=true;task["completedAt"]=Store.now();try put("tasks",task)
        }
    }
}
