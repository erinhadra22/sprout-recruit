import Foundation

/// Shared validation for locally curated context. No content is sent to a model here.
enum AIContext {
    static func text(_ object: Record, _ key: String, max: Int = 6000, required: Bool = false) throws -> String {
        guard object[key] == nil || object[key] is String else { throw StoreError(message:"Invalid text in \(key).") }
        let value = (object[key] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.count <= max, !required || !value.isEmpty else { throw StoreError(message:"Please enter \(key) (up to \(max) characters).") }
        return value
    }
    static func rows(_ object: Record, _ key: String, max: Int) throws -> [Record] {
        guard object[key] == nil || object[key] is [Record] else { throw StoreError(message:"Invalid list in \(key).") }
        let values = object[key] as? [Record] ?? []
        guard values.count <= max else { throw StoreError(message:"Please provide up to \(max) \(key).") }
        return values
    }
    /// Version 1 stored multiline strings. Split only line breaks, preserving punctuation inside phrases.
    static func phrases(_ value: Any?) throws -> [String] {
        let values: [String]
        if value == nil { values = [] }
        else if let lines = value as? String { values = lines.components(separatedBy:.newlines) }
        else if let list = value as? [String] { values = list }
        else { throw StoreError(message:"Phrases must be a list of text entries.") }
        var found = Set<String>(), result: [String] = []
        for raw in values {
            let phrase = raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if phrase.isEmpty { continue }
            guard phrase.count <= 500, !phrase.contains("\n"), !phrase.contains("\r") else { throw StoreError(message:"Keep each phrase on one line, up to 500 characters.") }
            if found.insert(phrase.lowercased()).inserted { result.append(phrase) }
        }
        guard result.count <= 50 else { throw StoreError(message:"Use up to 50 phrases in each list.") }
        return result
    }
    static func validURL(_ value: String) -> Bool {
        guard let url = URLComponents(string:value), ["https","http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
    static func source(_ value: String, type: String) throws -> String {
        guard ["reference","url","file"].contains(type) else { throw StoreError(message:"Choose a reference, web URL or local file.") }
        if value.isEmpty { return "" }
        if type == "url" && !validURL(value) { throw StoreError(message:"Enter a complete http or https URL without embedded credentials.") }
        // Saving a path checks its shape only. An explicit preview checks existence and reads that one file.
        if type == "file" { return try LocalKnowledge.normalizedPath(value) }
        return value
    }
    static func empty() -> Record {
        ["schemaVersion":2,"expectedRevision":0,"voice":"","textStyle":"","emailStyle":"","approvedWording":[String](),"avoidWording":[String](),"approvedRules":"","summaryInstructions":"","researchInstructions":"","companyFacts":[Record](),"examples":[Record](),"corrections":[Record](),"knowledgeReferences":[Record](),"chatGPTContext":["text":"","source":"","reviewed":false]]
    }
    static func json(_ record: Record) throws -> Data { try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]) }
}

extension Store {
    /// Called inside Store.command's transaction; creates immutable revision and current pointer together.
    func saveAIContext(_ p: Record) throws {
        guard let schema = p["schemaVersion"] as? Int, [1,2].contains(schema) else { throw StoreError(message:"Unsupported AI context version.") }
        let prior = try all("settings").first(where: { $0["id"] as? String == "ai-context" })
        let oldRevision = prior?["revision"] as? Int ?? 0
        guard p["expectedRevision"] is Int else { throw StoreError(message:"A valid AI context revision is required.") }
        let now = Store.now()
        var result: Record = ["id":"ai-context","schemaVersion":2,"revision":oldRevision+1,"createdAt":prior?["createdAt"] as? String ?? now,"updatedAt":now,"origin":"User-curated local settings","defaultChannel":"Message"]
        for key in ["voice","textStyle","emailStyle","approvedRules","summaryInstructions","researchInstructions"] { result[key] = try AIContext.text(p,key) }
        for key in ["approvedWording","avoidWording"] { result[key] = try AIContext.phrases(p[key]) }
        result["changeReason"] = try AIContext.text(p,"changeReason",max:500)
        var facts: [Record] = []
        for value in try AIContext.rows(p,"companyFacts",max:12) {
            let claim = try AIContext.text(value,"claim",required:true)
            let type = try AIContext.text(value,"sourceType",max:20)
            let sourceType = type.isEmpty ? "reference" : type
            let source = try AIContext.source(AIContext.text(value,"source",max:2000),type:sourceType)
            let effective = try AIContext.text(value,"effectiveDate",max:10), status = try AIContext.text(value,"status",max:20,required:true)
            guard ["unverified","verified","retired"].contains(status) else { throw StoreError(message:"Choose a valid company fact status.") }
            guard effective.isEmpty || Store.parseDay(effective) != nil else { throw StoreError(message:"Choose a valid company fact effective date.") }
            if status == "verified" {
                guard !source.isEmpty, !effective.isEmpty, effective <= Store.day() else { throw StoreError(message:"A verified company fact needs its source and an effective date of today or earlier.") }
            }
            facts.append(["claim":claim,"source":source,"sourceType":sourceType,"effectiveDate":effective,"status":status,"verificationMethod":status == "verified" ? "User confirmed" : "Not verified for use","suggestionId":try AIContext.text(value,"suggestionId",max:100)])
        }
        var examples: [Record] = []
        for value in try AIContext.rows(p,"examples",max:8) {
            let body = try AIContext.text(value,"body",required:true), label = try AIContext.text(value,"label",max:120,required:true), source = try AIContext.text(value,"source",max:2000)
            let channel = try AIContext.text(value,"channel",max:20,required:true), status = try AIContext.text(value,"status",max:20,required:true)
            guard ["Message","Email"].contains(channel), ["pending","approved"].contains(status) else { throw StoreError(message:"Choose a valid example channel and approval status.") }
            guard status != "approved" || !source.isEmpty else { throw StoreError(message:"Add where an approved writing example came from.") }
            examples.append(["label":label,"body":body,"channel":channel,"source":source,"status":status,"suggestionId":try AIContext.text(value,"suggestionId",max:100)])
        }
        var corrections: [Record] = []
        for value in try AIContext.rows(p,"corrections",max:8) {
            let feedback = try AIContext.text(value,"feedback",required:true), rule = try AIContext.text(value,"rule"), source = try AIContext.text(value,"source",max:2000)
            guard let promoted = value["promoted"] as? Bool else { throw StoreError(message:"Choose whether to approve each feedback rule.") }
            guard !promoted || (!rule.isEmpty && !source.isEmpty) else { throw StoreError(message:"An approved feedback rule needs the proposed rule and its source draft or observation.") }
            corrections.append(["feedback":feedback,"rule":rule,"source":source,"promoted":promoted])
        }
        var references: [Record] = []
        for value in try AIContext.rows(p,"knowledgeReferences",max:12) {
            let title = try AIContext.text(value,"title",max:120,required:true)
            let type = try AIContext.text(value,"type",max:20,required:true)
            let locator = try AIContext.source(AIContext.text(value,"locator",max:2000,required:true),type:type)
            references.append(["title":title,"type":type,"locator":locator,"notes":try AIContext.text(value,"notes"),"contentPolicy":"Reference only; explicit preview required; never auto-verified"])
        }
        guard p["chatGPTContext"] == nil || p["chatGPTContext"] is Record else { throw StoreError(message:"Invalid curated ChatGPT context.") }
        let curated = p["chatGPTContext"] as? Record ?? [:]
        let importText = try AIContext.text(curated,"text",max:20000), importSource = try AIContext.text(curated,"source",max:2000)
        guard curated["reviewed"] == nil || curated["reviewed"] is Bool else { throw StoreError(message:"Choose whether you reviewed the imported context.") }
        let reviewed = curated["reviewed"] as? Bool ?? false
        guard !reviewed || (!importText.isEmpty && !importSource.isEmpty) else { throw StoreError(message:"Reviewed ChatGPT context needs pasted text and its source.") }
        result["chatGPTContext"] = ["text":importText,"source":importSource,"reviewed":reviewed,"importMethod":"User-pasted excerpt; no automatic ChatGPT memory access"]
        result["companyFacts"] = facts; result["examples"] = examples; result["corrections"] = corrections; result["knowledgeReferences"] = references
        let contentKeys = ["schemaVersion","defaultChannel","voice","textStyle","emailStyle","approvedWording","avoidWording","approvedRules","summaryInstructions","researchInstructions","companyFacts","examples","corrections","knowledgeReferences","chatGPTContext"]
        if let prior = prior {
            if try AIContext.json(prior.filter { contentKeys.contains($0.key) }) == AIContext.json(result.filter { contentKeys.contains($0.key) }) { return }
        }
        guard p["expectedRevision"] as? Int == oldRevision else { throw StoreError(message:"AI context changed since you opened it. Reopen Settings and try again so no changes are lost.") }
        let revisionID = String(format:"ai-context-revision-%06d",oldRevision+1)
        guard try all("settings").contains(where:{$0["id"] as? String == revisionID}) == false else { throw StoreError(message:"This AI context revision already exists. No changes were saved.") }
        var archived = result; archived["id"] = revisionID; archived["recordType"] = "ai-context-revision"
        try put("settings",archived); try put("settings",result)
    }

