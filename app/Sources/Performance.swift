import Foundation
import CoreFoundation

// Calendar-period evidence is independent of agent LTM totals and sourcing scores.
// Call mutations through Store.command's transaction. Reports are frozen local snapshots.
extension Store {
    private func performanceText(_ p: Record, _ key: String, max: Int = 500, optional: Bool = false) throws -> String {
        guard let text = p[key] as? String else {
            if optional && p[key] == nil { return "" }
            throw StoreError(message: "Enter a valid \(key).")
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= max, optional || !value.isEmpty else { throw StoreError(message: "Enter a valid \(key) (up to \(max) characters).") }
        return value
    }

    private func performanceNumber(_ value: Any?, label: String, maximum: Double) throws -> Any {
        guard let value = value, !(value is NSNull) else { return NSNull() }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= maximum else {
            throw StoreError(message: "\(label) must be a nonnegative number, or blank when unknown.")
        }
        return n.doubleValue
    }

    private func validatedPerformance(_ p: Record) throws -> Record {
        let allowed: Set<String> = ["agentId", "year", "periodStart", "periodEnd", "asOfDate", "coverage", "attribution", "source", "buyerUnits", "buyerVolume", "sellerUnits", "sellerVolume", "dualSidedUnits", "dualSidedVolume", "expectedRevision", "changeReason"]
        guard Set(p.keys).isSubset(of: allowed) else { throw StoreError(message: "Unexpected performance fields.") }
        let aid = try performanceText(p,"agentId"); _ = try get("agents",aid)
        let number = try performanceNumber(p["year"],label:"Year",maximum:9999)
        guard let y = number as? Double, y.rounded() == y, y >= 1900,
              y <= Double(Store.day().prefix(4))! else { throw StoreError(message:"Choose a calendar year through the current year.") }
        let year = Int(y), start = try performanceText(p,"periodStart",max:10), end = try performanceText(p,"periodEnd",max:10)
        let asOf = try performanceText(p,"asOfDate",max:10)
        guard Store.parseDay(start) != nil, Store.parseDay(end) != nil, Store.parseDay(asOf) != nil,
              start.hasPrefix("\(year)-"), end.hasPrefix("\(year)-"), start <= end, end <= asOf, asOf <= Store.day() else {
            throw StoreError(message:"Use a valid period within the selected year and an as-of date from its end through today.")
        }
        let attribution = try performanceText(p,"attribution"), coverage = try performanceText(p,"coverage")
        guard ["individual","team","unknown"].contains(attribution), ["complete","partial","unknown"].contains(coverage) else {
            throw StoreError(message:"Choose the attribution and source coverage.")
        }
        guard let source = p["source"] as? Record, Set(source.keys).isSubset(of:["label","reference","method"]) else { throw StoreError(message:"Add the source for this period.") }
        let method = try performanceText(source,"method")
        guard ["manual","import"].contains(method) else { throw StoreError(message:"Choose manual entry or import.") }
        let reason = try performanceText(p,"changeReason",max:1000)
        let revision = try performanceNumber(p["expectedRevision"],label:"Revision",maximum:1_000_000)
        guard let expected = revision as? Double, expected.rounded() == expected else { throw StoreError(message:"Reload this period before saving.") }
        var r: Record = ["id":aid+":\(year)","agentId":aid,"year":year,"periodStart":start,"periodEnd":end,"asOfDate":asOf,"attribution":attribution,"coverage":coverage,"source":["label":try performanceText(source,"label",max:200),"reference":try performanceText(source,"reference",max:2000,optional:true),"method":method],"changeReason":reason,"expectedRevision":Int(expected),"schemaVersion":1]
        for key in ["buyerUnits","sellerUnits","dualSidedUnits","buyerVolume","sellerVolume","dualSidedVolume"] {
            r[key] = try performanceNumber(p[key],label:key,maximum:key.hasSuffix("Units") ? 1_000_000 : 1_000_000_000_000)
        }
        for suffix in ["Units","Volume"] {
            if let overlap = r["dualSided"+suffix] as? Double {
                guard let buyer = r["buyer"+suffix] as? Double, let seller = r["seller"+suffix] as? Double,
                      overlap <= min(buyer,seller) else { throw StoreError(message:"Dual-side overlap needs both side values and cannot exceed either side.") }
            }
        }
        for prefix in ["buyer","seller","dualSided"] {
            if let units = r[prefix+"Units"] as? Double, let volume = r[prefix+"Volume"] as? Double,
               (units == 0 && volume != 0) || (units > 0 && volume == 0) { throw StoreError(message:"Known units and volume must agree; leave unavailable values blank.") }
        }
        return r
    }

    private func persistPerformance(_ validated: Record) throws {
        var r = validated
        let id = r["id"] as! String, expected = r.removeValue(forKey:"expectedRevision") as! Int
        let existing = try all("performance").first { $0["id"] as? String == id }
        let revision = existing?["revision"] as? Int ?? 0
        if let old = existing {
            var body = old
            for key in ["revision","createdAt","updatedAt","revisions"] { body.removeValue(forKey:key) }
            if NSDictionary(dictionary:body).isEqual(to:r) { return }
        }
        guard revision == expected else { throw StoreError(message:"This performance period changed. Reload before saving your edit.") }
        var history = existing?["revisions"] as? [Record] ?? []
        if var old = existing { old.removeValue(forKey:"revisions"); history.append(old) }
        r["revision"] = revision+1; r["createdAt"] = existing?["createdAt"] ?? Store.now(); r["updatedAt"] = Store.now(); r["revisions"] = history
        try put("performance",r)
    }

    func savePerformance(_ p: Record) throws { try persistPerformance(validatedPerformance(p)) }

    func importPerformance(_ p: Record) throws {
        guard Set(p.keys) == ["records"], let rows = p["records"] as? [Record], !rows.isEmpty, rows.count <= 250 else { throw StoreError(message:"Import 1–250 explicitly sourced calendar periods.") }
        let validated = try rows.map { row -> Record in
            guard (row["source"] as? Record)?["method"] as? String == "import" else { throw StoreError(message:"Imported periods must identify their import source.") }
            return try validatedPerformance(row)
        }
        guard Set(validated.compactMap{$0["id"] as? String}).count == validated.count else { throw StoreError(message:"An import cannot contain the same agent and year twice.") }
        for row in validated { try persistPerformance(row) }
    }

    static func performanceTotals(_ r: Record) -> Record {
        var totals: Record = ["creditedSides":NSNull(),"uniqueUnits":NSNull(),"uniqueVolume":NSNull()]
        if let b = r["buyerUnits"] as? Double, let s = r["sellerUnits"] as? Double {
            totals["creditedSides"] = b+s
            if let overlap = r["dualSidedUnits"] as? Double { totals["uniqueUnits"] = b+s-overlap }
        }
        if let b = r["buyerVolume"] as? Double, let s = r["sellerVolume"] as? Double, let overlap = r["dualSidedVolume"] as? Double { totals["uniqueVolume"] = b+s-overlap }
        return totals
    }

    static func performanceDataset(_ agent: Record) -> String {
        let source = (agent["source"] as? String ?? "").lowercased()
        if (agent["id"] as? String ?? "").hasPrefix("sample-") || source.contains("sample") || source.contains("fictional") || agent["sample"] as? Bool == true || agent["dataset"] as? String == "sample" || agent["datasetId"] as? String == "sample" { return "sample" }
        if agent["manual"] as? Bool == true || agent["dataset"] as? String == "live" || agent["datasetId"] as? String == "live" { return "real" }
        return "unclassified"
    }

    private static func reportDay(_ value: Any?, timeZone: TimeZone) -> String? {
        guard let text = value as? String else { return nil }
        if text.count == 10 { return Store.parseDay(text) == nil ? nil : text }
        // Existing manual activity timestamps carry no timezone; their calendar date is intentional.
        if text.range(of:"^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}$",options:.regularExpression) != nil {
            let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=timeZone;f.dateFormat="yyyy-MM-dd'T'HH:mm:ss";f.isLenient=false
            guard let date=f.date(from:text),f.string(from:date)==text else{return nil};return String(text.prefix(10))
        }
        let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        var date=f.date(from:text);if date == nil { f.formatOptions=[.withInternetDateTime];date=f.date(from:text) }
        guard let date=date else{return nil}
        let day=DateFormatter();day.locale=Locale(identifier:"en_US_POSIX");day.timeZone=timeZone;day.dateFormat="yyyy-MM-dd";return day.string(from:date)
    }

    private func reportFilters(_ p: Record) throws -> Record {
        guard Set(p.keys).isSubset(of:["id","title","fromDate","toDate","timeZone","includeSamples"]) else { throw StoreError(message:"Unexpected report fields.") }
        let from=try performanceText(p,"fromDate",max:10),to=try performanceText(p,"toDate",max:10)
        guard Store.parseDay(from) != nil,Store.parseDay(to) != nil,from<=to,to<=Store.day() else{throw StoreError(message:"Choose a valid report window ending today or earlier.")}
        let zone=p["timeZone"] as? String ?? TimeZone.current.identifier
        guard TimeZone(identifier:zone) != nil else{throw StoreError(message:"Choose a valid report time zone.")}
        if let value=p["includeSamples"] { guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw StoreError(message:"Sample inclusion must be explicit.")} }
        return ["title":try performanceText(p,"title",max:150,optional:true),"fromDate":from,"toDate":to,"timeZone":zone,"includeSamples":p["includeSamples"] as? Bool ?? false]
    }

