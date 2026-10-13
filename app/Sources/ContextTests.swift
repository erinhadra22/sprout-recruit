import Foundation

/// Disposable tests through the same transactional command used by the app.
func runAIContextTests() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-context-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let store = try Store(path:folder.appendingPathComponent("test.sqlite").path,seed:false)
    func check(_ ok: Bool, _ message: String) throws { if !ok { throw StoreError(message:"AI context test failed: " + message) } }
    func expectFailure(_ payload: Record, _ message: String) throws {
        do { _ = try store.command("context.save",payload) }
        catch is StoreError { return }
        throw StoreError(message:"AI context test failed: " + message)
    }
    var p: Record = ["schemaVersion":1,"expectedRevision":0,"voice":"  Concise  ","textStyle":"Natural","emailStyle":"Clear","approvedWording":"","avoidWording":"Hype","approvedRules":"One question","summaryInstructions":"Separate facts and interpretation","researchInstructions":"Cite evidence","changeReason":"First setup","companyFacts":[["claim":"Test claim only","source":"","effectiveDate":"","status":"unverified"]],"examples":[],"corrections":[["feedback":"Too many questions","rule":"Ask one question","source":"Draft review","promoted":false]]]
    _ = try store.command("context.save",p)
    var saved = try store.get("settings","ai-context")
    try check(saved["voice"] as? String == "Concise","normalize text")
    try check(saved["revision"] as? Int == 1,"first revision")
    try check((saved["companyFacts"] as? [Record])?.first?["status"] as? String == "unverified","never auto-verify facts")
    try check((saved["corrections"] as? [Record])?.first?["promoted"] as? Bool == false,"never auto-promote feedback")
    _ = try store.command("context.save",p)
    try check(try store.all("settings").count == 2,"retry identical save without duplicate history")
    p["voice"] = "Changed"; try expectFailure(p,"reject stale changed content")
    p["expectedRevision"] = 1
    p["companyFacts"] = [["claim":"Test","source":"","effectiveDate":Store.day(),"status":"verified"]]
    try expectFailure(p,"verified fact needs source")
    p["companyFacts"] = [["claim":"Test","source":"Local test","effectiveDate":"2026-02-31","status":"verified"]]
    try expectFailure(p,"reject invalid dates")
    p["companyFacts"] = [["claim":"Test","source":"Local test","effectiveDate":Store.plusDays(1),"status":"verified"]]
    try expectFailure(p,"future fact not currently verified")
    p["companyFacts"] = [["claim":"Test","source":"Local test","effectiveDate":Store.day(),"status":"verified"]]
    p["corrections"] = [["feedback":"Test","rule":"","source":"Draft review","promoted":true]]
    try expectFailure(p,"promotion requires rule")
    p["corrections"] = [["feedback":"Test","rule":"One question","source":"Draft review","promoted":true]]
    p["examples"] = [["label":"Test email","body":"Example","channel":"Email","status":"approved","source":""]]
    try expectFailure(p,"approved example requires provenance")
    p["examples"] = [["label":"Test email","body":"Example","channel":"Email","status":"approved","source":"Manual review"]]
    _ = try store.command("context.save",p)
    saved = try store.get("settings","ai-context")
    try check(saved["revision"] as? Int == 2,"second revision")
    try check(try store.get("settings","ai-context-revision-000001")["voice"] as? String == "Concise","first revision immutable")
    try check(try store.all("settings").count == 3,"invalid saves create no revision")
    let reopened = try Store(path:store.path,seed:false)
    try check(try reopened.get("settings","ai-context")["revision"] as? Int == 2,"context persists across reopen")
    print("PASS: AI context provenance, explicit approval, validation, stale revision protection, no-op retry, history and persistence.")
    try runAIContextV2Tests()
}

