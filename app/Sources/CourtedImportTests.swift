import Foundation

func runCourtedImportTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-courted-import-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let db = directory.appendingPathComponent("fixture.sqlite")
    let csv = directory.appendingPathComponent("courted.csv")
    let store = try Store(path:db.path,seedSamples:true)
    func check(_ condition: Bool,_ reason: String) throws {
        if !condition { throw StoreError(message:"Courted import test failed: "+reason) }
    }
    func escape(_ text: String) -> String { "\""+text.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
    var source: [String:String] = [
        "First Name":"Fixture", "Last Name":"Agent", "MLS Affiliation":"TEST-MLS",
        "MLS ID":"00042", "Courted Profile URL":"https://brokerage.courted.io/cts/candidates/fixture-agent",
        "Status":"Not interested", "Email":"fixture@example.invalid", "Phone":"+15125550123",
        "Units":"0", "Buy-side Units":"0.5", "License Number":"001234",
        "Agent's Home Address":"Private fixture address", "Note 1":"A note, with a comma\nand a second line"
    ]
    func write(_ rows: [[String:String]]) throws {
        let lines = [CourtedCSV.headers.map(escape).joined(separator:",")] + rows.map { row in
            CourtedCSV.headers.map { escape(row[$0] ?? "") }.joined(separator:",")
        }
        try Data((lines.joined(separator:"\r\n")+"\r\n").utf8).write(to:csv)
    }
    try write([source])
    let payload: Record = ["paths":[csv.path]]
    let preview = try store.previewCourtedImport(payload)
    try check(preview["rows"] as? Int == 1 && preview["newAgents"] as? Int == 1,"preview counts one new record")
    let result = try store.commitCourtedImport(["paths":[csv.path],"token":preview["token"]!])
    try check(result["newAgents"] as? Int == 1,"one record committed")
    let imported = try store.all("agents").filter { $0["datasetId"] as? String == "live" }
    try check(imported.count == 1,"sample and live records remain separate")
    let agent = imported[0], original = agent["courtedFields"] as? [String:String] ?? [:]
    try check(agent["status"] as? String == "Not interested","source exclusion status preserved")
    try check(agent["mlsId"] as? String == "00042" && agent["license"] as? String == "001234","identity text retains zeroes")
    try check(agent["units"] as? Double == 0 && agent["buySideUnits"] as? Double == 0.5,"zero and fractional units preserved")
    try check(agent["avgRentalPrice"] == nil && original["Note 1"] == source["Note 1"],"blank remains unknown and quoted note survives")
    try check(try store.all("importBatches").count == 1,"batch receipt saved")
    try check(FileManager.default.fileExists(atPath:result["backupPath"] as? String ?? ""),"consistent backup created")
    let replay = try store.previewCourtedImport(payload)
    try check(replay["alreadyImported"] as? Bool == true,"exact replay is detected")
    _ = try store.commitCourtedImport(["paths":[csv.path],"token":replay["token"]!])
    try check(try store.all("agents").count == 25 && store.all("importBatches").count == 1,"replay does not duplicate")
    source["Courted Profile URL"] = "https://brokerage.courted.io/cts/candidates/fixture-agent-2"
    try write([source,source])
    do {
        _ = try store.previewCourtedImport(payload)
        throw StoreError(message:"Expected duplicate source identity rejection")
    } catch let error as StoreError {
        try check(error.message != "Expected duplicate source identity rejection","duplicate identity is rejected")
    }
    try check(try store.all("agents").count == 25,"invalid batch caused no write")
    print("PASS: Courted CSV parse, source fields, unknown/zero, identity, preview, backup, atomic commit and replay.")
}
