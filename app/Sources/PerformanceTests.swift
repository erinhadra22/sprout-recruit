import Foundation

func runPerformanceTests() throws {
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
    print("PASS: sourced performance persistence/revisions, atomic import, unknown vs zero, dual-side totals, report evidence/dedupe/timezone/denominators and frozen export.")
}
