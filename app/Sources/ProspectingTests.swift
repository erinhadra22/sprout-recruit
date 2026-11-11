import Foundation

private func runProspectingInterimTests() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-interim-tests-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:dir)}
    let path=dir.appendingPathComponent("fixture.sqlite").path
    var store:Store?=try Store(path:path,seed:false)
    func check(_ condition:Bool,_ message:String)throws{if !condition{throw StoreError(message:"Interim prospecting test failed: "+message)}}
    func fails(_ body:()throws->Void)throws{do{try body()}catch{return};throw StoreError(message:"Interim prospecting test expected failure")}
    let today=Store.prospectingLocalDay(),cutoff=Store.parseDay(today)!,anniversary=Calendar(identifier:.gregorian).date(byAdding:.year,value:-2,to:cutoff)!
    let original=Store.day(anniversary)
    let row:Record=["name":"Interim Fixture","license":"009001-SA","licenseJurisdiction":"TX","licenseType":"Sales Agent","sourceAgentId":"009001-SA","serviceCities":["Waco"],"serviceJurisdiction":"TX","experienceYears":NSNull(),"experienceCheckedAt":today,"experienceReference":"fixture://professional/service","individualVolume":NSNull(),"licenseStatus":"Active","originalLicenseDate":original,"licenseCheckedAt":today,"licenseReference":"fixture://registry/009001-SA","identityMatchStatus":"verified","identityCheckedAt":today,"identityReference":"fixture://identity/review","phone":"+12545559001"]
    func payload(_ rows:[Record])->Record{["serviceAreaId":"broader-waco","mappingId":"canonical-license-roster","source":["providerId":"interim-fixture","label":"Reviewed public fixture","reference":"fixture://interim/roster","kind":"public_roster","checkedAt":today],"rows":rows]}
    func qualification(_ r:Record)throws->Record{let p=try store!.previewProspecting(payload([r]));return (p["rows"] as! [Record])[0]["qualification"] as! Record}
    func stage(_ rows:[Record])throws->[String]{var p=payload(rows);let preview=try store!.previewProspecting(p);p["previewToken"]=preview["previewToken"];_=try store!.command("discovery.stage",p);return (preview["rows"] as! [Record]).map{$0["id"] as! String}}
    func accept(_ ids:[String],newOnly:Bool=true)throws{
        var revisions=[String:Int]();for id in ids{revisions[id]=try store!.get("discoveryProspects",id)["revision"] as? Int ?? 0}
        _=try store!.command("discovery.accept",["recordIds":ids,"expectedRevisions":revisions,"reviewConfirmed":true,"newRecordsOnly":newOnly,"requiredEligibilityMode":"interim_license_tenure"])
    }
    func setMode(_ mode:String)throws{
        let old=try store!.all("serviceAreas").first{$0["id"] as? String=="broader-waco"}
        try store!.saveServiceArea(["id":"broader-waco","name":"Broader Waco","jurisdiction":"TX","cities":["Waco"],"eligibilityMode":mode,"expectedRevision":old?["revision"] as? Int ?? 0])
    }
    try check(try qualification(row)["state"] as? String=="needs_evidence","unchanged default full-production mode does not qualify unknown volume/experience")
    try setMode("interim_license_tenure")
    let q=try qualification(row)
    try check(q["state"] as? String=="interim_eligible" && q["productionThresholdMet"] as? Bool==false,"exact two-year anniversary qualifies only for interim consideration")
    try check((q["fullProductionQualification"] as? Record)?["state"] as? String=="needs_evidence" && !(q["missingEvidence"] as? [String] ?? []).isEmpty,"full-production assessment and missing evidence remain visible")
    var productionKnown=row
    let priorYear=Int(today.prefix(4))!-1
    for (key,value) in ["periodStart":"\(priorYear)-01-01","periodEnd":"\(priorYear)-12-31","periodType":"annual","asOfDate":"\(priorYear)-12-31","coverage":"complete","attribution":"individual","volumeDefinition":"unique_closed_volume","productionCheckedAt":today,"productionReference":"fixture://production/verified"]{productionKnown[key]=value}
    productionKnown["individualVolume"]=2_500_000
    let metricOnly=try qualification(productionKnown)
    try check(metricOnly["state"] as? String=="interim_eligible" && metricOnly["productionThresholdMet"] as? Bool==true,"production threshold is independent of missing actual-experience evidence")
    productionKnown["experienceYears"]=3
    try check(try qualification(productionKnown)["state"] as? String=="qualified","passing both rubrics is fully qualified, not double counted as interim")
    let area=try store!.get("serviceAreas","broader-waco")
    try store!.saveServiceArea(["id":"broader-waco","name":"Broader Waco updated","jurisdiction":"TX","cities":["Waco"],"expectedRevision":area["revision"] as! Int])
    try check(try store!.get("serviceAreas","broader-waco")["eligibilityMode"] as? String=="interim_license_tenure","older area callers preserve the chosen mode when omitted")
    for key in ["identityMatchStatus","identityReference","identityCheckedAt","licenseStatus","licenseReference","licenseCheckedAt","originalLicenseDate","serviceCities","serviceJurisdiction","experienceReference","experienceCheckedAt"]{
        var missing=row;missing.removeValue(forKey:key)
        try check(try qualification(missing)["state"] as? String != "interim_eligible","missing \(key) never qualifies for interim consideration")
    }
    for (key,value) in [("identityMatchStatus","possible"),("identityMatchStatus","rejected"),("identityCheckedAt","2000-01-01"),("licenseCheckedAt","2000-01-01"),("experienceCheckedAt","2000-01-01"),("licenseStatus","Inactive"),("licenseType","Broker Company"),("serviceJurisdiction","CA")]{
        var bad=row;bad[key]=value;try check(try qualification(bad)["state"] as? String != "interim_eligible","invalid/stale \(key)=\(value) is held")
    }
    var short=row;short["originalLicenseDate"]=Store.day(Calendar(identifier:.gregorian).date(byAdding:.day,value:1,to:anniversary)!)
    try check(try qualification(short)["state"] as? String=="not_qualified","one day short of two calendar years does not pass")
    var broker=row;broker["licenseType"]="Broker Individual";broker["license"]="009001-B"
    try check(try qualification(broker)["state"] as? String=="interim_eligible","individual broker qualifies for interim consideration")
    var malformed=row;malformed["originalLicenseDate"]="02/30/2020"
    try check(!(try store!.previewProspecting(payload([malformed]))["hardConflicts"] as! [String]).isEmpty,"malformed date is a hard source-data conflict")
    malformed=row;malformed["originalLicenseDateRaw"]="01/01/2000"
    try check(!(try store!.previewProspecting(payload([malformed]))["hardConflicts"] as! [String]).isEmpty,"parseable raw and canonical license dates must agree")
    var aiPreviewInput=payload([row]),aiSource=aiPreviewInput["source"] as! Record
    aiSource["sourceType"]="ai_agent";aiSource["sourceActor"]="Research Agent";aiSource["sourcedAt"]="2025-04-10T15:30:00Z";aiPreviewInput["source"]=aiSource
    let aiPreview=try store!.previewProspecting(aiPreviewInput),aiPreviewSource=(aiPreview["rows"] as! [Record])[0]["source"] as! Record
    try check(aiPreviewSource["sourceType"] as? String=="ai_agent" && aiPreviewSource["sourceActor"] as? String=="Research Agent" && aiPreviewSource["sourcedAt"] as? String=="2025-04-10T15:30:00Z","AI discovery keeps actor and source time separately from provider checked day")
    aiSource.removeValue(forKey:"sourceActor");aiPreviewInput["source"]=aiSource
    try fails{_=try store!.previewProspecting(aiPreviewInput)}
    let ids=try stage([row]),id=ids[0]
    let savedRevision=try store!.get("discoveryProspects",id)["revision"] as! Int
    try setMode("full_production")
    let refresh=try store!.prospectingWorkspace()["staged"] as! [Record]
    try check((refresh[0]["qualification"] as? Record)?["state"] as? String=="needs_evidence" && (try store!.get("discoveryProspects",id))["revision"] as? Int==savedRevision,"workspace recomputes changed mode without mutating staging")
    try fails{try accept(ids)}
    try setMode("interim_license_tenure")
    try accept(ids)
    let agent=try store!.all("agents").first!,aid=agent["id"] as! String
    try check(agent["status"] as? String=="Identified" && agent["volume"]==nil && agent["years"]==nil && (try store!.all("performance")).isEmpty,"interim intake invents neither production nor continuous experience")
    try check(agent["sourceType"] as? String=="provider_import" && agent["sourceReference"] as? String=="fixture://interim/roster" && agent["sourcedAt"] as? String==today,"discovery intake retains provider source and explicit checked day without inventing a source time")
    let admission=agent["recruitingEligibility"] as! Record
    try check(admission["state"] as? String=="interim_eligible" && admission["scope"] as? String=="at_intake" && admission["productionThresholdMet"] as? Bool==false,"admission metadata is explicitly interim and dated")
    let e=try store!.get("prospectingEvidence",aid)
    try check(e["experienceYears"] is NSNull && e["originalLicenseDate"] as? String==original && e["identityMatchStatus"] as? String=="verified","registry and identity evidence survives normal intake independently of experience")
    try store!.saveProspectingEvidence(["agentId":aid,"serviceCities":["Waco","Hewitt"],"serviceJurisdiction":"TX","experienceYears":NSNull(),"checkedAt":today,"source":["label":"Updated service review","reference":"fixture://service/review"],"expectedRevision":e["revision"] as! Int])
    let edited=try store!.get("prospectingEvidence",aid)
    try check(edited["originalLicenseDate"] as? String==original && edited["identityMatchStatus"] as? String=="verified","ordinary service evidence edits preserve omitted license evidence")
    try accept(ids)
    try check(try store!.all("agents").count==1,"exact imported replay remains a no-op under new-only intake")
    let planned=try store!.dailyActionPlan(),actions=planned["actions"] as! [Record],counters=planned["counters"] as! Record
    try check(actions.count==1 && actions[0]["action"] as? String=="Research recruiting interest" && actions[0]["qualificationState"] as? String=="interim_eligible","interim consideration without opportunity evidence does not become an automatic call")
    try check(counters["qualifiedDiscoveryToday"] as? Int==0 && counters["interimEligibleDiscoveryToday"] as? Int==1 && counters["eligibleDiscoveryToday"] as? Int==1,"interim counters never count unknown production as qualified")
    var dnc=agent;dnc["status"]="Do not contact";try store!.put("agents",dnc)
    try store!.put("tasks",["id":"dnc-interim-call","agentId":aid,"title":"Blocked call","type":"Call","dueDate":today,"completed":false])
    try check((try store!.dailyActionPlan()["actions"] as! [Record]).isEmpty,"DNC still excludes interim candidates and old calls")
    var refreshed=row;refreshed["experienceReference"]="fixture://new-service-source";_=try stage([refreshed])
    try fails{try accept(ids,newOnly:false)}
    try check(try store!.get("agents",aid)["status"] as? String=="Do not contact","suppression prevents refresh intake and survives rollback")
    var duplicate=row;duplicate["name"]="Different Legal Name";duplicate["license"]="9001-B";duplicate["licenseType"]="Broker Individual";duplicate["sourceAgentId"]="variant";duplicate["phone"]="+12545559002"
    let overlap=try stage([duplicate]);try fails{try accept(overlap)}
    try check(try store!.all("agents").count==1,"numeric TX formatting/type overlap is held without a merge or DNC bypass")
    var valid=row;valid["name"]="Second Interim";valid["license"]="009010-SA";valid["sourceAgentId"]="009010-SA";valid["phone"]="+12545559010"
    var invalid=valid;invalid["name"]="Third Interim";invalid["license"]="009011-SA";invalid["sourceAgentId"]="009011-SA";invalid["phone"]="+12545559011";invalid["identityMatchStatus"]="possible"
    let mixed=try stage([valid,invalid]);try fails{try accept(mixed)}
    try check(try store!.all("agents").count==1 && store!.get("discoveryProspects",mixed[0])["stage"] as? String=="discovery","a later missing-evidence row rolls back the whole accepted batch")
    store=nil;store=try Store(path:path,seed:false)
    try check((try store!.get("agents",aid)["recruitingEligibility"] as? Record)?["scope"] as? String=="at_intake" && store!.get("prospectingEvidence",aid)["originalLicenseDate"] as? String==original,"interim evidence and admission status survive restart")
    // Two provider rows for one person must not inflate the separate counters.
    let isolated=try Store(path:dir.appendingPathComponent("counter-conflict.sqlite").path,seed:false)
    try isolated.saveServiceArea(["id":"broader-waco","name":"Broader Waco","jurisdiction":"TX","cities":["Waco"],"eligibilityMode":"interim_license_tenure","expectedRevision":0])
    var fullID=""
    for (index,record) in [row,productionKnown].enumerated(){
        var p=payload([record]),source=p["source"] as! Record;source["providerId"]="counter-provider-\(index)";p["source"]=source
        let preview=try isolated.previewProspecting(p);p["previewToken"]=preview["previewToken"]
        _=try isolated.command("discovery.stage",p)
        if index==1{fullID=(preview["rows"] as! [Record])[0]["id"] as! String}
    }
    let counts=try isolated.dailyActionPlan()["counters"] as! Record
    try check(counts["discoveredToday"] as? Int==1 && counts["qualifiedDiscoveryToday"] as? Int==1 && counts["interimEligibleDiscoveryToday"] as? Int==0 && counts["eligibleDiscoveryToday"] as? Int==1,"one identity across full and interim sources counts once in the full-qualified bucket")
    let fullRevision=try isolated.get("discoveryProspects",fullID)["revision"] as! Int
    _=try isolated.command("discovery.accept",["recordIds":[fullID],"expectedRevisions":[fullID:fullRevision],"reviewConfirmed":true,"newRecordsOnly":true,"requiredEligibilityMode":"interim_license_tenure"])
    let fullAgent=try isolated.all("agents").first!,fullAgentID=fullAgent["id"] as! String
    // Simulate pre-existing conflicting history; normal production intake already
    // rejects such collisions, but the planner must also handle loaded evidence.
    var conflicting=try isolated.all("performance").first!
    conflicting["id"]="legacy-conflicting-series";conflicting["reportedVolume"]=3_500_000
    try isolated.put("performance",conflicting)
    let conflictPlan=try isolated.dailyActionPlan(),held=(conflictPlan["excluded"] as! [Record]).first{$0["agentId"] as? String==fullAgentID}!
    let conflict=held["qualification"] as! Record,fullConflict=conflict["fullProductionQualification"] as! Record
    try check((conflictPlan["actions"] as! [Record]).isEmpty && conflict["state"] as? String=="needs_evidence" && conflict["productionThresholdMet"] as? Bool==false,"conflicting same-period production remains held and cannot claim a verified threshold")
    try check(fullConflict["state"] as? String=="needs_evidence" && (fullConflict["missingEvidence"] as? [String] ?? []).contains(where:{$0.contains("Conflicting production totals")}),"nested full-production assessment carries the same conflict hold")
    print("PASS: interim license-tenure mode, evidence gates, calendar boundary, full-production separation, new-only duplicate/suppression guards, null preservation, replay, rollback and restart.")
}