    func managerReport(_ p: Record) throws -> Record {
        let filters=try reportFilters(p),from=filters["fromDate"] as! String,to=filters["toDate"] as! String,zone=TimeZone(identifier:filters["timeZone"] as! String)!,includeSamples=filters["includeSamples"] as! Bool
        let agents=try all("agents"),communications=try all("communications"),activities=try all("activities"),tasks=try all("tasks")
        let byID=Dictionary(uniqueKeysWithValues:agents.compactMap{a -> (String,Record)? in guard let id=a["id"] as? String else{return nil};return(id,a)})
        func dataset(_ aid:String)->String { byID[aid].map(Store.performanceDataset) ?? "unclassified" }
        func included(_ aid:String)->Bool { let d=dataset(aid);return d=="real" || (includeSamples && d=="sample") }
        func inWindow(_ date:String?)->Bool { guard let d=date else{return false};return d>=from && d<=to }
        var exclusions:[String:Int]=["sample":0,"test":0,"unclassified":0,"unconfirmed":0,"failed":0,"drafts":0,"linkedDuplicates":0,"invalidDates":0,"unsupportedInteractions":0]
        var events:[Record]=[],contacted=Set<String>(),seen=Set<String>()
        var metrics:[String:Int]=["calls":0,"connectedCalls":0,"messages":0,"emails":0,"notes":0,"tasksCompleted":0,"tasksDue":0,"dueTasksCompletedByEnd":0]
        var evidenceCounts:[String:Int]=["manual":0,"user":0,"provider":0]
        var datasetCounts:[String:Int]=["real":0,"sample":0]
        func add(_ key:String,_ aid:String,_ date:String,_ source:String,_ id:String,_ title:String) {
            guard seen.insert(id).inserted else{return};metrics[key,default:0]+=1;evidenceCounts[source,default:0]+=1;datasetCounts[dataset(aid),default:0]+=1
            if ["calls","messages","emails"].contains(key){contacted.insert(aid)}
            events.append(["id":id,"agentId":aid,"agentName":byID[aid]?["name"] as? String ?? "Unknown","date":date,"metric":key,"verification":source,"dataset":dataset(aid),"label":title])
        }
        let communicationIDs=Set(communications.compactMap{$0["id"] as? String}.map{$0.lowercased()})
        for c in communications {
            let state=c["state"] as? String ?? "",date=Store.reportDay(c["occurredOn"] ?? c["updatedAt"] ?? c["createdAt"],timeZone:zone)
            guard let date=date else{exclusions["invalidDates",default:0]+=1;continue};guard inWindow(date) else{continue}
            if c["target"] as? String == "test" {exclusions["test",default:0]+=1;continue}
            let aid=c["agentId"] as? String ?? ""
            guard included(aid) else{exclusions[dataset(aid),default:0]+=1;continue}
            if state == "failed" {exclusions["failed",default:0]+=1;continue}
            let channel=c["channel"] as? String ?? "",provider=state=="delivered" && c["confirmationSource"] as? String == "provider" && c["providerId"] is String
            let user=(state=="user_confirmed_sent" || state=="user_confirmed_call") && c["confirmationSource"] as? String == "user"
            guard (channel=="call" && state=="user_confirmed_call" && user) || (["message","email"].contains(channel) && (provider || (state=="user_confirmed_sent" && user))), c["occurredOn"] != nil,let id=c["id"] as? String else{exclusions["unconfirmed",default:0]+=1;continue}
            let key=channel=="call" ? "calls" : channel=="email" ? "emails" : "messages"
            add(key,aid,date,provider ? "provider":"user","comm:"+id.lowercased(),provider ? "Provider-confirmed delivery":"User-confirmed interaction")
        }
        for a in activities {
            let date=Store.reportDay(a["date"],timeZone:zone);guard let date=date else{exclusions["invalidDates",default:0]+=1;continue};guard inWindow(date) else{continue}
            let aid=a["agentId"] as? String ?? "";guard included(aid) else{exclusions[dataset(aid),default:0]+=1;continue}
            if let cid=a["communicationId"] as? String,communicationIDs.contains(cid.lowercased()){exclusions["linkedDuplicates",default:0]+=1;continue}
            let kind=a["kind"] as? String ?? "",id=a["id"] as? String ?? ""
            if kind=="draft" {exclusions["drafts",default:0]+=1;continue}
            if kind=="note" {add("notes",aid,date,"manual","activity:"+id,"Note added");continue}
            guard kind=="interaction" else{continue}
            // Current activity.create stores a controlled channel/outcome title. Unknown forms stay excluded.
            let parts=(a["title"] as? String ?? "").components(separatedBy:" — ")
            guard parts.count==2 else{exclusions["unsupportedInteractions",default:0]+=1;continue}
            let channel=parts[0],outcome=parts[1]
            if ["Failed","Not sent","Canceled","Cancelled"].contains(outcome){exclusions["failed",default:0]+=1;continue}
            if channel=="Call",["Completed","Connected","Left voicemail","No answer","No response"].contains(outcome){add("calls",aid,date,"manual","activity:"+id,"Call — "+outcome);if outcome=="Connected"{metrics["connectedCalls",default:0]+=1}}
            else if ["Message","Email"].contains(channel),["Completed","Connected","No response"].contains(outcome){add(channel=="Message" ? "messages":"emails",aid,date,"manual","activity:"+id,channel+" — "+outcome)}
            else{exclusions["unsupportedInteractions",default:0]+=1}
        }
        for t in tasks {
            let aid=t["agentId"] as? String ?? "";guard included(aid) else{continue}
            let due=Store.reportDay(t["dueDate"],timeZone:zone),done=Store.reportDay(t["completedAt"],timeZone:zone)
            if inWindow(due){metrics["tasksDue",default:0]+=1;if t["completed"] as? Bool == true,let done=done,done<=to{metrics["dueTasksCompletedByEnd",default:0]+=1}}
            if t["completed"] as? Bool == true,inWindow(done),let done=done,let id=t["id"] as? String{add("tasksCompleted",aid,done,"manual","task:"+id,"Task completed")}
        }
        let contactCount=agents.filter{included($0["id"] as? String ?? "")}.count
        let due=metrics["tasksDue"]!,done=metrics["dueTasksCompletedByEnd"]!
        let rates:Record=["taskCompletion":["numerator":done,"denominator":due,"percent":due>0 ? Double(done)*100/Double(due) as Any:NSNull()],"contactCoverage":["numerator":contacted.count,"denominator":contactCount,"percent":contactCount>0 ? Double(contacted.count)*100/Double(contactCount) as Any:NSNull()]]
        return ["schemaVersion":1,"filters":filters,"generatedAt":Store.now(),"metrics":metrics,"rates":rates,"distinctContacts":contacted.count,"includedContacts":contactCount,"verificationCounts":evidenceCounts,"datasetCounts":datasetCounts,"exclusions":exclusions,"events":events.sorted{($0["date"] as? String ?? "",$0["id"] as? String ?? "")<($1["date"] as? String ?? "",$1["id"] as? String ?? "")},"definitions":["Calls counts recorded attempts, including voicemail/no answer; connectedCalls requires an explicit Connected log. A handoff alone is excluded.","Messages/emails count provider-delivered, user-confirmed sent, or explicitly completed manual logs. Provider acceptance, drafts, failed and unknown attempts are excluded.","Task completion rate is tasks due in the selected window completed by its end / all tasks due in that window. Reopened tasks are not completed.","Contact coverage is distinct contacts with a counted call/message/email / included contacts currently in this local workspace. It is not a response or conversion rate.","Sample records are excluded by default. Test recipients and unclassified/orphaned records are excluded. Linked communication activity is counted only once.","Dates follow the selected report time zone; user-entered calendar dates keep their stated day. Counts reflect this local snapshot, not activity in other apps that has not been logged."]]
    }