    /// Durable inbox, not automated learning. Integrations must provide an observation and a proposed change.
    func saveContextSuggestion(_ p: Record) throws {
        let id = try AIContext.text(p,"id",max:100,required:true)
        guard UUID(uuidString:id) != nil else { throw StoreError(message:"A stable learning suggestion ID is required.") }
        let origin = try AIContext.text(p,"originType",max:30,required:true)
        guard ["edit-example","call-outcome","text-outcome","email-outcome","manual-feedback"].contains(origin) else { throw StoreError(message:"Choose the source of this learning suggestion.") }
        let kind = try AIContext.text(p,"proposedKind",max:30,required:true)
        guard ["writingRule","companyFact","styleExample"].contains(kind) else { throw StoreError(message:"Choose a writing rule, company fact or style example.") }
        let channel = try AIContext.text(p,"channel",max:20,required:true)
        guard ["Message","Email"].contains(channel) else { throw StoreError(message:"Choose text message or email guidance.") }
        let occurredOn = try AIContext.text(p,"sourceOccurredOn",max:10)
        guard occurredOn.isEmpty || (Store.parseDay(occurredOn) != nil && occurredOn <= Store.day()) else { throw StoreError(message:"Choose an observed date of today or earlier.") }
        var content: Record = ["id":id,"originType":origin,"proposedKind":kind,"channel":channel,"sourceOccurredOn":occurredOn]
        for key in ["source","sourceRecordId","observation","beforeText","afterText","proposal"] {
            content[key] = try AIContext.text(p,key,max:key == "sourceRecordId" ? 100 : key == "source" ? 2000 : 6000,required:["source","observation","proposal"].contains(key))
        }
        if let prior = try all("contextSuggestions").first(where:{$0["id"] as? String == id}) {
            let priorContent = prior.filter { content.keys.contains($0.key) }
            guard try AIContext.json(priorContent) == AIContext.json(content) else { throw StoreError(message:"That learning suggestion ID already contains different evidence. No changes saved.") }
            return
        }
        let now = Store.now()
        content["status"] = "pending"; content["revision"] = 1; content["createdAt"] = now; content["updatedAt"] = now
        content["provenance"] = "User-entered or locally supplied outcome; no automated truth verification"
        content["history"] = [["revision":1,"status":"pending","at":now]]
        try put("contextSuggestions",content)
    }

