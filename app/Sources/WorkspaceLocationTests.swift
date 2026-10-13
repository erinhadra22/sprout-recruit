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
    print("Workspace location tests passed")
}