func runProspectingTests() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-prospecting-tests-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:dir)}
    let path=dir.appendingPathComponent("fixture.sqlite").path
    var store:Store?=try Store(path:path,seed:false)
    func check(_ condition:Bool,_ message:String)throws{if !condition{throw StoreError(message:"Prospecting test failed: "+message)}}
    func fails(_ body:()throws->Void)throws{do{try body()}catch{return};throw StoreError(message:"Prospecting test expected failure")}
    let today=Store.prospectingLocalDay(),year=Int(today.prefix(4))!-1,start="\(year)-01-01",end="\(year)-12-31"
    let row:Record=["name":"Verified Fixture","license":"000123-A","licenseJurisdiction":"TX","licenseType":"sales agent","sourceAgentId":"member-001","office":"Fixture Office","officeCity":"Dallas","serviceCities":["Woodway"],"experienceYears":3,"experienceCheckedAt":today,"experienceReference":"https://example.test/agent/experience","periodStart":start,"periodEnd":end,"periodType":"annual","asOfDate":end,"coverage":"complete","attribution":"individual","individualVolume":2_500_000,"volumeDefinition":"unique_closed_volume","productionCheckedAt":today,"productionReference":"fixture://production/unique-closed" ]
    func payload(_ rows:[Record],_ provider:String="fixture-provider",_ kind:String="fixture")->Record{
        ["serviceAreaId":"broader-waco","mappingId":"canonical-license-roster","source":["providerId":provider,"label":"Reviewed fixture source","reference":"fixture://source/roster","kind":kind,"checkedAt":today],"rows":rows]
    }
    func stage(_ p:Record)throws -> Record{
        let preview=try store!.previewProspecting(p);var write=p;write["previewToken"]=preview["previewToken"]
        try store!.transaction{try store!.stageProspecting(write)};return preview
    }
    func accept(_ ids:[String])throws{
        var revisions=[String:Int]()
        for id in ids{revisions[id]=try store!.get("discoveryProspects",id)["revision"] as? Int ?? 0}
        try store!.transaction{try store!.acceptDiscoveredProspects(["recordIds":ids,"expectedRevisions":revisions,"reviewConfirmed":true])}
    }
    func state(_ row:Record)throws -> String {
        let preview=try store!.previewProspecting(payload([row]))
        return ((preview["rows"] as! [Record])[0]["qualification"] as! Record)["state"] as? String ?? ""
    }
    let initial=try store!.previewProspecting(payload([row]))
    try check(initial["readyCount"] as? Int==1,"explicit sourced individual annual evidence qualifies")
    try check(try store!.all("discoveryProspects").isEmpty && store!.all("agents").isEmpty,"preview has no writes")
    let staged=try stage(payload([row])),fixtureID=(staged["rows"] as! [Record])[0]["id"] as! String
    _=try stage(payload([row]))
    try check(try store!.all("discoveryProspects").count==1,"stage replay is idempotent")
    try fails{try accept([fixtureID])}
    try check(try store!.all("agents").isEmpty,"fixture cannot be promoted to real contact")
    var duplicate=row;duplicate["sourceAgentId"]="different-member"
    let duplicates=try store!.previewProspecting(payload([row,duplicate]))
    try check(!(duplicates["hardConflicts"] as! [String]).isEmpty,"duplicate license within source batch blocks stage")
    var numeric=row;numeric["license"]=123
    try check(!(try store!.previewProspecting(payload([numeric]))["hardConflicts"] as! [String]).isEmpty,"numeric licenses cannot lose zeros")
    var multiple=row;multiple["license"]="001, 002"
    try check(!(try store!.previewProspecting(payload([multiple]))["hardConflicts"] as! [String]).isEmpty,"multi-license source needs separate scopes")
    var unknown=row;unknown.removeValue(forKey:"serviceCities");unknown["individualVolume"]=NSNull()
    let incomplete=(try store!.previewProspecting(payload([unknown]))["rows"] as! [Record])[0]
    try check((incomplete["qualification"] as? Record)?["state"] as? String=="needs_evidence","office city and unknown volume cannot qualify")
    var wrongJurisdiction=row;wrongJurisdiction["licenseJurisdiction"]="CA"
    try check(try state(wrongJurisdiction)=="not_qualified","same-named city in another jurisdiction is not the selected footprint")
    var missingJurisdiction=row;missingJurisdiction.removeValue(forKey:"licenseJurisdiction")
    let missingScope=try store!.previewProspecting(payload([missingJurisdiction]))
    try check(!(missingScope["hardConflicts"] as! [String]).isEmpty,"missing license scope remains an intake conflict")
    var explicitService=row;explicitService["licenseJurisdiction"]="CA";explicitService["serviceJurisdiction"]="TX"
    try check(try state(explicitService)=="qualified","separate explicit service jurisdiction can evidence multi-state work")
    var zero=row;zero["individualVolume"]=0
    try check(try state(zero)=="not_qualified","known zero is distinct from unknown")
    var teamOnly=row;teamOnly["attribution"]="team";teamOnly["individualVolume"]=20_000_000
    try check(try state(teamOnly)=="needs_evidence","team volume cannot qualify individual")
    var stale=row;stale["productionCheckedAt"]="2000-01-01"
    try check(try state(stale)=="needs_evidence","stale checked dates remain missing evidence")
    var undefined=row;undefined.removeValue(forKey:"volumeDefinition")
    try check(try state(undefined)=="needs_evidence","ambiguous sales volume is not invented unique volume")
    var mapped=payload([row]);mapped["mapping"]=["id":"invalid","name":"Unknown map","fields":["age":"age"]]
    try fails{_=try store!.previewProspecting(mapped)}
    try fails{try store!.saveServiceArea(["id":"broader-waco","name":"Waco","jurisdiction":"TX","cities":["Waco"],"minIndividualVolume":1])}
    try store!.transaction{try store!.saveSourceMapping(["id":"custom-map","name":"Reusable mapping","fields":["license":"License Number","licenseType":"Type","name":"Agent"],"defaults":["licenseJurisdiction":"TX"],"expectedRevision":0])}
    let custom=try store!.get("sourceMappings","custom-map")
    try check((custom["defaults"] as? Record)?["licenseJurisdiction"] as? String=="TX","jurisdiction default is explicit mapping data")
    try fails{try store!.saveSourceMapping(["id":"bad-default","name":"Bad","fields":["license":"License"],"defaults":["individualVolume":2_000_000]])}

    // Same person in two public source contracts counts once and imports once.
    let first=try stage(payload([row],"public-one","public_roster")),second=try stage(payload([row],"public-two","public_roster"))
    let firstID=(first["rows"] as! [Record])[0]["id"] as! String,secondID=(second["rows"] as! [Record])[0]["id"] as! String
    let beforePlan=try store!.dailyActionPlan()
    try check((beforePlan["counters"] as? Record)?["discoveredToday"] as? Int==1,"discovery counts distinct licenses across providers and excludes fixtures")
    try check((beforePlan["counters"] as? Record)?["qualifiedDiscoveryToday"] as? Int==1 && (beforePlan["counters"] as? Record)?["qualifiedDiscoveryShortfall"] as? Int==9,"qualified new identities count separately and deduplicate providers")
    try accept([firstID])
    let imported=try store!.all("agents").first!,aid=imported["id"] as! String
    try check(imported["license"] as? String=="000123-A" && imported["licenseRaw"] as? String=="000123-A","raw license remains intact")
    try check(try store!.all("performance").count==1,"aggregate imports with explicit unique definition and period")
    let performance=try store!.all("performance").first!
    try check(performance["buyerVolume"] is NSNull && Store.performanceTotals(performance)["uniqueVolume"] as? Double==2_500_000,"aggregate does not fabricate side allocations")
    let samePreview=try stage(payload([row],"public-one","public_roster"))
    try check((samePreview["rows"] as! [Record])[0]["matchedAgentId"] as? String==aid,"new preview resolves imported identity")
    try check(try store!.get("discoveryProspects",firstID)["stage"] as? String=="imported","source replay does not revert imported stage")
    try accept([firstID])
    try check(try store!.all("agents").count==1,"accept replay retains agent identity")
    // A second source's production must not silently overwrite the first source.
    try fails{try accept([secondID])}
    try check(try store!.all("agents").count==1 && store!.get("discoveryProspects",secondID)["stage"] as? String=="discovery","production source collision rolls back batch")
    try check(!(try store!.get("agents",aid)["sourceAliases"] as? [Record] ?? []).contains{$0["provider"] as? String=="public-two"},"failed acceptance rolls back aliases as well as staged state")
    var modified=imported;modified["name"]="Recruiter-edited name";modified["email"]="kept@example.test";modified["localOverrides"]=["name","email"];modified["status"]="Connected";modified["history"]=[["title":"Preserve history"]]
    try store!.put("agents",modified);try store!.put("tasks",["id":"preserved-task","agentId":aid,"title":"Preserve task","completed":false,"dueDate":Store.plusDays(10),"type":"Call"])
    var refresh=row;refresh["email"]="new@example.test";refresh.removeValue(forKey:"individualVolume")
    _=try stage(payload([refresh],"public-one","public_roster"));try accept([firstID])
    let preserved=try store!.get("agents",aid)
    try check(preserved["name"] as? String=="Recruiter-edited name" && preserved["email"] as? String=="kept@example.test" && preserved["status"] as? String=="Connected","refresh preserves recruiter overrides and stage")
    try check((preserved["history"] as? [Record])?.count==1 && (try store!.get("tasks","preserved-task"))["agentId"] as? String==aid,"refresh preserves linked history/tasks")
    var conflicting=row;conflicting["license"]="00999"
    try check(!(try store!.previewProspecting(payload([conflicting],"public-one","public_roster"))["hardConflicts"] as! [String]).isEmpty,"provider alias cannot move between licenses")

    // Ten action priorities come from the full pool; due commitments and holds survive.
    try store!.put("teams",["id":"production-team-fixture","name":"Production fixture team","checkedAt":today,"source":["reference":"https://example.test/production-team"]])
    for n in 0..<16 {
        let id="pool-\(n)"
        try store!.put("agents",["id":id,"name":"Pool \(n)","datasetId":"live","manual":true,"source":"Fixture manual contact","status":"Identified","phone":"+1512555\(String(format:"%04d",n))","createdAt":"2020-01-01T00:00:00Z","years":99,"volume":99_000_000])
        if n != 6 {
            try store!.saveProspectingEvidence(["agentId":id,"serviceCities":["Waco"],"serviceJurisdiction":"TX","experienceYears":4,"checkedAt":today,"source":["label":"Professional evidence","reference":"https://example.test/\(id)"],"opportunity":["kind":"professional_need","summary":"Explicit business support request","occurredOn":today,"reference":"https://example.test/\(id)/statement"],"expectedRevision":0])
        }
        if n != 7 {
            var production:Record=["agentId":id,"year":year,"periodStart":start,"periodEnd":end,"periodType":"annual","asOfDate":end,"coverage":"complete","attribution":n==8 ? "team" : "individual","reportedVolume":3_000_000,"volumeDefinition":"unique_closed_volume","source":["label":"Fixture annual","reference":"fixture://annual/\(id)","method":"manual","checkedAt":today],"expectedRevision":0,"changeReason":"Qualification fixture"]
            if n==8{production["teamId"]="production-team-fixture"}
            try store!.savePerformance(production)
        }
    }
    try store!.put("tasks",["id":"due-one","agentId":"pool-0","type":"Call","title":"Promised callback","dueDate":today,"completed":false])
    try store!.put("tasks",["id":"due-duplicate","agentId":"pool-0","type":"Check-in","title":"Same-person follow-up","dueDate":today,"completed":false])
    var dnc=try store!.get("agents","pool-1");dnc["status"]="Do not contact";try store!.put("agents",dnc)
    try store!.put("tasks",["id":"dnc-call","agentId":"pool-1","type":"Call","title":"Blocked call","dueDate":today,"completed":false])
    try store!.put("tasks",["id":"dnc-review","agentId":"pool-1","type":"Review","title":"Review suppression evidence","dueDate":today,"completed":false])
    try store!.put("sequences",["id":"paused","agentId":"pool-2","pendingOutputState":"paused_reply","pauseReason":"inbound_reply"])
    try store!.put("tasks",["id":"paused-call","agentId":"pool-2","type":"Call","title":"Paused callback","dueDate":today,"completed":false])
    try store!.put("tasks",["id":"held-call","agentId":"pool-3","type":"Call","title":"Identity held callback","dueDate":today,"completed":false,"identityHoldId":"hold-1"])
    try store!.put("tasks",["id":"future-call","agentId":"pool-4","type":"Call","title":"Future promise","dueDate":Store.plusDays(5),"completed":false])
    try store!.put("teams",["id":"team-fixture","name":"Fixture team","checkedAt":today,"source":["reference":"https://example.test/team"]])
    try store!.put("teamMemberships",["id":"member-fixture","agentId":"pool-5","teamId":"team-fixture","role":"leader","startDate":"2020-01-01","endDate":"","checkedAt":today,"source":["reference":"https://example.test/team/leader"]])
    var changedPhone=try store!.get("agents","pool-9");changedPhone["manual"]=false;changedPhone["communicationVerification"]=["confirmed":true,"name":"Pool 9","source":"Fixture manual contact","phone":"+15125550000"];try store!.put("agents",changedPhone)
    let plan=try store!.dailyActionPlan(),actions=plan["actions"] as! [Record],ids=actions.compactMap{$0["agentId"] as? String}
    try check(actions.count==10 && Set(ids).count==ids.count,"planner caps at ten distinct contact actions")
    try check(ids.contains("pool-0") && (actions.first{$0["agentId"] as? String=="pool-0"}?["taskIds"] as? [String])?.count==2,"two due follow-ups combine into one contact action")
    try check(actions.first{$0["agentId"] as? String=="pool-1"}?["priorityKind"] as? String=="review","DNC review is allowed without suggesting outreach")
    try check(!ids.contains("pool-2") && !ids.contains("pool-3") && !ids.contains("pool-4"),"reply pause identity hold and future promise prevent calls")
    try check(!ids.contains("pool-6") && !ids.contains("pool-7") && !ids.contains("pool-8"),"old summaries missing service evidence and team totals never qualify")
    try check(actions.first{$0["priorityKind"] as? String=="qualified_opportunity"}?["agentId"] as? String=="pool-5","fresh verified team relation is preferred within same priority class")
    try check(actions.first{$0["agentId"] as? String=="pool-9"}?["action"] as? String=="Verify contact route before calling","changed saved phone invalidates old verification")
    try check((plan["counters"] as? Record)?["newProspectsGoal"] as? Int==10 && (plan["counters"] as? Record)?["actionGoal"] as? Int==10,"discovery and action goals remain independent")
    try check((plan["schedule"] as? Record)?["state"] as? String=="externally_managed","schedule is managed externally; app installs no scheduler")
    var oldTeam=try store!.get("teams","team-fixture");oldTeam["checkedAt"]="2000-01-01";try store!.put("teams",oldTeam)
    let withoutFreshTeam=try store!.dailyActionPlan()["actions"] as! [Record]
    try check(withoutFreshTeam.first{$0["agentId"] as? String=="pool-5"}?["teamPreference"] as? Bool==false,"stale team source cannot earn current team preference")
    try store!.saveServiceArea(["id":"another-city","name":"Another market","jurisdiction":"TX","cities":["Houston"],"expectedRevision":0])
    let shortPlan=try store!.dailyActionPlan(["serviceAreaId":"another-city"])
    try check((shortPlan["actions"] as! [Record]).count==2 && (shortPlan["counters"] as? Record)?["actionShortfall"] as? Int==8,"shortfall is exposed instead of padding with unqualified contacts")
    let agentCount=try store!.all("agents").count,taskCount=try store!.all("tasks").count
    _=try store!.dailyActionPlan()
    try check(try store!.all("agents").count==agentCount && store!.all("tasks").count==taskCount,"planning is read-only and never auto-creates outreach tasks")
    store=nil;store=try Store(path:path,seed:false)
    try check(try store!.all("sourceMappings").count==1 && store!.all("discoveryProspects").count==3,"source mapping and staged records survive restart")
    try check((try store!.dailyActionPlan()["actions"] as! [Record]).count==10,"plan is reproducible after restart")
    try runProspectingInterimTests()
    try runProspectingSourceNameTests()
    try runProspectingCalendarTests()
    print("PASS: license-keyed staged discovery, documented unconnected source mappings, explicit atomic acceptance, period/coverage/null/freshness evidence, preserved overrides/history, distinct daily goals and ten-action full-pool planner.")
}