/// Only generated temporary documents and an isolated SQLite store are touched by these tests.
func runAIContextV2Tests() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-context-v2-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:folder) }
    let store = try Store(path:folder.appendingPathComponent("test.sqlite").path,seed:false)
    func check(_ ok: Bool, _ message: String) throws { if !ok { throw StoreError(message:"AI context v2 test failed: " + message) } }
    func fails(_ message: String, _ block: () throws -> Void) throws {
        do { try block() } catch { return }
        throw StoreError(message:"AI context v2 test failed: expected rejection for " + message)
    }
    // Simulate an actual v1 persisted row, including an immutable old revision.
    var legacy = AIContext.empty()
    legacy["id"] = "ai-context"; legacy["revision"] = 1; legacy["schemaVersion"] = 1
    legacy["approvedWording"] = "  Hey there  \nThanks, Erin\nhey there\n"; legacy["avoidWording"] = "Synergy"
    legacy.removeValue(forKey:"knowledgeReferences"); legacy.removeValue(forKey:"chatGPTContext")
    try store.put("settings",legacy)
    var archive = legacy; archive["id"] = "ai-context-revision-000001"; try store.put("settings",archive)
    var p = legacy; p["expectedRevision"] = 1
    _ = try store.command("context.save",p)
    var current = try store.get("settings","ai-context")
    try check(current["schemaVersion"] as? Int == 2,"migrates version 1 context")
    try check(current["approvedWording"] as? [String] == ["Hey there","Thanks, Erin"],"phrase migration preserves comma and deduplicates")
    try check(try store.get("settings","ai-context-revision-000001")["approvedWording"] is String,"legacy archive remains unchanged")
    _ = try store.command("context.save",p)
    try check(try store.get("settings","ai-context")["revision"] as? Int == 2,"legacy retry is idempotent")
    p = current; p["expectedRevision"] = 2; p["approvedWording"] = ["One\nTwo"]
    try fails("multiline list item") { _ = try store.command("context.save",p) }
    p["approvedWording"] = current["approvedWording"]
    p["knowledgeReferences"] = [["title":"Reference","type":"url","locator":"https://example.com/policy","notes":"Reference only"]]
    p["chatGPTContext"] = ["text":"Be clear and specific.","source":"User-selected test conversation excerpt","reviewed":true]
    _ = try store.command("context.save",p)
    current = try store.get("settings","ai-context")
    try check(current["revision"] as? Int == 3,"curated references saved")
    p["expectedRevision"] = 3; p["knowledgeReferences"] = [["title":"Bad URL","type":"url","locator":"https://user:secret@example.com/","notes":""]]
    try fails("embedded URL credentials") { _ = try store.command("context.save",p) }
    p["knowledgeReferences"] = [["title":"Bad path","type":"file","locator":"relative/policy.txt","notes":""]]
    try fails("relative local path") { _ = try store.command("context.save",p) }
    p["knowledgeReferences"] = []
    p["chatGPTContext"] = ["text":"Imported","source":"","reviewed":true]
    try fails("reviewed import without provenance") { _ = try store.command("context.save",p) }

    var suggestion: Record = ["id":UUID().uuidString,"originType":"edit-example","source":"Disposable draft review","sourceRecordId":"fixture-draft-1","sourceOccurredOn":Store.day(),"channel":"Message","observation":"Too many questions","beforeText":"Can we meet? What time?","afterText":"Would tomorrow work?","proposedKind":"writingRule","proposal":"Use one clear question."]
    _ = try store.command("context.suggest",suggestion)
    _ = try store.command("context.suggest",suggestion)
    try check(try store.all("contextSuggestions").count == 1,"suggestion retry is idempotent")
    try check(try store.get("settings","ai-context")["revision"] as? Int == 3,"pending suggestion cannot alter context")
    var conflicting = suggestion; conflicting["proposal"] = "Different content"
    try fails("reuse suggestion ID with different evidence") { _ = try store.command("context.suggest",conflicting) }
    var review: Record = ["id":suggestion["id"]!,"decision":"approve","expectedRevision":1,"expectedContextRevision":3,"confirmed":false,"reviewNote":"Reviewed fixture"]
    try fails("approval needs explicit confirmation") { _ = try store.command("context.reviewSuggestion",review) }
    review["confirmed"] = true; review["expectedContextRevision"] = 2
    try fails("stale context approval") { _ = try store.command("context.reviewSuggestion",review) }
    review["expectedContextRevision"] = 3
    _ = try store.command("context.reviewSuggestion",review)
    _ = try store.command("context.reviewSuggestion",review)
    current = try store.get("settings","ai-context")
    try check(current["revision"] as? Int == 4,"one context revision for retried approval")
    try check(current["approvedRules"] as? String == "Use one clear question.","approved rule promoted")
    let reviewed = try store.get("contextSuggestions",suggestion["id"] as! String)
    try check((reviewed["history"] as? [Record])?.count == 2,"pending and approval history preserved")
    try check(reviewed["beforeText"] as? String == "Can we meet? What time?","original edit evidence preserved")

    suggestion["id"] = UUID().uuidString; suggestion["originType"] = "call-outcome"; suggestion["proposedKind"] = "companyFact"; suggestion["proposal"] = "Fixture company support claim"
    _ = try store.command("context.suggest",suggestion)
    review["id"] = suggestion["id"]!; review["expectedContextRevision"] = 4
    _ = try store.command("context.reviewSuggestion",review)
    current = try store.get("settings","ai-context")
    let fact = (current["companyFacts"] as? [Record])!.first!
    try check(fact["status"] as? String == "unverified","approved company suggestion never auto-verifies")
    try check(fact["suggestionId"] as? String == suggestion["id"] as? String,"fact provenance linked")
    suggestion["id"] = UUID().uuidString; suggestion["originType"] = "email-outcome"; suggestion["proposedKind"] = "writingRule"; suggestion["proposal"] = "Dismiss me"
    _ = try store.command("context.suggest",suggestion)
    review["id"] = suggestion["id"]!; review["decision"] = "dismiss"
    _ = try store.command("context.reviewSuggestion",review)
    try check(try store.get("settings","ai-context")["revision"] as? Int == 5,"dismissal does not change context")
    review["decision"] = "approve"; review["expectedContextRevision"] = 5
    try fails("cannot approve dismissed suggestion") { _ = try store.command("context.reviewSuggestion",review) }
    let reopened = try Store(path:store.path,seed:false)
    try check(try reopened.all("contextSuggestions").count == 3,"learning inbox durable across reopen")

    // A failed promotion cannot leave context and suggestion status disagreeing.
    p = try store.get("settings","ai-context"); p["expectedRevision"] = 5
    p["companyFacts"] = (0..<12).map { ["claim":"Fixture fact \($0)","status":"unverified","source":"","sourceType":"reference","effectiveDate":""] }
    _ = try store.command("context.save",p)
    suggestion["id"] = UUID().uuidString; suggestion["proposedKind"] = "companyFact"; suggestion["proposal"] = "Thirteenth fact"
    _ = try store.command("context.suggest",suggestion)
    review["id"] = suggestion["id"]!; review["expectedContextRevision"] = 6
    try fails("full company-fact list") { _ = try store.command("context.reviewSuggestion",review) }
    try check(try store.get("settings","ai-context")["revision"] as? Int == 6,"failed promotion creates no context revision")
    try check(try store.get("contextSuggestions",suggestion["id"] as! String)["status"] as? String == "pending","failed promotion remains pending")

    let file = folder.appendingPathComponent("reference.md")
    try "Policy fixture\nMonthly training is available.\nThis is a test only.".write(to:file,atomically:true,encoding:.utf8)
    try fails("file read without explicit preview") { _ = try LocalKnowledge.preview(["path":file.path]) }
    let preview = try LocalKnowledge.preview(["path":file.path,"query":"TRAINING","readConfirmed":true])
    try check((preview["matches"] as? [Record])?.first?["line"] as? Int == 2,"case-insensitive local search with line evidence")
    try check(preview["networkUsed"] as? Bool == false && preview["persistedContent"] as? Bool == false,"preview is local and not persisted")
    try check((preview["sha256"] as? String)?.count == 64,"preview content fingerprint")
    try fails("folder path") { _ = try LocalKnowledge.preview(["path":folder.path,"readConfirmed":true]) }
    try fails("network URL") { _ = try LocalKnowledge.preview(["path":"https://example.com/policy.md","readConfirmed":true]) }
    try fails("missing file") { _ = try LocalKnowledge.preview(["path":folder.appendingPathComponent("missing.txt").path,"readConfirmed":true]) }
    let binary = folder.appendingPathComponent("binary.txt"); try Data([0,1,0,2]).write(to:binary)
    try fails("binary text") { _ = try LocalKnowledge.preview(["path":binary.path,"readConfirmed":true]) }
    let long = folder.appendingPathComponent("long.txt"); try String(repeating:"a",count:200100).write(to:long,atomically:true,encoding:.utf8)
    let bounded = try LocalKnowledge.preview(["path":long.path,"readConfirmed":true])
    try check(bounded["extractionTruncated"] as? Bool == true && bounded["charactersExamined"] as? Int == 200000,"bounded extraction")
    try check((bounded["preview"] as? String)?.count == 8000,"bounded preview")
    let empty = folder.appendingPathComponent("empty.txt"); try Data().write(to:empty)
    try check(try LocalKnowledge.preview(["path":empty.path,"readConfirmed":true])["charactersExamined"] as? Int == 0,"empty reference is a valid preview")
    // Small generated PDF with a text layer, avoiding private documents or external conversion tools.
    let stream = "BT /F1 12 Tf 40 140 Td (Training fixture only) Tj ET"
    let objects = ["<< /Type /Catalog /Pages 2 0 R >>","<< /Type /Pages /Kids [3 0 R] /Count 1 >>","<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>","<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>","<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"]
    var pdf = "%PDF-1.4\n", offsets = [0]
    for (index,object) in objects.enumerated() { offsets.append(pdf.utf8.count); pdf += "\(index+1) 0 obj\n\(object)\nendobj\n" }
    let start = pdf.utf8.count
    pdf += "xref\n0 6\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() { pdf += String(format:"%010d 00000 n \n",offset) }
    pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
    let pdfURL = folder.appendingPathComponent("fixture.pdf"); try pdf.write(to:pdfURL,atomically:true,encoding:.utf8)
    let pdfResult = try LocalKnowledge.preview(["path":pdfURL.path,"query":"training","readConfirmed":true])
    try check(pdfResult["pagesRead"] as? Int == 1 && !(pdfResult["matches"] as? [Record] ?? []).isEmpty,"selected text PDF is locally searchable")
    print("PASS: context v1 migration, phrase lists, selected local-file reading/search, explicit and atomic suggestion review, provenance, revision history and durable pending learning.")
}
