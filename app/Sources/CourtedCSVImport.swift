import Foundation
import CryptoKit

struct CourtedImportPlan {
    let agents: [Record]
    let files: [String]
    let digest: String
    let token: String
    let existingCount: Int
    let conflicts: Int
    let possibleMatches: Int
    let alreadyImported: Bool

    var summary: Record {
        ["fileNames": files, "rows": agents.count, "newAgents": alreadyImported ? 0 : agents.count - conflicts,
         "conflicts": conflicts, "possibleMatches": possibleMatches, "alreadyImported": alreadyImported,
         "token": token, "batchId": "courted-\(digest)", "sourceDate": "unknown"]
    }
}

enum CourtedCSV {
    static let statuses: Set<String> = ["Identified", "Called", "Contacted", "Connected", "Meeting scheduled",
        "Meeting held", "Negotiating", "Contract out", "Recruited", "Lost", "Not interested",
        "Not qualified", "Do not contact"]
    static let headers = [
        "First Name", "Last Name", "Current Office", "Years in Industry", "LTM Sales Volume",
        "LTM Sales Volume % Growth", "Most Transacted City", "Most Recent Mutual Connection Closed Date",
        "Potential to Move", "Potential to Grow", "Buy-side sales volume", "List-side sales volume",
        "Approx. GCI", "Avg. Sales Price", "Units", "Buy-side Units", "List-side Units",
        "Closed Transactions", "Active Listings", "Pending Sales", "Closed Rentals", "Avg. Rental Price",
        "Office City", "Office Zip", "Brand", "MLS Affiliation", "Years in Office", "Avg. Time at Office",
        "Mutual Connections", "Last Viewed Date", "LTM Closed/List Price %", "LTM Avg Days on Market",
        "YTD Sales Volume", "YTD Units", "YTD Avg Sales Price", "Agent's MLS Home City",
        "Agent's MLS Home Zip", "MLS ID", "License Number", "Status", "Assigned To",
        "Most Recent Mutual Connection Agent Name", "Most Recent Mutual Connection Address",
        "Most Recent Mutual Connection Closed Price", "Email", "Phone", "Agent's Home Address",
        "Courted Profile URL", "Note 1", "Note 2", "Note 3"
    ]

    static func hash(_ data: Data) -> String {
        SHA256.hash(data:data).map { String(format:"%02x", $0) }.joined()
    }

