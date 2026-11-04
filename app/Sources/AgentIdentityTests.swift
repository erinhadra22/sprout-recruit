import Foundation

func runAgentIdentityTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message:"Agent identity test failed: \(message)") }
    }
    func rejects(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch is StoreError { return }
        throw StoreError(message:"Agent identity test failed: expected rejection — \(message)")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-identity-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let storePath = root.appendingPathComponent("fixture.sqlite").path
    var store: Store? = try Store(path:storePath,seed:false)
    let scoped: Record = ["license":"00123-S","licenseJurisdiction":"tx","licenseType":"Salesperson"]
    let normalized = try AgentIdentity.normalized(scoped)
    try check(normalized["license"] as? String == "00123-S" && normalized["licenseRaw"] as? String == "00123-S","leading zeroes and type suffix retained")
    try check(normalized["licenseJurisdiction"] as? String == "TX" && normalized["licenseType"] as? String == "sales-agent","scope canonicalized separately")
    let texasAlias = try AgentIdentity.normalized(["license":"00123-S","licenseJurisdiction":"US-TX","licenseType":"Sales Agent"])
    try check(AgentIdentity.licenseKey(texasAlias) == AgentIdentity.licenseKey(normalized),"documented Texas type/jurisdiction labels share one identity")
    try check(texasAlias["licenseJurisdictionRaw"] as? String == "US-TX" && texasAlias["licenseTypeRaw"] as? String == "Sales Agent","original type and jurisdiction labels retained")
    try check(AgentIdentity.licenseKey(["license":"00123-S","licenseJurisdiction":"TX","licenseType":"salesperson"]) == AgentIdentity.licenseKey(normalized),"old stored type labels match without rekeying IDs")
    let unknownType = try AgentIdentity.normalized(["license":"00123-S","licenseJurisdiction":"TX","licenseType":"special-real-estate-license"])
    try check(AgentIdentity.licenseKey(unknownType) != AgentIdentity.licenseKey(normalized),"unknown types remain distinct")
    var rawSpaces = scoped; rawSpaces["license"] = " 00123-S "
    let rawNormalized = try AgentIdentity.normalized(rawSpaces)
    try check(rawNormalized["licenseRaw"] as? String == " 00123-S " && rawNormalized["license"] as? String == "00123-S","raw input retained alongside trimmed matching value")
    for changed in [["license":"123-S"],["licenseJurisdiction":"CA"],["licenseType":"broker"]] {
        var variant = scoped; for (key,value) in changed { variant[key] = value }
        try check(AgentIdentity.licenseKey(try AgentIdentity.normalized(variant)) != AgentIdentity.licenseKey(normalized),"zeroes, jurisdiction and type produce distinct keys")
    }
    try rejects("raw and normalized license mismatch") { _ = try AgentIdentity.normalized(["license":"00123-S","licenseRaw":"00123-B","licenseJurisdiction":"TX","licenseType":"salesperson"]) }
    try rejects("invalid source date") { _ = try AgentIdentity.normalized(["sourceAliases":[["provider":"ntreis","sourceId":"1","observedAt":"last Tuesday"]]]) }
    let datedAliases = try AgentIdentity.normalized(["sourceAliases":[["provider":"ntreis","sourceId":"1","observedAt":"2026-01-01T01:02:03.000Z"]]])
    try check((datedAliases["sourceAliases"] as? [Record])?.count == 1,"valid ISO source timestamp accepted")
    try rejects("numeric license loses leading zeroes") { _ = try AgentIdentity.normalized(["license":123,"licenseJurisdiction":"TX","licenseType":"salesperson"]) }
    try rejects("new unscoped license") { _ = try AgentIdentity.normalized(["license":"00123"]) }
    try rejects("one-sided source change cannot reuse old ID") { _ = try AgentIdentity.normalized(["sourceProvider":"different"],existing:["sourceProvider":"original","sourceAgentId":"0001"]) }
    try rejects("one-sided MLS change cannot reuse old ID") { _ = try AgentIdentity.normalized(["mls":"Other MLS"],existing:["mls":"NTREIS","mlsId":"0001"]) }
    try rejects("half source alias") { _ = try AgentIdentity.normalized(["sourceProvider":"ntreis"]) }
    try rejects("bad alias array") { _ = try AgentIdentity.normalized(["sourceAliases":"not an array"]) }
    try rejects("empty alias ID") { _ = try AgentIdentity.normalized(["sourceAliases":[["provider":"ntreis","sourceId":""]]]) }

    var create = scoped; create["name"] = "Fixture Licensed Person"
    _ = try store!.command("agent.create",create)
    let first = try store!.all("agents")[0], firstID = first["id"] as! String
    try check(first["licenseRaw"] as? String == "00123-S","manual creation persists license fields")
    try rejects("manual duplicate") { _ = try store!.command("agent.create",create) }
    var typedAlias = create; typedAlias["licenseJurisdiction"] = "US-TX"; typedAlias["licenseType"] = "Sales Agent"
    try rejects("equivalent Texas labels cannot create duplicate") { _ = try store!.command("agent.create",typedAlias) }
    var otherState = create; otherState["licenseJurisdiction"] = "CA"
    _ = try store!.command("agent.create",otherState)
    var otherType = create; otherType["licenseType"] = "broker"
    _ = try store!.command("agent.create",otherType)
    var zeroVariant = create; zeroVariant["license"] = "123-S"
    _ = try store!.command("agent.create",zeroVariant)
    try check(try store!.all("agents").count == 4,"scope and exact raw identifier distinguish people")
    _ = try store!.command("agent.update",["agentId":firstID,"sourceAliases":[["provider":"NTREIS","sourceId":"member-0001","reference":"fixture-roster","observedAt":Store.day()]],"city":"Waco"])
    _ = try store!.command("agent.update",["agentId":firstID,"phone":"5125550101"])
    var saved = try store!.get("agents",firstID)
    try check((saved["sourceAliases"] as? [Record])?.count == 1 && saved["license"] as? String == "00123-S","unrelated manual edits retain identity and aliases")
    let second = try store!.all("agents").first { $0["licenseJurisdiction"] as? String == "CA" }!
    try rejects("alias cannot move to another contact") { _ = try store!.command("agent.update",["agentId":second["id"]!,"sourceProvider":"ntreis","sourceAgentId":"member-0001"]) }
    try rejects("conflicting license replacement") { _ = try store!.command("agent.update",["agentId":firstID,"license":"123-S"]) }
    try check(try store!.get("agents",firstID)["license"] as? String == "00123-S","failed correction leaves old identity intact")

    let overlappingMLS = [["id":"old-normalized-identity","mls":"Test MLS","mlsId":"a-b-001"] as Record]
    try rejects("old lossy MLS formatting is reviewed, not merged") { _ = try AgentIdentity.match(["mls":"TestMLS","mlsId":"ab001"],among:overlappingMLS) }
    let preciseMLS = try AgentIdentity.match(["mls":"Test MLS","mlsId":"a-b-001"],among:overlappingMLS)
    try check(preciseMLS?["id"] as? String == "old-normalized-identity","exact old MLS evidence retains existing ID")
    let duplicateStore = try Store(path:root.appendingPathComponent("preexisting-duplicates.sqlite").path,seed:false)
    var duplicated = first; duplicated["id"] = "preexisting-duplicate"
    try duplicateStore.put("agents",first); try duplicateStore.put("agents",duplicated)
    _ = try duplicateStore.command("agent.update",["agentId":firstID,"city":"Existing contact correction"])
    try check(try duplicateStore.get("agents",firstID)["city"] as? String == "Existing contact correction","preexisting duplicate does not prevent unrelated edit")

    let legacyID = "legacy-kept-id"
    try store!.put("agents",["id":legacyID,"name":"Legacy Fixture","license":"000777","mls":"NTREIS","mlsId":"old-member-7","datasetId":"live","status":"Do not contact","doNotContact":true,"office":"Recruiter correction","localOverrides":["office"],"history":[["title":"Preserve this history"]],"transactions":[],"signals":[]])
    try store!.put("tasks",["id":"keep-task","agentId":legacyID,"title":"Existing promise","completed":false])
    try rejects("unscoped old license needs alias evidence") { _ = try store!.prepareAgentIntake(["license":"000777","licenseJurisdiction":"TX","licenseType":"salesperson"]) }
    let csv = root.appendingPathComponent("license-pilot.csv")
    let headers = ["Name","License Number","License Jurisdiction","License Type","MLS","MLS ID","Source Provider","Source Agent ID","Office"]
    let targets = ["name","license","licenseJurisdiction","licenseType","mls","mlsId","sourceProvider","sourceAgentId","office"]
    let mappings: [Record] = zip(headers,targets).map { ["header":$0,"target":"core:"+$1,"label":$0,"type":"text"] }
    let row = "Legacy Fixture,000777,TX,salesperson,NTREIS,old-member-7,ntreis,member-new-7,Source office"
    try Data((headers.joined(separator:",")+"\n"+row+"\n").utf8).write(to:csv)
    let input: Record = ["paths":[csv.path],"mappings":mappings]
    let preview = try store!.previewGenericImport(input)
    try check(preview["hardConflicts"] as? Int == 0 && preview["updateAgents"] as? Int == 1,"MLS evidence permits adding scope to legacy license")
    var commit = input; commit["token"] = preview["token"]
    _ = try store!.commitGenericImport(commit)
    saved = try store!.get("agents",legacyID)
    try check(saved["licenseJurisdiction"] as? String == "TX" && saved["licenseRaw"] as? String == "000777","CSV enriches scoped identity on original ID")
    try check(saved["office"] as? String == "Recruiter correction" && saved["status"] as? String == "Do not contact" && saved["doNotContact"] as? Bool == true,"CSV preserves recruiter override and suppression")
    try check((saved["history"] as? [Record])?.count == 1 && (try store!.get("tasks","keep-task"))["agentId"] as? String == legacyID,"linked history and promise preserved")
    let retainedAliases = saved["sourceAliases"] as? [Record] ?? []
    try check(retainedAliases.contains { $0["provider"] as? String == "mls:ntreis" && $0["sourceId"] as? String == "old-member-7" },"legacy source alias retained")
    try check(retainedAliases.contains { $0["provider"] as? String == "ntreis" && $0["sourceId"] as? String == "member-new-7" },"new source alias retained")
    commit["token"] = try store!.previewGenericImport(input)["token"]
    try check(try store!.commitGenericImport(commit)["alreadyImported"] as? Bool == true,"license import replay idempotent")
    let beforeCount = try store!.all("agents").count
    let beforeBatchCount = try store!.all("importBatches").count
    let badRow = "Conflict Fixture,00123-S,TX,salesperson,,,ntreis,member-new-7,Conflict office"
    let newRow = "New Fixture,000888,TX,salesperson,,,,,Fixture office"
    try Data((headers.joined(separator:",")+"\n"+newRow+"\n"+badRow+"\n").utf8).write(to:csv)
    let conflictPreview = try store!.previewGenericImport(input)
    try check((conflictPreview["hardConflicts"] as? Int ?? 0) > 0,"license/source aliases pointing to different people block")
    commit["token"] = conflictPreview["token"]
    try rejects("conflicted batch is atomic") { _ = try store!.commitGenericImport(commit) }
    try check(try store!.all("agents").count == beforeCount && store!.all("importBatches").count == beforeBatchCount,"conflict leaves all contacts and batches unchanged")
    try Data((headers.joined(separator:",")+"\n"+newRow+"\n"+newRow+"\n").utf8).write(to:csv)
    try check((try store!.previewGenericImport(input)["hardConflicts"] as? Int ?? 0) > 0,"duplicate license rows cannot be imported twice")
    try Data((headers.joined(separator:",")+"\n"+newRow+"\n").utf8).write(to:csv)
    let licenseOnlyPreview = try store!.previewGenericImport(input)
    try check(licenseOnlyPreview["hardConflicts"] as? Int == 0 && licenseOnlyPreview["newAgents"] as? Int == 1,"scoped license is sufficient without Courted or MLS")
    commit["token"] = licenseOnlyPreview["token"]
    _ = try store!.commitGenericImport(commit)
    store = nil
    store = try Store(path:storePath,seed:false)
    try check(try store!.all("agents").count == beforeCount+1 && store!.get("agents",legacyID)["license"] as? String == "000777","identity and old IDs survive restart/readback")
    try runSourceNameCSVTests()
    print("PASS: scoped license identity, manual/CSV paths, leading zeroes, source aliases, conflicts, legacy preservation, rollback, replay and restart.")
}