    /// Parent routes inside the same transaction as context.save, so context and review commit atomically.
    func reviewContextSuggestion(_ p: Record) throws {
        let id = try AIContext.text(p,"id",max:100,required:true), decision = try AIContext.text(p,"decision",max:20,required:true)
        guard ["approve","dismiss"].contains(decision), p["confirmed"] as? Bool == true else { throw StoreError(message:"Explicitly approve or dismiss the learning suggestion.") }
        var suggestion = try get("contextSuggestions",id)
        let target = decision == "approve" ? "approved" : "dismissed"
        let status = suggestion["status"] as? String ?? ""
        if status == target { return } // Retried completed review must not duplicate rules or revisions.
        guard status == "pending", p["expectedRevision"] as? Int == suggestion["revision"] as? Int else { throw StoreError(message:"This learning suggestion changed. Reopen it before reviewing.") }
        let reviewNote = try AIContext.text(p,"reviewNote",max:1000)
        var contextRevision = 0
        if decision == "approve" {
            let prior = try all("settings").first(where:{$0["id"] as? String == "ai-context"})
            let revision = prior?["revision"] as? Int ?? 0
            guard p["expectedContextRevision"] as? Int == revision else { throw StoreError(message:"Your AI context changed. Reopen this suggestion before approving it.") }
            var context = prior ?? AIContext.empty()
            context["schemaVersion"] = 2; context["expectedRevision"] = revision; context["changeReason"] = "Approved learning suggestion \(id)"
            let source = suggestion["source"] as? String ?? "", proposal = suggestion["proposal"] as? String ?? ""
            switch suggestion["proposedKind"] as? String {
            case "writingRule":
                let priorRules = context["approvedRules"] as? String ?? ""
                if !priorRules.components(separatedBy:.newlines).contains(proposal) { context["approvedRules"] = priorRules.isEmpty ? proposal : priorRules + "\n" + proposal }
            case "companyFact":
                var facts = context["companyFacts"] as? [Record] ?? []
                facts.append(["claim":proposal,"source":source,"sourceType":"reference","effectiveDate":"","status":"unverified","suggestionId":id])
                context["companyFacts"] = facts
            case "styleExample":
                var examples = context["examples"] as? [Record] ?? []
                examples.append(["label":String((suggestion["observation"] as? String ?? "Reviewed example").prefix(120)),"body":proposal,"source":source,"channel":suggestion["channel"] as? String ?? "Message","status":"approved","suggestionId":id])
                context["examples"] = examples
            default: throw StoreError(message:"Unsupported learning suggestion.")
            }
            try saveAIContext(context)
            contextRevision = try get("settings","ai-context")["revision"] as? Int ?? 0
        }
        let next = (suggestion["revision"] as? Int ?? 1)+1, now = Store.now()
        suggestion["status"] = target; suggestion["revision"] = next; suggestion["updatedAt"] = now; suggestion["reviewNote"] = reviewNote
        suggestion["reviewedAt"] = now; suggestion["reviewedBy"] = "User"; suggestion["promotedContextRevision"] = contextRevision
        var history = suggestion["history"] as? [Record] ?? []
        history.append(["revision":next,"status":target,"at":now,"reviewNote":reviewNote,"contextRevision":contextRevision])
        suggestion["history"] = history
        try put("contextSuggestions",suggestion)
    }
}
