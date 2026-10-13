import Foundation

// A file is parsed again at commit time. The preview token binds its bytes, mappings,
// and the current CRM state so an edited file or intervening contact edit cannot win.
private struct GenericFile {
    let name: String
    let headers: [String]
    let rows: [[String: String]]
    let digest: String
}

private struct GenericPlan {
    let files: [GenericFile]
    let mappings: [Record]
    let agents: [Record]
    let customFields: [Record]
    let digest: String
    let token: String
    let newCount: Int
    let updateCount: Int
    let hardConflicts: [String]
    let possibleMatches: Int
    let alreadyImported: Bool
    let existingCount: Int
}

private enum GenericCSV {
    static let coreTargets = [
        "name", "firstName", "lastName", "office", "city", "email", "phone", "linkedinUrl",
        "courtedProfileURL", "mls", "mlsId", "license", "brand", "officeCity",
        "officeZip", "mlsHomeCity", "mlsHomeZip", "years", "officeYears",
        "volume", "change", "units", "buySideVolume", "listSideVolume",
        "buySideUnits", "listSideUnits", "active", "pending", "rentals",
        "avgRentalPrice", "avgSalesPrice", "approxGCI", "closedTransactions",
        "closeRatio", "dom", "move", "growth", "ytdVolume", "ytdUnits",
        "ytdAvgSalesPrice", "mutualConnections", "recentMutualCloseDate",
        "recentMutualAgentName", "recentMutualAddress", "recentMutualClosePrice",
        "sourceStatus", "sourceAssignee", "sourceLastViewedDate", "note1", "note2", "note3"
    ]
    static let numericTargets: Set<String> = ["years", "officeYears", "volume", "change", "units",
        "buySideVolume", "listSideVolume", "buySideUnits", "listSideUnits", "active", "pending",
        "rentals", "avgRentalPrice", "avgSalesPrice", "approxGCI", "closedTransactions",
        "closeRatio", "dom", "ytdVolume", "ytdUnits", "ytdAvgSalesPrice", "mutualConnections",
        "recentMutualClosePrice"]
    static let sourceOnly: Set<String> = ["sourceStatus", "sourceAssignee", "sourceLastViewedDate",
        "note1", "note2", "note3", "recentMutualAddress"]
    static let aliases: [String: String] = [
        "name":"name", "agentname":"name", "firstname":"firstName", "lastname":"lastName",
        "currentoffice":"office", "office":"office", "brokerage":"office", "mosttransactedcity":"city",
        "city":"city", "email":"email", "emailaddress":"email", "phone":"phone",
        "linkedin":"linkedinUrl", "linkedinurl":"linkedinUrl", "linkedinprofile":"linkedinUrl",
        "linkedinprofileurl":"linkedinUrl",
        "phonenumber":"phone", "courtedprofileurl":"courtedProfileURL", "profileurl":"courtedProfileURL",
        "mlsaffiliation":"mls", "mls":"mls", "mlsid":"mlsId", "licensenumber":"license",
        "brand":"brand", "officecity":"officeCity", "officezip":"officeZip",
        "agentsmlshomecity":"mlsHomeCity", "agentsmlshomezip":"mlsHomeZip",
        "yearsindustry":"years", "yearsinindustry":"years", "yearsinoffice":"officeYears",
        "ltmsalesvolume":"volume", "ltmsalesvolumegrowth":"change", "units":"units",
        "buysidesalesvolume":"buySideVolume", "listsidesalesvolume":"listSideVolume",
        "buysideunits":"buySideUnits", "listsideunits":"listSideUnits",
        "activelistings":"active", "pendingsales":"pending", "closedrentals":"rentals",
        "avgrentalprice":"avgRentalPrice", "avgsalesprice":"avgSalesPrice", "approxgci":"approxGCI",
        "closedtransactions":"closedTransactions", "ltmclosedlistprice":"closeRatio",
        "ltmavgdaysonmarket":"dom", "potentialtomove":"move", "potentialtogrow":"growth",
        "ytdsalesvolume":"ytdVolume", "ytdunits":"ytdUnits", "ytdavgsalesprice":"ytdAvgSalesPrice",
        "mutualconnections":"mutualConnections", "mostrecentmutualconnectioncloseddate":"recentMutualCloseDate",
        "mostrecentmutualconnectionagentname":"recentMutualAgentName",
        "mostrecentmutualconnectionaddress":"recentMutualAddress",
        "mostrecentmutualconnectionclosedprice":"recentMutualClosePrice",
        "status":"sourceStatus", "assignedto":"sourceAssignee", "lastvieweddate":"sourceLastViewedDate",
        "note1":"note1", "note2":"note2", "note3":"note3"
    ]
    static func norm(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    static func suggested(_ header: String) -> String {
        let normalized = norm(header)
        return aliases[normalized].map { "core:\($0)" } ?? "custom:new"
    }
    static func inferred(_ values: [String]) -> String {
        let nonempty = values.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !nonempty.isEmpty else { return "text" }
        if nonempty.allSatisfy({ (try? CourtedCSV.number($0,label:"field")) != nil }) { return "number" }
        if nonempty.allSatisfy({ Store.parseDay($0) != nil }) { return "date" }
        return "text"
    }
    static func files(_ payload: Record) throws -> [GenericFile] {
        guard let paths = payload["paths"] as? [String], !paths.isEmpty, paths.count <= 16,
              Set(paths).count == paths.count else { throw StoreError(message:"Choose one to sixteen distinct CSV files.") }
        var result: [GenericFile] = []
        var total = 0
        for path in paths {
            let url = URL(fileURLWithPath:path)
            guard url.pathExtension.lowercased() == "csv" else { throw StoreError(message:"Choose CSV files only.") }
            let info = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 30_000_000 else {
                throw StoreError(message:"Choose a regular CSV file no larger than 30 MB.")
            }
            let handle = try FileHandle(forReadingFrom:url)
            defer { try? handle.close() }
            // Bound the read as well as the initial size check in case the file grows.
            let data = try handle.read(upToCount:30_000_001) ?? Data()
            guard data.count <= 30_000_000, let decoded = String(data:data,encoding:.utf8) else {
                throw StoreError(message:"A CSV is too large or is not UTF-8 text.")
            }
            let parsed = try CourtedCSV.parse(decoded.hasPrefix("\u{feff}") ? String(decoded.dropFirst()) : decoded)
            guard let headers = parsed.first, !headers.isEmpty, headers.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }),
                  Set(headers).count == headers.count else { throw StoreError(message:"A CSV has missing or repeated column headers.") }
            let rows = try parsed.dropFirst().enumerated().map { index, row -> [String:String] in
                guard row.count == headers.count else { throw StoreError(message:"CSV row \(index + 2) has the wrong number of cells.") }
                return Dictionary(uniqueKeysWithValues:zip(headers,row))
            }
            total += rows.count
            guard total <= 25_000 else { throw StoreError(message:"Import at most 25,000 rows at once.") }
            result.append(GenericFile(name:url.lastPathComponent,headers:headers,rows:rows,digest:CourtedCSV.hash(data)))
        }
        return result
    }
    static func identityKeys(_ fields: [String:Any]) -> [String] {
        var keys: [String] = []
        let profile = (fields["courtedProfileURL"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        if !profile.isEmpty, let url = URLComponents(string:profile), url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "brokerage.courted.io", !url.path.isEmpty, url.path != "/" {
            keys.append("profile:" + (url.host! + url.path).lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"/")))
        }
        let mls = (fields["mls"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        let id = (fields["mlsId"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        if !mls.isEmpty && !id.isEmpty { keys.append("mls:" + norm(mls) + ":" + norm(id)) }
        return keys
    }
    static func identity(_ fields: [String:Any]) -> String? {
        identityKeys(fields).first
    }
    static func value(_ text: String, type: String, label: String) throws -> Any? {
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if type == "number" { return try CourtedCSV.number(trimmed,label:label) }
        if type == "date" {
            guard Store.parseDay(trimmed) != nil else { throw StoreError(message:"Invalid date in \(label).") }
            return trimmed
        }
        return text
    }
}

extension Store {
    func inspectGenericImport(_ payload: Record) throws -> Record {
        let files = try GenericCSV.files(payload)
        var headers: [String] = [], values: [String:[String]] = [:], filled: [String:Int] = [:]
        for file in files {
            for header in file.headers where !headers.contains(header) { headers.append(header) }
            for row in file.rows { for header in file.headers {
                let value = row[header] ?? ""
                values[header,default:[]].append(value)
                if !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { filled[header,default:0] += 1 }
            } }
        }
        let existingCustom = try all("customFields")
        let columns: [Record] = headers.map { header in
            var suggestion = GenericCSV.suggested(header)
            if suggestion == "custom:new",
               let field = existingCustom.first(where:{ GenericCSV.norm($0["label"] as? String ?? "") == GenericCSV.norm(header) }),
               let id = field["id"] as? String { suggestion = "custom:" + id }
            return ["header":header,"filled":filled[header] ?? 0,"inferredType":GenericCSV.inferred(values[header] ?? []),
             "suggestedTarget":suggestion,"suggestedLabel":header]
        }
        return ["rows":files.reduce(0){$0+$1.rows.count},"fileNames":files.map{$0.name},"columns":columns,
                "coreTargets":GenericCSV.coreTargets,"customFields":existingCustom]
    }

    private func genericPlan(_ payload: Record) throws -> GenericPlan {
        let files = try GenericCSV.files(payload)
        let headers = Set(files.flatMap{$0.headers})
        guard let mappings = payload["mappings"] as? [Record], mappings.count == headers.count else {
            throw StoreError(message:"Review a mapping for every CSV column.")
        }
        let existingCustom = try all("customFields")
        var byHeader: [String:Record] = [:], created: [Record] = []
        for mapping in mappings {
            guard let header = mapping["header"] as? String, headers.contains(header), byHeader[header] == nil,
                  let target = mapping["target"] as? String,
                  let label = mapping["label"] as? String, !label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  label.count <= 120, let type = mapping["type"] as? String,
                  ["text","number","date"].contains(type) else { throw StoreError(message:"A CSV mapping is incomplete or invalid.") }
            if target.hasPrefix("core:") {
                let key = String(target.dropFirst(5))
                guard GenericCSV.coreTargets.contains(key),
                      (GenericCSV.numericTargets.contains(key) ? type == "number" : type != "number") else {
                    throw StoreError(message:"A canonical field has the wrong type or is unavailable.")
                }
            } else if target == "custom:new" {
                let id = "custom-" + String(CourtedCSV.hash(Data(GenericCSV.norm(label).utf8)).prefix(20))
                let old = existingCustom.first(where:{$0["id"] as? String == id})
                let new = created.first(where:{$0["id"] as? String == id})
                guard (old == nil || old?["type"] as? String == type),
                      (new == nil || new?["type"] as? String == type) else {
                    throw StoreError(message:"That custom field has a different type.") }
                if old == nil && new == nil { created.append(["id":id,"label":label,"type":type,"private":GenericCSV.norm(header) == "agentshomeaddress","createdAt":Store.now()]) }
                var mapped = mapping; mapped["target"] = "custom:"+id; byHeader[header] = mapped
                continue
            } else if target.hasPrefix("custom:") {
                let id = String(target.dropFirst(7))
                guard existingCustom.contains(where:{$0["id"] as? String == id && $0["type"] as? String == type}) else {
                    throw StoreError(message:"A custom field is missing or has a different type.")
                }
            } else if target != "ignore" { throw StoreError(message:"Choose a supported field mapping.") }
            byHeader[header] = mapping
        }
        guard byHeader.count == headers.count else { throw StoreError(message:"Review every CSV column.") }
        for file in files {
            let mapped = file.headers.compactMap { byHeader[$0]?["target"] as? String }.filter { $0 != "ignore" }
            guard Set(mapped).count == mapped.count else {
                throw StoreError(message:"A CSV file maps two columns to the same field. Review \(file.name).")
            }
        }
        let canonicalMappings = mappings.map { byHeader[$0["header"] as! String]! }
        let mappingData = try JSONSerialization.data(withJSONObject:canonicalMappings.sorted { ($0["header"] as! String) < ($1["header"] as! String) },options:[.sortedKeys])
        let digest = CourtedCSV.hash(Data((files.map{$0.digest}.sorted().joined(separator:"|") + "|" + CourtedCSV.hash(mappingData)).utf8))
        let batchId = "generic-" + digest
        let existing = try all("agents")
        var existingByIdentity: [String:[Record]] = [:]
        for agent in existing {
            for key in GenericCSV.identityKeys(agent) { existingByIdentity[key,default:[]].append(agent) }
        }
        var agents: [Record] = [], hard: [String] = [], newCount = 0, updateCount = 0, possible = 0
        var seen = Set<String>()
        let importedAt = Store.now()
        for file in files { for (index,row) in file.rows.enumerated() {
            var core: Record = [:], custom: Record = [:]
            for header in file.headers {
                let mapping = byHeader[header]!, target = mapping["target"] as! String,
                    type = mapping["type"] as! String
                if target == "ignore" { continue }
                if let parsed = try GenericCSV.value(row[header] ?? "",type:type,label:header) {
                    if target.hasPrefix("core:") { core[String(target.dropFirst(5))] = parsed }
                    else { custom[String(target.dropFirst(7))] = parsed }
                } else if type == "number" {
                    // Blank numeric source data means unknown, including on a later export.
                    if target.hasPrefix("core:") { core[String(target.dropFirst(5))] = NSNull() }
                    else { custom[String(target.dropFirst(7))] = NSNull() }
                }
            }
            let first = core["firstName"] as? String ?? "", last = core["lastName"] as? String ?? ""
            if let profile = core["linkedinUrl"] as? String {
                core["linkedinUrl"] = try Store.linkedInProfileURL(profile)
            }
            let full = (core["name"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            let name = full.isEmpty ? "\(first) \(last)".trimmingCharacters(in:.whitespacesAndNewlines) : full
            if name.isEmpty { hard.append("\(file.name) row \(index + 2): missing name"); continue }
            core["name"] = name
            let identityKeys = GenericCSV.identityKeys(core)
            guard let identity = identityKeys.first else {
                hard.append("\(file.name) row \(index + 2): missing Courted profile or MLS identity"); continue
            }
            if identityKeys.contains(where:{seen.contains($0)}) {
                hard.append("\(file.name) row \(index + 2): identity repeats in selected files"); continue
            }
            identityKeys.forEach { seen.insert($0) }
            let matches = Array(Dictionary(grouping:identityKeys.flatMap{existingByIdentity[$0] ?? []},by:{$0["id"] as? String ?? ""}).values.compactMap{$0.first})
            if matches.count > 1 { hard.append("\(file.name) row \(index + 2): multiple existing identity matches"); continue }
            if let match = matches.first, match["datasetId"] as? String == "sample" {
                hard.append("\(file.name) row \(index + 2): identity collides with sample data"); continue
            }
            let id = matches.first?["id"] as? String ?? "import-" + String(CourtedCSV.hash(Data(identity.utf8)).prefix(32))
            if matches.isEmpty && existing.contains(where:{$0["id"] as? String == id}) {
                hard.append("\(file.name) row \(index + 2): generated ID already exists"); continue
            }
            let raw: Record = row
            var agent = try matches.first ?? ["id":id,"name":name,"office":"","city":"","email":"","phone":"",
                "source":"CSV import","datasetId":"live","manual":false,"status":"Identified",
                "assignee":try operatorName(),"liked":false,"disposition":"","createdAt":importedAt,
                "history":[],"transactions":[],"signals":[]]
            if matches.isEmpty, let sourceStatus = core["sourceStatus"] as? String,
               stages.contains(sourceStatus) { agent["status"] = sourceStatus }
            let prior = agent["importedCoreValues"] as? Record ?? [:]
            let localOverrides = Set(agent["localOverrides"] as? [String] ?? [])
            var managed: Record = prior
            for (key,value) in core {
                if key == "firstName" || key == "lastName" || key == "courtedProfileURL" || key == "mls" || key == "mlsId" { agent[key] = value; managed[key] = value; continue }
                if key == "move", let move = value as? String { let norm = move.capitalized; coreValue(&agent,key:key,value:norm,prior:prior,managed:&managed,localOverrides:localOverrides); continue }
                if GenericCSV.sourceOnly.contains(key) { agent[key] = value; managed[key] = value; continue }
                coreValue(&agent,key:key,value:value,prior:prior,managed:&managed,localOverrides:localOverrides)
            }
            if let source = core["courtedProfileURL"] as? String { agent["courtedProfileURL"] = source }
            agent["courtedFields"] = raw
            var customValues = agent["customValues"] as? Record ?? [:]
            for (key,value) in custom { customValues[key] = value }
            agent["customValues"] = customValues
            agent["importedCoreValues"] = managed
            agent["sourceBatchId"] = batchId
            agent["sourceFileName"] = file.name
            agent["sourceMetricCutoff"] = "unknown"
            if agent["importedAt"] == nil { agent["importedAt"] = importedAt }
            agent["lastImportedAt"] = importedAt
            agent["identityReviewState"] = "unreviewed"
            agent["datasetId"] = "live"
            if matches.isEmpty {
                newCount += 1
                let comparisons = existing + agents
                for key in ["email","phone"] {
                    let value = (agent[key] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                    if !value.isEmpty && comparisons.contains(where:{($0[key] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased() == value}) { possible += 1; break }
                }
            } else { updateCount += 1 }
            agents.append(agent)
        } }
        let workspaceData = try JSONSerialization.data(withJSONObject:existing,options:[.sortedKeys])
        let customsData = try JSONSerialization.data(withJSONObject:existingCustom,options:[.sortedKeys])
        let token = CourtedCSV.hash(Data("\(digest)|\(CourtedCSV.hash(workspaceData))|\(CourtedCSV.hash(customsData))".utf8))
        let imported = try all("importBatches").contains { $0["id"] as? String == batchId }
        return GenericPlan(files:files,mappings:canonicalMappings,agents:agents,customFields:created,digest:digest,
            token:token,newCount:newCount,updateCount:updateCount,hardConflicts:hard,possibleMatches:possible,
            alreadyImported:imported,existingCount:existing.count)
    }

    private func coreValue(_ agent: inout Record, key: String, value: Any, prior: Record, managed: inout Record,
                           localOverrides: Set<String>) {
        let current = agent[key]
        let previous = prior[key]
        let empty = (current as? String)?.isEmpty == true
        let unchanged = !localOverrides.contains(key) && (current == nil || empty ||
            (previous != nil && String(describing:current!) == String(describing:previous!)))
        if unchanged { agent[key] = value }
        managed[key] = value
    }

    func previewGenericImport(_ payload: Record) throws -> Record {
        let plan = try genericPlan(payload)
        let emailReview = plan.agents.compactMap { agent -> String? in
            let review = Store.emailCompanyReview(agent)
            guard ["needs_review", "unverified"].contains(review["state"] as? String ?? ""),
                  !(review["emailDomain"] as? String ?? "").isEmpty else { return nil }
            return "\(agent["name"] as? String ?? "Agent"): \(review["emailDomain"] as? String ?? "") vs \(review["company"] as? String ?? "")"
        }
        return ["token":plan.token,"rows":plan.files.reduce(0){$0+$1.rows.count},
                "newAgents":plan.alreadyImported ? 0 : plan.newCount,
                "updateAgents":plan.alreadyImported ? 0 : plan.updateCount,
                "hardConflicts":plan.hardConflicts.count,"conflictDetails":Array(plan.hardConflicts.prefix(20)),
                "possibleMatches":plan.possibleMatches,"emailCompanyReviewCount":emailReview.count,
                "emailCompanyReviewDetails":Array(emailReview.prefix(20)),"customFieldsToCreate":plan.customFields,
                "alreadyImported":plan.alreadyImported,"fileNames":plan.files.map{$0.name}]
    }

    func commitGenericImport(_ payload: Record) throws -> Record {
        let plan = try genericPlan(payload)
        guard let token = payload["token"] as? String, token == plan.token else {
            throw StoreError(message:"The CSVs, mappings, or workspace changed. Review the import again.")
        }
        let batchId = "generic-" + plan.digest
        if plan.alreadyImported { return ["alreadyImported":true,"batchId":batchId,"rows":plan.files.reduce(0){$0+$1.rows.count}] }
        guard plan.hardConflicts.isEmpty else { throw StoreError(message:"Resolve identity and row conflicts before importing.") }
        let backup = try consistentBackup(label:"before-generic-import")
        let importedAt = Store.now()
        try transaction {
            // Recheck under the write lock: a second app or local worker may have
            // committed an edit while the consistent backup was being created.
            let lockedPlan = try genericPlan(payload)
            guard lockedPlan.token == token, !lockedPlan.alreadyImported else {
                throw StoreError(message:"The workspace changed during backup. Review the import again.")
            }
            for field in plan.customFields { try put("customFields",field) }
            for agent in plan.agents { try put("agents",agent) }
            try put("importBatches",["id":batchId,"source":"CSV import","fileNames":plan.files.map{$0.name},
                "fileDigest":plan.digest,"rows":plan.agents.count,"newAgents":plan.newCount,
                "updateAgents":plan.updateCount,"createdCustomFieldIds":plan.customFields.compactMap{$0["id"] as? String},
                "backupPath":backup,"importedAt":importedAt,"schemaVersion":1])
            guard try all("agents").count == plan.existingCount + plan.newCount else {
                throw StoreError(message:"Import counts did not reconcile.")
            }
        }
        guard try all("importBatches").contains(where:{$0["id"] as? String == batchId}),
              try all("agents").count == plan.existingCount + plan.newCount else {
            throw StoreError(message:"Import readback failed. The pre-import backup is retained.")
        }
        return ["batchId":batchId,"rows":plan.agents.count,"newAgents":plan.newCount,
                "updateAgents":plan.updateCount,"backupPath":backup,"agentCount":plan.existingCount+plan.newCount]
    }

    func reconcileImportedMove() throws -> Record {
        let candidates = try all("agents").filter { agent in
            guard agent["datasetId"] as? String == "live", agent["source"] as? String == "CSV import",
                  agent["move"] as? String == "Unknown",
                  let desired = (agent["importedCoreValues"] as? Record)?["move"] as? String,
                  ["High","Moderate","Low"].contains(desired),
                  let source = (agent["courtedFields"] as? Record)?["Potential to Move"] as? String,
                  source.trimmingCharacters(in:.whitespacesAndNewlines).capitalized == desired else { return false }
            return !(agent["localOverrides"] as? [String] ?? []).contains("move")
        }
        guard !candidates.isEmpty else { return ["updated":0,"backupPath":""] }
        let backup = try consistentBackup(label:"before-csv-move-repair")
        try transaction {
            for var agent in candidates {
                agent["move"] = (agent["importedCoreValues"] as! Record)["move"]
                try put("agents",agent)
            }
        }
        let saved = try all("agents")
        let savedByID = Dictionary(uniqueKeysWithValues:saved.compactMap { row -> (String,Record)? in
            guard let id = row["id"] as? String else { return nil }; return (id,row)
        })
        guard candidates.allSatisfy({ candidate in
            guard let id = candidate["id"] as? String else { return false }
            return savedByID[id]?["move"] as? String == (candidate["importedCoreValues"] as? Record)?["move"] as? String
        }) else { throw StoreError(message:"Imported move values did not read back; the pre-repair backup is retained.") }
        return ["updated":candidates.count,"backupPath":backup]
    }
}
