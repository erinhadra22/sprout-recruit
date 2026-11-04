import Foundation

/// User-defined sourcing eligibility. Natural-language notes never grant a bypass.
enum SourcingRules {
    static let recordID = "sourcing-rules"
    static func normalizedName(_ value: String) -> String {
        value.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            .components(separatedBy:CharacterSet.alphanumerics.inverted).filter{!$0.isEmpty}.joined(separator:" ")
    }
    static func empty() -> Record {
        ["id":recordID,"schemaVersion":1,"revision":0,"name":"Recruiting target audience","description":"","excludedBrokerages":[String](),"excludedTeams":[String](),"scope":"sourcing_only"]
    }
    static func names(_ value: Any?, label: String) throws -> [String] {
        guard value == nil || value is [String] else { throw StoreError(message:"Enter \(label) as a list of names.") }
        let values=value as? [String] ?? []
        guard values.count<=100 else { throw StoreError(message:"Use up to 100 \(label).") }
        var result=[String](),seen=Set<String>()
        for raw in values {
            let name=raw.trimmingCharacters(in:.whitespacesAndNewlines),key=normalizedName(raw)
            guard !key.isEmpty,name.count<=200,!name.contains("\n"),!name.contains("\r") else { throw StoreError(message:"Each \(label) entry needs a name on one line, up to 200 characters.") }
            if seen.insert(key).inserted{result.append(name)}
        }
        return result
    }
    static func assessment(fields:Record,profile:Record,currentTeamNames:[String]=[]) -> Record {
        let brokerages=profile["excludedBrokerages"] as? [String] ?? [],teams=profile["excludedTeams"] as? [String] ?? []
        let officeNames=["office","brand","brokerage"].compactMap{fields[$0] as? String}.filter{!normalizedName($0).isEmpty}
        let teamNames=([fields["teamName"] as? String ?? ""]+currentTeamNames).filter{!normalizedName($0).isEmpty}
        var reasons=[String](),missing=[String](),matches=[Record]()
        for (kind,rules,known) in [("brokerage",brokerages,officeNames),("team",teams,teamNames)] {
            let keys=Set(known.map(normalizedName))
            for name in rules where keys.contains(normalizedName(name)) {
                reasons.append("Excluded \(kind): \(name)")
                matches.append(["kind":kind,"name":name,"matchedNames":known.filter{normalizedName($0)==normalizedName(name)}])
            }
            if !rules.isEmpty && known.isEmpty { missing.append("Current \(kind) affiliation is needed to check the target-audience exclusions.") }
        }
        return ["state":!matches.isEmpty ? "excluded" : !missing.isEmpty ? "needs_evidence" : "eligible","reasons":reasons,"missingEvidence":missing,"matches":matches,"rulesRevision":profile["revision"] as? Int ?? 0,"profileId":recordID]
    }
    static func applying(_ assessment:Record,to qualification:Record) -> Record {
        var result=qualification;result["sourcingRulesAssessment"]=assessment
        let state=assessment["state"] as? String ?? "eligible"
        if state=="eligible"{return result}
        let reasons=assessment["reasons"] as? [String] ?? [],missing=assessment["missingEvidence"] as? [String] ?? []
        result["state"]=state=="excluded" || qualification["state"] as? String=="not_qualified" ? "not_qualified" : "needs_evidence"
        result["reasons"]=reasons+missing+(qualification["reasons"] as? [String] ?? [])
        result["missingEvidence"]=missing+(qualification["missingEvidence"] as? [String] ?? [])
        result["failedCriteria"]=reasons+(qualification["failedCriteria"] as? [String] ?? [])
        return result
    }
}

extension Store {
    func sourcingRulesRecord() throws -> Record {
        try all("settings").first{$0["id"] as? String==SourcingRules.recordID} ?? SourcingRules.empty()
    }
    /// Store.command supplies the transaction; a stale form never overwrites newer rules.
    func saveSourcingRules(_ p:Record) throws {
        guard p["schemaVersion"] as? Int==1,let expected=p["expectedRevision"] as? Int else { throw StoreError(message:"Reopen the target audience form before saving.") }
        let prior=try sourcingRulesRecord(),revision=prior["revision"] as? Int ?? 0
        let name=try AIContext.text(p,"name",max:120,required:true),description=try AIContext.text(p,"description",max:6000)
        let brokerages=try SourcingRules.names(p["excludedBrokerages"],label:"excluded brokerages"),teams=try SourcingRules.names(p["excludedTeams"],label:"excluded teams")
        guard expected==revision else { throw StoreError(message:"Target audience rules changed since this form opened. Reopen Settings and review the latest rules.") }
        let content:Record=["name":name,"description":description,"excludedBrokerages":brokerages,"excludedTeams":teams]
        if revision>0,try AIContext.json(prior.filter{content.keys.contains($0.key)})==AIContext.json(content){return}
        let now=Store.now()
        var result=content
        for (key,value) in ["id":SourcingRules.recordID,"schemaVersion":1,"revision":revision+1,"createdAt":prior["createdAt"] ?? now,"updatedAt":now,"scope":"sourcing_only","origin":"User-defined target audience"] as Record{result[key]=value}
        let archiveID=String(format:"sourcing-rules-revision-%06d",revision+1)
        guard try all("settings").allSatisfy({$0["id"] as? String != archiveID}) else {throw StoreError(message:"This target-audience revision already exists; no changes were saved.")}
        var archived=result;archived["id"]=archiveID;archived["recordType"]="sourcing-rules-revision"
        try put("settings",archived);try put("settings",result)
    }
    func sourcingRuleAssessment(fields:Record,asOf:String,profile:Record?=nil,teams:[Record]?=nil,memberships:[Record]?=nil) throws -> Record {
        let aid=fields["id"] as? String ?? ""
        var names=[String]()
        if !aid.isEmpty {
            let teamRecords=try teams ?? all("teams"),membershipRecords=try memberships ?? all("teamMemberships")
            for membership in membershipRecords where membership["agentId"] as? String==aid {
                let start=membership["startDate"] as? String ?? "",end=membership["endDate"] as? String ?? ""
                guard Store.parseDay(start) != nil,start<=asOf,end.isEmpty || (Store.parseDay(end) != nil && end>=asOf),
                      let team=teamRecords.first(where:{$0["id"] as? String==membership["teamId"] as? String}),let name=team["name"] as? String else{continue}
                names.append(name)
            }
        }
        return SourcingRules.assessment(fields:fields,profile:try profile ?? sourcingRulesRecord(),currentTeamNames:names)
    }
    func applySourcingRules(to qualification:Record,fields:Record,asOf:String) throws -> Record {
        SourcingRules.applying(try sourcingRuleAssessment(fields:fields,asOf:asOf),to:qualification)
    }
}