private func runProspectingCalendarTests() throws {
    func check(_ condition:Bool,_ message:String)throws{if !condition{throw StoreError(message:"Prospecting calendar test failed: "+message)}}
    let cases:[(String,String)] = [
        ("2026-10-29T01:00:00Z","2026-10-28"),
        ("2026-10-29T04:59:59.999Z","2026-10-28"),
        ("2026-10-29T05:00:00Z","2026-10-29"),
        ("2026-03-08T05:59:59Z","2026-03-07"),
        ("2026-03-08T06:00:00Z","2026-03-08"),
        ("2026-03-09T04:59:59Z","2026-03-08"),
        ("2026-03-09T05:00:00Z","2026-03-09"),
        ("2025-11-02T04:59:59Z","2025-11-01"),
        ("2025-11-02T05:00:00Z","2025-11-02"),
        ("2025-11-03T05:59:59Z","2025-11-02"),
        ("2025-11-03T06:00:00Z","2025-11-03")
    ]
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-prospect-calendar-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:dir)}
    let store=try Store(path:dir.appendingPathComponent("fixture.sqlite").path,seed:false)
    for (index,pair) in cases.enumerated() {
        let (timestamp,expectedDay)=pair
        try check(Store.prospectingTimestampDay(timestamp)==expectedDay,"UTC instant maps to Central day: \(timestamp)")
        let id="calendar-agent-\(index)"
        try store.put("agents",["id":id,"name":id,"datasetId":"live","manual":true,"status":"Identified","importedAt":timestamp])
        try store.put("discoveryProspects",["id":"calendar-discovery-\(index)","createdAt":timestamp,"isFixture":false,"newIdentityAtDiscovery":true,"fields":["license":"00\(index)","licenseJurisdiction":"TX","licenseType":"broker"],"serviceAreaId":"broader-waco"])
    }
    try check(Store.prospectingTimestampDay("2026-10-28")=="2026-10-28","legacy date-only evidence preserves its calendar day")
    try check(Store.prospectingTimestampDay("invalid")==nil,"invalid timestamps do not count")
    try check(Store.prospectingTimestampDay("2026-10-29T00:00:00-05:00")=="2026-10-29","explicit offset timestamps preserve the instant")
    for day in Set(cases.map{$0.1}) {
        let expected=cases.filter{$0.1==day}.count
        let plan=try store.dailyActionPlan(["asOfDate":day]),counters=plan["counters"] as! Record
        try check(counters["discoveredToday"] as? Int==expected && counters["importedToday"] as? Int==expected,"both daily counters honor Central midnight and DST for \(day)")
        try check(plan["timeZone"] as? String=="America/Chicago","plan declares its reporting timezone")
    }
    try store.put("tasks",["id":"calendar-due","agentId":"calendar-agent-0","title":"Existing promise","dueDate":"2026-10-28","type":"Call","completed":false])
    try store.put("tasks",["id":"calendar-future","agentId":"calendar-agent-1","title":"Future promise","dueDate":"2026-10-29","type":"Call","completed":false])
    let duePlan=try store.dailyActionPlan(["asOfDate":"2026-10-28"])
    let ids=(duePlan["actions"] as! [Record]).compactMap{$0["agentId"] as? String}
    try check(ids.contains("calendar-agent-0") && !ids.contains("calendar-agent-1"),"task date-only deadlines are compared without timestamp conversion")
    let defaultPlan=try store.dailyActionPlan()
    try check(defaultPlan["date"] as? String==Store.prospectingLocalDay(),"default plan uses Central calendar day")
}


