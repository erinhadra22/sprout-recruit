import Foundation

// Fresh installations use stable per-user storage. Existing development workspaces
// retain their exact path; relocation/migration must never silently create an empty CRM.
enum WorkspaceLocation {
    // Resolve the known workspace even between restore renames. Actual recovery
    // and database validation happen under WorkspaceLease before Store opens.
    private static func hasPendingRecovery(_ path: String) -> Bool {
        let database = URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        let parent = database.deletingLastPathComponent(), container = database.deletingLastPathComponent().deletingLastPathComponent()
        let journal = WorkspaceRecovery.journal(database.path)
        do {
            try WorkspaceRecovery.safeDirectory(journal.deletingLastPathComponent())
            try WorkspaceRecovery.regular(journal)
            let size = try WorkspaceRecovery.status(journal).st_size
            guard size > 0 && size < 16384 else { return false }
            let handle = try FileHandle(forReadingFrom:journal);defer { try? handle.close() }
            let data = try handle.read(upToCount:16384) ?? Data()
            guard data.count < 16384,
                  let record = try JSONSerialization.jsonObject(with:data) as? Record,
                  let previous = record["previous"] as? String, let staged = record["staged"] as? String else { return false }
            let old = URL(fileURLWithPath:previous).standardizedFileURL,
                stage = URL(fileURLWithPath:staged).standardizedFileURL
            guard old.deletingLastPathComponent() == container,
                  stage.deletingLastPathComponent() == container,
                  old != parent, stage != parent, old != stage,
                  old.lastPathComponent.hasPrefix(".sprout-before-"),
                  stage.lastPathComponent.hasPrefix(".sprout-restore-") else { return false }
            try WorkspaceRecovery.safeDirectory(old)
            try WorkspaceRecovery.regular(old.appendingPathComponent(database.lastPathComponent))
            return true
        } catch { return false }
    }
    static func resolve(explicitPath: String?, bundleURL: URL, supportURL: URL, savedLegacyPath: String?) throws -> String {
        let fm = FileManager.default
        if let path = explicitPath, !path.isEmpty { return URL(fileURLWithPath:path).standardizedFileURL.path }
        if let path = savedLegacyPath, !path.isEmpty {
            guard fm.fileExists(atPath:path) || hasPendingRecovery(path) else { throw StoreError(message:"The existing workspace could not be found at \(path). Restore that folder before opening Sprout; no new empty database was created.") }
            return path
        }
        let existing = bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("Data/SproutRecruit.sqlite")
        if fm.fileExists(atPath:existing.path) { return existing.path }
        return supportURL.appendingPathComponent("SproutRecruit.sqlite").path
    }
}