private func runSourceNameCSVTests() throws {
    func check(_ condition:Bool,_ message:String)throws{if !condition{throw StoreError(message:"Source-name CSV test failed: "+message)}}
    func rejects(_ work:()throws->Void)throws{do{try work()}catch{return};throw StoreError(message:"Source-name CSV test expected rejection")}
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-csv-source-name-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:dir)}
    let store=try Store(path:dir.appendingPathComponent("fixture.sqlite").path,seed:false)
    let csv=dir.appendingPathComponent("names.csv")
    let headers=["Name","License","State","Type","Office"],targets=["name","license","licenseJurisdiction","licenseType","office"]
    let mappings:[Record]=zip(headers,targets).map{["header":$0,"target":"core:"+$1,"type":"text","label":$0]}
    let input:Record=["paths":[csv.path],"mappings":mappings]
    func write(_ name:String,_ office:String)throws{try Data((headers.joined(separator:",")+"\n"+"\(name),623935,TX,Sales Agent,\(office)\n").utf8).write(to:csv)}
    func commit()throws{let preview=try store.previewGenericImport(input);var p=input;p["token"]=preview["token"];_=try store.commitGenericImport(p)}
    try write("Fixture Natalie Johnson","Original office");try commit()
    let existing=try store.all("agents")[0],id=existing["id"] as! String
    try write("Fixture NATALIE CAROL DERRICK","Other office")
    let mismatch=try store.previewGenericImport(input)
    try check(mismatch["hardConflicts"] as? Int==1 && (mismatch["conflictDetails"] as? [String] ?? []).contains{$0.contains("Source name")},"same license with unrelated public/legal name requires review")
    try rejects{try commit()}
    try check(try store.all("agents").count==1 && store.get("agents",id)["name"] as? String=="Fixture Natalie Johnson" && store.all("importBatches").count==1,"conflicting source cannot overwrite or create a second contact")
    // Explicit manual edits stay available; later source updates preserve them.
    _=try store.command("agent.update",["agentId":id,"name":"Recruiter display name","office":"Recruiter office"])
    try write(" FIXTURE  NATALIE JOHNSON ","Source refresh office");try commit()
    let saved=try store.get("agents",id)
    try check(saved["name"] as? String=="Recruiter display name" && saved["office"] as? String=="Recruiter office","known source spelling and local overrides preserve manual edits")
    try write("Fixture NATALIE CAROL DERRICK","Another office")
    try check(try store.previewGenericImport(input)["hardConflicts"] as? Int==1,"an override is not permission for an unknown source alias")
    let raw=try AgentIdentity.normalized(["license":"0774072","licenseJurisdiction":"TX","licenseType":"Sales Agent","sourceAliases":[["provider":"fixture-trec","sourceId":"774072-SA"]]])
    try check(raw["licenseRaw"] as? String=="0774072" && raw["license"] as? String=="0774072","published leading zero remains separate from provider source ID")
    try rejects{_=try AgentIdentity.normalized(["licenseRaw":"0774072","license":"774072-SA","licenseJurisdiction":"TX","licenseType":"Sales Agent"])}
    var aliasContact=raw;aliasContact["id"]="fixture-zero"
    try rejects{_=try AgentIdentity.match(["license":"774072-SA","licenseJurisdiction":"TX","licenseType":"Sales Agent","sourceAliases":[["provider":"fixture-trec","sourceId":"774072-SA"]]],among:[aliasContact])}
    let broker=try AgentIdentity.normalized(["license":"711670","licenseJurisdiction":"TX","licenseType":"Broker Individual"])
    let salesperson=try AgentIdentity.normalized(["license":"711670","licenseJurisdiction":"TX","licenseType":"Sales Agent"])
    try check(AgentIdentity.licenseKey(broker) != AgentIdentity.licenseKey(salesperson) && broker["licenseTypeRaw"] as? String=="Broker Individual","provider broker-individual scope remains distinct from salesperson")
}
