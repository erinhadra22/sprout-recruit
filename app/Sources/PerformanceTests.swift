import Foundation

func runPerformanceTests() throws {
    try runProductionSeriesTests()
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-performance-tests-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:dir)}
    let path=dir.appendingPathComponent("fixture.sqlite").path
    var store:Store?=try Store(path:path,seed:false)
    func check(_ condition:Bool,_ message:String)throws{if !condition{throw StoreError(message:"Performance test failed: "+message)}}
    func fails(_ body:()throws->Void)throws{do{try body()}catch{return};throw StoreError(message:"Performance test expected validation failure")}
    let year=Int(Store.day().prefix(4))!-1, start="\(year)-01-01",end="\(year)-12-31"
    let real:Record=["id":"real-a","name":"Real Contact","manual":true,"status":"Connected"]
    try store!.put("agents",real)
    try store!.put("agents",["id":"real-b","name":"Another Contact","manual":true])
    try store!.put("agents",["id":"sample-a","name":"Sample Contact","manual":true])
    try store!.put("agents",["id":"uncertain","name":"Unclassified"])
    var row:Record=["agentId":"real-a","year":year,"periodStart":start,"periodEnd":end,"asOfDate":end,"coverage":"complete","attribution":"individual","source":["label":"Fixture annual export","reference":"local fixture","method":"manual"],"expectedRevision":0,"changeReason":"Initial sourced entry","buyerUnits":4,"buyerVolume":2_000_000,"sellerUnits":3,"sellerVolume":1_800_000,"dualSidedUnits":1,"dualSidedVolume":600_000]
    _=try store!.command("performance.save",row)
    let id="real-a:\(year)"
    let initial=try store!.get("performance",id)
    try check(initial["revision"] as? Int == 1,"first save creates revision")
    let totals=Store.performanceTotals(initial)
    try check(totals["creditedSides"] as? Double == 7 && totals["uniqueUnits"] as? Double == 6 && totals["uniqueVolume"] as? Double == 3_200_000,"dual-side overlap is deducted exactly once")
    _=try store!.command("performance.save",row)
    try check(try store!.get("performance",id)["revision"] as? Int == 1,"same payload replay does not create history")
    row["expectedRevision"]=1;row["source"]=["label":"Corrected annual source","reference":"fixture v2","method":"manual"];row["changeReason"]="Correct source attribution";row["attribution"]="team"
    _=try store!.command("performance.save",row)
    let edited=try store!.get("performance",id), history=edited["revisions"] as? [Record] ?? []
    try check(edited["revision"] as? Int == 2 && history.count == 1,"source edits create history")
    try check((history.first?["source"] as? Record)?["label"] as? String == "Fixture annual export" && history.first?["attribution"] as? String == "individual","previous source and attribution retained")
    var stale=row;stale["buyerUnits"]=5
    try fails{_=try store!.command("performance.save",stale)}
    var unknown=row;unknown["year"]=year-1;unknown["periodStart"]="\(year-1)-03-01";unknown["periodEnd"]="\(year-1)-10-31";unknown["asOfDate"]="\(year-1)-11-01";unknown["expectedRevision"]=0;unknown["coverage"]="partial";unknown["attribution"]="unknown"
    for key in ["buyerUnits","buyerVolume","sellerUnits","sellerVolume","dualSidedUnits","dualSidedVolume"]{unknown[key]=NSNull()}
    unknown["buyerUnits"]=0;unknown["buyerVolume"]=0
    _=try store!.command("performance.save",unknown)
    let partial=try store!.get("performance","real-a:\(year-1)")
    try check(partial["buyerUnits"] as? Double == 0 && partial["sellerUnits"] is NSNull,"zero survives separately from unknown")
    try check(Store.performanceTotals(partial)["uniqueUnits"] is NSNull && partial["coverage"] as? String == "partial","partial unknown period stays unknown")
    var noOverlap=row;noOverlap["expectedRevision"]=2;noOverlap["dualSidedUnits"]=NSNull();noOverlap["dualSidedVolume"]=NSNull()
    _=try store!.command("performance.save",noOverlap)
    try check(Store.performanceTotals(try store!.get("performance",id))["uniqueUnits"] is NSNull,"unknown overlap never assumes zero")
    for mutation:Record in [["buyerUnits":-1],["buyerVolume":true],["sellerUnits":"3"],["dualSidedUnits":9],["periodEnd":"\(year)-02-30"],["asOfDate":"1900-01-01"],["year":Double(year)+0.5],["attribution":"individual and team"],["buyerUnits":0,"buyerVolume":1]]{
        var invalid=row;invalid["expectedRevision"]=3;for(k,v)in mutation{invalid[k]=v};try fails{_=try store!.command("performance.save",invalid)}
    }
    var imported=unknown;imported["agentId"]="real-b";imported["source"]=["label":"Imported fixture","method":"import"];imported["changeReason"]="Import source row"
    var conflicting=noOverlap;conflicting["expectedRevision"]=0;conflicting["buyerUnits"]=12;conflicting["source"]=["label":"Imported fixture","method":"import"]
    let beforeImport=try store!.all("performance").count
    try fails{_=try store!.command("performance.import",["records":[imported,conflicting]])}
    try check(try store!.all("performance").count == beforeImport,"stale row rolls back entire import")
    _=try store!.command("performance.import",["records":[imported]])
    try fails{_=try store!.command("performance.import",["records":[imported,imported]])}
    store=nil;store=try Store(path:path,seed:false)
    try check(try store!.get("performance",id)["revision"] as? Int == 3,"performance and revision survive reopen")
    try check(try store!.get("performance","real-b:\(year-1)")["sellerUnits"] is NSNull,"imported unknown survives reopen")

    let day="\(year)-06-15", filter:Record=["title":"Fixture manager report","fromDate":"\(year)-06-01","toDate":"\(year)-06-30","timeZone":"America/Chicago"]
    func activity(_ id:String,_ kind:String,_ title:String,_ aid:String="real-a",_ date:String?=nil,_ extra:Record=[:])throws{
        var r:Record=["id":id,"agentId":aid,"kind":kind,"title":title,"date":date ?? day+"T12:00:00","body":"Private fixture body not exported"]
        for(k,v)in extra{r[k]=v};try store!.put("activities",r)
    }
    func communication(_ id:String,_ channel:String,_ state:String,_ confirmation:String,_ aid:String="real-a",_ extra:Record=[:])throws{
        var c:Record=["id":id,"agentId":aid,"target":"agent","channel":channel,"state":state,"confirmationSource":confirmation,"occurredOn":day,"updatedAt":day+"T12:00:00Z","providerId":UUID().uuidString,"body":"Private message body"]
        for(k,v)in extra{c[k]=v};try store!.put("communications",c)
    }
    try communication("delivered","message","delivered","provider")
    try communication("user-message","message","user_confirmed_sent","user")
    try communication("user-call","call","user_confirmed_call","user")
    try communication("accepted","message","accepted","provider")
    try communication("failed","message","failed","provider")
    try communication("unknown","message","unknown","provider")
    try communication("handoff","call","handoff_opened","")
    try communication("test","message","delivered","provider","real-a",["target":"test"])
    try communication("sample-send","message","delivered","provider","sample-a")
    try communication("orphan","message","delivered","provider","missing")
    try activity("linked","interaction","Message — Completed","real-a",nil,["communicationId":"delivered"])
    try activity("call","interaction","Call — Connected")
    try activity("voicemail","interaction","Call — Left voicemail")
    try activity("email","interaction","Email — Completed")
    try activity("manual-message","interaction","Message — Completed")
    try activity("failed-email","interaction","Email — Failed")
    try activity("note","note","Private note")
    try activity("draft","draft","Message draft saved")
    try activity("sample-note","note","Sample","sample-a")
    try activity("unclassified-note","note","Unknown","uncertain")
    try activity("malformed","interaction","Assume sent?")
    try activity("boundary-in","note","Timezone inclusion","real-a","\(year)-07-01T04:30:00Z")
    try activity("boundary-out","note","Timezone exclusion","real-a","\(year)-06-01T04:30:00Z")
    try store!.put("tasks",["id":"task-done","agentId":"real-a","dueDate":day,"completed":true,"completedAt":day+"T18:00:00Z"])
    try store!.put("tasks",["id":"task-open","agentId":"real-a","dueDate":day,"completed":false])
    try store!.put("tasks",["id":"task-reopened","agentId":"real-a","dueDate":day,"completed":false,"completedAt":day+"T18:00:00Z"])
    try store!.put("tasks",["id":"task-late","agentId":"real-a","dueDate":day,"completed":true,"completedAt":"\(year)-07-02T18:00:00Z"])
    try store!.put("tasks",["id":"task-early","agentId":"real-a","dueDate":"\(year)-07-01","completed":true,"completedAt":day+"T18:00:00Z"])
    try store!.put("tasks",["id":"sample-task","agentId":"sample-a","dueDate":day,"completed":true,"completedAt":day+"T18:00:00Z"])
    let report=try store!.managerReport(filter),metrics=report["metrics"] as! [String:Int],rates=report["rates"] as! Record
    try check(metrics["calls"] == 3 && metrics["connectedCalls"] == 1,"calls distinguish logged attempts and explicit connected outcomes")
    try check(metrics["messages"] == 3 && metrics["emails"] == 1 && metrics["notes"] == 2,"reports count confirmed/manual events and honor timezone boundaries")
    try check(metrics["tasksCompleted"] == 2 && metrics["tasksDue"] == 4 && metrics["dueTasksCompletedByEnd"] == 1,"task window and reopened records retain correct denominator")
    try check((rates["taskCompletion"] as! Record)["percent"] as? Double == 25 && (rates["contactCoverage"] as! Record)["denominator"] as? Int == 2,"rates show real denominators")
    let ex=report["exclusions"] as! [String:Int]
    try check(ex["linkedDuplicates"] == 1 && ex["test"] == 1 && ex["drafts"] == 1 && ex["failed"] == 2 && ex["unconfirmed"] == 3,"unconfirmed, duplicate, failed, draft and test events are excluded")
    let counts=report["verificationCounts"] as! [String:Int]
    try check(counts["provider"] == 1 && counts["user"] == 2 && counts["manual"] == 8,"evidence levels remain distinct")
    var sampleFilter=filter;sampleFilter["includeSamples"]=true
    let sampleReport=try store!.managerReport(sampleFilter),sampleMetrics=sampleReport["metrics"] as! [String:Int]
    try check(sampleMetrics["messages"] == 4 && sampleMetrics["notes"] == 3 && (sampleReport["datasetCounts"] as! [String:Int])["sample"] == 3,"explicit sample opt-in is separately labeled")
    let text=Store.managerReportText(report)
    try check(!text.contains("Private fixture") && !text.contains("Private message"),"export omits message/note bodies")
    var save=filter;save["id"]=UUID().uuidString
    _=try store!.command("report.save",save)
    let saved=try store!.get("reports",save["id"] as! String)
    try activity("later-note","note","Added after report")
    _=try store!.command("report.save",save)
    try check(NSDictionary(dictionary:saved).isEqual(to:try store!.get("reports",save["id"] as! String)),"saved report replay stays frozen")
    var changed=save;changed["toDate"]=day;try fails{_=try store!.command("report.save",changed)}
    store=nil;store=try Store(path:path,seed:false)
    try check(try store!.all("reports").count == 1,"saved reports survive reopen")
    let empty=try store!.managerReport(["fromDate":"\(year)-01-01","toDate":"\(year)-01-02","timeZone":"America/Chicago"])
    try check(((empty["rates"] as! Record)["taskCompletion"] as! Record)["percent"] is NSNull,"empty rate stays unknown rather than zero percent")
    // Gmail notices and calendar RSVP messages are not human replies. Keep
    // legacy unclassified imports usable without accepting new unknown classes.
    for (id,classification) in [("human","received_reply"),("notice","automatic_notice"),("rsvp","meeting_response"),("future","unsupported_class"),("legacy","")] {
        var message:Record=["id":id,"agentId":"real-b","provider":"gmail","providerMessageId":"fixture-"+id,"channel":"Email","direction":"inbound","occurredAt":day+"T17:00:00Z"]
        if !classification.isEmpty { message["messageClass"]=classification }
        try store!.put("externalMessages",message)
    }
    let classified=try store!.managerReport(filter),classifiedMetrics=classified["metrics"] as! [String:Int]
    try check(classifiedMetrics["emailReplies"] == 2 && classifiedMetrics["meetingResponses"] == 1,"human and legacy replies stay separate from calendar RSVP and notices")
    let classifiedExclusions=classified["exclusions"] as! [String:Int]
    try check(classifiedExclusions["automaticNotices"] == 1 && classifiedExclusions["unsupportedReplyClasses"] == 1,"automatic notices and unsupported message classes are explicitly excluded")
    try check(classified["distinctRespondingContacts"] as? Int == 1,"only actual reply records contribute to responding contacts")
    let classifiedText=Store.managerReportText(classified)
    try check(classifiedText.contains("Meeting responses imported: 1"),"manager export labels meeting responses independently")
    try runWeeklyReportDeliveryPlanTests()
    try runMeetingReportMetricsTests()
    print("PASS: sourced performance persistence/revisions, atomic import, unknown vs zero, dual-side totals, report evidence/dedupe/timezone/denominators, reply classification and frozen export.")
}


