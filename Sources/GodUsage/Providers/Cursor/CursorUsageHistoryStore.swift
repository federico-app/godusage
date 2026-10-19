import Foundation

/// One local calendar day of Cursor usage: token totals per raw model slug. Prices are applied when
/// the day is read, so a pricing update re-prices stored days too. `isComplete` is false for today
/// (the day is still running) and true once the day fully elapsed before it was fetched.
struct CursorUsageDay: Codable, Sendable, Equatable {
    var models: [String: TokenBreakdown]
    var isComplete: Bool

    mutating func add(_ tokens: TokenBreakdown, for model: String) {
        var existing = models[model] ?? TokenBreakdown()
        existing.input += tokens.input
        existing.cacheWrite5m += tokens.cacheWrite5m
        existing.cacheWrite1h += tokens.cacheWrite1h
        existing.cacheRead += tokens.cacheRead
        existing.output += tokens.output
        existing.isFast = existing.isFast || tokens.isFast
        models[model] = existing
    }
}

/// Stores fetched Cursor usage days on disk, one JSON file per Cursor user ID, so a short or slow
/// download never wipes days that were already fetched. Days are keyed by local `yyyy-MM-dd`, so the
/// file is ignored when the Mac's time zone changes (the day boundaries no longer line up).
struct CursorUsageHistoryStore: Sendable {
    private struct File: Codable {
        var schemaVersion: Int
        var userID: String
        var timeZone: String
        var days: [String: CursorUsageDay]
    }

    private static let schemaVersion = 1

    var directory: URL

    init(directory: URL = CursorUsageHistoryStore.defaultDirectory) {
        self.directory = directory
    }

    func load(userID: String, timeZone: String) -> [String: CursorUsageDay] {
        let url = fileURL(userID: userID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            guard file.schemaVersion == Self.schemaVersion,
                  file.userID == userID,
                  file.timeZone == timeZone
            else {
                return [:]
            }
            return file.days
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "usage history cache could not be read: \(error.localizedDescription)")
            return [:]
        }
    }

    func save(_ days: [String: CursorUsageDay], userID: String, timeZone: String) {
        let file = File(
            schemaVersion: Self.schemaVersion,
            userID: userID,
            timeZone: timeZone,
            days: days
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL(userID: userID), options: .atomic)
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "usage history cache could not be saved: \(error.localizedDescription)")
        }
    }

    private func fileURL(userID: String) -> URL {
        directory.appendingPathComponent("\(JSONLScanCachePaths.stableFingerprint(userID)).json")
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GodUsage/cursor-usage-history", isDirectory: true)
    }
}
