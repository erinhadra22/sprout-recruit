import Foundation

func runTeamTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message:"Team test failed: \(message)") }
    }
    func fails(_ message: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try check(rejected,message)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-teams-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let path = root.appendingPathComponent("fixture.sqlite").path
    var teamID = ""
    do {
        let store = try Store(path:path,seed:false)
        for aid in ["a","b","c"] { try store.put("agents",["id":aid,"name":"Fixture "+aid,"status":"Identified","history":[["note":"Keep"]]]) }
        var team: Record = ["name":"Fixture Waco Team","brokerage":"Fixture Brokerage",
            "source":["label":"Official roster","reference":"https://example.test/teams/fixture"],
            "checkedAt":"2025-06-01","evidence":"Official brokerage team roster.","expectedRevision":0]
        func saveTeam(_ p: Record) throws { try store.transaction { try store.saveTeam(p) } }
        func saveMember(_ p: Record) throws { try store.transaction { try store.saveTeamMembership(p) } }
        try saveTeam(team); try saveTeam(team)
        try check(try store.all("teams").count == 1,"team retry deduplicates")
        teamID = try store.all("teams").first!["id"] as! String
        try check((try store.get("teams",teamID))["revision"] as? Int == 1,"team retry no revision")
        var member: Record = ["agentId":"a","teamId":teamID,"role":"member","startDate":"2025-01-01","endDate":"",
            "source":["label":"Official roster","reference":"https://example.test/teams/fixture"],
            "checkedAt":"2025-06-01","evidence":"Roster states join date.","expectedRevision":0]
        try saveMember(member); try saveMember(member)
        try check(try store.all("teamMemberships").count == 1,"membership retry deduplicates")
        let membershipID = try store.all("teamMemberships").first!["id"] as! String
        var conflict = member; conflict["role"] = "leader"; conflict["startDate"] = "2025-02-01"
        try fails("overlapping role requires review") { try saveMember(conflict) }
        conflict = member; conflict["startDate"] = "2025-02-30"
        try fails("invalid start rejected") { try saveMember(conflict) }
        conflict["startDate"] = "2025-07-01"
        try fails("start after observation rejected") { try saveMember(conflict) }
        conflict = member; conflict["endDate"] = "2024-12-31"
        try fails("end before start rejected") { try saveMember(conflict) }
        member["id"] = membershipID; member["endDate"] = "2025-02-28"; member["expectedRevision"] = 1
        try saveMember(member)
        let ended = try store.get("teamMemberships",membershipID)
        try check(ended["revision"] as? Int == 2 && (ended["revisions"] as? [Record])?.count == 1,"ending membership preserves prior observation")
        conflict = member; conflict["endDate"] = "2025-02-27"
        try fails("stale membership edit rejected") { try saveMember(conflict) }
        conflict = member; conflict["expectedRevision"] = 2; conflict["agentId"] = "b"
        try fails("relationship cannot be reassigned") { try saveMember(conflict) }
        member.removeValue(forKey:"id"); member["expectedRevision"] = 0
        member["role"] = "leader"; member["startDate"] = "2025-03-01"; member["endDate"] = ""
        try saveMember(member)
        member["agentId"] = "b"
        try saveMember(member)
        try check(try store.all("teamMemberships").filter { $0["role"] as? String == "leader" }.count == 2,"multiple team leaders allowed")
        team["id"] = teamID; team["expectedRevision"] = 1; team["name"] = "Renamed Fixture Waco Team"
        try saveTeam(team)
        try check((try store.get("teams",teamID))["revision"] as? Int == 2,"team ID stable through rename")
        try check(try store.all("teamMemberships").allSatisfy { $0["teamId"] as? String == teamID },"memberships retain team link")
        let count = try store.all("teamMemberships").count
        try fails("batch member failure rolls back") {
            try store.transaction {
                var newMember = member; newMember["agentId"] = "c"
                try store.saveTeamMembership(newMember)
                newMember["role"] = "unsupported"
                try store.saveTeamMembership(newMember)
            }
        }
        try check(try store.all("teamMemberships").count == count,"failed batch does not retain partial relationship")
        try check((try store.get("agents","a"))["history"] as? [Record] != nil,"contact history untouched")
        try check(try store.all("performance").isEmpty,"roster creates no inferred production")
    }
    let reopened = try Store(path:path,seed:false)
    try check((try reopened.get("teams",teamID))["name"] as? String == "Renamed Fixture Waco Team","team restart readback")
    try check(try reopened.all("teamMemberships").count == 3,"dated relationships survive restart")
}