// Source fixtures only. None of these records represent real agents or production.
private func runProductionSeriesTests() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-production-series-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:dir) }
    let path = dir.appendingPathComponent("fixture.sqlite").path
    var store:Store? = try Store(path:path,seed:false)
    func check(_ condition:Bool,_ message:String)throws { if !condition { throw StoreError(message:"Production series test failed: "+message) } }
    func fails(_ body:()throws->Void)throws { do { try body() } catch { return }; throw StoreError(message:"Production series validation should fail") }
    let year=Int(Store.day().prefix(4))!-1
    try store!.put("agents",["id":"production-agent","name":"Fixture production agent","manual":true,"status":"Do not contact","localOverrides":["office"],"office":"User brokerage","history":[["note":"Preserve me"]]])
    try store!.put("agents",["id":"production-other","name":"Fixture second agent","manual":true])
    try store!.put("teams",["id":"production-team","name":"Fixture team","brokerage":"Fixture brokerage"])
    try store!.put("activities",["id":"production-note","agentId":"production-agent","kind":"note","body":"Keep this note"])
    try store!.put("tasks",["id":"production-promise","agentId":"production-agent","title":"Promised callback","completed":false])
    let originalAgent = try store!.get("agents","production-agent")
    var individual:Record=["agentId":"production-agent","year":year,"periodStart":"\(year)-01-01","periodEnd":"\(year)-12-31","asOfDate":"\(year)-12-31","coverage":"complete","attribution":"individual","source":["label":"Fixture licensed export","reference":"fixture://annual","method":"manual","providerId":"fixture-provider","recordIds":["0001","0002"],"checkedAt":Store.day()],"expectedRevision":0,"changeReason":"Fixture source evidence","buyerUnits":4,"buyerVolume":2_000_000,"sellerUnits":2,"sellerVolume":1_000_000,"dualSidedUnits":0,"dualSidedVolume":0]
    _ = try store!.command("performance.save",individual)
    let legacyID="production-agent:\(year)"
    try check(try store!.get("performance",legacyID)["schemaVersion"] as? Int == 1,"legacy individual ID remains unchanged")
    var team=individual;team["periodType"]="annual";team["teamId"]="production-team";team["attribution"]="team";team["buyerUnits"]=20;team["buyerVolume"]=10_000_000
    _ = try store!.command("performance.save",team)
    let teamRow=try store!.all("performance").first{$0["teamId"] as? String == "production-team"}!
    let teamID=teamRow["id"] as! String
    try check(teamID != legacyID && !Store.performanceIsIndividual(teamRow),"team series is distinct and cannot qualify as individual")
    try check(Store.performanceIsIndividual(try store!.get("performance",legacyID)),"legacy individual evidence remains eligible for individual review")
    try check(try store!.all("performance").count == 2,"one agent/year can retain separate individual and team figures")
    _ = try store!.command("performance.save",team)
    try check(try store!.get("performance",teamID)["revision"] as? Int == 1,"team replay does not duplicate or revise")
    var teamOnly=team;teamOnly.removeValue(forKey:"agentId");teamOnly["expectedRevision"]=1;teamOnly["recordId"]=teamID;teamOnly["changeReason"]="Remove optional contact link"
    _ = try store!.command("performance.save",teamOnly)
    try check(try store!.get("performance",teamID)["agentId"] as? String == "","team may be represented independently of a member")
    var invalidTeam=team;invalidTeam["teamId"]="missing-team";try fails{_ = try store!.command("performance.save",invalidTeam)}
    invalidTeam=team;invalidTeam["attribution"]="individual";try fails{_ = try store!.command("performance.save",invalidTeam)}
    invalidTeam=team;invalidTeam.removeValue(forKey:"teamId");try fails{_ = try store!.command("performance.save",invalidTeam)}
    var explicitDuplicate=individual;explicitDuplicate["periodType"]="annual"
    try fails{_ = try store!.command("performance.save",explicitDuplicate)}
    var legacyEdit=individual;legacyEdit["periodType"]="annual";legacyEdit["recordId"]=legacyID;legacyEdit["expectedRevision"]=1;legacyEdit["changeReason"]="Review legacy source and preserve its ID"
    _ = try store!.command("performance.save",legacyEdit)
    let migrated=try store!.get("performance",legacyID)
    try check(migrated["schemaVersion"] as? Int == 2 && (migrated["revisions"] as? [Record])?.count == 1,"reviewed legacy edit retains ID and prior source history")
    var switchAttribution=legacyEdit;switchAttribution["attribution"]="unknown";switchAttribution["expectedRevision"]=2
    try fails{_ = try store!.command("performance.save",switchAttribution)}
    var overlap=legacyEdit;overlap.removeValue(forKey:"recordId");overlap["periodStart"]="\(year)-03-01";overlap["expectedRevision"]=0;overlap["coverage"]="partial"
    try fails{_ = try store!.command("performance.save",overlap)}
    var ltm=individual;ltm["periodType"]="ltm";ltm["periodStart"]="\(year-1)-07-01";ltm["periodEnd"]="\(year)-06-30";ltm["asOfDate"]="\(year)-07-01"
    _ = try store!.command("performance.save",ltm)
    let ltmRow=try store!.all("performance").first{Store.performancePeriodType($0)=="ltm"}!
    try check(Store.performanceIsFullPeriod(ltmRow),"LTM dates are an explicitly full dated window")
    try check(try store!.all("performance").count == 3,"annual and LTM coexist without adding their overlapping totals")
    var nextLTM=ltm;nextLTM["periodStart"]="\(year-1)-08-01";nextLTM["periodEnd"]="\(year)-07-31";nextLTM["asOfDate"]="\(year)-08-01"
    _ = try store!.command("performance.save",nextLTM)
    var competing=nextLTM;competing["periodStart"]="\(year-1)-09-01";competing["periodEnd"]="\(year)-08-31";competing["asOfDate"]="\(year)-09-01";competing["source"]=["label":"Different coverage","method":"import","providerId":"other-provider"]
    try fails{_ = try store!.command("performance.import",["records":[competing]])}
    var shortLTM=ltm;shortLTM["periodStart"]="\(year)-01-01"
    try fails{_ = try store!.command("performance.save",shortLTM)}
    var checkedBeforeAsOf=individual;checkedBeforeAsOf["source"]=["label":"Bad checked date","method":"manual","checkedAt":"\(year)-01-01"]
    try fails{_ = try store!.command("performance.save",checkedBeforeAsOf)}
    var duplicateRefs=individual;duplicateRefs["source"]=["label":"Duplicate raw identifiers","method":"manual","recordIds":["001","001"]]
    try fails{_ = try store!.command("performance.save",duplicateRefs)}
    var imported=individual;imported["agentId"]="production-other";imported["periodType"]="annual";imported["source"]=["label":"Fixture licensed export","method":"import","providerId":"fixture-provider"]
    for key in ["buyerUnits","buyerVolume","sellerUnits","sellerVolume","dualSidedUnits","dualSidedVolume"] { imported[key]=NSNull() }
    imported["buyerUnits"]=0;imported["buyerVolume"]=0
    let before=try store!.all("performance").count
    var missingAgent=imported;missingAgent["agentId"]="not-present"
    try fails{_ = try store!.command("performance.import",["records":[imported,missingAgent]])}
    try check(try store!.all("performance").count == before,"multi-agent invalid input leaves all records unchanged")
    var conflictingImport=legacyEdit;conflictingImport["source"]=["label":"Fixture licensed export","method":"import","providerId":"fixture-provider"];conflictingImport["expectedRevision"]=0;conflictingImport["buyerUnits"]=99
    try fails{_ = try store!.command("performance.import",["records":[imported,conflictingImport]])}
    try check(try store!.all("performance").count == before,"late stale revision rolls back earlier valid row")
    _ = try store!.command("performance.import",["records":[imported]])
    let importedRow=try store!.all("performance").first{$0["agentId"] as? String == "production-other"}!
    let importedID=importedRow["id"] as! String
    try check(importedRow["buyerVolume"] as? Double == 0 && importedRow["sellerVolume"] is NSNull,"multi-agent annual import preserves zero and unknown separately")
    try check(Store.performanceTotals(importedRow)["uniqueVolume"] is NSNull,"unknown overlap never creates an individual volume claim")
    _ = try store!.command("performance.import",["records":[imported]])
    try check(try store!.get("performance",importedID)["revision"] as? Int == 1,"bulk replay is idempotent")
    var otherSource=imported;otherSource["recordId"]=importedID;otherSource["expectedRevision"]=1;otherSource["source"]=["label":"Competing source","method":"import","providerId":"other-provider"]
    try fails{_ = try store!.command("performance.import",["records":[otherSource]])}
    var aggregate=imported;aggregate["recordId"]=importedID;aggregate["expectedRevision"]=1;aggregate["reportedVolume"]=2_500_000;aggregate["volumeDefinition"]="unique_closed_volume";aggregate["changeReason"]="Explicitly defined source aggregate"
    _ = try store!.command("performance.import",["records":[aggregate]])
    let aggregateRow=try store!.get("performance",importedID)
    try check(Store.performanceTotals(aggregateRow)["uniqueVolume"] as? Double == 2_500_000 && aggregateRow["sellerVolume"] is NSNull && aggregateRow["dualSidedVolume"] is NSNull,"explicit source aggregate supplies volume without invented side breakdown")
    var genericVolume=aggregate;genericVolume.removeValue(forKey:"volumeDefinition");try fails{_ = try store!.command("performance.import",["records":[genericVolume]])}
    var conflictingAggregate=legacyEdit;conflictingAggregate["expectedRevision"]=2;conflictingAggregate["reportedVolume"]=99;conflictingAggregate["volumeDefinition"]="unique_closed_volume"
    try fails{_ = try store!.command("performance.save",conflictingAggregate)}
    try check(NSDictionary(dictionary:try store!.get("agents","production-agent")).isEqual(to:originalAgent),"production import preserves recruiter fields, suppression and history")
    try check(try store!.get("activities","production-note")["body"] as? String == "Keep this note" && store!.get("tasks","production-promise")["completed"] as? Bool == false,"notes and promised follow-up survive")
    store=nil;store=try Store(path:path,seed:false)
    try check(try store!.get("performance",teamID)["revision"] as? Int == 2 && store!.get("performance",legacyID)["revision"] as? Int == 2,"separate series and legacy history persist after restart")
    try check(try store!.get("performance",importedID)["sellerVolume"] is NSNull,"unknown source fields persist after restart")
    print("PASS: independent individual/team/LTM series, legacy IDs/history, provenance collisions, multi-agent atomicity, replay, null/zero, preserved suppression/follow-ups and restart readback.")
}

