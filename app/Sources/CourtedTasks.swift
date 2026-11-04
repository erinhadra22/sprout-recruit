import Foundation

// Input is a human-reviewed capture from the designated Courted UI. This adapter
// has no network access and does not infer a task or a contact from its name.
private struct CourtedTaskPlan {
    let rows: [Record]
    let additions: [Record]
    let token: String
    var summary: Record {
        ["rows":rows.count,"newTasks":additions.count,
         "duplicates":rows.filter { $0["state"] as? String == "existing" }.count,
         "held":rows.filter { $0["state"] as? String == "held" }.count,
         "details":rows,"token":token,"source":"Courted manually reviewed UI capture"]
    }
}

extension Store {
    private func courtedCandidateIDs(_ agent: Record) -> Set<String> {
        var values=Set<String>()
        func add(_ raw: Any?) {
            guard let value=raw as? String, !value.isEmpty else { return }
            values.insert(value)
        }
        add(agent["courtedId"]);add(agent["courtedID"])
        if (agent["sourceProvider"] as? String)?.lowercased() == "courted" {
            add(agent["sourceAgentId"]);add(agent["providerID"]);add(agent["providerId"])
        }
        for alias in agent["sourceAliases"] as? [Record] ?? [] where (alias["provider"] as? String)?.lowercased() == "courted" {
            if let value=alias["sourceId"] as? String {
                add(value)
                // Legacy aliases contain the complete Courted profile path.
                if value.hasPrefix("cts/dashboard/") || value.hasPrefix("cts/candidates/") { add(value.split(separator:"/").last.map(String.init)) }
            }
        }
        if let raw=agent["courtedProfileURL"] as? String, let url=URLComponents(string:raw),
           url.scheme?.lowercased() == "https",url.host?.lowercased() == "brokerage.courted.io",url.user == nil,url.password == nil {
            let parts=url.path.split(separator:"/").map(String.init)
            if parts.count == 3,parts[0] == "cts",["dashboard","candidates"].contains(parts[1]) { add(parts[2]) }
        }
        return values
    }
    private func capturedCourtedTask(_ raw: Record) throws -> Record {
        func text(_ key: String,_ maximum: Int,_ allowEmpty: Bool = false) throws -> String {
            guard let value=raw[key] as? String,value.count<=maximum,
                  allowEmpty || !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
                throw StoreError(message:"Missing or invalid \(key).")
            }
            return value
        }
        let sourceTaskId=try text("taskId",36)
        guard let uuid=UUID(uuidString:sourceTaskId),sourceTaskId.count == 36 else { throw StoreError(message:"The source task needs its exact Courted UUID.") }
        let candidate=try text("candidateId",200)
        guard candidate.range(of:"^[A-Za-z0-9][A-Za-z0-9_:.\\-]{0,199}$",options:.regularExpression) != nil else { throw StoreError(message:"The source candidate ID is invalid.") }
        let title=try text("title",200),due=try text("dueDate",10),type=try text("type",30),priority=try text("priority",20)
        let description=try text("description",20000,true),source=try text("sourceURL",2000),captured=try text("capturedAt",60)
        guard Store.parseDay(due) != nil else { throw StoreError(message:"The source task needs an exact calendar due date.") }
        guard ["Check-in","Call","Email","Message","Meeting","To-do","Review","Approval"].contains(type) else { throw StoreError(message:"Review the source task type before importing.") }
        guard ["None","Low","Medium","High"].contains(priority) else { throw StoreError(message:"Review the source task priority before importing.") }
        guard let url=URLComponents(string:source),url.scheme == "https",url.host == "brokerage.courted.io",url.user == nil,url.password == nil,!url.path.isEmpty,url.path != "/" else { throw StoreError(message:"A Courted source URL is required.") }
        let iso=ISO8601DateFormatter(),fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard iso.date(from:captured) != nil || fractional.date(from:captured) != nil else { throw StoreError(message:"The capture needs an exact timestamp with a time zone.") }
        return ["id":"courted-task-"+uuid.uuidString.lowercased(),"sourceTaskId":uuid.uuidString.lowercased(),"sourceCandidateId":candidate,
                "title":title,"dueDate":due,"type":type,"priority":priority,"description":description,
                "sourceURL":source,"capturedAt":captured,"courtedTaskSource":raw]
    }
    private func courtedTaskPlan(_ payload: Record) throws -> CourtedTaskPlan {
        guard let captures=payload["tasks"] as? [Record],!captures.isEmpty,captures.count<=5000 else { throw StoreError(message:"Provide one to 5,000 manually reviewed Courted task captures.") }
        let encoded=try JSONSerialization.data(withJSONObject:captures,options:.sortedKeys)
        guard encoded.count<=20_000_000 else { throw StoreError(message:"The Courted task capture is too large.") }
        let agents=try all("agents"),tasks=try all("tasks"),deleted=try all("deletedTasks")
        var identityMap:[String:[String]]=[:]
        for a in agents {
            guard let id=a["id"] as? String else { continue }
            for key in courtedCandidateIDs(a) { identityMap[key,default:[]].append(id) }
        }
        let state: Record=["candidates":identityMap.mapValues { $0.sorted() },"tasks":tasks,"deletedTasks":deleted]
        let stateBytes=try JSONSerialization.data(withJSONObject:state,options:.sortedKeys)
        let token=CourtedCSV.hash(encoded+stateBytes)
        let sourceCounts=Dictionary(grouping:captures,by:{ ($0["taskId"] as? String ?? "").lowercased() }).mapValues(\.count)
        var rows:[Record]=[],additions:[Record]=[]
        func semantic(_ task: Record) -> String {
            let title=(task["title"] as? String ?? "").split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").lowercased()
            return [task["agentId"] as? String ?? "",task["type"] as? String ?? "",task["dueDate"] as? String ?? "",title].joined(separator:"\u{1f}")
        }
        for (index,raw) in captures.enumerated() {
            var row:Record=["row":index+1,"taskId":raw["taskId"] as? String ?? "","candidateId":raw["candidateId"] as? String ?? "","state":"held"]
            do {
                var task=try capturedCourtedTask(raw)
                let sourceID=task["sourceTaskId"] as! String,candidate=task["sourceCandidateId"] as! String,localID=task["id"] as! String
                row["localTaskId"]=localID
                guard sourceCounts[sourceID] == 1 else { throw StoreError(message:"duplicate_source_task_id") }
                let matches=identityMap[candidate] ?? []
                guard matches.count == 1 else { throw StoreError(message:matches.isEmpty ? "contact_not_found" : "ambiguous_contact_identity") }
                let aid=matches[0];task["agentId"]=aid;row["agentId"]=aid
                let existing=tasks.filter { ($0["sourceProvider"] as? String == "courted" && ($0["sourceTaskId"] as? String)?.lowercased() == sourceID) || $0["id"] as? String == localID }
                if !existing.isEmpty {
                    guard existing.count == 1,existing[0]["sourceProvider"] as? String == "courted",(existing[0]["sourceTaskId"] as? String)?.lowercased() == sourceID,existing[0]["agentId"] as? String == aid else { throw StoreError(message:"existing_source_identity_conflict") }
                    row["state"]="existing";row["reason"]="already_imported_local_edits_preserved"
                } else {
                    guard !deleted.contains(where:{ archive in
                        let task=archive["task"] as? Record ?? archive
                        return archive["id"] as? String == localID || (task["sourceProvider"] as? String == "courted" && (task["sourceTaskId"] as? String)?.lowercased() == sourceID)
                    }) else { throw StoreError(message:"previously_deleted_task") }
                    guard !(tasks+additions).contains(where:{semantic($0)==semantic(task)}) else { throw StoreError(message:"possible_existing_local_task") }
                    task["sourceProvider"]="courted";task["source"]="Courted manually reviewed UI capture";task["completed"]=false;task["repeatDays"]=0
                    task["sourceRefs"]=["courted:task:"+sourceID,task["sourceURL"] as! String]
                    additions.append(task);row["state"]="new";row["reason"]="exact_contact_identity"
                }
            } catch { row["reason"]=(error as? StoreError)?.message ?? "invalid_source_record" }
            rows.append(row)
        }
        return CourtedTaskPlan(rows:rows,additions:additions,token:token)
    }
    func previewCourtedTasks(_ payload: Record) throws -> Record { try courtedTaskPlan(payload).summary }
    func commitCourtedTasks(_ payload: Record) throws -> Record {
        let plan=try courtedTaskPlan(payload)
        guard let token=payload["token"] as? String,token==plan.token else { throw StoreError(message:"The Courted capture or workspace changed. Preview the task import again.") }
        if plan.additions.isEmpty { var result=plan.summary;result["imported"]=0;return result }
        let backup=try consistentBackup(label:"before-courted-task-import"),now=Store.now()
        try transaction {
            let locked=try courtedTaskPlan(payload)
            guard locked.token==token else { throw StoreError(message:"The workspace changed during backup. Preview the task import again.") }
            for var task in locked.additions {
                task["createdAt"]=now;task["importedAt"]=now;task["assignee"]=try operatorName()
                try put("tasks",task)
            }
        }
        for task in plan.additions {
            let saved=try get("tasks",task["id"] as! String)
            guard saved["sourceTaskId"] as? String == task["sourceTaskId"] as? String,saved["agentId"] as? String == task["agentId"] as? String,saved["title"] as? String == task["title"] as? String else { throw StoreError(message:"Courted task readback failed. The pre-import backup is retained.") }
        }
        var result=plan.summary;result["imported"]=plan.additions.count;result["backupPath"]=backup
        result["importedTaskIds"]=plan.additions.compactMap { $0["id"] as? String }
        return result
    }
}
