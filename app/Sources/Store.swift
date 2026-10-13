import Foundation
import SQLite3

typealias Record = [String: Any]
struct StoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Store {
    private var db: OpaquePointer?
    let path: String
    let stages = ["Identified", "Called", "Contacted", "Connected", "Meeting scheduled", "Meeting held", "Negotiating", "Contract out", "Recruited", "Lost", "Not interested", "Not qualified", "Do not contact"]
    let kinds = ["agents", "tasks", "activities", "watchlists", "searches", "drafts", "alerts", "settings", "communications", "externalMessages", "contextSuggestions", "performance", "reports", "workflows", "workflowEvents", "sequences", "aiJobs", "candidateFeedback", "importBatches", "customFields"]
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func plusDays(_ n: Int, from date: Date = Date()) -> String {
        day(Calendar.current.date(byAdding: .day, value: n, to: date)!)
    }
    static func parseDay(_ text: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: text), f.string(from: date) == text else { return nil }; return date
    }
    static func linkedInProfileURL(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        guard value.count <= 500 else { throw StoreError(message: "LinkedIn profile URL is too long.") }
        let candidate = value.contains("://") ? value : "https://" + value
        guard var url = URLComponents(string: candidate), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), ["linkedin.com", "www.linkedin.com"].contains(host),
              url.user == nil, url.password == nil,
              url.path.lowercased().hasPrefix("/in/"), url.path.split(separator: "/").count == 2 else {
            throw StoreError(message: "Enter a LinkedIn profile URL such as linkedin.com/in/name.")
        }
        url.host = "www.linkedin.com"
        url.query = nil; url.fragment = nil
        return url.string ?? candidate
    }
    static func emailCompanyReview(_ agent: Record) -> Record {
        let email = (agent["email"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let company = (agent["brand"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (agent["office"] as? String ?? "")
        guard let at = email.lastIndex(of: "@"), at < email.index(before: email.endIndex) else {
            return ["state":"no_email", "message":"No email address to compare with the listed brokerage.",
                    "emailDomain":"", "company":company]
        }
        let domain = String(email[email.index(after: at)...]).lowercased()
        guard !company.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["state":"unverified", "message":"No brokerage is listed for an email-domain comparison.",
                    "emailDomain":domain, "company":company]
        }
        let personalDomains: Set<String> = ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com", "aol.com"]
        if personalDomains.contains(domain) {
            return ["state":"unverified", "message":"Personal email domain; confirm the current business address before outreach.",
                    "emailDomain":domain, "company":company]
        }
        let ignored: Set<String> = ["real", "estate", "realty", "texas", "llc", "inc", "group", "team", "the", "and", "homes", "properties", "company", "brokerage"]
        let words = company.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !ignored.contains($0) }
        guard !words.isEmpty else {
            return ["state":"unverified", "message":"Brokerage name is too short or generic for a domain comparison; verify the business address before outreach.",
                    "emailDomain":domain, "company":company]
        }
        let base = domain.components(separatedBy: ".").dropLast().joined(separator: "")
        let match = words.contains { base.contains($0) }
        return ["state":match ? "appears_consistent" : "needs_review",
                "message":match ? "Email domain appears consistent with the listed brokerage; this does not verify delivery."
                    : "Email domain does not visibly match the listed brokerage. Verify the agent's current affiliation and address before outreach.",
                "emailDomain":domain, "company":company]
    }
    init(path: String, seed: Bool = true, seedSamples: Bool = false) throws {
        self.path = path
        let existed = FileManager.default.fileExists(atPath:path)
        if existed {
            let info = try WorkspaceRecovery.compatibility(path)
            if info["schemaVersion"] as? Int == 0 { _ = try WorkspaceRecovery.snapshot(path,reason:"before-schema-1") }
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw StoreError(message: "Cannot open the local database.") }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)
        sqlite3_busy_timeout(db, 5000)
        try sql("PRAGMA journal_mode=WAL")
        try sql("PRAGMA synchronous=FULL")
        try sql("CREATE TABLE IF NOT EXISTS records (kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(kind,id))")
        try sql("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        // Schema 1 formalizes the existing records/meta layout; future versions require ordered migrations.
        try transaction { try self.sql("PRAGMA user_version=1") }

        if seed {
            try transaction {
                if try self.meta("seed_version") == nil {
                    if seedSamples { try self.seedDemo() } else { try self.seedWorkspace() }
                    try self.sql("INSERT INTO meta VALUES ('seed_version','2')")
                }
            }
        }
    }
    deinit { sqlite3_close(db) }
    private func sql(_ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
    }
    private func meta(_ key: String) throws -> String? {
        var s: OpaquePointer?; defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key=?", -1, &s, nil) == SQLITE_OK else { throw StoreError(message: "Unable to read database version.") }
        sqlite3_bind_text(s, 1, key, -1, Store.transient)
        return sqlite3_step(s) == SQLITE_ROW ? String(cString: sqlite3_column_text(s, 0)) : nil
    }
    func all(_ kind: String) throws -> [Record] {
        var s: OpaquePointer?; defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT body FROM records WHERE kind=? ORDER BY id", -1, &s, nil) == SQLITE_OK else { throw StoreError(message: "Unable to read local records.") }
        sqlite3_bind_text(s, 1, kind, -1, Store.transient)
        var result: [Record] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            let data = Data(String(cString: sqlite3_column_text(s, 0)).utf8)
            guard let row = try JSONSerialization.jsonObject(with: data) as? Record else { throw StoreError(message: "An invalid record was found.") }
            result.append(row)
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw StoreError(message: "Unable to finish reading local records.") }
        return result
    }
    func get(_ kind: String, _ id: String) throws -> Record {
        var s: OpaquePointer?; defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db,"SELECT body FROM records WHERE kind=? AND id=?",-1,&s,nil) == SQLITE_OK else {
            throw StoreError(message:"Unable to find the local record.")
        }
        sqlite3_bind_text(s,1,kind,-1,Store.transient)
        sqlite3_bind_text(s,2,id,-1,Store.transient)
        guard sqlite3_step(s) == SQLITE_ROW,
              let row = try JSONSerialization.jsonObject(with:Data(String(cString:sqlite3_column_text(s,0)).utf8)) as? Record else {
            throw StoreError(message:"That record no longer exists.")
        }
        return row
    }
    func put(_ kind: String, _ record: Record) throws {
        guard kinds.contains(kind), let id = record["id"] as? String else { throw StoreError(message: "Invalid record type.") }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let body = String(decoding: data, as: UTF8.self)
        var s: OpaquePointer?; defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "INSERT INTO records(kind,id,body) VALUES (?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body", -1, &s, nil) == SQLITE_OK else { throw StoreError(message: "Unable to prepare save.") }
        for (i,v) in [kind,id,body].enumerated() { sqlite3_bind_text(s, Int32(i+1), v, -1, Store.transient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError(message: "Unable to save local changes.") }
        if kind == "drafts" { try ensureDraftReviewTask(record) }
    }
    private func ensureDraftReviewTask(_ draft: Record) throws {
        guard draft["state"] as? String == "draft",
              draft["approvalState"] as? String != "rejected",
              let draftID = draft["id"] as? String,
              let agentID = draft["agentId"] as? String,
              let body = draft["body"] as? String, !body.isEmpty else { return }
        let agent = try get("agents",agentID)
        let channel = draft["channel"] as? String ?? "Message"
        let label = channel == "Message" ? "text" : channel == "Phone call" ? "phone call" : "email"
        let name = agent["name"] as? String ?? "contact"
        let title = String("Review unsent \(label) draft — \(name)".prefix(200))
        let description = "Unsent draft for review. Completing this task does not send it.\n\n" + body
        let linked = try all("tasks").filter { $0["draftId"] as? String == draftID }
        if var open = linked.first(where: { $0["completed"] as? Bool != true }) {
            guard open["agentId"] as? String == agentID else { throw StoreError(message:"Draft review task contact does not match.") }
            open["title"] = title
            open["description"] = description
            open["draftBody"] = body
            open["draftUpdatedAt"] = draft["updatedAt"] as? String ?? Store.now()
            try put("tasks",open)
            return
        }
        if linked.contains(where: { $0["draftBody"] as? String == body }) { return }
        let day = Calendar.current.date(byAdding:.day,value:1,to:Date()) ?? Date()
        var due = day
        while Calendar.current.isDateInWeekend(due) {
            due = Calendar.current.date(byAdding:.day,value:1,to:due) ?? due
        }
        let task: Record = [
            "id":UUID().uuidString,"agentId":agentID,"draftId":draftID,
            "draftBody":body,"draftUpdatedAt":draft["updatedAt"] as? String ?? Store.now(),
            "title":title,"description":description,"dueDate":Store.day(due),
            "type":channel == "Message" ? "Message" : channel == "Phone call" ? "Call" : "Email",
            "priority":"Medium","assignee":try operatorName(),"repeatDays":0,
            "completed":false,"createdAt":Store.now()
        ]
        try put("tasks",task)
    }
    private func deleteRecord(_ kind: String, _ id: String) throws {
        guard kinds.contains(kind) else { throw StoreError(message:"Invalid record type.") }
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db,"DELETE FROM records WHERE kind=? AND id=?",-1,&statement,nil) == SQLITE_OK else {
            throw StoreError(message:"Unable to prepare sample cleanup.")
        }
        sqlite3_bind_text(statement,1,kind,-1,Store.transient)
        sqlite3_bind_text(statement,2,id,-1,Store.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError(message:"Unable to remove sample record.") }
    }
    private func purgeSampleContacts() throws {
        let samples = try all("agents").filter { row in
            guard let id = row["id"] as? String else { return false }
            return id.hasPrefix("sample-") || row["source"] as? String == "Fictional sample"
        }
        let ids = Set(samples.compactMap { $0["id"] as? String })
        guard samples.count == 24, ids.count == 24,
              samples.allSatisfy({ row in
                  guard let id = row["id"] as? String else { return false }
                  return id.hasPrefix("sample-") && row["source"] as? String == "Fictional sample"
                     && row["mls"] as? String == "SAMPLE"
              }) else { throw StoreError(message:"Sample inventory changed; cleanup was not applied.") }
        for kind in kinds {
            for row in try all(kind) {
                guard let id = row["id"] as? String else { continue }
                if ids.contains(id) || row["agentId"] as? String != nil && ids.contains(row["agentId"] as! String)
                    || id.hasPrefix("sample-") {
                    try deleteRecord(kind,id)
                } else if let members = row["agentIds"] as? [String], members.contains(where: { ids.contains($0) }) {
                    var updated = row; updated["agentIds"] = members.filter { !ids.contains($0) }
                    try put(kind,updated)
                }
            }
        }
    }
    func transaction<T>(_ block: () throws -> T) throws -> T {
        try sql("BEGIN IMMEDIATE")
        do { let result = try block(); try sql("COMMIT"); return result }
        catch { try? sql("ROLLBACK"); throw error }
    }
    func consistentBackup(label: String) throws -> String {
        let result = try WorkspaceRecovery.snapshot(path,reason:label)
        return result["snapshotPath"] as! String
    }
    private func required(_ p: Record, _ key: String, max: Int = 10000) throws -> String {
        guard let v = p[key] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, v.count <= max else { throw StoreError(message: "Please enter a valid \(key) (up to \(max) characters).") }; return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func agentID(_ p: Record) throws -> String {
        let id = try required(p,"agentId"); _ = try get("agents",id); return id
    }
    private func activity(_ agent: String, kind: String, title: String, body: String = "", date: String? = nil) throws {
        let now = Store.now()
        try put("activities", ["id":UUID().uuidString,"agentId":agent,"kind":kind,"title":title,"body":body,"date":date ?? now,"createdAt":now,"author":try operatorName(),"pinned":false])
    }
    private func saveTask(_ p: Record) throws -> Record {
        let title = try required(p,"title",max:200), due = try required(p,"dueDate",max:10)
        guard Store.parseDay(due) != nil else { throw StoreError(message: "Choose a valid due date.") }
        let aid = try agentID(p)
        let interval = p["repeatDays"] as? Int ?? 0
        guard [0,1,7,14,30].contains(interval) else { throw StoreError(message: "Choose a supported recurrence.") }
        let type = p["type"] as? String ?? "Check-in", priority = p["priority"] as? String ?? "None"
        guard ["Check-in","Call","Email","Message","Meeting","To-do"].contains(type), ["None","Low","Medium","High"].contains(priority) else { throw StoreError(message: "Invalid task type or priority.") }
        let task: Record = ["id":UUID().uuidString,"agentId":aid,"title":title,"dueDate":due,"type":type,"priority":priority,"description":p["description"] as? String ?? "","assignee":try (p["assignee"] as? String ?? operatorName()),"repeatDays":interval,"completed":false,"createdAt":Store.now()]
        try put("tasks",task); try activity(aid,kind:"task",title:"Task created: \(title)",body:"Due \(due)")
        return task
    }
    func snapshot() throws -> Record {
        let hasLive = try all("agents").contains { $0["datasetId"] as? String == "live" }
        var s: Record = ["mode":hasLive ? "mixed" : "sample","schemaVersion":2,"databasePath":path,"today":Store.day(),"stages":stages]
        for k in kinds {
            let rows = try all(k)
            s[k] = k == "agents" ? rows.map { agent -> Record in
                var enriched = agent
                enriched["emailCompanyReview"] = Store.emailCompanyReview(agent)
                return enriched
            } : rows
        }
        return s
    }
    func dataVersion() throws -> Int {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError(message: "Unable to check local database changes.")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func command(_ action: String, _ p: Record = [:]) throws -> Record {
        if action == "history.audit" { return try historicalAudit(p) }
        if action == "recovery.list" { return try WorkspaceRecovery.list(path) }
        if action == "recovery.create" { return try WorkspaceRecovery.snapshot(path,reason:"manual") }
        if action == "snapshot" { return try snapshot() }
        if action == "workspace.version" { return ["dataVersion": try dataVersion()] }
        if action == "performance.report" { return try managerReport(p) }
        if action == "csv.import.inspect" { return try inspectGenericImport(p) }
        if action == "csv.import.preview" { return try previewGenericImport(p) }
        if action == "csv.import.commit" { return try commitGenericImport(p) }
        if action == "csv.import.reconcile-move" { return try reconcileImportedMove() }
        return try transaction {
            switch action {
            case "onboarding.save": try self.saveOnboarding(p)
            case "sample.purge":
                try self.purgeSampleContacts()
            case "agent.create":
                let name = try required(p,"name",max:120)
                let linkedIn = try Store.linkedInProfileURL(p["linkedinUrl"] as? String ?? "")
                let r: Record = ["id":UUID().uuidString,"name":name,"office":p["office"] as? String ?? "Independent","city":p["city"] as? String ?? "","email":p["email"] as? String ?? "","phone":p["phone"] as? String ?? "","linkedinUrl":linkedIn,"source":"Manual contact","datasetId":"live","manual":true,"status":"Identified","assignee":try operatorName(),"liked":false,"disposition":"","createdAt":Store.now(),"history":[],"transactions":[],"signals":[],"move":"Unknown"]
                try self.put("agents",r); try self.activity(r["id"] as! String,kind:"system",title:"Contact added locally")
            case "agent.verifyCommunication":
                let requestedKeys = Set(p.keys)
                guard requestedKeys == Set(["agentId","name","phone","confirmed"])
                    || requestedKeys == Set(["agentId","name","phone","confirmed","evidence"]),
                    p["confirmed"] as? Bool == true else {
                    throw StoreError(message:"Review the exact contact and phone before enabling communication.")
                }
                let aid = try self.agentID(p); var r = try self.get("agents",aid)
                guard r["datasetId"] as? String == "live", r["manual"] as? Bool != true,
                      let name = r["name"] as? String, !name.isEmpty, p["name"] as? String == name,
                      let source = r["source"] as? String, !source.isEmpty,
                      let savedPhone = r["phone"] as? String,
                      let suppliedPhone = p["phone"] as? String,
                      try Store.normalizedCommunicationPhone(savedPhone) == Store.normalizedCommunicationPhone(suppliedPhone) else {
                    throw StoreError(message:"The imported contact, source, or phone changed. Review the current record again.")
                }
                guard !["Do not contact","Not interested"].contains(r["status"] as? String ?? ""), r["doNotContact"] as? Bool != true else {
                    throw StoreError(message:"This contact is marked not to receive recruiting outreach.")
                }
                let phone = try Store.normalizedCommunicationPhone(savedPhone)
                var evidence: Record? = nil
                if let supplied = p["evidence"] as? Record {
                    guard let candidateID = supplied["candidateId"] as? String, candidateID.hasPrefix("agent_"),
                          let sourceURL = supplied["profileURL"] as? String,
                          let savedURL = r["courtedProfileURL"] as? String,
                          URLComponents(string:sourceURL)?.path.contains(candidateID) == true,
                          URLComponents(string:savedURL)?.path.contains(candidateID) == true,
                          let second = supplied["secondIdentifier"] as? String,
                          let license = r["license"] as? String,
                          !second.filter({ $0.isNumber }).isEmpty,
                          second.filter({ $0.isNumber }) == license.filter({ $0.isNumber }),
                          (supplied["phoneSource"] as? String)?.hasPrefix("Courted MLS contact field") == true,
                          let assignmentID = supplied["assignmentActionId"] as? String, !assignmentID.isEmpty
                    else { throw StoreError(message:"The Courted source evidence does not match this imported contact.") }
                    evidence = supplied
                }
                if let prior = r["communicationVerification"] as? Record,
                   prior["name"] as? String == name, prior["phone"] as? String == phone,
                   prior["source"] as? String == source, prior["confirmed"] as? Bool == true { break }
                var verification: Record = ["name":name,"phone":phone,"source":source,
                    "confirmed":true,"reviewedAt":Store.now(),"reviewer":evidence == nil ? "User" : "Codex"]
                if let evidence { verification["evidence"] = evidence }
                r["communicationVerification"] = verification
                try self.put("agents",r)
                let now = Store.now()
                try self.put("activities",["id":UUID().uuidString,"agentId":aid,"kind":"system",
                    "title":"Contact and phone reviewed for communication",
                    "body":evidence == nil ? "Reviewed the saved contact name, source, and phone. No message or call was made."
                        : "Codex matched the imported name, phone, Courted profile ID, and license to the first-contact source record. No message or call was made.",
                    "date":now,"createdAt":now,"author":evidence == nil ? (try operatorName()) : "Codex","pinned":false])
            case "agent.update":
                let aid = try self.agentID(p); var r = try self.get("agents",aid)
                var overrides = Set(r["localOverrides"] as? [String] ?? [])
                if let status = p["status"] as? String, status != r["status"] as? String {
                    guard self.stages.contains(status) || status.isEmpty else { throw StoreError(message:"Choose a valid status.") }
                    r["status"] = status; r["statusAt"] = Store.now(); try self.activity(aid,kind:"status",title:status.isEmpty ? "Status cleared" : "Status changed to \(status)")
                    if r["datasetId"] as? String == "live" { overrides.insert("status") }
                }
                if let move = p["move"] as? String, move != r["move"] as? String {
                    guard ["High","Moderate","Low","Unknown"].contains(move) else { throw StoreError(message:"Choose a valid move potential.") }
                    r["move"] = move; r["moveAt"] = Store.now()
                    try self.activity(aid,kind:"status",title:"Move potential changed to \(move)")
                    if r["datasetId"] as? String == "live" { overrides.insert("move") }
                }
                for key in ["name","office","city","phone","email","linkedinUrl","assignee","disposition"] {
                    if let v = p[key] as? String {
                        guard v.count <= 500 else { throw StoreError(message:"\(key) is too long.") }
                        if key == "name" && v.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw StoreError(message:"Name is required.") }
                        if key == "disposition" && !["","skipped","snoozed"].contains(v) { throw StoreError(message:"Invalid recommendation disposition.") }
                        let updated = key == "linkedinUrl" ? try Store.linkedInProfileURL(v) : v
                        if r[key] as? String != updated, r["datasetId"] as? String == "live" { overrides.insert(key) }
                        r[key] = updated
                    }
                }
                if let liked = p["liked"] as? Bool { r["liked"] = liked }
                if !overrides.isEmpty { r["localOverrides"] = overrides.sorted() }
                try self.put("agents",r)
            case "candidate.reject":
                let aid = try self.agentID(p)
                var agent = try self.get("agents",aid)
                guard agent["manual"] as? Bool != true else { throw StoreError(message:"Only recommendations can be rated.") }
                let reason = try self.required(p,"reason",max:100)
                let allowed = ["Outside target market","Production too low","Too little experience","Poor fit for Sprout","Information is inaccurate","Already reviewed","Other"]
                guard allowed.contains(reason) else { throw StoreError(message:"Choose a feedback reason.") }
                let detail = (p["detail"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                guard detail.count <= 1000, reason != "Other" || !detail.isEmpty else { throw StoreError(message:"Add a short explanation for Other.") }
                let feedback: Record = ["id":UUID().uuidString,"agentId":aid,"reason":reason,"detail":detail,"createdAt":Store.now(),"source":try operatorName()+" review"]
                try self.put("candidateFeedback",feedback)
                agent["disposition"] = "skipped"
                agent["rejectionReason"] = reason
                agent["rejectionDetail"] = detail
                try self.put("agents",agent)
                try self.activity(aid,kind:"feedback",title:"Candidate declined: \(reason)",body:detail)
            case "candidate.restore":
                let aid = try self.agentID(p)
                var agent = try self.get("agents",aid)
                agent["disposition"] = ""
                agent.removeValue(forKey:"rejectionReason")
                agent.removeValue(forKey:"rejectionDetail")
                try self.put("agents",agent)
                try self.activity(aid,kind:"feedback",title:"Candidate restored")
            case "agent.view":
                let aid = try self.agentID(p); var r = try self.get("agents",aid); r["viewedAt"] = Store.now(); try self.put("agents",r)
            case "activity.create":
                let aid = try self.agentID(p), kind = p["kind"] as? String ?? "note"
                guard ["note","interaction"].contains(kind) else { throw StoreError(message:"Invalid activity type.") }
                let body = try self.required(p,"body")
                let title = kind == "note" ? "Note added" : try self.required(p,"title",max:200)
                let now = Store.now()
                let date: String
                let occurredAt: String
                if kind == "interaction" {
                    let localDateTime = try self.required(p,"dateTime",max:16)
                    let parser = DateFormatter(); parser.locale = Locale(identifier:"en_US_POSIX"); parser.timeZone = .current; parser.dateFormat = "yyyy-MM-dd'T'HH:mm"; parser.isLenient = false
                    guard let parsed = parser.date(from:localDateTime), parser.string(from:parsed) == localDateTime else { throw StoreError(message:"Choose a valid activity date and time.") }
                    let iso = ISO8601DateFormatter().string(from:parsed)
                    date = String(localDateTime.prefix(10)); occurredAt = iso
                    guard parsed <= Date() else { throw StoreError(message:"Completed activity time cannot be in the future.") }
                } else { date = Store.day(); occurredAt = now }
                try self.activity(aid,kind:kind,title:title,body:body,date:occurredAt)
                if kind == "interaction" { var a = try self.get("agents",aid); a["lastInteraction"] = max(date, a["lastInteraction"] as? String ?? ""); try self.put("agents",a) }
                if let next = p["task"] as? Record { var t = next; t["agentId"] = aid; _ = try self.saveTask(t) }
            case "activity.pin":
                var r = try self.get("activities",self.required(p,"id")); r["pinned"] = p["pinned"] as? Bool ?? false; try self.put("activities",r)
            case "task.create": _ = try self.saveTask(p)
            case "task.update":
                var t = try self.get("tasks",self.required(p,"id"))
                guard t["completed"] as? Bool != true else { throw StoreError(message:"Reopen the task before editing it.") }
                let keys = Set(p.keys).subtracting(["id"])
                let allowed: Set<String> = t["draftId"] == nil ? ["title","dueDate","type","priority","description","repeatDays"] : ["dueDate","priority"]
                guard keys.isSubset(of:allowed) else { throw StoreError(message:"Linked draft wording must be edited in its draft.") }
                for key in ["title","dueDate","type","priority","description"] where p[key] != nil {
                    guard p[key] is String else { throw StoreError(message:"Task fields must contain text.") }
                }
                if let due=p["dueDate"] as? String { guard Store.parseDay(due) != nil else { throw StoreError(message:"Choose a valid due date.") } }
                if let type=p["type"] as? String { guard ["Check-in","Call","Email","Message","Meeting","To-do"].contains(type) else { throw StoreError(message:"Invalid task type.") } }
                if let priority=p["priority"] as? String { guard ["None","Low","Medium","High"].contains(priority) else { throw StoreError(message:"Invalid priority.") } }
                if p["title"] != nil { _ = try self.required(p,"title",max:200) }
                if let description=p["description"] as? String { guard description.count<=20000 else { throw StoreError(message:"Task description is too long.") } }
                if let value=p["repeatDays"] {
                    guard let n=value as? Int, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(), [0,1,7,14,30].contains(n) else { throw StoreError(message:"Choose a supported repeat interval.") }
                }
                for (k,v) in p where k != "id" { t[k]=v }
                t["updatedAt"]=Store.now(); try self.put("tasks",t)
            case "task.reopen":
                var t = try self.get("tasks",self.required(p,"id"))
                if t["completed"] as? Bool == true {
                    t["completed"]=false; t.removeValue(forKey:"completedAt");t["reopenedAt"]=Store.now();try self.put("tasks",t)
                    try self.activity(t["agentId"] as! String,kind:"task",title:"Task reopened: \(t["title"] as? String ?? "Follow-up")")
                }
            case "task.complete":
                var t = try self.get("tasks",self.required(p,"id"))
                if t["completed"] as? Bool != true {
                    t["completed"] = true; t["completedAt"] = Store.now(); try self.put("tasks",t)
                    let aid = t["agentId"] as! String
                    try self.activity(aid,kind:"task",title:"Task completed: \(t["title"] as? String ?? "Follow-up")")
                    let interval = t["repeatDays"] as? Int ?? 0
                    if try interval > 0 && !self.all("tasks").contains(where: { $0["recurrenceSourceId"] as? String == t["id"] as? String }) {
                        let oldDue = Store.parseDay(t["dueDate"] as? String ?? "") ?? Date()
                        t["dueDate"] = Store.plusDays(interval,from:max(oldDue,Date()))
                        var next = try self.saveTask(t); next["recurrenceSourceId"] = t["id"]; try self.put("tasks",next)
                    }
                }
            case "watchlist.save":
                let name = try self.required(p,"name",max:100)
                let ids = p["agentIds"] as? [String] ?? []
                for id in ids { _ = try self.get("agents",id) }
                let id = p["id"] as? String ?? UUID().uuidString
                try self.put("watchlists",["id":id,"name":name,"agentIds":Array(Set(ids)),"createdAt":Store.now()])
            case "search.save":
                let name = try self.required(p,"name",max:100)
                try self.put("searches",["id":UUID().uuidString,"name":name,"filters":p["filters"] as? Record ?? [:],"createdAt":Store.now()])
            case "ai.prepare": try self.prepareAIJob(p)
            case "ai.result": try self.importAIJobResult(p)
            case "context.suggest": try self.saveContextSuggestion(p)
            case "context.reviewSuggestion": try self.reviewContextSuggestion(p)
            case "performance.save": try self.savePerformance(p)
            case "performance.import": try self.importPerformance(p)
            case "report.save": try self.saveManagerReport(p)
            case "workflow.call": try self.recordWorkflowCall(p)
            case "workflow.artifact": try self.recordWorkflowArtifact(p)
            case "workflow.result": try self.applyWorkflowResult(p)
            case "workflow.review": try self.reviewWorkflowDraft(p)
            case "sequence.save": try self.saveWorkflowSequence(p)
            case "sequence.update": try self.updateWorkflowSequence(p)
            case "sequence.event": try self.workflowSequenceEvent(p)
            case "sequence.evaluate": try self.evaluateWorkflowSequences(p)
            case "context.save": try self.saveAIContext(p)
            case "communication.prepare": try self.prepareCommunication(p)
            case "communication.update": try self.updateCommunication(p)
            case "externalMessage.import": try self.importExternalMessage(p)
            case "preferences.save", "settings.save":
                let key = action == "preferences.save" ? "preferences" : "workspace"
                var r = try self.get("settings",key)
                if key == "workspace" { r = try self.validatedWorkspaceSettings(p,existing:r) }
                else { for (k,v) in p where k != "id" { r[k] = v } }
                if key == "preferences" {
                    guard let limit = r["dailyLimit"] as? Int, [10,15,20].contains(limit) else { throw StoreError(message:"Choose 10, 15 or 20 daily sample agents.") }
                    for pair in [("minVolume","maxVolume"),("minYears","maxYears"),("minUnits","maxUnits"),("minPrice","maxPrice")] {
                        let lo = r[pair.0] as? Double ?? 0, hi = r[pair.1] as? Double ?? 0
                        guard lo >= 0, hi >= 0, hi == 0 || hi >= lo else { throw StoreError(message:"Maximum must be at least the minimum.") }
                    }
                }
                try self.put("settings",r)
            case "draft.save":
                let aid = try self.agentID(p), body = try self.required(p,"body")
                let channel = p["channel"] as? String ?? "Message"
                guard ["Message","Email","Phone call"].contains(channel) else { throw StoreError(message:"Invalid draft channel.") }
                let id = p["id"] as? String ?? UUID().uuidString
                let oldDraft = try self.all("drafts").first { $0["id"] as? String == id }
                if let prior = oldDraft, prior["agentId"] as? String != aid { throw StoreError(message:"A draft cannot be moved to a different contact.") }
                if oldDraft?["state"] as? String == "sent" { throw StoreError(message:"This message was already sent. Create a new draft for another message.") }
                var draft = oldDraft ?? [:]
                let now = Store.now()
                for (key,value) in ["id":id,"agentId":aid,"body":body,"channel":channel,"state":"draft","createdAt":oldDraft?["createdAt"] as? String ?? now,"updatedAt":now] { draft[key] = value }
                if let subject = p["subject"] as? String { draft["subject"] = subject }
                if let before = oldDraft?["body"] as? String, before != body {
                    if draft["approvalState"] != nil && draft["approvalState"] as? String != "paused_reply" { draft["approvalState"] = "pending_review" }
                    if ["Message","Email"].contains(channel) {
                        try self.saveContextSuggestion(["id":UUID().uuidString,"originType":"edit-example","source":"Manual draft edit","sourceRecordId":id,"sourceOccurredOn":Store.day(),"channel":channel,"observation":"The user revised a saved draft. Review this example before adding it to the writing context.","beforeText":before,"afterText":body,"proposedKind":"styleExample","proposal":body])
                    }
                }
                try self.put("drafts",draft)
                let activityNow = Store.now()
                try self.put("activities",["id":UUID().uuidString,"agentId":aid,"kind":"draft",
                    "title":"\(channel) draft saved — not sent","body":body,"draftId":id,
                    "date":activityNow,"createdAt":activityNow,"author":try operatorName(),"pinned":false])
            case "draft.tasks.ensure":
                for draft in try self.all("drafts") where draft["state"] as? String == "draft" {
                    guard let aid = draft["agentId"] as? String,
                          let agent = try? self.get("agents",aid),
                          agent["datasetId"] as? String == "live" else { continue }
                    try self.ensureDraftReviewTask(draft)
                }
            case "alert.dismiss":
                var a = try self.get("alerts",self.required(p,"id")); a["dismissed"] = true; try self.put("alerts",a)
            default: throw StoreError(message:"Unknown local command: \(action)")
            }
            return try self.snapshot()
        }
    }
}
