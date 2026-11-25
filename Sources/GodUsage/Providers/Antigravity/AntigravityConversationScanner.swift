import Foundation

/// Builds daily token/cost estimates for Antigravity from its local conversation databases
/// (`~/.gemini/antigravity/conversations/<id>.db`, one SQLite file per conversation). Each
/// `gen_metadata` row is one model generation with its token counts; see
/// `AntigravityGenerationParser` for the layout.
///
/// An actor so the per-database parse cache lives across refreshes off the main actor. A database
/// is re-read only when the size or modification time of the `.db` file or its `-wal` sidecar
/// changes (Antigravity writes through the WAL, so the main file alone can look unchanged). The
/// databases are opened read-only through the `sqlite3` CLI. A database that cannot be read is
/// logged and skipped; the others still count.
actor AntigravityConversationScanner {
    private struct Fingerprint: Equatable {
        var size: Int
        var mtime: Date
        var walSize: Int
        var walMtime: Date?

        var lastModified: Date { max(mtime, walMtime ?? .distantPast) }
    }

    private let sqlite: SQLiteAccessing
    private let conversationsDirectory: @Sendable () -> URL
    private let readFailureReporter: UsageLogReadFailureReporter
    private var cache: [String: (fingerprint: Fingerprint, parse: AntigravityDatabaseParse)] = [:]
    private(set) var databaseReadsForTesting = 0

    static let logTag = LogTag.plugin("antigravity")

    static let defaultConversationsDirectory: @Sendable () -> URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
    }

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        conversationsDirectory: @escaping @Sendable () -> URL = AntigravityConversationScanner.defaultConversationsDirectory
    ) {
        self.sqlite = sqlite
        self.conversationsDirectory = conversationsDirectory
        self.readFailureReporter = UsageLogReadFailureReporter(logTag: Self.logTag)
    }

    /// Scan the last `daysBack` days. Returns `nil` when there is no conversations directory, no
    /// database in it, or no database could be read, so the spend tiles read "No data".
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let databases = discoverDatabases()
        guard !databases.isEmpty else {
            cache.removeAll()
            return nil
        }

        var parses: [AntigravityDatabaseParse] = []
        var checked: Set<String> = []
        var failures: [String: String] = [:]
        var live: Set<String> = []
        for (path, fingerprint) in databases {
            if Task.isCancelled { return nil }
            live.insert(path)
            // A conversation untouched since before the window cannot hold a generation inside it.
            guard fingerprint.lastModified >= since else { continue }
            if let cached = cache[path], cached.fingerprint == fingerprint {
                parses.append(cached.parse)
                continue
            }
            checked.insert(path)
            do {
                let parse = try readDatabase(path: path)
                databaseReadsForTesting += 1
                Self.logDroppedRows(parse, file: (path as NSString).lastPathComponent)
                cache[path] = (fingerprint, parse)
                parses.append(parse)
            } catch {
                cache[path] = nil
                failures[path] = error.localizedDescription
            }
        }
        cache = cache.filter { live.contains($0.key) }

        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.error(Self.logTag, "conversation database unreadable, skipped: \((path as NSString).lastPathComponent): \(failures[path] ?? "unknown error")")
        }
        if parses.isEmpty, !failures.isEmpty { return nil }
        return Self.aggregate(parses, since: since, pricing: pricing)
    }

    // MARK: - Reading

    /// Every `*.db` in the conversations directory with its change fingerprint. Empty when the
    /// directory is missing.
    private func discoverDatabases() -> [(String, Fingerprint)] {
        let directory = conversationsDirectory()
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [(String, Fingerprint)] = []
        for name in names.sorted() where name.hasSuffix(".db") {
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let mtime = attributes[.modificationDate] as? Date
            else { continue }
            let wal = try? fileManager.attributesOfItem(atPath: path + "-wal")
            result.append((path, Fingerprint(
                size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                mtime: mtime,
                walSize: (wal?[.size] as? NSNumber)?.intValue ?? 0,
                walMtime: wal?[.modificationDate] as? Date
            )))
        }
        return result
    }

    /// Logged once per database change (the parse is cached until then), so a format change that
    /// drops rows is never silent. A database with rows but nothing countable is an error: its
    /// usage is missing from the tiles.
    static func logDroppedRows(_ parse: AntigravityDatabaseParse, file: String) {
        guard parse.droppedCount > 0 else { return }
        let detail = "\(parse.generationRowCount) generation row(s): \(parse.undecodableCount) undecodable, "
            + "\(parse.withoutUsageCount) without usage stats, \(parse.undatedCount) without a step time"
        if parse.countedNothing {
            AppLog.error(logTag, "no countable generations in \(file) (\(detail)); the conversation format may have changed")
        } else {
            AppLog.warn(logTag, "some generations in \(file) were left out of the spend tiles (\(detail))")
        }
    }

    static let rowsSQL = """
        SELECT 'g' AS k, idx AS i, hex(data) AS h FROM gen_metadata
        UNION ALL
        SELECT 's', idx, hex(metadata) FROM steps WHERE metadata IS NOT NULL;
        """

    private struct RawRow: Decodable {
        var k: String
        var i: Int
        var h: String
    }

    private func readDatabase(path: String) throws -> AntigravityDatabaseParse {
        guard let json = try sqlite.queryJSONRows(path: path, sql: Self.rowsSQL) else {
            return AntigravityDatabaseParse(generations: [], modelNames: [:], undatedCount: 0)
        }
        let raw = try JSONDecoder().decode([RawRow].self, from: Data(json.utf8))
        // Bad hex reaches the parser as an empty blob, so a generation row is counted as undecodable
        // rather than vanishing; a step without a decodable time leaves its generation undated.
        let rows = raw.map { row in
            AntigravityGenerationParser.Row(
                kind: row.k == "g" ? .generation : .step,
                index: row.i,
                data: Self.data(fromHex: row.h) ?? Self.undecodableBlob
            )
        }
        return AntigravityGenerationParser.parseDatabase(rows)
    }

    /// A truncated varint: never valid protobuf.
    static let undecodableBlob = Data([0x80])

    static func data(fromHex hex: String) -> Data? {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }

    // MARK: - Aggregation

    /// Model enum → name pairs observed on this Mac's Antigravity build. Used only for enums whose name
    /// no request config in the scanned databases carries; observed pairs always win.
    static let knownModelNames: [Int: String] = [
        1026: "claude-opus-4-6-thinking",
        1071: "gemini-3.6-flash-high",
        1132: "gemini-3-flash-agent",
        1133: "gemini-3-flash-agent",
        1264: "gemini-3.6-flash-high",
        1319: "gemini-3.8-flash-medium",
        1530: "gemini-4-hydrogen-tiered-high",
        1533: "gemini-4-neon-medium"
    ]

    /// The name shown for an enum no source can name. It never prices, so it surfaces in the
    /// unknown-model warning instead of being dropped.
    static func unnamedModel(_ enumValue: Int?) -> String {
        enumValue.map { "antigravity-model-\($0)" } ?? "antigravity-unknown-model"
    }

    /// Bucket generations into local days and price them. A generation copied into two databases
    /// (same response id) counts once. Unpriced models keep their tokens out of every total and
    /// appear in the warning triangle, like the other spend sources.
    static func aggregate(_ parses: [AntigravityDatabaseParse], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var names = knownModelNames
        for parse in parses {
            names.merge(parse.modelNames) { _, observed in observed }
        }
        var accumulator = DailyUsageAccumulator()
        var dayKeys = DailyUsageAccumulator.DayKeyCache()
        var seen: Set<String> = []
        var rates: [String: ModelRates?] = [:]
        for parse in parses {
            for generation in parse.generations where generation.timestamp >= since {
                if let id = generation.responseID, !seen.insert(id).inserted { continue }
                let model = generation.modelName
                    ?? generation.modelEnum.flatMap { names[$0] }
                    ?? unnamedModel(generation.modelEnum)
                let tokens = generation.tokens
                guard tokens.totalTokens > 0 else { continue }
                let day = dayKeys.key(for: generation.timestamp)
                let modelRates: ModelRates?
                if let cached = rates[model] {
                    modelRates = cached
                } else {
                    modelRates = AntigravityUsagePricing.rates(for: model, pricing: pricing)
                    rates[model] = modelRates
                }
                if let modelRates {
                    accumulator.add(day: day, tokens: tokens.totalTokens, cost: modelRates.costDollars(for: tokens), model: model)
                } else {
                    accumulator.addUnknownModel(day: day, model: model)
                }
            }
        }
        return accumulator.build()
    }
}

/// Antigravity bills at Google's API list price. Its model names are the same slugs Cursor uses, so
/// they share the supplement's alias rules, but for Gemini an exact public-catalog entry (Google's
/// list price) wins over a supplement rate taken from Cursor's table. Models no catalog carries
/// (Gemini 4) come from the supplement.
enum AntigravityUsagePricing {
    static func rates(for model: String, pricing: ModelPricing) -> ModelRates? {
        let canonical = pricing.supplement.canonicalName(for: model) ?? model
        if canonical.hasPrefix("gemini-"), let listed = pricing.primary.findExact(canonical) {
            return listed.rates
        }
        return pricing.resolve(model: model)
    }
}
