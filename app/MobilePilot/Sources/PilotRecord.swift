import Foundation
import CoreFoundation

enum PilotValidation {
    // This bounded pilot permits explicit US-format test numbers only.
    static func phone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\+1[2-9][0-9]{2}[2-9][0-9]{6}$"#, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    // A local expiry guard, not signature verification. Telnyx authenticates the JWT.
    static func tokenExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = claims["exp"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID() else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }

    static func usableToken(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = tokenExpiry(token) else { return false }
        return expiry.timeIntervalSince(now) > 30
    }
}

struct PilotEvent: Codable {
    let at: Date
    let state: String
}

struct PilotCallRecord: Codable, Identifiable {
    let id: UUID
    let from: String
    let to: String
    let requestedAt: Date
    var connectedAt: Date?
    var endedAt: Date?
    var recoveryObservedAt: Date?
    var outcome = "requested"
    var telnyxSessionID: String?
    var telnyxLegID: String?
    var telnyxCallControlID: String?
    var operatorConfirmedTestConsent: Bool?
    var providerRecording = "unverified"
    var events: [PilotEvent] = []

    mutating func append(_ state: String, at date: Date = Date()) {
        events.append(PilotEvent(at: date, state: state))
    }
}

final class PilotJournal {
    let url: URL
    private(set) var records: [PilotCallRecord]

    init(url: URL) throws {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = FileManager.default.fileExists(atPath: url.path)
            ? try decoder.decode([PilotCallRecord].self, from: Data(contentsOf: url)) : []
        // A restarted app cannot prove how a previous call ended.
        for index in records.indices where records[index].endedAt == nil && records[index].outcome != "interrupted-unverified" {
            records[index].outcome = "interrupted-unverified"
            records[index].recoveryObservedAt = Date()
            records[index].append("App restarted; remote call outcome requires reconciliation")
        }
    }

    func save(_ record: PilotCallRecord) throws {
        var next = records
        if let index = next.firstIndex(where: { $0.id == record.id }) { next[index] = record }
        else { next.append(record) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var localURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localURL.setResourceValues(values)
        #else
        try data.write(to: url, options: .atomic)
        #endif
        records = next
    }

    static func export(_ record: PilotCallRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }
}