    func saveManagerReport(_ p: Record) throws {
        let id=try performanceText(p,"id",max:36);guard UUID(uuidString:id) != nil else{throw StoreError(message:"Use a stable report ID.")}
        let filters=try reportFilters(p)
        if let old=try all("reports").first(where:{$0["id"] as? String == id}) {
            guard let previous=old["filters"] as? Record,NSDictionary(dictionary:previous).isEqual(to:filters) else{throw StoreError(message:"That report ID already belongs to a different window. Create a new report.")};return
        }
        var report=try managerReport(p);report["id"]=id;try put("reports",report)
    }

    static func managerReportText(_ r: Record) -> String {
        let f=r["filters"] as? Record ?? [:],m=r["metrics"] as? Record ?? [:],rates=r["rates"] as? Record ?? [:]
        var lines=[f["title"] as? String == "" ? "Recruiting activity report":f["title"] as? String ?? "Recruiting activity report","Window: \(f["fromDate"] ?? "") through \(f["toDate"] ?? "") (\(f["timeZone"] ?? ""))","Generated: \(r["generatedAt"] ?? "")","Sample records included: \(f["includeSamples"] as? Bool == true ? "Yes — illustrative records included":"No")",""]
        for (key,label) in [("calls","Calls logged"),("connectedCalls","Explicitly connected calls"),("messages","Messages logged"),("emails","Emails logged"),("notes","Notes added"),("tasksCompleted","Tasks completed")] {lines.append("\(label): \(m[key] ?? 0)")}
        for (key,label) in [("taskCompletion","Tasks due completed by end"),("contactCoverage","Contacts with a recorded interaction")] {let rate=rates[key] as? Record ?? [:];lines.append("\(label): \(rate["numerator"] ?? 0) / \(rate["denominator"] ?? 0)")}
        lines += ["","Evidence counts: \(r["verificationCounts"] ?? [:])","Dataset counts: \(r["datasetCounts"] ?? [:])","Excluded records: \(r["exclusions"] ?? [:])","","Definitions:"]
        lines += (r["definitions"] as? [String] ?? []).map{"- "+$0}
        lines += ["","Activity ledger (bodies and contact details omitted):"]
        for e in r["events"] as? [Record] ?? [] {lines.append([e["date"],e["agentName"],e["label"],e["verification"],e["dataset"]].map{String(describing:$0 ?? "").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")}.joined(separator:" | "))}
        return lines.joined(separator:"\n")+"\n"
    }
}
