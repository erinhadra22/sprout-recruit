import Foundation
func runWorkspaceLocationTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-location-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let app = root.appendingPathComponent("dev/Sprout Recruit.app")
    let support = root.appendingPathComponent("support")
    let fresh = try WorkspaceLocation.resolve(explicitPath:nil,bundleURL:app,supportURL:support,savedLegacyPath:nil)
    guard fresh == support.appendingPathComponent("SproutRecruit.sqlite").path else { throw StoreError(message:"Fresh workspace must use Application Support") }
    let moved = try WorkspaceLocation.resolve(explicitPath:nil,bundleURL:root.appendingPathComponent("Applications/Sprout Recruit.app"),supportURL:support,savedLegacyPath:nil)
    guard fresh == moved else { throw StoreError(message:"Moving a new app must not change its database") }
    let legacy = root.appendingPathComponent("dev/Data/SproutRecruit.sqlite")
    try FileManager.default.createDirectory(at:legacy.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data().write(to:legacy)
    let retained = try WorkspaceLocation.resolve(explicitPath:nil,bundleURL:app,supportURL:support,savedLegacyPath:nil)
    guard retained == legacy.path else { throw StoreError(message:"Existing workspace lost") }
    let relocated = try WorkspaceLocation.resolve(explicitPath:nil,bundleURL:root.appendingPathComponent("Applications/Sprout Recruit.app"),supportURL:support,savedLegacyPath:retained)
    guard relocated == retained else { throw StoreError(message:"Existing workspace pointer lost") }
    do {
        _ = try WorkspaceLocation.resolve(explicitPath:nil,bundleURL:app,supportURL:support,savedLegacyPath:root.appendingPathComponent("missing.sqlite").path)
        throw StoreError(message:"Missing workspace silently replaced")
    } catch let error as StoreError {
        guard error.message.contains("no new empty database") else { throw error }
    }
    // Reproduce the real icon-launch order: locate saved legacy path, acquire
    // lease, recover journal, only then open Store. The original folder is absent.
    let recoveryContainer = root.resolvingSymlinksInPath().appendingPathComponent("interrupted")
    let recoveryParent = recoveryContainer.appendingPathComponent("Data")
    let recoveryDB = recoveryParent.appendingPathComponent("SproutRecruit.sqlite")
    do {
        let fixture = try Store(path:recoveryDB.path,seed:false)
        try fixture.put("settings",["id":"location-fixture","value":"preserve"])
    }
    let old = recoveryContainer.appendingPathComponent(".sprout-before-location-fixture")
    let staged = recoveryContainer.appendingPathComponent(".sprout-restore-location-fixture")
    let journal = WorkspaceRecovery.journal(recoveryDB.path)
    try WorkspaceRecovery.privateDirectory(journal.deletingLastPathComponent())
    try FileManager.default.moveItem(at:recoveryParent,to:old)
    try JSONSerialization.data(withJSONObject:["previous":old.path,"staged":staged.path]).write(to:journal)
    let recoverable = try WorkspaceLocation.resolve(explicitPath:nil,bundleURL:app,supportURL:support,savedLegacyPath:recoveryDB.path)
    guard recoverable == recoveryDB.path, !FileManager.default.fileExists(atPath:recoveryDB.path) else { throw StoreError(message:"Location resolution must not create a replacement database") }
    let lease = try WorkspaceLease(recoverable)
    try withExtendedLifetime(lease) {
        try WorkspaceRecovery.recoverInterrupted(recoverable)
        let reopened = try Store(path:recoverable,seed:false)
        guard try reopened.get("settings","location-fixture")["value"] as? String == "preserve" else { throw StoreError(message:"Journal recovery did not retain the original workspace") }
    }
    guard !FileManager.default.fileExists(atPath:journal.path) else { throw StoreError(message:"Completed recovery left its journal behind") }

    // Merely having a file named journal must never permit silent replacement.
    try FileManager.default.moveItem(at:recoveryParent,to:old)
    for payload in [Data("not JSON".utf8),try JSONSerialization.data(withJSONObject:["previous":root.appendingPathComponent("elsewhere/.sprout-before-wrong").path,"staged":staged.path])] {
        try payload.write(to:journal)
        var rejected=false
        do { _ = try WorkspaceLocation.resolve(explicitPath:nil,bundleURL:app,supportURL:support,savedLegacyPath:recoveryDB.path) } catch { rejected=true }
        guard rejected, !FileManager.default.fileExists(atPath:recoveryDB.path) else { throw StoreError(message:"Invalid recovery journal allowed a replacement workspace") }
    }
    print("Workspace location tests passed")
}
