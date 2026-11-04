import Foundation

extension Store {
    func saveTeam(_ p: Record) throws {
        guard Set(p.keys).isSubset(of:["id","name","brokerage","source","checkedAt","evidence","expectedRevision"]) else {
            throw StoreError(message:"Unexpected team fields.")
        }
        let name = try Self.professionalText(p["name"],"team name",max:200)
        let brokerage = try Self.professionalText(p["brokerage"],"team brokerage",max:200)
        let source = try Self.professionalSource(p["source"])
        let supplied = try Self.professionalText(p["id"],"team ID",max:200,optional:true)
        let id = supplied.isEmpty ? Self.professionalID("team-",[name.lowercased(),brokerage.lowercased(),source["label"] as! String,source["reference"] as! String]) : supplied
        let record: Record = ["id":id,"name":name,"brokerage":brokerage,"source":source,
            "checkedAt":try Self.professionalCheckedDay(p["checkedAt"]),
            "evidence":try Self.professionalText(p["evidence"],"team evidence",max:4000,optional:true),"schemaVersion":1]
        try persistProfessionalRecord("teams",record,expectedRevision:Self.professionalRevision(p["expectedRevision"]))
    }

    func saveTeamMembership(_ p: Record) throws {
        guard Set(p.keys).isSubset(of:["id","agentId","teamId","role","startDate","endDate","source","checkedAt","evidence","expectedRevision"]) else {
            throw StoreError(message:"Unexpected team membership fields.")
        }
        let aid = try Self.professionalText(p["agentId"],"contact",max:200)
        let team = try Self.professionalText(p["teamId"],"team",max:200)
        _ = try get("agents",aid); _ = try get("teams",team)
        let role = try Self.professionalText(p["role"],"team role",max:20)
        guard ["leader","member"].contains(role) else { throw StoreError(message:"Choose leader or member.") }
        let start = try Self.professionalText(p["startDate"],"membership start date",max:10)
        let end = try Self.professionalText(p["endDate"],"membership end date",max:10,optional:true)
        let checked = try Self.professionalCheckedDay(p["checkedAt"])
        guard Self.parseDay(start) != nil, start <= checked,
              end.isEmpty || (Self.parseDay(end) != nil && start <= end && end <= checked) else {
            throw StoreError(message:"Use known membership dates: start through end, no later than the checked date. Leave an ongoing end date blank.")
        }
        let supplied = try Self.professionalText(p["id"],"membership ID",max:200,optional:true)
        let id = supplied.isEmpty ? Self.professionalID("membership-",[team,aid,role,start]) : supplied
        let existing = try all("teamMemberships").first { $0["id"] as? String == id }
        if let existing = existing,
           existing["agentId"] as? String != aid || existing["teamId"] as? String != team {
            throw StoreError(message:"A membership cannot be reassigned to another contact or team. Add a separate relationship.")
        }
        let overlap = try all("teamMemberships").first { row in
            guard row["id"] as? String != id, row["agentId"] as? String == aid,
                  row["teamId"] as? String == team, let otherStart = row["startDate"] as? String else { return false }
            let otherEnd = row["endDate"] as? String ?? ""
            return start <= (otherEnd.isEmpty ? "9999-12-31" : otherEnd) && otherStart <= (end.isEmpty ? "9999-12-31" : end)
        }
        guard overlap == nil else {
            throw StoreError(message:"Overlapping membership evidence for this contact and team needs review. Update or end the existing relationship before adding another role.")
        }
        let record: Record = ["id":id,"agentId":aid,"teamId":team,"role":role,"startDate":start,"endDate":end,
            "source":try Self.professionalSource(p["source"]),"checkedAt":checked,
            "evidence":try Self.professionalText(p["evidence"],"membership evidence",max:4000,optional:true),"schemaVersion":1]
        try persistProfessionalRecord("teamMemberships",record,expectedRevision:Self.professionalRevision(p["expectedRevision"]))
    }
}