    static func parse(_ input: String) throws -> [[String]] {
        let text = input.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        let scalars = Array(text.unicodeScalars)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, afterQuote = false, started = false
        var index = 0
        while index < scalars.count {
            let ch = scalars[index]
            if quoted {
                if ch == "\"" {
                    if index + 1 < scalars.count && scalars[index + 1] == "\"" {
                        field.unicodeScalars.append(ch); index += 1
                    } else { quoted = false; afterQuote = true }
                } else { field.unicodeScalars.append(ch) }
            } else if ch == "\"" {
                guard !started && !afterQuote else { throw StoreError(message:"Malformed quoted CSV field.") }
                quoted = true; started = true
            } else if ch == "," || ch == "\n" {
                row.append(field); field = ""; started = false; afterQuote = false
                if ch == "\n" { rows.append(row); row = [] }
            } else {
                guard !afterQuote else { throw StoreError(message:"Unexpected text after a quoted CSV field.") }
                field.unicodeScalars.append(ch); started = true
            }
            index += 1
        }
        guard !quoted else { throw StoreError(message:"An imported CSV has an unfinished quoted field.") }
        if started || afterQuote || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func number(_ text: String, label: String) throws -> Double? {
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.isEmpty { return nil }
        let clean = value.replacingOccurrences(of:",",with:"").replacingOccurrences(of:"$",with:"")
            .replacingOccurrences(of:"%",with:"")
        guard let number = Double(clean), number.isFinite else { throw StoreError(message:"Invalid numeric value in \(label).") }
        return number
    }

    static func agent(_ fields: [String:String], batchId: String, importedAt: String) throws -> Record {
        func value(_ key: String) -> String { fields[key] ?? "" }
        let profile = value("Courted Profile URL").trimmingCharacters(in:.whitespacesAndNewlines)
        guard let url = URL(string:profile), url.scheme == "https", url.host == "brokerage.courted.io",
              !url.path.isEmpty, !value("MLS Affiliation").isEmpty, !value("MLS ID").isEmpty else {
            throw StoreError(message:"A Courted profile or MLS identity is missing or invalid.")
        }
        let name = [value("First Name"),value("Last Name")].joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError(message:"An imported agent has no name.") }
        let status = value("Status")
        guard status.isEmpty || statuses.contains(status) else {
            throw StoreError(message:"An imported status is not supported by this app.")
        }
        var agent: Record = [
            "id":"courted-" + String(hash(Data(profile.utf8)).prefix(32)), "name":name,
            "office":value("Current Office"), "city":value("Most Transacted City"),
            "email":value("Email"), "phone":value("Phone"), "status":status,
            "source":"Courted CSV export", "datasetId":"live", "manual":false,
            "identityReviewState":"unreviewed", "sourceBatchId":batchId,
            "sourceExportDate":"unknown", "sourceMetricCutoff":"unknown",
            "importedAt":importedAt, "createdAt":importedAt, "liked":false, "disposition":"",
            "history":[], "transactions":[], "signals":[], "move":value("Potential to Move"),
            "growth":value("Potential to Grow"), "mls":value("MLS Affiliation"),
            "mlsId":value("MLS ID"), "license":value("License Number"),
            "brand":value("Brand"), "officeCity":value("Office City"), "officeZip":value("Office Zip"),
            "mlsHomeCity":value("Agent's MLS Home City"), "mlsHomeZip":value("Agent's MLS Home Zip"),
            "courtedProfileURL":profile, "courtedFields":fields,
            "sourceStatus":status, "sourceAssignee":value("Assigned To"),
            "sourceLastViewedDate":value("Last Viewed Date"),
            "homeAddress":value("Agent's Home Address")
        ]
        let numeric: [(String,String)] = [
            ("years","Years in Industry"), ("volume","LTM Sales Volume"),
            ("change","LTM Sales Volume % Growth"), ("buySideVolume","Buy-side sales volume"),
            ("listSideVolume","List-side sales volume"), ("approxGCI","Approx. GCI"),
            ("avgSalesPrice","Avg. Sales Price"), ("units","Units"),
            ("buySideUnits","Buy-side Units"), ("listSideUnits","List-side Units"),
            ("closedTransactions","Closed Transactions"), ("active","Active Listings"),
            ("pending","Pending Sales"), ("rentals","Closed Rentals"),
            ("avgRentalPrice","Avg. Rental Price"), ("officeYears","Years in Office"),
            ("avgTimeAtOffice","Avg. Time at Office"), ("mutualConnections","Mutual Connections"),
            ("closeRatio","LTM Closed/List Price %"), ("dom","LTM Avg Days on Market"),
            ("ytdVolume","YTD Sales Volume"), ("ytdUnits","YTD Units"),
            ("ytdAvgSalesPrice","YTD Avg Sales Price"),
            ("recentMutualClosePrice","Most Recent Mutual Connection Closed Price")
        ]
        for (key, header) in numeric { if let parsed = try number(value(header),label:header) { agent[key] = parsed } }
        agent["recentMutualCloseDate"] = value("Most Recent Mutual Connection Closed Date")
        agent["recentMutualAgentName"] = value("Most Recent Mutual Connection Agent Name")
        agent["recentMutualAddress"] = value("Most Recent Mutual Connection Address")
        return agent
    }
}

extension Store {
    func previewCourtedImport(_ payload: Record) throws -> Record { try courtedPlan(payload).summary }

