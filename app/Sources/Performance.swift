import Foundation
import CoreFoundation
import CryptoKit

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

    static func performancePeriodType(_ r: Record) -> String { r["periodType"] as? String ?? "annual" }

    static func performanceIsIndividual(_ r: Record) -> Bool {
        r["attribution"] as? String == "individual" && (r["teamId"] as? String ?? "").isEmpty && !(r["agentId"] as? String ?? "").isEmpty
    }

    static func performanceIsFullPeriod(_ r: Record) -> Bool {
        guard let year = r["year"] as? Int, let start = r["periodStart"] as? String,
              let end = r["periodEnd"] as? String,
              let first = Store.parseDay(start), let last = Store.parseDay(end) else { return false }
        if performancePeriodType(r) == "annual" { return start == "\(year)-01-01" && end == "\(year)-12-31" }
        guard performancePeriodType(r) == "ltm" else { return false }
        let days = Calendar.current.dateComponents([.day], from:first, to:last).day.map { $0 + 1 } ?? 0
        return [365,366].contains(days)
    }

    private static func performanceSubject(_ r: Record) -> String {
        if let team = r["teamId"] as? String, !team.isEmpty { return "team:" + team }
        return "agent:" + (r["agentId"] as? String ?? "")
    }

    private static func samePerformanceSeries(_ a: Record, _ b: Record) -> Bool {
        performanceSubject(a) == performanceSubject(b) && a["attribution"] as? String == b["attribution"] as? String && performancePeriodType(a) == performancePeriodType(b)
    }

    private static func samePerformanceWindow(_ a: Record, _ b: Record) -> Bool {
        samePerformanceSeries(a,b) && a["periodStart"] as? String == b["periodStart"] as? String && a["periodEnd"] as? String == b["periodEnd"] as? String
    }

    private static func performanceSourceIdentity(_ r: Record) -> String {
        let source = r["source"] as? Record ?? [:]
        let provider = source["providerId"] as? String ?? ""
        return provider.isEmpty ? (source["label"] as? String ?? "") : "provider:" + provider
    }

    private func validatedPerformance(_ p: Record) throws -> Record {
        let allowed: Set<String> = ["agentId", "teamId", "recordId", "periodType", "year", "periodStart", "periodEnd", "asOfDate", "coverage", "coverageNotes", "attribution", "source", "reportedVolume", "volumeDefinition", "buyerUnits", "buyerVolume", "sellerUnits", "sellerVolume", "dualSidedUnits", "dualSidedVolume", "expectedRevision", "changeReason"]
        guard Set(p.keys).isSubset(of: allowed) else { throw StoreError(message: "Unexpected performance fields.") }
        let explicit = p["periodType"] != nil || p["teamId"] != nil || p["recordId"] != nil
        let editingID = try performanceText(p,"recordId",optional:true)
        if p["recordId"] != nil && editingID.isEmpty { throw StoreError(message:"Use the existing production record ID when editing.") }
        let editingRecord = editingID.isEmpty ? nil : try get("performance",editingID)
        let aid = try performanceText(p,"agentId",optional:true), team = try performanceText(p,"teamId",optional:true)
        if !aid.isEmpty { _ = try get("agents",aid) }
        if !team.isEmpty { _ = try get("teams",team) }
        guard !aid.isEmpty || !team.isEmpty else { throw StoreError(message:"Choose the agent or team this production belongs to.") }
        let number = try performanceNumber(p["year"],label:"Year",maximum:9999)
        guard let y = number as? Double, y.rounded() == y, y >= 1900,
              y <= Double(Store.day().prefix(4))! else { throw StoreError(message:"Choose a calendar year through the current year.") }
        let year = Int(y), start = try performanceText(p,"periodStart",max:10), end = try performanceText(p,"periodEnd",max:10)
        let asOf = try performanceText(p,"asOfDate",max:10)
        let periodType = try performanceText(p.merging(["periodType":p["periodType"] ?? "annual"],uniquingKeysWith:{$1}),"periodType")
        guard ["annual","ltm"].contains(periodType),
              Store.parseDay(start) != nil, Store.parseDay(end) != nil, Store.parseDay(asOf) != nil,
              end.hasPrefix("\(year)-"), start <= end, end <= asOf, asOf <= Store.day(),
              periodType == "ltm" || start.hasPrefix("\(year)-") else {
            throw StoreError(message:"Use valid annual or LTM dates ending in the selected year, with an as-of date from the period end through today.")
        }
        if periodType == "ltm", !Store.performanceIsFullPeriod(["year":year,"periodType":"ltm","periodStart":start,"periodEnd":end]) {
            throw StoreError(message:"An LTM window must cover 365 or 366 consecutive days. Do not substitute partial or calendar-year values.")
        }
        let attribution = try performanceText(p,"attribution"), coverage = try performanceText(p,"coverage")
        guard ["individual","team","unknown"].contains(attribution), ["complete","partial","unknown"].contains(coverage) else {
            throw StoreError(message:"Choose the attribution and source coverage.")
        }
        if explicit {
            let legacyUnlinkedTeam = attribution == "team" && team.isEmpty && editingRecord?["attribution"] as? String == "team" && (editingRecord?["teamId"] as? String ?? "").isEmpty
            guard attribution == "team" ? (!team.isEmpty || legacyUnlinkedTeam) : (team.isEmpty && !aid.isEmpty) else {
                throw StoreError(message:"Team production needs a team identity; individual or unknown agent production must not carry a team ID.")
            }
        }
        guard let source = p["source"] as? Record, Set(source.keys).isSubset(of:["label","reference","method","providerId","recordIds","checkedAt"]) else { throw StoreError(message:"Add the source for this period.") }
        let method = try performanceText(source,"method")
        guard ["manual","import"].contains(method) else { throw StoreError(message:"Choose manual entry or import.") }
        var savedSource: Record = ["label":try performanceText(source,"label",max:200),"reference":try performanceText(source,"reference",max:2000,optional:true),"method":method]
        if source["providerId"] != nil { savedSource["providerId"] = try performanceText(source,"providerId",max:200) }
        if source["recordIds"] != nil {
            guard let ids = source["recordIds"] as? [String], ids.count <= 5000,
                  ids.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count <= 500 }), Set(ids).count == ids.count else {
                throw StoreError(message:"Source record IDs must be distinct nonempty text values; preserve their original identifiers.")
            }
            savedSource["recordIds"] = ids.sorted()
        }
        if source["checkedAt"] != nil {
            let checked = try performanceText(source,"checkedAt",max:10)
            guard Store.parseDay(checked) != nil, checked >= asOf, checked <= Store.day() else { throw StoreError(message:"Source checked date must be on or after its as-of date and no later than today.") }
            savedSource["checkedAt"] = checked
        }
        let reason = try performanceText(p,"changeReason",max:1000)
        let revision = try performanceNumber(p["expectedRevision"],label:"Revision",maximum:1_000_000)
        guard let expected = revision as? Double, expected.rounded() == expected else { throw StoreError(message:"Reload this period before saving.") }
        var r: Record = ["agentId":aid,"year":year,"periodStart":start,"periodEnd":end,"asOfDate":asOf,"attribution":attribution,"coverage":coverage,"source":savedSource,"changeReason":reason,"expectedRevision":Int(expected),"schemaVersion":explicit ? 2 : 1]
        if explicit { r["periodType"] = periodType }
        if !team.isEmpty { r["teamId"] = team }
        if p["coverageNotes"] != nil { r["coverageNotes"] = try performanceText(p,"coverageNotes",max:2000,optional:true) }
        if let old = editingRecord {
            guard Store.samePerformanceWindow(old,r) else { throw StoreError(message:"This record belongs to a different subject, attribution or period. Add a separate source series instead of replacing it.") }
            r["id"] = editingID
        } else if explicit {
            let key = [Store.performanceSubject(r),attribution,periodType,start,end].joined(separator:"\u{001f}")
            r["id"] = "perf-" + SHA256.hash(data:Data(key.utf8)).map{String(format:"%02x",$0)}.joined()
        } else { r["id"] = aid+":\(year)" }
        if p["reportedVolume"] != nil {
            guard p["volumeDefinition"] as? String == "unique_closed_volume" else { throw StoreError(message:"A reported aggregate must explicitly be unique closed volume; do not infer its definition from a generic volume column.") }
            r["reportedVolume"] = try performanceNumber(p["reportedVolume"],label:"Reported unique closed volume",maximum:1_000_000_000_000)
            r["volumeDefinition"] = "unique_closed_volume"
        } else if p["volumeDefinition"] != nil {
            throw StoreError(message:"A volume definition needs an explicitly reported value or null.")
        }
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
        if let reported = r["reportedVolume"] as? Double, let buyer = r["buyerVolume"] as? Double,
           let seller = r["sellerVolume"] as? Double, let overlap = r["dualSidedVolume"] as? Double,
           abs(reported - (buyer + seller - overlap)) > 0.01 {
            throw StoreError(message:"Reported unique closed volume conflicts with the side-derived total. Reconcile the source instead of choosing a total silently.")
        }
        return r
    }

    private func persistPerformance(_ validated: Record) throws {
        var r = validated
        let id = r["id"] as! String, expected = r.removeValue(forKey:"expectedRevision") as! Int
        let records = try all("performance")
        let existing = records.first { $0["id"] as? String == id }
        for other in records where other["id"] as? String != id && Store.samePerformanceSeries(other,r) {
            let overlaps = (other["periodStart"] as? String ?? "") <= (r["periodEnd"] as? String ?? "") && (r["periodStart"] as? String ?? "") <= (other["periodEnd"] as? String ?? "")
            if Store.samePerformanceWindow(other,r) || (Store.performancePeriodType(r) == "annual" && overlaps) {
                throw StoreError(message:"Another record covers this subject, attribution and production window. Review the existing source and its record ID before importing; overlapping annual sources are not added together.")
            }
            // Rolling LTM snapshots can overlap, but their source must be consistently identified.
            if overlaps && Store.performanceSourceIdentity(other) != Store.performanceSourceIdentity(r) {
                throw StoreError(message:"Overlapping LTM windows have different sources. Reconcile their coverage before importing a competing series.")
            }
        }
        let revision = existing?["revision"] as? Int ?? 0
        if let old = existing {
            var body = old
            for key in ["revision","createdAt","updatedAt","revisions"] { body.removeValue(forKey:key) }
            if NSDictionary(dictionary:body).isEqual(to:r) { return }
            if (r["source"] as? Record)?["method"] as? String == "import", !Store.samePerformanceWindow(old,r) {
                throw StoreError(message:"Imported production changes the existing subject, attribution or period. Add a separate series or review the existing source before replacement.")
            }
            if (r["source"] as? Record)?["method"] as? String == "import", Store.performanceSourceIdentity(old) != Store.performanceSourceIdentity(r) {
                throw StoreError(message:"The imported production source differs from the saved source. Review and reconcile the source in an explicit manual revision before importing replacement evidence.")
            }
            // A legacy edit may retain its original ID, but must not rewrite a new series through that route.
            if old["schemaVersion"] as? Int == 2 && !Store.samePerformanceWindow(old,r) {
                throw StoreError(message:"Production series identity cannot be changed by an older intake route.")
            }
        }
        guard revision == expected else { throw StoreError(message:"This performance period changed. Reload before saving your edit.") }
        var history = existing?["revisions"] as? [Record] ?? []
        if var old = existing { old.removeValue(forKey:"revisions"); history.append(old) }
        r["revision"] = revision+1; r["createdAt"] = existing?["createdAt"] ?? Store.now(); r["updatedAt"] = Store.now(); r["revisions"] = history
        try put("performance",r)
    }

    func savePerformance(_ p: Record) throws { try persistPerformance(validatedPerformance(p)) }

    func importPerformance(_ p: Record) throws {
        guard Set(p.keys) == ["records"], let rows = p["records"] as? [Record], !rows.isEmpty, rows.count <= 250 else { throw StoreError(message:"Import 1–250 explicitly sourced annual or LTM periods.") }
        let validated = try rows.map { row -> Record in
            guard (row["source"] as? Record)?["method"] as? String == "import" else { throw StoreError(message:"Imported periods must identify their import source.") }
            return try validatedPerformance(row)
        }
        guard Set(validated.compactMap{$0["id"] as? String}).count == validated.count else { throw StoreError(message:"An import cannot contain the same production series and window twice.") }
        for row in validated { try persistPerformance(row) }
    }

    static func performanceTotals(_ r: Record) -> Record {
        var totals: Record = ["creditedSides":NSNull(),"uniqueUnits":NSNull(),"uniqueVolume":NSNull()]
        if let b = r["buyerUnits"] as? Double, let s = r["sellerUnits"] as? Double {
            totals["creditedSides"] = b+s
            if let overlap = r["dualSidedUnits"] as? Double { totals["uniqueUnits"] = b+s-overlap }
        }
        if let b = r["buyerVolume"] as? Double, let s = r["sellerVolume"] as? Double, let overlap = r["dualSidedVolume"] as? Double { totals["uniqueVolume"] = b+s-overlap }
        else if r["volumeDefinition"] as? String == "unique_closed_volume", let reported = r["reportedVolume"] as? Double { totals["uniqueVolume"] = reported }
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
        let agents=try all("agents"),communications=try all("communications"),externalMessages=try all("externalMessages"),activities=try all("activities"),tasks=try all("tasks"),workflows=try all("workflows"),meetings=try all("meetings")
        let byID=Dictionary(uniqueKeysWithValues:agents.compactMap{a -> (String,Record)? in guard let id=a["id"] as? String else{return nil};return(id,a)})
        func dataset(_ aid:String)->String { byID[aid].map(Store.performanceDataset) ?? "unclassified" }
        func included(_ aid:String)->Bool { let d=dataset(aid);return d=="real" || (includeSamples && d=="sample") }
        func inWindow(_ date:String?)->Bool { guard let d=date else{return false};return d>=from && d<=to }
        var exclusions:[String:Int]=["sample":0,"test":0,"unclassified":0,"unconfirmed":0,"failed":0,"drafts":0,"linkedDuplicates":0,"invalidDates":0,"unsupportedInteractions":0,"automaticNotices":0,"unsupportedReplyClasses":0,"unverifiedMeetings":0,"unlinkedBookings":0,"invalidMeetingLinks":0]
        var events:[Record]=[],contacted=Set<String>(),responded=Set<String>(),seen=Set<String>()
        var countedCorrespondence:[Record]=[]
        var metrics:[String:Int]=["calls":0,"connectedCalls":0,"messages":0,"emails":0,"messageReplies":0,"emailReplies":0,"meetingResponses":0,"appointmentsBooked":0,"meetingsHeld":0,"convertedConversations":0,"confirmedDeliveries":0,"notes":0,"tasksCompleted":0,"tasksDue":0,"dueTasksCompletedByEnd":0]
        var evidenceCounts:[String:Int]=["manual":0,"user":0,"provider":0,"external_history":0]
        var datasetCounts:[String:Int]=["real":0,"sample":0]
        func add(_ key:String,_ aid:String,_ date:String,_ source:String,_ id:String,_ title:String) {
            guard seen.insert(id).inserted else{return};metrics[key,default:0]+=1;evidenceCounts[source,default:0]+=1;datasetCounts[dataset(aid),default:0]+=1
            if ["calls","messages","emails"].contains(key){contacted.insert(aid)}
            events.append(["id":id,"agentId":aid,"agentName":byID[aid]?["name"] as? String ?? "Unknown","date":date,"metric":key,"verification":source,"dataset":dataset(aid),"label":title])
        }
        func providerIdentity(_ record: Record) -> (String,String,String)? {
            let provider = (record["provider"] as? String ?? record["transport"] as? String ?? "").lowercased()
            let id = record["providerMessageId"] as? String ?? record["providerId"] as? String ?? ""
            guard !provider.isEmpty, !id.isEmpty else { return nil }
            return (provider,id,(record["accountAddress"] as? String ?? "").lowercased())
        }
        func sameCorrespondence(_ a: Record,_ b: Record) -> Bool {
            guard a["agentId"] as? String == b["agentId"] as? String else { return false }
            // Only exact source links and provider IDs dedupe. Similar body text
            // or dates alone cannot establish that two messages are the same.
            if let linked = a["externalMessageId"] as? String, linked == b["id"] as? String { return true }
            if let linked = b["externalMessageId"] as? String, linked == a["id"] as? String { return true }
            if let job = a["outboxJobId"] as? String, !job.isEmpty, job == b["outboxJobId"] as? String { return true }
            guard let left = providerIdentity(a), let right = providerIdentity(b),
                  left.0 == right.0, left.1 == right.1 else { return false }
            if !left.2.isEmpty && !right.2.isEmpty && left.2 != right.2 { return false }
            if let ad = a["direction"] as? String, let bd = b["direction"] as? String, ad != bd { return false }
            return true
        }
        func duplicate(_ record: Record) -> Bool { countedCorrespondence.contains { sameCorrespondence(record,$0) } }
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
            if duplicate(c) { exclusions["linkedDuplicates",default:0]+=1;continue }
            add(key,aid,date,provider ? "provider":"user","comm:"+id.lowercased(),provider ? "Provider-confirmed delivery":"User-confirmed interaction")
            countedCorrespondence.append(c)
            if provider { metrics["confirmedDeliveries",default:0]+=1 }
        }
        for message in externalMessages {
            guard let date = Store.reportDay(message["occurredAt"],timeZone:zone) else { exclusions["invalidDates",default:0]+=1;continue }
            guard inWindow(date) else { continue }
            let aid = message["agentId"] as? String ?? ""
            guard included(aid) else { exclusions[dataset(aid),default:0]+=1;continue }
            let channel = message["channel"] as? String ?? "", direction = message["direction"] as? String ?? ""
            guard ["Message","Email"].contains(channel), ["outbound","inbound"].contains(direction),
                  providerIdentity(message) != nil, let id = message["id"] as? String else {
                exclusions["unsupportedInteractions",default:0]+=1;continue
            }
            if duplicate(message) { exclusions["linkedDuplicates",default:0]+=1;continue }
            let outbound = direction == "outbound"
            let messageClass = message["messageClass"] as? String ?? ""
            if !outbound && messageClass == "automatic_notice" {
                exclusions["automaticNotices",default:0]+=1;continue
            }
            if !outbound && messageClass == "meeting_response" {
                add("meetingResponses",aid,date,"external_history","external:"+id,"Meeting response in provider history")
                countedCorrespondence.append(message);continue
            }
            // Older imported history has no class. Preserve those genuine legacy
            // reply records, but do not promote a new unsupported class to a reply.
            if !outbound && !messageClass.isEmpty && messageClass != "received_reply" {
                exclusions["unsupportedReplyClasses",default:0]+=1;continue
            }
            let key = channel == "Message" ? (outbound ? "messages" : "messageReplies") : (outbound ? "emails" : "emailReplies")
            add(key,aid,date,"external_history","external:"+id,
                outbound ? "Sent \(channel.lowercased()) in provider history; delivery unverified" : "Received \(channel.lowercased()) in provider history")
            countedCorrespondence.append(message)
            if !outbound { responded.insert(aid) }
        }
        for a in activities {
            let date=Store.reportDay(a["date"],timeZone:zone);guard let date=date else{exclusions["invalidDates",default:0]+=1;continue};guard inWindow(date) else{continue}
            let aid=a["agentId"] as? String ?? "";guard included(aid) else{exclusions[dataset(aid),default:0]+=1;continue}
            if let cid=a["communicationId"] as? String,communicationIDs.contains(cid.lowercased()){exclusions["linkedDuplicates",default:0]+=1;continue}
            let kind=a["kind"] as? String ?? "",id=a["id"] as? String ?? ""
            if kind=="draft" {exclusions["drafts",default:0]+=1;continue}
            if kind=="note" {add("notes",aid,date,"manual","activity:"+id,"Note added");continue}
            guard kind=="interaction" else{continue}
            if let meetingID=a["meetingId"] as? String,meetings.contains(where:{$0["id"] as? String==meetingID}) {exclusions["linkedDuplicates",default:0]+=1;continue}
            if duplicate(a) { exclusions["linkedDuplicates",default:0]+=1;continue }
            if a["activityType"] as? String == "message.user_confirmed_sent",
               a["confirmationSource"] as? String == "user",
               let job = a["outboxJobId"] as? String, !job.isEmpty {
                add("messages",aid,date,"user","activity:"+id,"Text sent — confirmed by you")
                countedCorrespondence.append(a);continue
            }
            // Current activity.create stores a controlled channel/outcome title. Unknown forms stay excluded.
            let parts=(a["title"] as? String ?? "").components(separatedBy:" — ")
            guard parts.count==2 else{exclusions["unsupportedInteractions",default:0]+=1;continue}
            let channel=parts[0],rawOutcome=parts[1]
            let normalizedCalls=["completed":"Completed","connected":"Connected","no answer":"No answer","no_answer":"No answer","voicemail":"Left voicemail"]
            let outcome=channel=="Call" ? (normalizedCalls[rawOutcome.lowercased()] ?? rawOutcome) : rawOutcome
            if ["Failed","Not sent","Canceled","Cancelled"].contains(outcome){exclusions["failed",default:0]+=1;continue}
            if channel=="Call",["Completed","Connected","Left voicemail","No answer","No response"].contains(outcome){add("calls",aid,date,"manual","activity:"+id,"Call — "+outcome);countedCorrespondence.append(a);if outcome=="Connected"{metrics["connectedCalls",default:0]+=1}}
            else if ["Message","Email"].contains(channel),["Completed","Connected","No response"].contains(outcome){add(channel=="Message" ? "messages":"emails",aid,date,"manual","activity:"+id,channel+" — "+outcome);countedCorrespondence.append(a)}
            else{exclusions["unsupportedInteractions",default:0]+=1}
        }
        // Build exact conversation identities from explicit Connected evidence.
        // Workflow, call and interaction IDs are aliases for one call, not separate
        // conversations. A completed task or generic completed-call receipt is not
        // evidence that a conversation happened.
        var conversations:[String:Record]=[:],conversationAliases:[String:Set<String>]=[:]
        func aliasConversation(_ alias:String,_ canonical:String) {
            guard !alias.isEmpty else{return};conversationAliases[alias,default:[]].insert(canonical)
        }
        func conversation(_ row:Record,_ canonical:String,_ dateValue:Any?,_ aliases:[String]) {
            let aid=row["agentId"] as? String ?? ""
            guard included(aid),let day=Store.reportDay(dateValue,timeZone:zone) else{return}
            conversations[canonical]=["id":canonical,"agentId":aid,"day":day,"occurredAt":dateValue ?? day]
            aliasConversation(canonical,canonical)
            for alias in aliases{aliasConversation(alias,canonical)}
        }
        for c in communications where c["channel"] as? String=="call" && c["state"] as? String=="user_confirmed_call" && c["confirmationSource"] as? String=="user" && (c["outcome"] as? String)?.lowercased()=="connected" {
            guard let id=c["id"] as? String,c["target"] as? String != "test" else{continue}
            var aliases=["call:"+id]
            if let interaction=c["interactionId"] as? String{aliases.append("activity:"+interaction)}
            conversation(c,"comm:"+id.lowercased(),c["occurredAt"] ?? c["occurredOn"],aliases)
        }
        for a in activities where a["kind"] as? String=="interaction" && (a["title"] as? String)?.lowercased()=="call — connected" {
            guard let id=a["id"] as? String,!id.isEmpty else{continue}
            let canonical=(a["communicationId"] as? String).map{"comm:"+$0.lowercased()} ?? "activity:"+id
            conversation(a,canonical,a["date"],["activity:"+id])
        }
        for workflow in workflows where workflow["outcome"] as? String=="connected" {
            guard let wid=workflow["id"] as? String,let activityID=workflow["interactionId"] as? String,
                  let activity=activities.first(where:{$0["id"] as? String==activityID}),activity["agentId"] as? String==workflow["agentId"] as? String,
                  activity["kind"] as? String=="interaction",
                  (activity["title"] as? String)?.lowercased()=="call — connected",
                  ["user_confirmed","provider"].contains(workflow["source"] as? String ?? "") else{continue}
            let canonical=(activity["communicationId"] as? String).map{"comm:"+$0.lowercased()} ?? "activity:"+activityID
            var aliases=["workflow:"+wid,"activity:"+activityID]
            if let call=workflow["callId"] as? String{aliases.append("call:"+call)}
            conversation(workflow,canonical,workflow["occurredAt"] ?? workflow["occurredOn"],aliases)
        }
        let conversationCohort=Set(conversations.compactMap{key,row in inWindow(row["day"] as? String) ? key:nil})
        metrics["connectedCalls"]=conversationCohort.count
        var converted=Set<String>(),unlinkedBookings=0,invalidMeetingLinks=0
        for meeting in meetings {
            let aid=meeting["agentId"] as? String ?? ""
            guard included(aid) else{continue}
            let bookedDay=Store.reportDay(meeting["bookedAt"],timeZone:zone),heldDay=Store.reportDay(meeting["heldAt"],timeZone:zone)
            let relevant=inWindow(bookedDay)||inWindow(heldDay)
            guard meeting["state"] as? String=="booked",meeting["source"] as? String=="google_calendar",
                  let providerID=meeting["googleEventId"] as? String,!providerID.isEmpty,
                  Store.reportDay(meeting["providerVerifiedAt"],timeZone:zone) != nil,
                  let id=meeting["id"] as? String,let bookedDay else {
                if relevant{exclusions["unverifiedMeetings",default:0]+=1};continue
            }
            if inWindow(bookedDay){add("appointmentsBooked",aid,bookedDay,"google_calendar","meeting-booked:"+id,"Appointment booked — Google Calendar verified")}
            if let heldDay,inWindow(heldDay) {
                if meeting["heldSource"] as? String=="user_confirmed",Store.reportDay(meeting["heldRecordedAt"],timeZone:zone) != nil {add("meetingsHeld",aid,heldDay,"user","meeting-held:"+id,"Meeting held — explicitly confirmed by you")}
                else {exclusions["unverifiedMeetings",default:0]+=1}
            }
            guard bookedDay<=to else{continue}
            let rawLink=meeting["linkedConversationID"] as? String ?? ""
            guard !rawLink.isEmpty else {if inWindow(bookedDay){unlinkedBookings+=1};continue}
            guard let candidates=conversationAliases[rawLink],candidates.count==1,let canonical=candidates.first,
                  let call=conversations[canonical],call["agentId"] as? String==aid,
                  let conversationDay=call["day"] as? String,conversationDay<=bookedDay else {
                if inWindow(bookedDay){invalidMeetingLinks+=1};continue
            }
            // A booking cannot be credited to a later call on the same day.
            let callTime=call["occurredAt"] as? String ?? "",bookingTime=meeting["bookedAt"] as? String ?? ""
            let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            func instant(_ value:String)->Date? {
                if let date=parser.date(from:value){return date};let plain=ISO8601DateFormatter();if let date=plain.date(from:value){return date}
                let local=DateFormatter();local.locale=Locale(identifier:"en_US_POSIX");local.timeZone=zone;local.dateFormat="yyyy-MM-dd'T'HH:mm:ss";local.isLenient=false
                guard let date=local.date(from:value),local.string(from:date)==value else{return nil};return date
            }
            let callInstant=instant(callTime),bookingInstant=instant(bookingTime)
            let chronologyInvalid:Bool
            if let callInstant,let bookingInstant {chronologyInvalid=bookingInstant<callInstant}
            else {chronologyInvalid=conversationDay==bookedDay}
            if chronologyInvalid {
                if inWindow(bookedDay){invalidMeetingLinks+=1};continue
            }
            if conversationCohort.contains(canonical){converted.insert(canonical)}
        }
        metrics["convertedConversations"]=converted.count
        exclusions["unlinkedBookings"]=unlinkedBookings;exclusions["invalidMeetingLinks"]=invalidMeetingLinks
        let conversionMeasurable=conversationCohort.count>0 && converted.count>0 && unlinkedBookings==0 && invalidMeetingLinks==0
        let conversationRate:Record=["numerator":converted.count,"denominator":conversationCohort.count,"percent":conversionMeasurable ? Double(converted.count)*100/Double(conversationCohort.count) as Any:NSNull(),"linkedConversations":converted.count,"unlinkedBookings":unlinkedBookings,"invalidMeetingLinks":invalidMeetingLinks,"status":conversionMeasurable ? "recorded_links_only":"insufficient_verified_linkage","coverageNote":"Recorded conversion only. Call history and booking history may be incomplete. Each converted conversation needs an exact call-to-booking link; missing links are not assumed to be zero conversions."]
        for t in tasks {
            let aid=t["agentId"] as? String ?? "";guard included(aid) else{continue}
            let due=Store.reportDay(t["dueDate"],timeZone:zone),done=Store.reportDay(t["completedAt"],timeZone:zone)
            if inWindow(due){metrics["tasksDue",default:0]+=1;if t["completed"] as? Bool == true,let done=done,done<=to{metrics["dueTasksCompletedByEnd",default:0]+=1}}
            if t["completed"] as? Bool == true,inWindow(done),let done=done,let id=t["id"] as? String{add("tasksCompleted",aid,done,"manual","task:"+id,"Task completed")}
        }
        let contactCount=agents.filter{included($0["id"] as? String ?? "")}.count
        let due=metrics["tasksDue"]!,done=metrics["dueTasksCompletedByEnd"]!
        let rates:Record=["conversationToMeeting":conversationRate,"taskCompletion":["numerator":done,"denominator":due,"percent":due>0 ? Double(done)*100/Double(due) as Any:NSNull()],"contactCoverage":["numerator":contacted.count,"denominator":contactCount,"percent":contactCount>0 ? Double(contacted.count)*100/Double(contactCount) as Any:NSNull()]]
        return ["schemaVersion":3,"filters":filters,"generatedAt":Store.now(),"historyCoverage":["complete":false,"scope":"saved_workspace_only","note":"Manual/provider call logs, imported texts and emails, and verified calendar bookings only. Calls outside Sprout and older or unconnected history may be missing."],"metrics":metrics,"rates":rates,"distinctContacts":contacted.count,"distinctRespondingContacts":responded.count,"includedContacts":contactCount,"verificationCounts":evidenceCounts,"datasetCounts":datasetCounts,"exclusions":exclusions,"events":events.sorted{($0["date"] as? String ?? "",$0["id"] as? String ?? "")<($1["date"] as? String ?? "",$1["id"] as? String ?? "")},"definitions":["Calls counts recorded attempts, including voicemail/no answer; connectedCalls requires an explicit Connected log. A handoff alone is excluded.","Messages/emails count outbound provider-history records, provider-delivered records, user-confirmed sends, or explicitly completed manual logs. A Sent history record does not prove delivery. Provider acceptance, drafts, failed and unknown attempts are excluded.","Message/email replies count imported inbound replies, not outbound outreach, automatic notices or calendar meeting responses. Meeting responses have their own count. Distinct responding contacts counts each contact once; it is not a causal response rate. Confirmed deliveries requires separate provider delivery evidence.","Appointments booked count verified Google Calendar booking events by bookedAt; a later cancellation does not erase that historical booking. Meetings held require an explicit heldAt outcome, never a task status or an expired calendar event. Conversation conversion uses explicit Connected calls in the report window linked exactly to at least one booking after the call and by the report end; each conversation counts once. Missing or invalid linkage and zero verified conversions leave the percentage unavailable, not an invented zero.","Task completion rate is tasks due in the selected window completed by its end / all tasks due in that window. Reopened tasks are not completed.","Contact coverage is distinct contacts with a counted outbound call/message/email / included contacts currently in this local workspace. It is not a response or conversion rate.","Sample records are excluded by default. Test recipients and unclassified/orphaned records are excluded. Exact communication/source links and provider IDs deduplicate counted evidence. Unlinked manual logs cannot be reconciled by similar text alone.","Dates follow the selected report time zone; user-entered calendar dates keep their stated day. External history uses the message occurrence time, never its import time. Counts reflect this local snapshot, not activity in other apps that has not been imported or logged."]]
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
        for (key,label) in [("calls","Calls logged"),("connectedCalls","Explicitly connected calls"),("messages","Outbound messages logged"),("emails","Outbound emails logged"),("messageReplies","Inbound messages imported"),("emailReplies","Inbound email replies imported"),("meetingResponses","Meeting responses imported"),("appointmentsBooked","Appointments booked"),("meetingsHeld","Meetings held"),("convertedConversations","Conversations linked to a booked appointment"),("confirmedDeliveries","Provider-confirmed deliveries"),("notes","Notes added"),("tasksCompleted","Tasks completed")] {lines.append("\(label): \(m[key] ?? 0)")}
        for (key,label) in [("taskCompletion","Tasks due completed by end"),("contactCoverage","Contacts with a recorded interaction")] {let rate=rates[key] as? Record ?? [:];lines.append("\(label): \(rate["numerator"] ?? 0) / \(rate["denominator"] ?? 0)")}
        let conversion=rates["conversationToMeeting"] as? Record ?? [:]
        let conversionPercent=(conversion["percent"] as? Double).map{String(format:"%.1f%%",$0)} ?? "Unavailable — insufficient verified linkage"
        lines += ["Conversation to appointment conversion: \(conversion["numerator"] ?? 0) / \(conversion["denominator"] ?? 0) (\(conversionPercent))",conversion["coverageNote"] as? String ?? "History coverage is incomplete."]
        lines += ["","Evidence counts: \(r["verificationCounts"] ?? [:])","Dataset counts: \(r["datasetCounts"] ?? [:])","Excluded records: \(r["exclusions"] ?? [:])","","Definitions:"]
        lines += (r["definitions"] as? [String] ?? []).map{"- "+$0}
        lines += ["","Activity ledger (bodies and contact details omitted):"]
        for e in r["events"] as? [Record] ?? [] {lines.append([e["date"],e["agentName"],e["label"],e["verification"],e["dataset"]].map{String(describing:$0 ?? "").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")}.joined(separator:" | "))}
        return lines.joined(separator:"\n")+"\n"
    }
}