func runMeetingReportMetricsTests() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-meeting-metrics-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let store=try Store(path:directory.appendingPathComponent("fixture.sqlite").path,seed:false)
    let year=Int(Store.day().prefix(4))!-1,day="\(year)-06-15",later="\(year)-06-16"
    let filter:Record=["fromDate":"\(year)-06-01","toDate":"\(year)-06-30","timeZone":"America/Chicago"]
    try store.put("agents",["id":"real-one","name":"Private Name","manual":true])
    try store.put("agents",["id":"real-two","name":"Other Private Name","manual":true])
    for (id,title) in [("conversation-one","Call — Connected"),("conversation-two","Call — Connected"),("conversation-three","Call — connected"),("completed-call","Call — Completed")] {
        try store.put("activities",["id":id,"agentId":"real-one","kind":"interaction","title":title,"date":day+"T16:00:00Z"])
    }
    try store.put("workflows",["id":"call-workflow-three","agentId":"real-one","interactionId":"conversation-three","callId":"exact-call-three","source":"user_confirmed","outcome":"connected","occurredAt":day+"T16:00:00Z","occurredOn":day])
    try store.put("tasks",["id":"completed-meeting-task","agentId":"real-one","type":"Meeting","completed":true,"completedAt":later+"T16:00:00Z","dueDate":later])
    func check(_ condition:Bool,_ message:String)throws{if !condition{throw StoreError(message:"Meeting report metrics: "+message)}}
    func booking(_ id:String,_ link:String,_ extra:Record=[:])throws {
        var row:Record=["id":id,"agentId":"real-one","state":"booked","status":"confirmed","bookedAt":later+"T17:00:00Z","startsAt":later+"T18:00:00Z","endsAt":later+"T18:30:00Z","timeZone":"America/Chicago","source":"google_calendar","providerVerifiedAt":later+"T17:00:01Z","googleEventId":"google-"+id]
        if !link.isEmpty{row["linkedConversationID"]=link}
        for(key,value) in extra{row[key]=value}
        try store.put("meetings",row)
    }
    let initial=try store.managerReport(filter),initialMetrics=initial["metrics"] as! [String:Int]
    try check(initialMetrics["calls"]==4 && initialMetrics["connectedCalls"]==3,"only explicit conversations count; lowercase controlled workflow outcome is supported")
    try check(initialMetrics["appointmentsBooked"]==0 && initialMetrics["meetingsHeld"]==0,"completed Meeting task and expired event times do not establish a meeting")
    try check(((initial["rates"] as! Record)["conversationToMeeting"] as! Record)["percent"] is NSNull,"no verified conversion remains unavailable instead of an invented zero")
    try booking("meeting-one","activity:conversation-one",["heldAt":later+"T18:15:00Z","heldRecordedAt":later+"T18:16:00Z","heldSource":"user_confirmed"])
    try booking("meeting-two","activity:conversation-one",["status":"cancelled"])
    try booking("meeting-three","workflow:call-workflow-three")
    try booking("future","activity:conversation-two",["bookedAt":"\(year)-07-01T17:00:00Z"])
    var report=try store.managerReport(filter),m=report["metrics"] as! [String:Int],rate=(report["rates"] as! Record)["conversationToMeeting"] as! Record
    try check(m["appointmentsBooked"]==3 && m["meetingsHeld"]==1,"verified booking events survive later cancellation; held requires explicit outcome")
    try check(m["convertedConversations"]==2 && rate["numerator"] as? Int==2 && rate["denominator"] as? Int==3,"multiple bookings for one conversation count once and workflow/activity aliases agree")
    try check(abs((rate["percent"] as? Double ?? 0)-200.0/3)<0.0001,"linked conversation conversion has an explicit denominator")
    let email=try Store.weeklyReportEmailContent(report,plan:["recipients":["cody@sprouthomes.com"],"subject":"Weekly recruiting activity"])
    let body=email["body"] as? String ?? ""
    try check(body.contains("Appointments booked: 3") && body.contains("Meetings held: 1") && body.contains("2 / 3"),"aggregate email includes requested booking/held/conversion metrics")
    try check(!body.contains("Private Name") && !body.contains("google-meeting") && body.contains("may be missing"),"email omits contact detail and exposes incomplete-history limits")
    try booking("unlinked","")
    report=try store.managerReport(filter);rate=(report["rates"] as! Record)["conversationToMeeting"] as! Record
    try check(rate["percent"] is NSNull && rate["unlinkedBookings"] as? Int==1,"unlinked bookings make conversion unverifiable instead of implying a rate")
    try booking("wrong-agent","activity:conversation-two",["agentId":"real-two"])
    try booking("before-call","activity:conversation-two",["bookedAt":day+"T15:00:00Z"])
    try booking("unverified","activity:conversation-two",["state":"prepared"])
    report=try store.managerReport(filter);m=report["metrics"] as! [String:Int]
    let exclusions=report["exclusions"] as! [String:Int]
    try check(m["appointmentsBooked"]==6 && exclusions["invalidMeetingLinks"]==2 && exclusions["unverifiedMeetings"]==1,"cross-contact and before-call links cannot convert; prepared provider attempts cannot count as bookings")
    let empty=try store.managerReport(["fromDate":"\(year)-01-01","toDate":"\(year)-01-02","timeZone":"America/Chicago"])
    try check(((empty["rates"] as! Record)["conversationToMeeting"] as! Record)["percent"] is NSNull,"zero conversations has no conversion percentage")
    print("PASS: explicit conversations, verified booking and held outcomes, exact call linkage, deduplicated conversions, invalid/missing evidence and aggregate weekly email")
}