    private func courtedPlan(_ payload: Record) throws -> CourtedImportPlan {
        guard let paths = payload["paths"] as? [String], !paths.isEmpty, paths.count <= 8 else {
            throw StoreError(message:"Choose one to eight Courted CSV files.")
        }
        var rows: [[String:String]] = [], files: [String] = [], hashes: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath:path)
            guard url.pathExtension.lowercased() == "csv" else { throw StoreError(message:"Choose CSV files only.") }
            let data = try Data(contentsOf:url)
            guard data.count <= 20_000_000, let text = String(data:data,encoding:.utf8) else {
                throw StoreError(message:"A CSV is too large or is not UTF-8 text.")
            }
            var parsed = try CourtedCSV.parse(text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text)
            guard !parsed.isEmpty, parsed.removeFirst() == CourtedCSV.headers else {
                throw StoreError(message:"The Courted CSV headers do not match the reviewed 51-column export.")
            }
            for row in parsed {
                guard row.count == CourtedCSV.headers.count else { throw StoreError(message:"A Courted CSV row has the wrong number of fields.") }
                rows.append(Dictionary(uniqueKeysWithValues:zip(CourtedCSV.headers,row)))
            }
            files.append(url.lastPathComponent); hashes.append(CourtedCSV.hash(data))
        }
        guard rows.count <= 25_000 else { throw StoreError(message:"Import at most 25,000 agents in one batch.") }
        let digest = CourtedCSV.hash(Data(hashes.sorted().joined(separator:"|").utf8))
        let batchId = "courted-" + digest
        let importedAt = Store.now()
        let agents = try rows.map { try CourtedCSV.agent($0,batchId:batchId,importedAt:importedAt) }
        let ids = agents.compactMap { $0["id"] as? String }
        guard Set(ids).count == ids.count else { throw StoreError(message:"The selected files repeat a Courted profile.") }
        let mlsKeys = agents.map { "\($0["mls"] as? String ?? "")|\($0["mlsId"] as? String ?? "")" }
        guard Set(mlsKeys).count == mlsKeys.count else { throw StoreError(message:"The selected files repeat an MLS affiliation and ID.") }
        let existing = try all("agents")
        let existingIDs = Set(existing.compactMap { $0["id"] as? String })
        let alreadyImported = try all("importBatches").contains { $0["id"] as? String == batchId }
        let conflicts = alreadyImported ? 0 : ids.filter { existingIDs.contains($0) }.count
        let allContacts = existing + agents
        let possibleMatches = ["email","phone"].reduce(0) { count, key in
            let values = allContacts.compactMap { ($0[key] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
            return count + values.count - Set(values).count
        }
        let fingerprint = CourtedCSV.hash(try JSONSerialization.data(withJSONObject:existing,options:[.sortedKeys]))
        let token = CourtedCSV.hash(Data("\(digest)|\(fingerprint)".utf8))
        return CourtedImportPlan(agents:agents,files:files,digest:digest,token:token,
            existingCount:existing.count,conflicts:conflicts,possibleMatches:possibleMatches,alreadyImported:alreadyImported)
    }

    func commitCourtedImport(_ payload: Record) throws -> Record {
        let plan = try courtedPlan(payload)
        guard let token = payload["token"] as? String, token == plan.token else {
            throw StoreError(message:"The files or workspace changed since preview. Review the import again.")
        }
        if plan.alreadyImported { return ["alreadyImported":true,"rows":plan.agents.count,"batchId":"courted-\(plan.digest)"] }
        guard plan.conflicts == 0 else { throw StoreError(message:"Existing Courted identities need review before this import.") }
        let backup = try consistentBackup(label:"before-courted-import")
        let batchId = "courted-" + plan.digest
        let importedAt = Store.now()
        try transaction {
            let lockedPlan = try courtedPlan(payload)
            guard lockedPlan.token == token, !lockedPlan.alreadyImported, lockedPlan.conflicts == 0 else {
                throw StoreError(message:"The workspace changed during backup. Review the import again.")
            }
            for var agent in plan.agents {
                let id = agent["id"] as! String
                agent["createdAt"] = importedAt; agent["importedAt"] = importedAt; agent["lastImportedAt"] = importedAt
                try put("agents",agent)
                try recordContactEvent(agentId: id, type: "contact.imported", source: "Courted CSV export",
                    sourceRecordId: agent["courtedProfileURL"] as? String ?? "", batchId: batchId,
                    fileNames: plan.files, occurredAt: importedAt, recordedAt: importedAt,
                    dedupeKey: "import:" + batchId)
            }
            try put("importBatches",["id":batchId,"source":"Courted CSV export","sourceDate":"unknown",
                "fileNames":plan.files,"fileDigest":plan.digest,"importedAt":importedAt,
                "rows":plan.agents.count,"newAgents":plan.agents.count,"backupPath":backup])
            guard try all("agents").count == plan.existingCount + plan.agents.count else {
                throw StoreError(message:"Import row counts did not reconcile.")
            }
        }
        guard try all("agents").count == plan.existingCount + plan.agents.count,
              try all("importBatches").contains(where:{ $0["id"] as? String == batchId }) else {
            throw StoreError(message:"Import readback failed. The consistent pre-import backup is retained.")
        }
        return ["rows":plan.agents.count,"newAgents":plan.agents.count,"batchId":batchId,
                "backupPath":backup,"agentCount":plan.existingCount + plan.agents.count]
    }
}
