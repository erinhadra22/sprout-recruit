import Foundation

func runGenericImportTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message:"Generic import test failed: \(message)") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-generic-import-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let path = root.appendingPathComponent("fixture.sqlite").path
    let csv = root.appendingPathComponent("contacts.csv")
    let source = "First Name,Last Name,Courted Profile URL,Current Office,LTM Sales Volume,Status,Specialty\nAna,Reed,https://brokerage.courted.io/agents/ana,Oak,0,Called,Luxury\n"
    try Data(source.utf8).write(to:csv)
    let store = try Store(path:path,seed:false)
    let oversized = root.appendingPathComponent("oversized.csv")
    FileManager.default.createFile(atPath:oversized.path,contents:nil)
    let oversizedHandle = try FileHandle(forWritingTo:oversized)
    try oversizedHandle.truncate(atOffset:30_000_001); try oversizedHandle.close()
    do { _ = try store.inspectGenericImport(["paths":[oversized.path]]); throw StoreError(message:"Oversized CSV unexpectedly passed.") }
    catch let error as StoreError { guard error.message != "Oversized CSV unexpectedly passed." else { throw error } }
    let inspection = try store.inspectGenericImport(["paths":[csv.path]])
    try check(inspection["rows"] as? Int == 1,"inspection counts rows")
    let columns = inspection["columns"] as? [Record] ?? []
    try check(columns.count == 7,"inspection reports every header")
    let mappings: [Record] = [
        ["header":"First Name","target":"core:firstName","label":"First Name","type":"text"],
        ["header":"Last Name","target":"core:lastName","label":"Last Name","type":"text"],
        ["header":"Courted Profile URL","target":"core:courtedProfileURL","label":"Courted Profile URL","type":"text"],
        ["header":"Current Office","target":"core:office","label":"Current Office","type":"text"],
        ["header":"LTM Sales Volume","target":"core:volume","label":"LTM Sales Volume","type":"number"],
        ["header":"Status","target":"core:sourceStatus","label":"Status","type":"text"],
        ["header":"Specialty","target":"custom:new","label":"Specialty","type":"text"]
    ]
    let input: Record = ["paths":[csv.path],"mappings":mappings]
    let preview = try store.previewGenericImport(input)
    try check(preview["newAgents"] as? Int == 1,"preview reports a new contact")
    try check(preview["hardConflicts"] as? Int == 0,"valid identity has no conflict")
    var commitInput = input; commitInput["token"] = preview["token"]
    let receipt = try store.commitGenericImport(commitInput)
    try check(receipt["newAgents"] as? Int == 1,"commit creates one contact")
    let first = try store.all("agents")[0]
    try check(first["sourceType"] as? String == "csv_import" && !(first["sourceReference"] as? String ?? "").isEmpty,"CSV acquisition automatically carries origin and batch/file reference")
    try check(first["sourcedAt"] == nil,"unknown CSV source date is not invented from import time")
    try check(first["volume"] as? Double == 0,"numeric zero is retained")
    try check(first["status"] as? String == "Called","valid source status initializes a new contact")
    try check(first["sourceStatus"] as? String == "Called","original source status remains separate")
    try check(first["statusAt"] == nil,"CSV status is not a verified interaction")
    try check((first["courtedFields"] as? Record)?["Specialty"] as? String == "Luxury","raw custom source is retained")
    try check((first["customValues"] as? Record)?.count == 1,"custom field is stored")
    try check(try store.all("customFields").count == 1,"custom field definition is stored")
    let reusedInspection = try store.inspectGenericImport(["paths":[csv.path]])
    let reusedColumn = (reusedInspection["columns"] as? [Record] ?? []).first { $0["header"] as? String == "Specialty" }
    let savedCustomID = try store.all("customFields")[0]["id"] as! String
    try check(reusedColumn?["suggestedTarget"] as? String == "custom:" + savedCustomID,"repeat upload suggests saved custom field")
    let replay = try store.previewGenericImport(input)
    try check(replay["alreadyImported"] as? Bool == true,"same file and mapping replay is recognized")
    commitInput["token"] = replay["token"]
    try check(try store.commitGenericImport(commitInput)["alreadyImported"] as? Bool == true,"replay is idempotent")
    try check(try store.all("agents").count == 1,"replay does not duplicate contact")

    var initialTimestampFixture = first
    initialTimestampFixture["importedAt"] = "2025-01-02T03:04:05Z"
    try store.put("agents",initialTimestampFixture)
    _ = try store.command("agent.update",["agentId":first["id"] as! String,"office":"Erin corrected office","status":"Connected"])
    let changed = source.replacingOccurrences(of:",Oak,0,Called,Luxury",with:",Pine,,Contacted,Commercial")
    try Data(changed.utf8).write(to:csv)
    let existingField = try store.all("customFields")[0]["id"] as! String
    var changedMappings = mappings
    changedMappings[6]["target"] = "custom:"+existingField
    let changedInput: Record = ["paths":[csv.path],"mappings":changedMappings]
    let changedPreview = try store.previewGenericImport(changedInput)
    try check(changedPreview["updateAgents"] as? Int == 1,"changed file updates strong identity")
    var changedCommit = changedInput; changedCommit["token"] = changedPreview["token"]
    let concurrentStore = try Store(path:path,seed:false)
    _ = try concurrentStore.command("agent.update",["agentId":first["id"] as! String,"city":"Concurrent correction"])
    do { _ = try store.commitGenericImport(changedCommit); throw StoreError(message:"Stale import unexpectedly passed.") }
    catch let error as StoreError { guard error.message != "Stale import unexpectedly passed." else { throw error } }
    try check(try store.get("agents",first["id"] as! String)["city"] as? String == "Concurrent correction","stale preview cannot overwrite second-connection edits")
    changedCommit["token"] = try store.previewGenericImport(changedInput)["token"]
    _ = try store.commitGenericImport(changedCommit)
    let updated = try store.all("agents")[0]
    try check(updated["createdAt"] as? String == first["createdAt"] as? String && updated["sourceReference"] as? String == first["sourceReference"] as? String && updated["sourcedAt"] == nil,"refresh preserves original added time and acquisition provenance")
    try check(updated["importedAt"] as? String == "2025-01-02T03:04:05Z","first import timestamp survives reimport")
    try check(updated["lastImportedAt"] as? String != updated["importedAt"] as? String,"latest import timestamp is separately recorded")
    try check(updated["office"] as? String == "Erin corrected office","user correction survives reimport")
    try check(updated["status"] as? String == "Connected","local CRM status survives reimport")
    try check(updated["sourceStatus"] as? String == "Contacted","source status refreshes separately")
    try check(updated["volume"] is NSNull,"blank new source value becomes unknown, distinct from zero")
    try check((updated["customValues"] as? Record)?[existingField] as? String == "Commercial","custom field refreshes")
    let broken = "First Name,Last Name,Courted Profile URL,Current Office,LTM Sales Volume,Status,Specialty\nAna,Reed,\"unfinished,Oak,1,Called,Luxury\n"
    try Data(broken.utf8).write(to:csv)
    do { _ = try store.previewGenericImport(changedInput); throw StoreError(message:"Malformed CSV unexpectedly passed.") }
    catch let error as StoreError {
        guard error.message != "Malformed CSV unexpectedly passed." else { throw error }
    }
    try check(try store.all("agents").count == 1,"malformed source cannot partially commit")

    let dupCSV = root.appendingPathComponent("weak-duplicates.csv")
    let weakRows = "Name,Courted Profile URL,Email\nBea One,https://brokerage.courted.io/agents/bea,same@example.com\nCal Two,https://brokerage.courted.io/agents/cal,same@example.com\n"
    try Data(weakRows.utf8).write(to:dupCSV)
    let dupMappings: [Record] = [
        ["header":"Name","target":"core:name","label":"Name","type":"text"],
        ["header":"Courted Profile URL","target":"core:courtedProfileURL","label":"Courted Profile URL","type":"text"],
        ["header":"Email","target":"core:email","label":"Email","type":"text"]
    ]
    let weakPreview = try store.previewGenericImport(["paths":[dupCSV.path],"mappings":dupMappings])
    try check(weakPreview["hardConflicts"] as? Int == 0,"shared email does not force identity merge")
    try check(weakPreview["possibleMatches"] as? Int == 1,"distinct imported identities with shared email need review")

    let variantA = root.appendingPathComponent("variant-a.csv")
    let variantB = root.appendingPathComponent("variant-b.csv")
    try Data("First Name,Last Name,Courted Profile URL,Current Office\nAva,One,https://brokerage.courted.io/agents/ava,Oak\n".utf8).write(to:variantA)
    try Data("First Name,Last Name,Courted Profile URL,Brokerage\nBea,Two,https://brokerage.courted.io/agents/bea,Pine\n".utf8).write(to:variantB)
    let variantStore = try Store(path:root.appendingPathComponent("variants.sqlite").path,seed:false)
    let variantMappings: [Record] = [
        ["header":"First Name","target":"core:firstName","label":"First Name","type":"text"],
        ["header":"Last Name","target":"core:lastName","label":"Last Name","type":"text"],
        ["header":"Courted Profile URL","target":"core:courtedProfileURL","label":"Courted Profile URL","type":"text"],
        ["header":"Current Office","target":"core:office","label":"Current Office","type":"text"],
        ["header":"Brokerage","target":"core:office","label":"Brokerage","type":"text"]
    ]
    let variants = try variantStore.previewGenericImport(["paths":[variantA.path,variantB.path],"mappings":variantMappings])
    try check(variants["newAgents"] as? Int == 2 && variants["hardConflicts"] as? Int == 0,
              "header variants in separate files may map to one core field")

    let enrichmentCSV = root.appendingPathComponent("contact-enrichment.csv")
    let enrichmentSource = "Name,Courted Profile URL,Current Office,Email,Potential to Move,LinkedIn URL\nJordan Fixture,https://brokerage.courted.io/agents/fixture-enrichment,Cedar House Realty,old@different.example,High,linkedin.com/in/fixture-enrichment\n"
    try Data(enrichmentSource.utf8).write(to:enrichmentCSV)
    let enrichmentStore = try Store(path:root.appendingPathComponent("enrichment.sqlite").path,seed:false)
    let enrichmentInspection = try enrichmentStore.inspectGenericImport(["paths":[enrichmentCSV.path]])
    let linkedInColumn = (enrichmentInspection["columns"] as? [Record] ?? []).first { $0["header"] as? String == "LinkedIn URL" }
    try check(linkedInColumn?["suggestedTarget"] as? String == "core:linkedinUrl","LinkedIn CSV column maps to contact info")
    let enrichmentMappings: [Record] = [
        ["header":"Name","target":"core:name","label":"Name","type":"text"],
        ["header":"Courted Profile URL","target":"core:courtedProfileURL","label":"Courted Profile URL","type":"text"],
        ["header":"Current Office","target":"core:office","label":"Current Office","type":"text"],
        ["header":"Email","target":"core:email","label":"Email","type":"text"],
        ["header":"Potential to Move","target":"core:move","label":"Potential to Move","type":"text"],
        ["header":"LinkedIn URL","target":"core:linkedinUrl","label":"LinkedIn URL","type":"text"]
    ]
    let enrichmentInput: Record = ["paths":[enrichmentCSV.path],"mappings":enrichmentMappings]
    let enrichmentPreview = try enrichmentStore.previewGenericImport(enrichmentInput)
    try check(enrichmentPreview["emailCompanyReviewCount"] as? Int == 1,"brokerage and email-domain inconsistency is shown for review")
    var enrichmentCommit = enrichmentInput; enrichmentCommit["token"] = enrichmentPreview["token"]
    _ = try enrichmentStore.commitGenericImport(enrichmentCommit)
    let enrichedID = try enrichmentStore.all("agents")[0]["id"] as! String
    _ = try enrichmentStore.command("agent.update",["agentId":enrichedID,"move":"Low",
                                                   "email":"fixture@cedarhouse.example","linkedinUrl":"https://www.linkedin.com/in/fixture-enrichment/"])
    let researched = try enrichmentStore.get("agents",enrichedID)
    try check(researched["move"] as? String == "Low","research can correct imported move potential")
    try check((researched["localOverrides"] as? [String] ?? []).contains("move"),"move correction is protected from reimport")
    try check(researched["linkedinUrl"] as? String == "https://www.linkedin.com/in/fixture-enrichment/","LinkedIn profile is normalized and saved")
    let review = Store.emailCompanyReview(researched)
    try check(review["state"] as? String == "appears_consistent","updated business domain appears consistent")
    var personal = researched; personal["email"] = "@gmail.com"
    try check(Store.emailCompanyReview(personal)["state"] as? String == "unverified",
              "personal domain is flagged for review without being called invalid")
    let changedEnrichment = enrichmentSource.replacingOccurrences(of:"old@different.example,High",with:"other@different.example,High")
    try Data(changedEnrichment.utf8).write(to:enrichmentCSV)
    let reimportPreview = try enrichmentStore.previewGenericImport(enrichmentInput)
    var reimport = enrichmentInput; reimport["token"] = reimportPreview["token"]
    _ = try enrichmentStore.commitGenericImport(reimport)
    let afterImport = try enrichmentStore.get("agents",enrichedID)
    try check(afterImport["move"] as? String == "Low" && afterImport["email"] as? String == "fixture@cedarhouse.example",
              "research corrections survive a later source refresh")
    do {
        _ = try enrichmentStore.command("agent.update",["agentId":enrichedID,"linkedinUrl":"https://example.com/in/wrong"])
        throw StoreError(message:"Non-LinkedIn profile unexpectedly passed.")
    } catch let error as StoreError {
        try check(error.message != "Non-LinkedIn profile unexpectedly passed.","non-LinkedIn URL is rejected")
    }
    try check(try enrichmentStore.get("agents",enrichedID)["linkedinUrl"] as? String == "https://www.linkedin.com/in/fixture-enrichment/",
              "invalid LinkedIn update does not change the saved record")
    // Email/agent intake carries its actual origin; payload changes invalidate preview.
    let originCSV = root.appendingPathComponent("origin.csv")
    let originText = "Name,Courted Profile URL,Source date\nOrigin Fixture,https://brokerage.courted.io/agents/origin,2025-04-12\n"
    try Data(originText.utf8).write(to:originCSV)
    let originMappings:[Record] = [
        ["header":"Name","target":"core:name","label":"Name","type":"text"],
        ["header":"Courted Profile URL","target":"core:courtedProfileURL","label":"Courted Profile URL","type":"text"],
        ["header":"Source date","target":"core:sourcedAt","label":"Source date","type":"text"]]
    let originStore = try Store(path:root.appendingPathComponent("origins.sqlite").path,seed:false)
    let originInput:Record = ["paths":[originCSV.path],"mappings":originMappings,"importOrigin":["type":"email_import","messageId":"gmail:fixture-17","sourcedAt":"2025-04-10T15:30:00Z"]]
    let originPreview = try originStore.previewGenericImport(originInput)
    var staleOrigin = originInput
    staleOrigin["token"] = originPreview["token"]
    staleOrigin["importOrigin"] = ["type":"email_import","messageId":"gmail:different"]
    do { _ = try originStore.commitGenericImport(staleOrigin); throw StoreError(message:"Changed origin unexpectedly passed.") }
    catch let error as StoreError { guard error.message != "Changed origin unexpectedly passed." else { throw error } }
    var originCommit = originInput;originCommit["token"] = originPreview["token"]
    _ = try originStore.commitGenericImport(originCommit)
    let emailLead = try originStore.all("agents")[0]
    try check(emailLead["sourceType"] as? String == "email_import" && emailLead["sourceReference"] as? String == "gmail:fixture-17" && emailLead["sourcedAt"] as? String == "2025-04-10T15:30:00Z","email import stores exact message origin/time distinct from file row date and added time")
    let acquired = emailLead["sourcedAt"] as? String
    try Data(originText.replacingOccurrences(of:"2025-04-12",with:"2025-05-12").utf8).write(to:originCSV)
    var refreshInput:Record = ["paths":[originCSV.path],"mappings":originMappings]
    refreshInput["token"] = try originStore.previewGenericImport(refreshInput)["token"]
    _ = try originStore.commitGenericImport(refreshInput)
    let refreshedEmail = try originStore.all("agents")[0]
    try check(refreshedEmail["sourceType"] as? String == "email_import" && refreshedEmail["sourcedAt"] as? String == acquired && refreshedEmail["createdAt"] as? String == emailLead["createdAt"] as? String,"later CSV refresh cannot relabel an email-acquired lead")
    let aiStore = try Store(path:root.appendingPathComponent("ai-origin.sqlite").path,seed:false)
    var aiInput:Record = ["paths":[originCSV.path],"mappings":originMappings,"importOrigin":["type":"ai_agent","actor":"Research Agent","reference":"run:fixture-18"]]
    aiInput["token"] = try aiStore.previewGenericImport(aiInput)["token"]
    _ = try aiStore.commitGenericImport(aiInput)
    let aiLead = try aiStore.all("agents")[0]
    try check(aiLead["sourceType"] as? String == "ai_agent" && aiLead["sourceActor"] as? String == "Research Agent" && aiLead["sourcedAt"] as? String == "2025-05-12","AI source records agent attribution and preserves explicit day-only source precision")
    aiInput["importOrigin"] = ["type":"ai_agent","reference":"run:missing-agent"]
    do { _ = try aiStore.previewGenericImport(aiInput);throw StoreError(message:"Missing AI actor unexpectedly passed.") }
    catch let error as StoreError {guard error.message != "Missing AI actor unexpectedly passed." else {throw error}}
    try Data(originText.replacingOccurrences(of:"2025-04-12",with:"2025-02-30").utf8).write(to:originCSV)
    do { _ = try originStore.previewGenericImport(refreshInput);throw StoreError(message:"Malformed source date unexpectedly passed.") }
    catch let error as StoreError {guard error.message != "Malformed source date unexpectedly passed." else {throw error}}

    let gateStore = try Store(path:root.appendingPathComponent("ai-import-gate.sqlite").path,seed:false)
    let gateCSV = root.appendingPathComponent("ai-gated.csv")
    let gateMappings:[Record] = [
        ["header":"Name","target":"core:name","label":"Name","type":"text"],
        ["header":"Courted Profile URL","target":"core:courtedProfileURL","label":"Courted Profile URL","type":"text"],
        ["header":"Office","target":"core:office","label":"Office","type":"text"],
        ["header":"Team","target":"core:teamName","label":"Team","type":"text"]]
    var gateInput:Record = ["paths":[gateCSV.path],"mappings":gateMappings,"importOrigin":["type":"ai_agent","actor":"Research Agent","reference":"run:gate"]]
    _ = try gateStore.command("sourcingRules.save",["schemaVersion":1,"expectedRevision":0,"name":"Fixture exclusions","excludedBrokerages":["Blocked Realty"],"excludedTeams":["Blocked Team"]])
    let gateHeader = "Name,Courted Profile URL,Office,Team\n"
    try Data((gateHeader + "Excluded Fixture,https://brokerage.courted.io/agents/gate,Blocked Realty,Other Team\n").utf8).write(to:gateCSV)
    try check(try gateStore.previewGenericImport(gateInput)["hardConflicts"] as? Int == 1,"AI CSV intake cannot bypass exact brokerage exclusion")
    try Data((gateHeader + "Unknown Team Fixture,https://brokerage.courted.io/agents/gate,Allowed Realty,\n").utf8).write(to:gateCSV)
    try check(try gateStore.previewGenericImport(gateInput)["hardConflicts"] as? Int == 1,"AI CSV intake holds missing current team affiliation when team exclusions are active")
    try Data((gateHeader + "Allowed Fixture,https://brokerage.courted.io/agents/gate,Allowed Realty,Other Team\n").utf8).write(to:gateCSV)
    gateInput["token"] = try gateStore.previewGenericImport(gateInput)["token"]
    _ = try gateStore.command("sourcingRules.save",["schemaVersion":1,"expectedRevision":1,"name":"Changed exclusions","excludedBrokerages":["Blocked Realty","Allowed Realty"],"excludedTeams":["Blocked Team"]])
    do { _ = try gateStore.commitGenericImport(gateInput);throw StoreError(message:"Changed ICP unexpectedly passed.") }
    catch let error as StoreError {guard error.message != "Changed ICP unexpectedly passed." else {throw error}}
    try check(try gateStore.all("agents").isEmpty,"changed profile invalidates AI preview without creating contacts")
    _ = try gateStore.command("sourcingRules.save",["schemaVersion":1,"expectedRevision":2,"name":"Allowed again","excludedBrokerages":["Blocked Realty"],"excludedTeams":["Blocked Team"]])
    gateInput["token"] = try gateStore.previewGenericImport(gateInput)["token"]
    _ = try gateStore.commitGenericImport(gateInput)
    let gatedAgent = try gateStore.all("agents")[0]
    let savedAssessment = gatedAgent["sourcingRulesAssessment"] as? Record ?? [:]
    try check(savedAssessment["rulesRevision"] as? Int == 3 && savedAssessment["checkedAt"] is String,"AI import records actual audience revision and checked time")
    _ = try gateStore.command("sourcingRules.save",["schemaVersion":1,"expectedRevision":3,"name":"Exclude existing affiliation","excludedBrokerages":["Allowed Realty"],"excludedTeams":["Blocked Team"]])
    try Data((gateHeader + "Allowed Fixture,https://brokerage.courted.io/agents/gate,Allowed Realty,Other Team\n").replacingOccurrences(of:"Other Team",with:"Changed Team").utf8).write(to:gateCSV)
    try check(try gateStore.previewGenericImport(gateInput)["hardConflicts"] as? Int == 0,"existing contacts remain refreshable without applying a new-contact sourcing gate")

}
