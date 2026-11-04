import Foundation

func runSourcingRulesTests() throws {
    func check(_ condition:Bool,_ message:String)throws{if !condition{throw StoreError(message:"Sourcing rules test failed: "+message)}}
    func fails(_ body:()throws->Void)throws{do{try body()}catch{return};throw StoreError(message:"Sourcing rules expected rejection")}
    let profile:Record=["revision":3,"excludedBrokerages":["Acme Realty"],"excludedTeams":["Café Team"]]
    let q:Record=["state":"qualified","reasons":["Verified baseline"],"missingEvidence":[String](),"failedCriteria":[String]()]
    let blocked=SourcingRules.assessment(fields:["office":" ACME-realty ","teamName":"Cafe Team"],profile:profile)
    try check(blocked["state"] as? String=="excluded" && (blocked["matches"] as? [Record])?.count==2,"explicit normalized names match brokerage and team")
    let similar=SourcingRules.assessment(fields:["office":"Acme Realty West","teamName":"Cafe Team North"],profile:profile)
    try check(similar["state"] as? String=="eligible","similar and franchise names are never inferred")
    let alternate=SourcingRules.assessment(fields:["office":"Local Office","brand":"Acme Realty","teamName":"Other"],profile:profile)
    try check(alternate["state"] as? String=="excluded","explicit source brand is checked alongside office")
    let missing=SourcingRules.assessment(fields:[:],profile:profile)
    try check(missing["state"] as? String=="needs_evidence" && (missing["missingEvidence"] as? [String])?.count==2,"unknown affiliation cannot pass configured exclusions")
    try check(SourcingRules.applying(blocked,to:q)["state"] as? String=="not_qualified","rule exclusions gate an otherwise qualified prospect")
    try check(SourcingRules.applying(missing,to:["state":"not_qualified"])["state"] as? String=="not_qualified","missing affiliation never loosens an existing failure")
    try check(SourcingRules.assessment(fields:[:],profile:SourcingRules.empty())["state"] as? String=="eligible","no default exclusions invented")
    try check(try SourcingRules.names(["Acme Realty"," ACME-REALTY ","Acme Realty West"],label:"names")==["Acme Realty","Acme Realty West"],"native dedup preserves distinct full names")
    try fails{_=try SourcingRules.names(["--"],label:"names")}
    try fails{_=try SourcingRules.names([String](repeating:"Name",count:101),label:"names")}
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-sourcing-rules-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:dir)}
    let path=dir.appendingPathComponent("fixture.sqlite").path
    var store:Store?=try Store(path:path,seed:false)
    let p:Record=["schemaVersion":1,"expectedRevision":0,"name":"Test audience","description":"Evidence only","excludedBrokerages":["Acme Realty"],"excludedTeams":["Blocked Team"]]
    _=try store!.command("sourcingRules.save",p)
    try check(try store!.sourcingRulesRecord()["revision"] as? Int==1,"route persists current revision")
    try fails{_=try store!.command("sourcingRules.save",p)}
    var same=p;same["expectedRevision"]=1;_=try store!.command("sourcingRules.save",same)
    try check(try store!.sourcingRulesRecord()["revision"] as? Int==1,"identical current save is a no-op")
    try check(try store!.get("settings","sourcing-rules-revision-000001")["name"] as? String=="Test audience","immutable revision retained")
    try store!.put("agents",["id":"fixture-agent","name":"Affiliation Fixture","office":"Other Brokerage","datasetId":"live"])
    try store!.put("teams",["id":"blocked-team","name":"Blocked Team"])
    try store!.put("teams",["id":"allowed-team","name":"Other Team"])
    let today=Store.prospectingLocalDay()
    try store!.put("teamMemberships",["id":"historical","agentId":"fixture-agent","teamId":"blocked-team","startDate":"2000-01-01","endDate":"2001-01-01"])
    try store!.put("teamMemberships",["id":"current","agentId":"fixture-agent","teamId":"allowed-team","startDate":"2002-01-01","endDate":""])
    let agent=try store!.get("agents","fixture-agent")
    try check(try store!.sourcingRuleAssessment(fields:agent,asOf:today)["state"] as? String=="eligible","expired team membership is ignored")
    try store!.put("teamMemberships",["id":"current-block","agentId":"fixture-agent","teamId":"blocked-team","startDate":"2002-01-01","endDate":""])
    try check(try store!.sourcingRuleAssessment(fields:agent,asOf:today)["state"] as? String=="excluded","current saved team membership is checked")
    store=nil;store=try Store(path:path,seed:false)
    try check(try store!.sourcingRulesRecord()["excludedBrokerages"] as? [String]==["Acme Realty"],"rules persist across restart")
    let known:Record=["name":"Sourcing Gate Fixture","license":"009700-SA","licenseJurisdiction":"TX","licenseType":"Sales Agent","sourceAgentId":"rule-known","office":"Other Brokerage","teamName":"Other Team"]
    var unknown=known;unknown["license"]="009701-SA";unknown["sourceAgentId"]="rule-unknown";unknown["name"]="Unknown Affiliation Fixture";unknown.removeValue(forKey:"office");unknown.removeValue(forKey:"teamName")
    var intake:Record=["mappingId":"canonical-license-roster","serviceAreaId":"broader-waco","source":["providerId":"sourcing-rule-fixture","label":"Rule test public roster","reference":"fixture://rules/roster","kind":"public_roster","checkedAt":today],"rows":[known,unknown]]
    let preview=try store!.previewProspecting(intake),previewRows=preview["rows"] as! [Record]
    try check((preview["hardConflicts"] as! [String]).isEmpty,"eligible and missing-affiliation evidence can be reviewed without an exclusion match")
    intake["previewToken"]=preview["previewToken"];_=try store!.command("discovery.stage",intake)
    let knownID=previewRows[0]["id"] as! String,unknownID=previewRows[1]["id"] as! String
    func accept(_ id:String)throws{let row=try store!.get("discoveryProspects",id);_=try store!.command("discovery.accept",["recordIds":[id],"expectedRevisions":[id:row["revision"] as! Int],"reviewConfirmed":true])}
    try fails{try accept(unknownID)}
    var changed=p;changed["expectedRevision"]=1;changed["excludedBrokerages"]=["Acme Realty","Other Brokerage"];_=try store!.command("sourcingRules.save",changed)
    try fails{_=try store!.command("discovery.stage",intake)}
    let blockedPreview=try store!.previewProspecting(intake)
    try check(blockedPreview["previewToken"] as? String != preview["previewToken"] as? String && !(blockedPreview["hardConflicts"] as! [String]).isEmpty,"changed rules invalidate old preview and block excluded staging")
    try fails{try accept(knownID)}
    try check(try store!.all("agents").count==1,"full-production reviewed intake cannot bypass exclusions or missing affiliation")
    let refreshed=try store!.prospectingWorkspace()["staged"] as! [Record]
    try check((refreshed.first{$0["id"] as? String==knownID}?["qualification"] as? Record)?["state"] as? String=="not_qualified","saved discoveries are reassessed after target rules change")
    try store!.put("tasks",["id":"rule-call","agentId":"fixture-agent","type":"Call","title":"Old call commitment","dueDate":today,"completed":false])
    try store!.put("tasks",["id":"rule-review","agentId":"fixture-agent","type":"Review","title":"Review affiliation","dueDate":today,"completed":false])
    let plan=try store!.dailyActionPlan(),actions=plan["actions"] as! [Record]
    try check(actions.count==1 && (actions[0]["taskIds"] as? [String])==["rule-review"] && actions[0]["priorityKind"] as? String=="review","exclusions retain due review tasks while suppressing outbound call recommendations")
    try check(try store!.all("tasks").count==2 && store!.all("agents").count==1,"rules never delete existing contacts or commitments")
    store=nil
    print("Sourcing rules tests passed")
}