private func runProspectingSourceNameTests() throws {
    func check(_ condition:Bool,_ message:String)throws{if !condition{throw StoreError(message:"Prospecting identity evidence test failed: "+message)}}
    func fails(_ body:()throws->Void)throws{do{try body()}catch{return};throw StoreError(message:"Prospecting identity evidence expected rejection")}
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-source-name-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:dir)}
    let store=try Store(path:dir.appendingPathComponent("fixture.sqlite").path,seed:false)
    let today=Store.prospectingLocalDay()
    let existing:Record=["id":"fixture-name","name":"Fixture Natalie Johnson","license":"623935","licenseJurisdiction":"TX","licenseType":"sales-agent","datasetId":"live","importedCoreValues":["name":"Fixture Natalie Johnson"],"history":[["title":"Preserve history"]]]
    try store.put("agents",existing)
    func payload(_ name:String)->Record {
        ["serviceAreaId":"broader-waco","mappingId":"canonical-license-roster","source":["providerId":"fixture-trec","label":"Synthetic source-name test","reference":"fixture://source-name","kind":"public_roster","checkedAt":today],"rows":[["name":name,"license":"623935","licenseJurisdiction":"TX","licenseType":"Sales Agent","sourceAgentId":"623935-SA","officeCity":"Waco","county":"McLennan"]]]
    }
    let mismatch=try store.previewProspecting(payload("Fixture NATALIE CAROL DERRICK"))
    try check((mismatch["hardConflicts"] as? [String] ?? []).contains{$0.contains("Source name")},"different legal/public names produce explicit preview conflict")
    var blocked=payload("Fixture NATALIE CAROL DERRICK");blocked["previewToken"]=mismatch["previewToken"]
    try fails{try store.transaction{try store.stageProspecting(blocked)}}
    try check(try store.all("discoveryProspects").isEmpty && store.get("agents","fixture-name")["name"] as? String==existing["name"] as? String,"name conflict stages and overwrites nothing")
    let same=try store.previewProspecting(payload("  FIXTURE   NATALIE JOHNSON  "))
    try check((same["hardConflicts"] as? [String] ?? []).isEmpty,"case and whitespace differences alone are not identity conflicts")
    let missing=((same["rows"] as! [Record])[0]["qualification"] as! Record)["missingEvidence"] as! [String]
    try check(missing.contains{$0.contains("service cities")},"county and office city do not supply verified service footprint")
    var stagedInput=payload("Fixture Natalie Johnson");stagedInput["previewToken"]=try store.previewProspecting(stagedInput)["previewToken"]
    try store.transaction{try store.stageProspecting(stagedInput)}
    let staged=try store.all("discoveryProspects")[0],sid=staged["id"] as! String
    var changed=existing;changed["name"]="Fixture Different Identity";try store.put("agents",changed)
    try fails{try store.transaction{try store.acceptDiscoveredProspects(["recordIds":[sid],"expectedRevisions":[sid:staged["revision"] as! Int],"reviewConfirmed":true])}}
    try check(try store.get("agents","fixture-name")["name"] as? String=="Fixture Different Identity" && store.get("discoveryProspects",sid)["stage"] as? String=="discovery","accept rechecks changed saved identity and preserves staged/source data")
    try fails{try store.stageProspecting(stagedInput)}
    // An explicit recruiter override may retain the exact old source spelling;
    // this never legitimizes a new, unrelated source spelling.
    changed["localOverrides"]=["name"];try store.put("agents",changed)
    let known=try store.previewProspecting(payload("Fixture Natalie Johnson"))
    try check((known["hardConflicts"] as? [String] ?? []).isEmpty,"known prior source name survives an explicit recruiter override")
    try check(!(try store.previewProspecting(payload("Fixture NATALIE CAROL DERRICK"))["hardConflicts"] as! [String]).isEmpty,"recruiter override does not authorize a new source-name alias")
}
