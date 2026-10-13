import Foundation

func runOnboardingTests() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-onboarding-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store(path: dir.appendingPathComponent("test.sqlite").path)
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message: "Onboarding test failed: " + message) }
    }
    let fresh = try store.get("settings", "workspace")
    try check(fresh["name"] as? String == "" && fresh["onboardingRequired"] as? Bool == true, "fresh workspace has no inherited operator identity")
    try check(try store.all("agents").isEmpty, "fresh workspace is empty")
    let profile: Record = ["name":"  Fixture Recruiter  ", "company":"Sprout Realty", "role":"Recruiter", "timezone":"America/Chicago"]
    _ = try store.command("onboarding.save", profile)
    let saved = try store.get("settings", "workspace")
    try check(saved["name"] as? String == "Fixture Recruiter" && saved["onboardingRequired"] as? Bool == false, "setup is validated and persisted")
    try check(try store.operatorName() == "Fixture Recruiter", "new activity attribution uses profile")
    _ = try store.command("settings.save", ["instructions":"Keep it brief."])
    let unchanged = try store.get("settings", "workspace")
    try check(unchanged["name"] as? String == "Fixture Recruiter" && unchanged["timezone"] as? String == "America/Chicago", "unrelated preference edit preserves identity and zone")
    for invalid: Record in [["name":" "], ["timezone":"Mars/Olympus"], ["name":42], ["company":"A\nB"], ["onboardingRequired":false], ["columns":["name","name"]]] {
        do {
            _ = try store.command("settings.save", invalid)
            throw NSError(domain: "ExpectedValidationFailure", code: 1)
        } catch is StoreError { }
    }
    let reopened = try Store(path: store.path)
    try check(try reopened.operatorName() == "Fixture Recruiter", "identity survives reopening")
    var legacy = try store.get("settings", "workspace")
    legacy.removeValue(forKey: "onboardingRequired")
    legacy["legacyPreference"] = "keep"
    try store.put("settings", legacy)
    _ = try store.command("settings.save", ["role":"Team recruiter"])
    let preserved = try store.get("settings", "workspace")
    try check(preserved["legacyPreference"] as? String == "keep" && preserved["name"] as? String == "Fixture Recruiter", "existing identity and legacy preferences are retained")
    print("Onboarding tests passed")
}
