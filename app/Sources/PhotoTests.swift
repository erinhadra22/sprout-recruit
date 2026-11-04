import Foundation

func runPhotoTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message:"Photo import test failed: \(message)") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-photo-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let path = root.appendingPathComponent("fixture.sqlite").path
    let profile = "https://www.linkedin.com/in/fixture-agent"
    let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+nFVQAAAAASUVORK5CYII="
    var agentID = ""
    do {
        let store = try Store(path:path,seed:true)
        let created = try store.command("agent.create",["name":"Fixture Agent","linkedinUrl":profile])
        agentID = (created["agents"] as? [Record])?.first(where: { $0["name"] as? String == "Fixture Agent" })?["id"] as? String ?? ""
        try check(!agentID.isEmpty,"contact exists")
        var request: Record = ["agentId":agentID,"sourceProfileUrl":profile,"sourceUrl":"https://media.licdn.com/fixture.png",
            "sourceActor":"fixture/actor","sourceRunId":"fixture-run","mimeType":"image/png","base64":encoded]
        _ = try store.command("agent.photo.import",request)
        let photo = try store.command("agent.photo.get",["agentId":agentID])
        try check(photo["dataUri"] as? String == "data:image/png;base64,"+encoded,"photo readback matches exact bytes")
        let snapshot = try store.snapshot()
        let agent = (snapshot["agents"] as? [Record])?.first(where: { $0["id"] as? String == agentID })
        try check(agent?["photoAvailable"] as? Bool == true,"small snapshot marks photo availability")
        try check(snapshot["agentPhotos"] == nil,"small snapshot excludes image bytes")
        try check((try store.snapshot(includePhotos:true))["agentPhotos"] as? [Record] != nil,"backup includes image bytes")
        let activityCount = try store.all("activities").count
        _ = try store.command("agent.photo.import",request)
        try check(try store.all("activities").count == activityCount,"exact replay is idempotent")
        request["sourceProfileUrl"] = "https://www.linkedin.com/in/another-agent"
        do { _ = try store.command("agent.photo.import",request); throw StoreError(message:"Mismatched identity accepted") }
        catch let error as StoreError { try check(error.message != "Mismatched identity accepted","identity mismatch rejected") }
    }
    let reopened = try Store(path:path,seed:false)
    try check((try reopened.command("agent.photo.get",["agentId":agentID]))["available"] as? Bool == true,
              "image persists after reopening")
}
