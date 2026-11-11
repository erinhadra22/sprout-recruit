import Foundation
import CryptoKit
import CoreFoundation

// Local, reviewable intake and action planning. No network, scheduler, or probability model.
extension Store {
    static let prospectingTimeZone = TimeZone(identifier:"America/Chicago")!
    // Discovery quotas use Erin's requested working day, independently of the
    // Mac's timezone. Existing date-only task deadlines remain date-only.
    static func prospectingLocalDay(_ date:Date = Date()) -> String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.calendar=Calendar(identifier:.gregorian);formatter.timeZone=prospectingTimeZone;formatter.dateFormat="yyyy-MM-dd"
        return formatter.string(from:date)
    }
    static func prospectingTimestampDay(_ value:Any?) -> String? {
        guard let text=value as? String else{return nil}
        // Older date-only records already name a calendar day; do not invent an instant.
        if text.count==10,parseDay(text) != nil{return text}
        let fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard let date=fractional.date(from:text) ?? ISO8601DateFormatter().date(from:text) else{return nil}
        return prospectingLocalDay(date)
    }
    static let prospectingFields: Set<String> = ["name","license","licenseJurisdiction","licenseType","sourceAgentId","office","officeCity","email","phone","mls","mlsId","serviceCities","serviceJurisdiction","experienceYears","experienceCheckedAt","experienceReference","periodStart","periodEnd","periodType","asOfDate","coverage","attribution","individualVolume","volumeDefinition","productionCheckedAt","productionReference","teamName","teamRole","licenseStatus","originalLicenseDate","originalLicenseDateRaw","licenseCheckedAt","licenseReference","identityMatchStatus","identityCheckedAt","identityReference"]

    static func defaultServiceArea() -> Record {
        ["id":"broader-waco","name":"Broader Waco","eligibilityMode":"full_production","jurisdiction":"TX","cities":["Waco","Woodway","Hewitt","Bellmead","Lacy Lakeview","Robinson"],"minExperienceYears":2,"minIndividualVolume":2_000_000,"productionMaxAgeDays":365,"evidenceMaxAgeDays":90,"revision":0,"definitionNote":"Editable starting cities, not an exhaustive boundary. Verify service footprint independently of office city."]
    }
    static func defaultSourceMappings() -> [Record] {
        let canonical = Dictionary(uniqueKeysWithValues: prospectingFields.map { ($0,$0) })
        return [
            ["id":"canonical-license-roster","name":"Reviewed license roster / enrichment","fields":canonical,"defaults":[:],"revision":0,"sourceStatus":"unconnected"],
            ["id":"reso-member-2","name":"RESO DD 2.1 Member / license (schema only)","fields":["name":"MemberFullName","license":"MemberStateLicense","licenseJurisdiction":"MemberStateLicenseState","licenseType":"MemberStateLicenseType","sourceAgentId":"MemberKey","mlsId":"MemberMlsId","email":"MemberEmail","phone":"MemberDirectPhone"],"defaults":[:],"revision":0,"sourceStatus":"unconnected","schemaReference":"https://dd.reso.org/DD2.1/Member/","licenseSchemaReference":"https://dd.reso.org/DD2.1/MemberStateLicense/","notes":"Flattened reviewed Member/MemberStateLicense contract. MemberKey is scoped to its provider; MemberMlsId is not globally unique. A comma-separated license list needs separate verified license records. Member address/city is not service footprint. No closed-production coverage or provider access is implied."]
        ]
    }
    private static func prospectText(_ p: Record,_ key:String,required:Bool=false,max:Int=500) throws -> String {
        guard p[key] == nil || p[key] is String else { throw StoreError(message:"\(key) must be text; identifiers must retain leading zeros and suffixes.") }
        let text=(p[key] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.count <= max, !required || !text.isEmpty else { throw StoreError(message:"Enter \(key) (up to \(max) characters).") }
        return text
    }
    private static func prospectNumber(_ value:Any?) -> Double? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue >= 0 else{return nil};return n.doubleValue
    }
    private static func prospectDay(_ p:Record,_ key:String,required:Bool=true) throws -> String {
        let value=try prospectText(p,key,required:required,max:10)
        guard value.isEmpty && !required || (parseDay(value) != nil && value <= prospectingLocalDay()) else{throw StoreError(message:"Enter a valid \(key) through today.")};return value
    }
    private static func prospectHash(_ value:Any) throws -> String {
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    private static func prospectNorm(_ text:String)->String {text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}
    private static func prospectCities(_ value:Any?) throws -> [String] {
        guard let cities=value as? [String],cities.count <= 100 else{throw StoreError(message:"Service cities must be a list of at most 100 city names.")}
        var seen=Set<String>();return try cities.map {city in
            let name=city.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty,name.count<=100 else{throw StoreError(message:"Enter valid service city names.")};return name
        }.filter{seen.insert(prospectNorm($0)).inserted}
    }
    private func prospectArea(_ id:String?) throws -> Record {
        let chosen=id ?? "broader-waco"
        if let saved=try all("serviceAreas").first(where:{$0["id"] as? String == chosen}){return saved}
        if chosen == "broader-waco"{return Store.defaultServiceArea()}
        throw StoreError(message:"Choose a saved service area.")
    }
    private func prospectPersist(_ kind:String,_ record:Record,_ expected:Int) throws {
        let id=record["id"] as! String,old=try all(kind).first{$0["id"] as? String==id}
        if let old=old {
            var prior=old;for key in ["createdAt","updatedAt","revision","revisions"]{prior.removeValue(forKey:key)}
            if NSDictionary(dictionary:prior).isEqual(to:record){return}
        }
        guard (old?["revision"] as? Int ?? 0)==expected else{throw StoreError(message:"This record changed. Reload it before saving.")}
        var r=record;var history=old?["revisions"] as? [Record] ?? []
        if var prior=old{prior.removeValue(forKey:"revisions");history.append(prior)}
        r["createdAt"]=old?["createdAt"] ?? Store.now();r["updatedAt"]=Store.now();r["revision"]=expected+1;r["revisions"]=history
        try put(kind,r)
    }
    func saveServiceArea(_ p:Record) throws {
        let id=try Store.prospectText(p,"id",required:true,max:100),name=try Store.prospectText(p,"name",required:true,max:120),cities=try Store.prospectCities(p["cities"])
        guard !cities.isEmpty else{throw StoreError(message:"Select at least one service city.")}
        let jurisdiction=try Store.prospectText(p,"jurisdiction",required:true,max:32).uppercased()
        guard jurisdiction.range(of:"^[A-Z0-9][A-Z0-9._-]{1,31}$",options:.regularExpression) != nil else{throw StoreError(message:"Use an explicit service-area jurisdiction code, such as TX. City names alone can be ambiguous.")}
        guard p["minExperienceYears"] == nil || Store.prospectNumber(p["minExperienceYears"]) == 2,
              p["minIndividualVolume"] == nil || Store.prospectNumber(p["minIndividualVolume"]) == 2_000_000 else{throw StoreError(message:"The approved baseline is 2+ years and $2M+ individual annual/LTM production. Changing qualification criteria requires a separate decision.")}
        let mode=try Store.prospectText(p,"eligibilityMode")
        guard mode.isEmpty || ["full_production","interim_license_tenure"].contains(mode) else{throw StoreError(message:"Choose full production or interim license-tenure consideration.")}
        let saved=try all("serviceAreas").first{$0["id"] as? String==id}
        let eligibilityMode=mode.isEmpty ? saved?["eligibilityMode"] as? String ?? "full_production" : mode
        let freshness=Store.prospectNumber(p["evidenceMaxAgeDays"]) ?? 90,productionAge=Store.prospectNumber(p["productionMaxAgeDays"]) ?? 365
        guard freshness.rounded()==freshness,(1...730).contains(freshness),productionAge.rounded()==productionAge,(1...730).contains(productionAge) else{throw StoreError(message:"Freshness windows must be whole days between 1 and 730.")}
        try prospectPersist("serviceAreas",["id":id,"name":name,"eligibilityMode":eligibilityMode,"jurisdiction":jurisdiction,"cities":cities,"minExperienceYears":2,"minIndividualVolume":2_000_000,"productionMaxAgeDays":Int(productionAge),"evidenceMaxAgeDays":Int(freshness),"definitionNote":"Explicit service cities; office location alone is not qualification evidence."],p["expectedRevision"] as? Int ?? 0)
    }
    private func validatedSourceMapping(_ p:Record) throws -> Record {
        let id=try Store.prospectText(p,"id",required:true,max:100),name=try Store.prospectText(p,"name",required:true,max:150)
        guard let fields=p["fields"] as? [String:String],!fields.isEmpty,Set(fields.keys).isSubset(of:Store.prospectingFields),fields.values.allSatisfy({!$0.isEmpty && $0.count<=100}) else{throw StoreError(message:"Map supported canonical fields to explicit source column names.")}
        let defaults=p["defaults"] as? Record ?? [:]
        guard Set(defaults.keys).isSubset(of:["licenseJurisdiction","licenseType","mls"]),defaults.values.allSatisfy({$0 is String}) else{throw StoreError(message:"Only jurisdiction, license type and MLS may have explicit text defaults. Evidence and production cannot be defaulted.")}
        return ["id":id,"name":name,"fields":fields,"defaults":defaults,"sourceStatus":"unconnected"]
    }
    func saveSourceMapping(_ p:Record) throws {try prospectPersist("sourceMappings",validatedSourceMapping(p),p["expectedRevision"] as? Int ?? 0)}
    private func prospectMapping(_ p:Record) throws -> Record {
        if let inline=p["mapping"] as? Record{return try validatedSourceMapping(inline)}
        let id=p["mappingId"] as? String ?? "canonical-license-roster"
        guard let mapping=(try all("sourceMappings")+Store.defaultSourceMappings()).first(where:{$0["id"] as? String==id}) else{throw StoreError(message:"Choose a source mapping.")};return mapping
    }
    private static func prospectFresh(_ checked:String,_ asOf:String,_ maxDays:Int)->Bool {
        guard let date=parseDay(checked),let end=parseDay(asOf),date<=end else{return false}
        return Calendar.current.dateComponents([.day],from:date,to:end).day.map{$0<=maxDays} ?? false
    }
    private static func prospectFullPeriod(_ p:Record)->Bool {
        guard let start=p["periodStart"] as? String,let end=p["periodEnd"] as? String,let d1=parseDay(start),let d2=parseDay(end),d1<=d2 else{return false}
        if p["periodType"] as? String == "ltm"{let days=(Calendar.current.dateComponents([.day],from:d1,to:d2).day ?? -1)+1;return days==365 || days==366}
        return start.suffix(5)=="01-01" && end.suffix(5)=="12-31" && start.prefix(4)==end.prefix(4)
    }
    private static func prospectFullQualification(_ fields:Record,area:Record,asOf:String)->Record {
        var missing=[String](),reasons=[String](),failed=[String]()
        let freshness=area["evidenceMaxAgeDays"] as? Int ?? 90,productionAge=area["productionMaxAgeDays"] as? Int ?? 365
        let serviceCities=fields["serviceCities"] as? [String] ?? [],target=Set((area["cities"] as? [String] ?? []).map(prospectNorm))
        let serviceScope=(fields["serviceJurisdiction"] as? String).flatMap{$0.isEmpty ? nil : $0} ?? fields["licenseJurisdiction"] as? String ?? ""
        let areaScope=area["jurisdiction"] as? String ?? ""
        if serviceScope.isEmpty || areaScope.isEmpty{missing.append("Verified service jurisdiction; same-named cities are not interchangeable")}
        else if serviceScope.uppercased() != areaScope.uppercased(){failed.append("Service jurisdiction differs from selected area")}
        if serviceCities.isEmpty{missing.append("Verified service cities; office city is not service footprint")}
        else if !serviceCities.contains(where:{target.contains(prospectNorm($0))}){failed.append("Outside the selected service area")}
        else{reasons.append("Verified service area match")}
        if let years=prospectNumber(fields["experienceYears"]){if years>=2{reasons.append("At least two years of experience")}else{failed.append("Less than two years of experience")}}else{missing.append("Sourced years of experience")}
        if (fields["experienceReference"] as? String ?? "").isEmpty{missing.append("Experience/service-area source reference")}
        if !prospectFresh(fields["experienceCheckedAt"] as? String ?? "",asOf,freshness){missing.append("Experience/service-area evidence checked within \(freshness) days")}
        if fields["attribution"] as? String != "individual"{missing.append("Individual production attribution; team totals do not qualify an individual")}
        if fields["coverage"] as? String != "complete"{missing.append("Complete production coverage")}
        if fields["volumeDefinition"] as? String != "unique_closed_volume"{missing.append("Production volume definition; unqualified sales totals cannot be assumed unique closed volume")}
        if !prospectFullPeriod(fields){missing.append("Full calendar-year or LTM production period")}
        let end=fields["periodEnd"] as? String ?? "",cutoff=fields["asOfDate"] as? String ?? ""
        if !prospectFresh(end,asOf,productionAge){missing.append("Production period ending within \(productionAge) days")}
        if parseDay(cutoff)==nil || cutoff<end || cutoff>asOf{missing.append("Valid production as-of date")}
        if (fields["productionReference"] as? String ?? "").isEmpty{missing.append("Production source reference")}
        if !prospectFresh(fields["productionCheckedAt"] as? String ?? "",asOf,freshness){missing.append("Production source checked within \(freshness) days")}
        if let volume=prospectNumber(fields["individualVolume"]){if volume>=2_000_000{reasons.append("Individual production meets $2M baseline")}else{failed.append("Individual production below $2M")}}else{missing.append("Known individual production volume; missing is not zero")}
        return ["state":!failed.isEmpty ? "not_qualified" : missing.isEmpty ? "qualified" : "needs_evidence","reasons":reasons,"missingEvidence":missing,"failedCriteria":failed]
    }
    static let prospectLicenseEvidenceKeys=["licenseStatus","originalLicenseDate","originalLicenseDateRaw","licenseCheckedAt","licenseReference","identityMatchStatus","identityCheckedAt","identityReference"]
    private static func validatedProspectLicenseEvidence(_ p:Record) throws -> Record {
        var r:Record=[:]
        for key in prospectLicenseEvidenceKeys where p[key] != nil {
            r[key]=try prospectText(p,key,max:key.hasSuffix("Reference") ? 2000 : 150)
        }
        for key in ["originalLicenseDate","licenseCheckedAt","identityCheckedAt"] where !(r[key] as? String ?? "").isEmpty {
            r[key]=try prospectDay(r,key)
        }
        let raw=r["originalLicenseDateRaw"] as? String ?? "",canonical=r["originalLicenseDate"] as? String ?? ""
        if !raw.isEmpty,!canonical.isEmpty{
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="MM/dd/yyyy";formatter.isLenient=false
            if let parsed=formatter.date(from:raw),formatter.string(from:parsed)==raw,Store.day(parsed) != canonical{throw StoreError(message:"Original license date disagrees with its preserved source date.")}
        }
        let status=r["identityMatchStatus"] as? String ?? ""
        guard status.isEmpty || ["unreviewed","possible","verified","rejected"].contains(status) else{throw StoreError(message:"Use a reviewed identity match status; a matching name alone is not verification.")}
        return r
    }
    private static func prospectProductionThresholdMet(_ fields:Record,area:Record,asOf:String)->Bool {
        let freshness=area["evidenceMaxAgeDays"] as? Int ?? 90,age=area["productionMaxAgeDays"] as? Int ?? 365
        let end=fields["periodEnd"] as? String ?? "",cutoff=fields["asOfDate"] as? String ?? ""
        return fields["attribution"] as? String=="individual" && fields["coverage"] as? String=="complete" && fields["volumeDefinition"] as? String=="unique_closed_volume" && prospectFullPeriod(fields) && prospectFresh(end,asOf,age) && parseDay(cutoff) != nil && cutoff>=end && cutoff<=asOf && !(fields["productionReference"] as? String ?? "").isEmpty && prospectFresh(fields["productionCheckedAt"] as? String ?? "",asOf,freshness) && (prospectNumber(fields["individualVolume"]) ?? -1)>=2_000_000
    }
    private static func prospectQualification(_ fields:Record,area:Record,asOf:String)->Record {
        let full=prospectFullQualification(fields,area:area,asOf:asOf)
        let mode=area["eligibilityMode"] as? String ?? "full_production"
        guard mode=="interim_license_tenure" else{
            var result=full;result["eligibilityMode"]="full_production";result["fullProductionQualification"]=full
            result["productionThresholdMet"]=prospectProductionThresholdMet(fields,area:area,asOf:asOf)
            return result
        }
        var missing=[String](),reasons=[String](),failed=[String]()
        let freshness=area["evidenceMaxAgeDays"] as? Int ?? 90
        let type=AgentIdentity.canonicalType(fields["licenseType"] as? String ?? "",jurisdiction:fields["licenseJurisdiction"] as? String ?? "")
        if AgentIdentity.licenseKey(fields)==nil{missing.append("Scoped individual license identity")}
        if !["sales-agent","broker individual"].contains(type){failed.append("An individual Sales Agent or Broker Individual license is required for interim consideration")}
        let status=prospectNorm(fields["licenseStatus"] as? String ?? "")
        if status.isEmpty{missing.append("Verified active license status")}
        else if status != "active"{failed.append("License is not Active")}
        else{reasons.append("Active individual license verified")}
        if (fields["licenseReference"] as? String ?? "").isEmpty{missing.append("License registry source reference")}
        if !prospectFresh(fields["licenseCheckedAt"] as? String ?? "",asOf,freshness){missing.append("License registry checked within \(freshness) days")}
        let original=fields["originalLicenseDate"] as? String ?? ""
        if let start=parseDay(original),let cutoff=parseDay(asOf),let anniversary=Calendar(identifier:.gregorian).date(byAdding:.year,value:2,to:start),start<=cutoff{
            if anniversary<=cutoff{reasons.append("At least two calendar years since recorded original licensure; continuous practice is not established")}
            else{failed.append("Less than two years since recorded original licensure")}
        }else{missing.append("Verified original license date")}
        if fields["identityMatchStatus"] as? String != "verified"{missing.append("Reviewed verified identity match")}
        if (fields["identityReference"] as? String ?? "").isEmpty{missing.append("Identity-match source reference")}
        if !prospectFresh(fields["identityCheckedAt"] as? String ?? "",asOf,freshness){missing.append("Identity evidence checked within \(freshness) days")}
        let cities=fields["serviceCities"] as? [String] ?? [],target=Set((area["cities"] as? [String] ?? []).map(prospectNorm))
        let scope=fields["serviceJurisdiction"] as? String ?? "",areaScope=area["jurisdiction"] as? String ?? ""
        if scope.isEmpty || areaScope.isEmpty{missing.append("Verified service jurisdiction; license or office location alone is not service footprint")}
        else if scope.uppercased() != areaScope.uppercased(){failed.append("Service jurisdiction differs from selected area")}
        if cities.isEmpty{missing.append("Verified service cities; office city is not service footprint")}
        else if !cities.contains(where:{target.contains(prospectNorm($0))}){failed.append("Outside the selected service area")}
        else{reasons.append("Corroborated service-area match")}
        if (fields["experienceReference"] as? String ?? "").isEmpty{missing.append("Professional service-area source reference")}
        if !prospectFresh(fields["experienceCheckedAt"] as? String ?? "",asOf,freshness){missing.append("Service-area evidence checked within \(freshness) days")}
        let deferred=(full["missingEvidence"] as? [String] ?? [])+(full["failedCriteria"] as? [String] ?? [])
        return ["state":!failed.isEmpty ? "not_qualified" : missing.isEmpty ? ((full["state"] as? String)=="qualified" ? "qualified" : "interim_eligible") : "needs_evidence","eligibilityMode":mode,"reasons":reasons,"missingEvidence":missing+deferred,"blockingEvidence":missing,"deferredEvidence":deferred,"failedCriteria":failed,"fullProductionQualification":full,"productionThresholdMet":prospectProductionThresholdMet(fields,area:area,asOf:asOf),"considerationNote":"Interim consideration and the full-production rubric are assessed separately. Unknown production remains unknown."]
    }
    private static func prospectIdentity(_ fields:Record)->String {
        [fields["licenseJurisdiction"] as? String ?? "",fields["licenseType"] as? String ?? "",fields["license"] as? String ?? ""].map(prospectNorm).joined(separator:"|")
    }
    func previewProspecting(_ p:Record) throws -> Record {
        let area=try prospectArea(p["serviceAreaId"] as? String),mapping=try prospectMapping(p)
        guard let rows=p["rows"] as? [Record],!rows.isEmpty,rows.count<=250,let source=p["source"] as? Record else{throw StoreError(message:"Preview 1–250 rows with an explicit source.")}
        let provider=try Store.prospectText(source,"providerId",required:true,max:100),label=try Store.prospectText(source,"label",required:true,max:150),reference=try Store.prospectText(source,"reference",required:true,max:2000),checked=try Store.prospectDay(source,"checkedAt")
        let kind=try Store.prospectText(source,"kind",required:true)
        guard ["fixture","public_roster","authorized_export"].contains(kind) else{throw StoreError(message:"Choose fixture, public_roster or authorized_export. This app does not establish feed access.")}
        var provenance:Record=["providerId":provider,"label":label,"reference":reference,"kind":kind,"checkedAt":checked,"connectionStatus":"unconnected"]
        var acquisition:Record=["source":label,"sourceType":source["sourceType"] ?? "provider_import","sourceReference":reference,"sourcedAt":source["sourcedAt"] ?? checked]
        guard ["provider_import","ai_agent","email_import"].contains(acquisition["sourceType"] as? String ?? "") else{throw StoreError(message:"Discovery source type must be provider_import, ai_agent or email_import.")}
        acquisition["sourceActor"]=source["sourceActor"]
        for (key,value) in try Store.validatedCandidateSource(acquisition,defaultType:"provider_import",now:Store.now()){provenance[key]=value}
        let columns=mapping["fields"] as! [String:String],defaults=mapping["defaults"] as? Record ?? [:],agents=try all("agents")
        var result=[Record](),hard=[String](),seen=Set<String>()
        for(index,row) in rows.enumerated(){
            var fields=defaults,conflicts=[String]()
            for(canonical,column) in columns{if let value=row[column]{fields[canonical]=value}}
            for key in ["license","licenseJurisdiction","licenseType","sourceAgentId","mlsId"]{
                do{fields[key]=try Store.prospectText(fields,key,required:["license","licenseJurisdiction","licenseType"].contains(key),max:120)}catch{conflicts.append(error.localizedDescription)}
            }
            if (fields["license"] as? String ?? "").contains(","){conflicts.append("Multiple source licenses require separate verified license records.")}
            if let cities=fields["serviceCities"]{do{fields["serviceCities"]=try Store.prospectCities(cities)}catch{conflicts.append(error.localizedDescription)}}
            for key in ["experienceYears","individualVolume"]{if let value=fields[key],!(value is NSNull),Store.prospectNumber(value)==nil{conflicts.append("\(key) must be a nonnegative number or null.")}}
            do{for(key,value) in try Store.validatedProspectLicenseEvidence(fields){fields[key]=value}}catch{conflicts.append(error.localizedDescription)}
            let sourceId=fields["sourceAgentId"] as? String ?? ""
            if !sourceId.isEmpty{fields["sourceProvider"]=provider;fields["sourceAliases"]=[["provider":provider,"sourceId":sourceId,"reference":reference,"observedAt":checked]]}
            do{for(key,value) in try AgentIdentity.normalized(fields){fields[key]=value}}catch{conflicts.append(error.localizedDescription)}
            let identity=Store.prospectIdentity(fields)
            if !seen.insert(identity).inserted{conflicts.append("Duplicate license identity in this preview.")}
            var matched:Record?
            do{matched=try AgentIdentity.match(fields,among:agents);try AgentIdentity.ensureSourceNameCompatible(fields,existing:matched)}catch{conflicts.append(error.localizedDescription)}
            let id="prospect-"+String(try Store.prospectHash(["provider":provider,"identity":sourceId.isEmpty ? identity : sourceId]).prefix(32))
            if let saved=try all("discoveryProspects").first(where:{$0["id"] as? String==id}),let savedFields=saved["fields"] as? Record,Store.prospectIdentity(savedFields) != identity{conflicts.append("This source record changed license identity; a reviewer must resolve it.")}
            let qualification=try applySourcingRules(to:Store.prospectQualification(fields,area:area,asOf:Store.prospectingLocalDay()),fields:fields,asOf:Store.prospectingLocalDay())
            if (qualification["sourcingRulesAssessment"] as? Record)?["state"] as? String=="excluded"{conflicts += (qualification["sourcingRulesAssessment"] as? Record)?["reasons"] as? [String] ?? []}
            var r:Record=["id":id,"rowNumber":index+1,"name":fields["name"] as? String ?? "License \(fields["license"] as? String ?? "unknown")","fields":fields,"source":provenance,"serviceAreaId":area["id"] as! String,"mappingId":mapping["id"] as! String,"qualification":qualification,"conflicts":conflicts,"stage":"discovery","isFixture":kind=="fixture","newIdentityAtDiscovery":matched==nil]
            if let match=matched{r["matchedAgentId"]=match["id"]}
            result.append(r);hard += conflicts.map{"Row \(index+1): \($0)"}
        }
        let token=try Store.prospectHash(["rows":result,"area":area,"mapping":mapping,"sourcingRules":try sourcingRulesRecord(),"agentIdentities":agents.map{["id":$0["id"] ?? "","identity":Store.prospectIdentity($0),"aliases":$0["sourceAliases"] ?? [],"name":$0["name"] ?? "","sourceName":($0["importedCoreValues"] as? Record)?["name"] ?? "","nameOverridden":($0["localOverrides"] as? [String] ?? []).contains("name")]}])
        return ["rows":result,"hardConflicts":hard,"count":result.count,"readyCount":result.filter{["qualified","interim_eligible"].contains(($0["qualification"] as? Record)?["state"] as? String ?? "") && ($0["conflicts"] as? [String] ?? []).isEmpty}.count,"missingEvidenceCount":result.filter{($0["qualification"] as? Record)?["state"] as? String=="needs_evidence"}.count,"sourceStatus":"unconnected","previewToken":token,"notices":["Staging does not create a CRM contact or a call priority.","Provider access, recruiting permission and NTREIS historical continuity remain unverified."]]
    }
    func stageProspecting(_ p:Record) throws {
        let preview=try previewProspecting(p)
        guard let token=p["previewToken"] as? String,token==preview["previewToken"] as? String else{throw StoreError(message:"Preview changed. Review the source, mapping and identity matches again.")}
        guard (preview["hardConflicts"] as? [String] ?? []).isEmpty else{throw StoreError(message:"Resolve the preview's identity/data conflicts before staging.")}
        for var row in preview["rows"] as! [Record]{
            row.removeValue(forKey:"conflicts");row.removeValue(forKey:"rowNumber")
            let old=try all("discoveryProspects").first{$0["id"] as? String==row["id"] as? String}
            if let old=old {
                let keys=["name","fields","source","serviceAreaId","mappingId","qualification","isFixture"]
                if NSDictionary(dictionary:old.filter{keys.contains($0.key)}).isEqual(to:row.filter{keys.contains($0.key)}){continue}
                row["newIdentityAtDiscovery"]=old["newIdentityAtDiscovery"] ?? (old["matchedAgentId"] == nil)
                if let imported=old["importedAt"]{row["importedAt"]=imported;row["stage"]="review_update"}
                if let match=old["matchedAgentId"]{row["matchedAgentId"]=match}
            }
            try prospectPersist("discoveryProspects",row,old?["revision"] as? Int ?? 0)
        }
    }
    func saveProspectingEvidence(_ p:Record) throws {
        let aid=try Store.prospectText(p,"agentId",required:true);_=try get("agents",aid)
        let cities=try Store.prospectCities(p["serviceCities"]),checked=try Store.prospectDay(p,"checkedAt")
        guard let source=p["source"] as? Record else{throw StoreError(message:"Add evidence source details.")}
        let label=try Store.prospectText(source,"label",required:true,max:150),reference=try Store.prospectText(source,"reference",required:true,max:2000)
        let years:Any
        if p["experienceYears"] == nil || p["experienceYears"] is NSNull{years=NSNull()}else if let value=Store.prospectNumber(p["experienceYears"]),value<=100{years=value}else{throw StoreError(message:"Experience years must be a nonnegative number or unknown.")}
        let serviceJurisdiction=try Store.prospectText(p,"serviceJurisdiction",max:32).uppercased()
        guard serviceJurisdiction.isEmpty || serviceJurisdiction.range(of:"^[A-Z0-9][A-Z0-9._-]{1,31}$",options:.regularExpression) != nil else{throw StoreError(message:"Use a jurisdiction code for the verified service footprint.")}
        var r:Record=["id":aid,"agentId":aid,"serviceCities":cities,"serviceJurisdiction":serviceJurisdiction,"experienceYears":years,"checkedAt":checked,"source":["label":label,"reference":reference],"evidenceStatus":"reviewed"]
        var licenseEvidence=(try all("prospectingEvidence").first{$0["agentId"] as? String==aid} ?? [:]).filter{Store.prospectLicenseEvidenceKeys.contains($0.key)}
        for key in Store.prospectLicenseEvidenceKeys where p[key] != nil{licenseEvidence[key]=p[key]}
        for(key,value) in try Store.validatedProspectLicenseEvidence(licenseEvidence){r[key]=value}
        if let opportunity=p["opportunity"] as? Record{
            let kind=try Store.prospectText(opportunity,"kind",required:true)
            guard ["none","expressed_interest","professional_need"].contains(kind)else{throw StoreError(message:"Use an explicit professional interest/need, or none. Do not infer personal motives.")}
            if kind != "none"{
                let occurred=try Store.prospectDay(opportunity,"occurredOn")
                guard occurred<=checked else{throw StoreError(message:"Opportunity evidence cannot be checked before the professional statement occurred.")}
                r["opportunity"]=["kind":kind,"summary":try Store.prospectText(opportunity,"summary",required:true,max:1000),"occurredOn":occurred,"reference":try Store.prospectText(opportunity,"reference",required:true,max:2000)]
            }
        }
        try prospectPersist("prospectingEvidence",r,p["expectedRevision"] as? Int ?? 0)
    }
    // Conservative review holds for a new-record-only batch. These comparisons
    // never canonicalize or merge an identity; exact source values remain intact.
    private static func prospectPossibleNewContactOverlap(_ fields:Record,among agents:[Record])->Bool {
        func numericLicense(_ r:Record)->String?{
            let scope=AgentIdentity.canonicalJurisdiction(r["licenseJurisdiction"] as? String ?? "")
            guard scope.isEmpty || scope=="TX" else{return nil}
            let number=(r["license"] as? String ?? "").uppercased()
            guard number.range(of:"^[0-9]+(?:-[A-Z]+)?$",options:.regularExpression) != nil else{return nil}
            let digits=String(number.split(separator:"-").first ?? "").drop(while:{$0=="0"})
            return digits.isEmpty ? "0" : String(digits)
        }
        let number=numericLicense(fields),name=AgentIdentity.sourceNameKey(fields["name"] as? String ?? ""),email=prospectNorm(fields["email"] as? String ?? "")
        let phone=try? normalizedCommunicationPhone(fields["phone"] as? String ?? "")
        return agents.contains{agent in
            if let number=number,number==numericLicense(agent){return true}
            if !name.isEmpty,name==AgentIdentity.sourceNameKey(agent["name"] as? String ?? ""){return true}
            if !email.isEmpty,email==prospectNorm(agent["email"] as? String ?? ""){return true}
            if let phone=phone,phone==(try? normalizedCommunicationPhone(agent["phone"] as? String ?? "")){return true}
            return false
        }
    }
    // Explicit reviewed promotion. It is intentionally separate from discovery and planning.
    // Store.command wraps the whole batch in a transaction; any collision rolls it all back.
    func acceptDiscoveredProspects(_ p:Record) throws {
        guard p["reviewConfirmed"] as? Bool==true,let ids=p["recordIds"] as? [String],!ids.isEmpty,ids.count<=250,Set(ids).count==ids.count,
              let expected=p["expectedRevisions"] as? [String:Int] else{throw StoreError(message:"Select reviewed staged records and confirm their exact revisions before importing.")}
        for id in ids {
            var staged=try get("discoveryProspects",id)
            guard expected[id]==staged["revision"] as? Int else{throw StoreError(message:"A staged record changed. Review it again before import.")}
            guard staged["isFixture"] as? Bool != true else{throw StoreError(message:"Fixture discovery records cannot be promoted to real CRM contacts.")}
            guard let fields=staged["fields"] as? Record,let source=staged["source"] as? Record else{throw StoreError(message:"This staged source is incomplete.")}
            let identity=try AgentIdentity.normalized(fields),existing=try AgentIdentity.match(identity,among:all("agents"))
            try AgentIdentity.ensureSourceNameCompatible(fields,existing:existing)
            let name=(fields["name"] as? String ?? existing?["name"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty else{throw StoreError(message:"Resolve the licensed agent's name from a verified source before importing a new contact.")}
            let generatedID="discovery-"+String(try Store.prospectHash(["license":Store.prospectIdentity(identity)]).prefix(32))
            let aid=existing?["id"] as? String ?? generatedID
            var affiliation=existing ?? [:]
            for(key,value) in fields{affiliation[key]=value}
            let ruleAssessment=try sourcingRuleAssessment(fields:affiliation,asOf:Store.prospectingLocalDay())
            guard ruleAssessment["state"] as? String=="eligible" else{throw StoreError(message:((ruleAssessment["reasons"] as? [String] ?? [])+(ruleAssessment["missingEvidence"] as? [String] ?? [])).joined(separator:" "))}
            if staged["stage"] as? String=="imported",staged["matchedAgentId"] as? String==aid{continue}
            let currentAgents=try all("agents")
            if p["newRecordsOnly"] as? Bool==true,(existing != nil || Store.prospectPossibleNewContactOverlap(fields,among:currentAgents)){throw StoreError(message:"A selected discovery now matches or overlaps an existing contact. New-record-only intake stopped for duplicate review without changing it.")}
            if existing==nil,try all("agents").contains(where:{$0["id"] as? String==generatedID}){throw StoreError(message:"The generated contact ID is already occupied; review identity before importing.")}
            let area=try prospectArea(staged["serviceAreaId"] as? String),mode=area["eligibilityMode"] as? String ?? "full_production"
            if let required=p["requiredEligibilityMode"] as? String,required != mode{throw StoreError(message:"Eligibility mode changed. Review the intake again.")}
            let qualification=try applySourcingRules(to:Store.prospectQualification(fields,area:area,asOf:Store.prospectingLocalDay()),fields:fields,asOf:Store.prospectingLocalDay())
            if mode=="interim_license_tenure"{
                guard ["qualified","interim_eligible"].contains(qualification["state"] as? String ?? "") else{throw StoreError(message:"Interim intake requires current verified identity, Active individual licensure, two years of recorded tenure and corroborated service-area evidence.")}
                if let existing=existing{
                    let status=Store.prospectNorm(existing["status"] as? String ?? "")
                    guard !["do not contact","not interested","not qualified","recruited","lost"].contains(status),existing["doNotContact"] as? Bool != true,
                          !["skipped","snoozed"].contains(existing["disposition"] as? String ?? ""),!["conflict","held","needs_review"].contains(existing["identityReviewState"] as? String ?? "") else{throw StoreError(message:"Existing suppression or identity hold prevents interim intake; it was preserved.")}
                }
            }
            let now=Store.now()
            var agent=existing ?? ["id":aid,"name":name,"office":"","city":"","email":"","phone":"","status":"Identified","move":"Unknown","manual":false,"datasetId":"live","source":"Reviewed discovery import","createdAt":now,"importedAt":now,"history":[],"transactions":[],"signals":[],"liked":false,"disposition":""]
            if existing==nil {
                let acquisition:Record=["source":source["source"] ?? source["label"] ?? "Reviewed discovery import","sourceType":source["sourceType"] ?? "provider_import","sourceReference":source["sourceReference"] ?? source["reference"] ?? id,"sourceActor":source["sourceActor"] ?? "","sourcedAt":source["sourcedAt"] ?? source["checkedAt"] ?? ""]
                for(key,value) in try Store.validatedCandidateSource(acquisition,defaultType:"provider_import",now:now){agent[key]=value}
            }
            for(key,value) in try AgentIdentity.normalized(identity,existing:existing){agent[key]=value}
            let overrides=Set(agent["localOverrides"] as? [String] ?? []),prior=agent["importedCoreValues"] as? Record ?? [:]
            var managed=prior
            for key in ["name","office","officeCity","email","phone"] {
                guard let value=fields[key] as? String,!value.isEmpty else{continue}
                let current=agent[key] as? String ?? "",previous=prior[key] as? String
                if !overrides.contains(key) && (current.isEmpty || current==previous || existing==nil){agent[key]=value;managed[key]=value}
            }
            agent["importedCoreValues"]=managed;agent["lastImportedAt"]=now
            agent["discoverySourceId"]=id;agent["discoverySource"]=source
            agent["identityReviewState"]=agent["identityReviewState"] ?? (mode=="interim_license_tenure" ? "verified" : "unreviewed")
            if existing==nil{agent["recruitingEligibility"]=["mode":mode,"state":qualification["state"] ?? "needs_evidence","checkedAt":Store.prospectingLocalDay(),"productionThresholdMet":qualification["productionThresholdMet"] ?? false,"scope":"at_intake","qualification":qualification]}
            try put("agents",agent)
            // Preserve independently edited evidence rather than silently replacing it.
            if try all("prospectingEvidence").allSatisfy({$0["agentId"] as? String != aid}),
               let cities=fields["serviceCities"] as? [String],let checked=fields["experienceCheckedAt"] as? String,
               let reference=fields["experienceReference"] as? String,!reference.isEmpty {
                var evidencePayload:Record=["agentId":aid,"serviceCities":cities,"serviceJurisdiction":fields["serviceJurisdiction"] ?? fields["licenseJurisdiction"] ?? "","experienceYears":fields["experienceYears"] ?? NSNull(),"checkedAt":checked,"source":["label":source["label"] ?? "Reviewed source","reference":reference],"expectedRevision":0]
                for key in Store.prospectLicenseEvidenceKeys where fields[key] != nil{evidencePayload[key]=fields[key]}
                try saveProspectingEvidence(evidencePayload)
            }
            // An aggregate is imported only with an explicit unique-closed definition.
            if fields["volumeDefinition"] as? String=="unique_closed_volume",let volume=Store.prospectNumber(fields["individualVolume"]),
               fields["attribution"] as? String=="individual",let start=fields["periodStart"] as? String,let end=fields["periodEnd"] as? String,
               let year=Int(end.prefix(4)),let cutoff=fields["asOfDate"] as? String,let checked=fields["productionCheckedAt"] as? String,
               let reference=fields["productionReference"] as? String,!reference.isEmpty {
                let production:Record=["agentId":aid,"year":year,"periodStart":start,"periodEnd":end,"periodType":fields["periodType"] ?? "annual","asOfDate":cutoff,"coverage":fields["coverage"] ?? "unknown","attribution":"individual","reportedVolume":volume,"volumeDefinition":"unique_closed_volume","source":["label":source["label"] ?? "Reviewed source","reference":reference,"method":"import","providerId":source["providerId"] ?? "","recordIds":[id],"checkedAt":checked],"expectedRevision":0,"changeReason":"Reviewed discovery source \(id)"]
                // Existing annual source conflicts require explicit performance review, never replacement.
                try importPerformance(["records":[production]])
            }
            staged["stage"]="imported";staged["matchedAgentId"]=aid;staged["importedAt"]=now;staged["updatedAt"]=now;staged["revision"]=(staged["revision"] as? Int ?? 0)+1
            try put("discoveryProspects",staged)
        }
    }
    private func prospectAgentQualification(_ agent:Record,area:Record,asOf:String,evidence:[Record],performance:[Record])->Record {
        let aid=agent["id"] as? String ?? "",e=evidence.first{$0["agentId"] as? String==aid} ?? [:]
        let periods=performance.filter{Store.performanceIsIndividual($0) && $0["agentId"] as? String==aid && $0["coverage"] as? String=="complete" && Store.performanceIsFullPeriod($0) && ($0["periodEnd"] as? String ?? "")<=asOf}.sorted{a,b in
            let ae=a["periodEnd"] as? String ?? "",be=b["periodEnd"] as? String ?? "";if ae != be{return ae>be}
            let at=Store.performancePeriodType(a),bt=Store.performancePeriodType(b);if at != bt{return at=="annual"}
            return (a["id"] as? String ?? "")<(b["id"] as? String ?? "")
        }
        let chosen=periods.first ?? [:],source=chosen["source"] as? Record ?? [:]
        var fields=chosen
        for key in ["license","licenseJurisdiction","licenseType"]{fields[key]=agent[key]}
        for key in Store.prospectLicenseEvidenceKeys{fields[key]=e[key]}
        fields["licenseJurisdiction"]=agent["licenseJurisdiction"] ?? "";fields["serviceJurisdiction"]=e["serviceJurisdiction"] ?? ""
        fields["periodType"]=Store.performancePeriodType(chosen);fields["serviceCities"]=e["serviceCities"] ?? [];fields["experienceYears"]=e["experienceYears"] ?? NSNull();fields["experienceCheckedAt"]=e["checkedAt"] ?? "";fields["experienceReference"]=(e["source"] as? Record)?["reference"] ?? "";fields["productionReference"]=source["reference"] ?? "";fields["productionCheckedAt"]=source["checkedAt"] ?? "";fields["individualVolume"]=Store.performanceTotals(chosen)["uniqueVolume"] ?? NSNull();fields["volumeDefinition"]="unique_closed_volume"
        var result=Store.prospectQualification(fields,area:area,asOf:asOf)
        if periods.count>1,let end=chosen["periodEnd"] as? String{
            let tied=periods.filter{$0["periodEnd"] as? String==end && $0["periodStart"] as? String==chosen["periodStart"] as? String && Store.performancePeriodType($0)==Store.performancePeriodType(chosen)}
            let volumes=Set(tied.compactMap{Store.performanceTotals($0)["uniqueVolume"] as? Double})
            if volumes.count>1{
                let conflict="Conflicting production totals for the same cutoff require review"
                var missing=result["missingEvidence"] as? [String] ?? [];missing.append(conflict)
                result["missingEvidence"]=missing;result["state"]="needs_evidence";result["productionThresholdMet"]=false
                var full=result["fullProductionQualification"] as? Record ?? [:]
                var fullMissing=full["missingEvidence"] as? [String] ?? [];fullMissing.append(conflict)
                full["missingEvidence"]=fullMissing;full["state"]="needs_evidence";result["fullProductionQualification"]=full
            }
        }
        if let id=chosen["id"]{result["performanceId"]=id}
        return result
    }
    func dailyActionPlan(_ p:Record=[:]) throws -> Record {
        let asOf=try Store.prospectDay(["asOfDate":p["asOfDate"] ?? Store.prospectingLocalDay()],"asOfDate"),area=try prospectArea(p["serviceAreaId"] as? String)
        let agents=try all("agents"),tasks=try all("tasks"),sequences=try all("sequences"),evidence=try all("prospectingEvidence"),performance=try all("performance"),memberships=try all("teamMemberships"),teams=try all("teams")
        let sourcingProfile=try sourcingRulesRecord()
        var candidates=[Record](),excluded=[Record]()
        for agent in agents{
            let aid=agent["id"] as? String ?? "",name=agent["name"] as? String ?? "Contact",status=Store.prospectNorm(agent["status"] as? String ?? "")
            if Store.performanceDataset(agent) != "real"{excluded.append(["agentId":aid,"reason":"Sample or unclassified contact"]);continue}
            let suppressed=["do not contact","not interested","not qualified","recruited","lost"].contains(status) || agent["doNotContact"] as? Bool==true
            if ["skipped","snoozed"].contains(agent["disposition"] as? String ?? ""){excluded.append(["agentId":aid,"reason":"Existing skipped/snoozed disposition"]);continue}
            let ownTasks=tasks.filter{$0["agentId"] as? String==aid && $0["completed"] as? Bool != true}
            let ruleAssessment=try sourcingRuleAssessment(fields:agent,asOf:asOf,profile:sourcingProfile,teams:teams,memberships:memberships),ruleHeld=ruleAssessment["state"] as? String != "eligible"
            let held=ruleHeld || ownTasks.contains{($0["identityHoldId"] as? String ?? "") != "" || ($0["pauseReason"] as? String ?? "").contains("identity")} || ["conflict","held","needs_review"].contains(agent["identityReviewState"] as? String ?? "")
            let replyPaused=ownTasks.contains{($0["followUpState"] as? String ?? "").contains("paused")} || sequences.contains{$0["agentId"] as? String==aid && (($0["pendingOutputState"] as? String ?? "").contains("paused") || ($0["pauseReason"] as? String ?? "")=="inbound_reply")}
            let due=ownTasks.filter{task in let date=task["dueDate"] as? String ?? "";return Store.parseDay(date) != nil && date<=asOf}.sorted{($0["dueDate"] as? String ?? "")<($1["dueDate"] as? String ?? "")}
            let safeDue=due.filter{task in (!suppressed && !held && !replyPaused) || ["Review","Approval"].contains(task["type"] as? String ?? "")}
            let qualification=SourcingRules.applying(ruleAssessment,to:prospectAgentQualification(agent,area:area,asOf:asOf,evidence:evidence,performance:performance))
            let missing=qualification["missingEvidence"] as? [String] ?? []
            if let task=safeDue.first{
                let review=suppressed || held || replyPaused
                candidates.append(["agentId":aid,"name":name,"action":review ? "Review before further outreach" : task["title"] as? String ?? "Complete due follow-up","reason":review ? "A saved review task is due; outreach remains held." : "Saved follow-up or commitment is due on \(task["dueDate"] as? String ?? asOf).","reasons":["Existing task from the full contact pool"],"taskIds":safeDue.compactMap{$0["id"] as? String},"missingEvidence":missing,"qualificationState":qualification["state"] ?? "needs_evidence","priorityKind":review ? "review" : "due_follow_up","sortGroup":0,"sortDate":task["dueDate"] ?? asOf,"teamPreference":false])
                continue
            }
            if suppressed{excluded.append(["agentId":aid,"reason":"Existing recruiting exclusion: \(status)"]);continue}
            if ruleHeld{excluded.append(["agentId":aid,"reason":((ruleAssessment["reasons"] as? [String] ?? [])+(ruleAssessment["missingEvidence"] as? [String] ?? [])).joined(separator:" "),"sourcingRulesAssessment":ruleAssessment]);continue}
            if held || replyPaused{excluded.append(["agentId":aid,"reason":held ? "Identity review holds outreach" : "Received reply paused follow-ups"]);continue}
            // A future promise must not become an unsolicited new-priority call today.
            if ownTasks.contains(where:{let date=$0["dueDate"] as? String ?? "";return Store.parseDay(date) != nil && date>asOf && ["Call","Check-in","Follow-up"].contains($0["type"] as? String ?? "")}){excluded.append(["agentId":aid,"reason":"Future follow-up is already scheduled"]);continue}
            guard ["qualified","interim_eligible"].contains(qualification["state"] as? String ?? "") else{excluded.append(["agentId":aid,"reason":"Qualification evidence is incomplete or outside baseline","qualification":qualification]);continue}
            let e=evidence.first{$0["agentId"] as? String==aid} ?? [:],opportunity=e["opportunity"] as? Record ?? [:],kind=opportunity["kind"] as? String ?? "none"
            let freshOpportunity=Store.prospectFresh(opportunity["occurredOn"] as? String ?? "",asOf,area["evidenceMaxAgeDays"] as? Int ?? 90)
            let team=memberships.contains{membership in
                guard membership["agentId"] as? String==aid,let start=membership["startDate"] as? String,Store.parseDay(start) != nil,start<=asOf,
                      (membership["endDate"] as? String ?? "").isEmpty || (membership["endDate"] as? String ?? "")>=asOf,
                      Store.prospectFresh(membership["checkedAt"] as? String ?? "",asOf,area["evidenceMaxAgeDays"] as? Int ?? 90),
                      !((membership["source"] as? Record)?["reference"] as? String ?? "").isEmpty,
                      let team=teams.first(where:{$0["id"] as? String==membership["teamId"] as? String}) else{return false}
                return Store.prospectFresh(team["checkedAt"] as? String ?? "",asOf,area["evidenceMaxAgeDays"] as? Int ?? 90) && !((team["source"] as? Record)?["reference"] as? String ?? "").isEmpty
            }
            let verification=agent["communicationVerification"] as? Record ?? [:],phone=try? Store.normalizedCommunicationPhone(agent["phone"] as? String ?? "")
            let reviewedPhone=agent["datasetId"] as? String=="live" && verification["confirmed"] as? Bool==true && verification["name"] as? String==agent["name"] as? String && verification["source"] as? String==agent["source"] as? String && verification["phone"] as? String==phone
            let verifiedPhone=phone != nil && (agent["manual"] as? Bool==true || reviewedPhone)
            let hasSignal=freshOpportunity && ["expressed_interest","professional_need"].contains(kind)
            let interim=qualification["state"] as? String=="interim_eligible"
            let fitLabel=interim ? "Interim license-tenure fit" : "Qualified business fit"
            let reason=hasSignal ? "\(fitLabel) and dated professional evidence: \(opportunity["summary"] as? String ?? "")" : "\(fitLabel); research current professional interest before outreach."
            candidates.append(["agentId":aid,"name":name,"action":hasSignal && verifiedPhone ? "Review evidence and call" : hasSignal ? "Verify contact route before calling" : "Research recruiting interest","reason":reason,"reasons":(qualification["reasons"] as? [String] ?? [])+(team ? ["Verified current team relationship; no team production threshold inferred"] : []),"taskIds":[],"missingEvidence":(interim ? missing : [])+(hasSignal ? [] : ["Current evidence of recruiting interest or professional need"])+(verifiedPhone ? [] : ["Verified saved phone route"]),"qualificationState":qualification["state"] ?? "needs_evidence","priorityKind":hasSignal ? (interim ? "interim_opportunity" : "qualified_opportunity") : "research","sortGroup":hasSignal ? 1 : 2,"sortDate":opportunity["occurredOn"] ?? "","teamPreference":team])
        }
        for task in tasks where task["agentId"] == nil && task["completed"] as? Bool != true{
            let date=task["dueDate"] as? String ?? ""
            if Store.parseDay(date) != nil && date<=asOf{candidates.append(["name":"General task","action":task["title"] as? String ?? "Review task","reason":"Existing general task is due on \(date).","reasons":["Due task from the existing work queue"],"taskIds":[task["id"] as? String ?? ""],"missingEvidence":[],"qualificationState":"not_applicable","priorityKind":"general_task","sortGroup":0,"sortDate":date,"teamPreference":false])}
        }
        candidates.sort{a,b in
            let x=a["sortGroup"] as! Int,y=b["sortGroup"] as! Int;if x != y{return x<y}
            let ad=a["sortDate"] as? String ?? "",bd=b["sortDate"] as? String ?? "";if x==0 && ad != bd{return ad<bd}
            let at=a["teamPreference"] as? Bool ?? false,bt=b["teamPreference"] as? Bool ?? false;if at != bt{return at}
            if ad != bd{return ad>bd};return (a["agentId"] as? String ?? a["name"] as? String ?? "")<(b["agentId"] as? String ?? b["name"] as? String ?? "")
        }
        let actions=candidates.prefix(10).map{r -> Record in var value=r;value.removeValue(forKey:"sortGroup");value.removeValue(forKey:"sortDate");return value}
        let staged=try all("discoveryProspects")
        let newRecords=staged.filter{Store.prospectingTimestampDay($0["createdAt"])==asOf && $0["isFixture"] as? Bool != true && $0["newIdentityAtDiscovery"] as? Bool==true}
        let groups=Dictionary(grouping:newRecords,by:{Store.prospectIdentity($0["fields"] as? Record ?? [:])})
        let discovered=groups.count
        var qualifiedDiscovery=0,interimDiscovery=0,eligibleDiscovery=0,needsEvidenceDiscovery=0
        for records in groups.values {
            var states=Set<String>()
            for record in records {
                let recordArea=try prospectArea(record["serviceAreaId"] as? String)
                let q=try applySourcingRules(to:Store.prospectQualification(record["fields"] as? Record ?? [:],area:recordArea,asOf:asOf),fields:record["fields"] as? Record ?? [:],asOf:asOf)
                states.insert(q["state"] as? String ?? "needs_evidence")
            }
            if !states.contains("not_qualified"),states.contains("qualified") || states.contains("interim_eligible"){
                eligibleDiscovery+=1
                if states.contains("qualified"){qualifiedDiscovery+=1}else{interimDiscovery+=1}
            }else if states.contains("needs_evidence") || ((states.contains("qualified") || states.contains("interim_eligible")) && states.contains("not_qualified")){needsEvidenceDiscovery+=1}
        }
        let imported=agents.filter{Store.performanceDataset($0)=="real" && Store.prospectingTimestampDay($0["importedAt"])==asOf}.count
        return ["date":asOf,"timeZone":Store.prospectingTimeZone.identifier,"serviceAreaId":area["id"] ?? "broader-waco","actions":actions,"counters":["discoveredToday":discovered,"importedToday":imported,"newProspectsGoal":10,"qualifiedDiscoveryToday":qualifiedDiscovery,"interimEligibleDiscoveryToday":interimDiscovery,"eligibleDiscoveryToday":eligibleDiscovery,"eligibleDiscoveryShortfall":max(0,10-eligibleDiscovery),"needsEvidenceDiscoveryToday":needsEvidenceDiscovery,"qualifiedDiscoveryShortfall":max(0,10-qualifiedDiscovery),"actionGoal":10,"actionCount":actions.count,"actionShortfall":max(0,10-actions.count)],"eligibleActionCount":candidates.count,"discoveryCounterScope":"all_service_areas","excluded":excluded,"sourceStatus":"unconnected","schedule":["state":"externally_managed","days":"weekdays","time":"08:30","timeZone":"America/Chicago","owner":"parent workflow"],"notices":["Discovery/import and the daily action list are separate stages; new imports are not automatically the best actions.","Due commitments come first, followed by qualified professional opportunities and evidence research. No move probability is invented.",(area["eligibilityMode"] as? String=="interim_license_tenure" ? "Interim consideration: Active verified individual license, 2+ years since original licensure and corroborated service footprint. Production remains separately unverified; continuous practice is not assumed." : "Baseline: 2+ years, $2M+ individual annual/LTM production; teams preferred without an invented team threshold."),"Freshness policy: production period within \(area["productionMaxAgeDays"] ?? 365) days and source checks within \(area["evidenceMaxAgeDays"] ?? 90) days. Missing evidence creates shortfalls, not quota padding.","Weekday 08:30 Central workflow is managed externally; this app installs no scheduler. Production feed remains unconnected; public research can continue."]]
    }
    func prospectingWorkspace(_ p:Record=[:]) throws -> Record {
        var areas=try all("serviceAreas");if !areas.contains(where:{$0["id"] as? String=="broader-waco"}){areas.insert(Store.defaultServiceArea(),at:0)}
        let saved=try all("sourceMappings"),ids=Set(saved.compactMap{$0["id"] as? String})
        let asOf=try Store.prospectDay(["asOfDate":p["asOfDate"] ?? Store.prospectingLocalDay()],"asOfDate")
        let staged=try all("discoveryProspects").map{row -> Record in
            var refreshed=row;refreshed["qualification"]=try applySourcingRules(to:Store.prospectQualification(row["fields"] as? Record ?? [:],area:try prospectArea(row["serviceAreaId"] as? String),asOf:asOf),fields:row["fields"] as? Record ?? [:],asOf:asOf);return refreshed
        }
        return ["sourcingRules":try sourcingRulesRecord(),"serviceAreas":areas,"sourceMappings":saved+Store.defaultSourceMappings().filter{!ids.contains($0["id"] as? String ?? "")},"selectedArea":try prospectArea(p["serviceAreaId"] as? String),"staged":staged,"evidence":try all("prospectingEvidence"),"sourceStatus":"unconnected","plan":try dailyActionPlan(p),"notices":["NTREIS/MLS access and recruiting/analytics entitlement have not been verified.","Documented schemas are mapping contracts; source field availability and historical continuity must be confirmed."]]
    }
}
