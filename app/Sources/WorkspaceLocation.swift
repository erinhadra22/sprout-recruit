import Foundation

// Fresh installations use stable per-user storage. Existing development workspaces
// retain their exact path; relocation/migration must never silently create an empty CRM.
enum WorkspaceLocation {
    static func resolve(explicitPath: String?, bundleURL: URL, supportURL: URL, savedLegacyPath: String?) throws -> String {
        let fm = FileManager.default
        if let path = explicitPath, !path.isEmpty { return URL(fileURLWithPath:path).standardizedFileURL.path }
        if let path = savedLegacyPath, !path.isEmpty {
            guard fm.fileExists(atPath:path) else { throw StoreError(message:"The existing workspace could not be found at \(path). Restore that folder before opening Sprout; no new empty database was created.") }
            return path
        }
        let existing = bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("Data/SproutRecruit.sqlite")
        if fm.fileExists(atPath:existing.path) { return existing.path }
        return supportURL.appendingPathComponent("SproutRecruit.sqlite").path
    }
}
