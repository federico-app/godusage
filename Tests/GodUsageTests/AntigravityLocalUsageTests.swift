import XCTest
@testable import GodUsage

extension AntigravityConversationScanner {
    /// A scanner pointed at a directory that never exists, so provider tests never read the real
    /// `~/.gemini/antigravity/conversations` of the machine running them.
    static let emptyForTesting = AntigravityConversationScanner(
        sqlite: AntigravityFakeSQLite(results: [:]),
        conversationsDirectory: { URL(fileURLWithPath: "/nonexistent/godusage-antigravity-tests") }
    )
}

/// Encodes protobuf wire-format fixtures, so tests never need real Antigravity databases.
enum ProtoFixture {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func field(_ number: Int, varint value: UInt64) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(value)
    }

    static func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    static func field(_ number: Int, string: String) -> [UInt8] {
        field(number, bytes: Array(string.utf8))
    }

    /// A `gen_metadata.data` blob in Antigravity's layout.
    static func generation(
        modelEnum: UInt64, input: UInt64, output: UInt64, cacheRead: UInt64 = 0,
        thinking: UInt64 = 0, response: UInt64? = nil, responseID: String? = nil,
        steps: [UInt64], configName: String? = nil
    ) -> Data {
        var usage = field(1, varint: modelEnum) + field(2, varint: input) + field(3, varint: output)
        if cacheRead > 0 { usage += field(5, varint: cacheRead) }
        usage += field(6, varint: 24)
        usage += field(8, bytes: field(1, string: "sessionID") + field(2, string: "-1"))
        if thinking > 0 { usage += field(9, varint: thinking) }
        usage += field(10, varint: response ?? (output - thinking))
        if let responseID { usage += field(11, string: responseID) }
        // Field 1 carries other metadata before the usage stats, and a duplicate under 17 → 2.
        let message1 = field(3, varint: modelEnum) + field(4, bytes: usage) + field(17, bytes: field(2, bytes: usage))
        var top = field(2, bytes: steps.flatMap { varint($0) }) + field(1, bytes: message1)
        if let configName {
            top += field(3, bytes: field(1, varint: modelEnum) + field(28, string: configName))
        }
        return Data(top)
    }

    /// A `steps.metadata` blob whose creation time is `date`.
    static func step(at date: Date) -> Data {
        let seconds = UInt64(date.timeIntervalSince1970)
        let timestamp = field(1, varint: seconds) + field(2, varint: 250_000_000)
        return Data(field(1, bytes: timestamp) + field(3, varint: 2) + field(4, string: "tool payload"))
    }
}

/// Serves canned `sqlite3 -json` output per database path; a path mapped to `nil` fails.
final class AntigravityFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: String?]
    private(set) var queries: [String] = []

    init(results: [String: String?]) {
        self.results = results
    }

    func set(_ path: String, _ json: String?) {
        lock.withLock { results[path] = json }
    }

    func queryValue(path: String, sql: String) throws -> String? { nil }

    func queryJSONRows(path: String, sql: String) throws -> String? {
        try lock.withLock {
            queries.append(path)
            guard let entry = results[path] else { return nil }
            guard let json = entry else { throw SQLiteError.queryFailed("database disk image is malformed") }
            return json
        }
    }

    static func json(generations: [(Int, Data)], steps: [(Int, Data)]) -> String {
        func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
        let rows = generations.map { #"{"k":"g","i":\#($0.0),"h":"\#(hex($0.1))"}"# }
            + steps.map { #"{"k":"s","i":\#($0.0),"h":"\#(hex($0.1))"}"# }
        return "[" + rows.joined(separator: ",") + "]"
    }
}

final class AntigravityLocalUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_615_908)  // 2026-11-25
    private var since: Date { JSONLScanning.sinceDate(daysBack: 30, now: now) }

    // MARK: - Protobuf reader

    func testReaderDecodesEveryWireTypeAndPackedVarints() throws {
        let bytes = ProtoFixture.field(1, varint: 300)
            + [0x11] + [1, 0, 0, 0, 0, 0, 0, 0]        // field 2, fixed64 = 1
            + ProtoFixture.field(3, bytes: [0xAC, 0x02, 0x05])
            + [0x25] + [7, 0, 0, 0]                    // field 4, fixed32 = 7
        let fields = try XCTUnwrap(ProtobufWireReader.fields(in: Data(bytes)))
        XCTAssertEqual(fields.varint(1), 300)
        XCTAssertEqual(fields.map(\.value)[1], .fixed64(1))
        XCTAssertEqual(fields.map(\.value)[3], .fixed32(7))
        XCTAssertEqual(fields.repeatedVarints(3), [300, 5])
    }

    func testReaderRejectsMalformedInputInsteadOfReturningAPartialMessage() {
        XCTAssertNil(ProtobufWireReader.fields(in: Data([0x08, 0x80])), "truncated varint")
        XCTAssertNil(ProtobufWireReader.fields(in: Data([0x0A, 0x05, 0x01])), "length past the end")
        XCTAssertNil(ProtobufWireReader.fields(in: Data([0x00, 0x01])), "field number 0")
        XCTAssertNil(ProtobufWireReader.fields(in: Data([0x0B])), "group wire type")
        XCTAssertEqual(ProtobufWireReader.fields(in: Data())?.count, 0)
    }

    // MARK: - Extraction

    func testGenerationExtractsUsageStepsAndConfigName() throws {
        let blob = ProtoFixture.generation(
            modelEnum: 1533, input: 10_854, output: 572, cacheRead: 18_226, thinking: 396,
            responseID: "resp-1", steps: [6, 7, 8], configName: "gemini-4-neon-medium"
        )
        let parsed = try XCTUnwrap(AntigravityGenerationParser.parseGeneration(blob))
        let generation = try XCTUnwrap(parsed.generation)
        XCTAssertEqual(parsed.stepIndices, [6, 7, 8])
        XCTAssertEqual(generation.modelEnum, 1533)
        XCTAssertEqual(generation.modelName, "gemini-4-neon-medium")
        XCTAssertEqual(generation.responseID, "resp-1")
        XCTAssertEqual(generation.input, 10_854)
        XCTAssertEqual(generation.cacheRead, 18_226)
        XCTAssertEqual(generation.output, 572, "output already includes thinking; it is not added again")
        XCTAssertEqual(parsed.namedModel?.name, "gemini-4-neon-medium")
    }

    func testResponseOnlyOutputStillCountsThinkingOnce() throws {
        let blob = ProtoFixture.generation(modelEnum: 1319, input: 10, output: 154, thinking: 49, response: 154, steps: [1])
        let generation = try XCTUnwrap(AntigravityGenerationParser.parseGeneration(blob)?.generation)
        XCTAssertEqual(generation.output, 203)
    }

    func testDatabaseParseDatesEachGenerationByItsEarliestLinkedStep() {
        let early = Date(timeIntervalSince1970: 1_795_600_000)
        let rows: [AntigravityGenerationParser.Row] = [
            .init(kind: .step, index: 1, data: ProtoFixture.step(at: early.addingTimeInterval(30))),
            .init(kind: .step, index: 2, data: ProtoFixture.step(at: early)),
            .init(kind: .generation, index: 0, data: ProtoFixture.generation(modelEnum: 1132, input: 5, output: 3, steps: [1, 2])),
            .init(kind: .generation, index: 1, data: ProtoFixture.generation(modelEnum: 1132, input: 5, output: 3, steps: [99])),
            .init(kind: .generation, index: 2, data: ProtoFixture.generation(
                modelEnum: 1264, input: 1, output: 1, steps: [1], configName: "gemini-3.6-flash-high"
            ))
        ]
        let parse = AntigravityGenerationParser.parseDatabase(rows)
        XCTAssertEqual(parse.generations.count, 2)
        XCTAssertEqual(parse.generations[0].timestamp.timeIntervalSince1970, early.timeIntervalSince1970 + 0.25, accuracy: 0.001)
        XCTAssertEqual(parse.undatedCount, 1, "a generation whose steps are missing is reported, not dated by guess")
        XCTAssertEqual(parse.modelNames, [1264: "gemini-3.6-flash-high"])
    }

    func testRowsLeftOutAreCountedAndAFormatChangeIsFlagged() {
        let step = AntigravityGenerationParser.Row(kind: .step, index: 1, data: ProtoFixture.step(at: now))
        let good = ProtoFixture.generation(modelEnum: 1533, input: 1, output: 1, steps: [1])
        // Usage moved away from field 1 → 4: valid protobuf, but no usage stats where expected.
        let moved = Data(ProtoFixture.field(2, bytes: [1]) + ProtoFixture.field(1, bytes: ProtoFixture.field(9, varint: 5)))
        let parse = AntigravityGenerationParser.parseDatabase([
            step,
            .init(kind: .generation, index: 0, data: good),
            .init(kind: .generation, index: 1, data: moved),
            .init(kind: .generation, index: 2, data: AntigravityConversationScanner.undecodableBlob),
            .init(kind: .generation, index: 3, data: ProtoFixture.generation(modelEnum: 1533, input: 1, output: 1, steps: [7]))
        ])
        XCTAssertEqual(parse.generationRowCount, 4)
        XCTAssertEqual(parse.generations.count, 1)
        XCTAssertEqual(parse.withoutUsageCount, 1)
        XCTAssertEqual(parse.undecodableCount, 1)
        XCTAssertEqual(parse.undatedCount, 1)
        XCTAssertEqual(parse.droppedCount, 3)
        XCTAssertFalse(parse.countedNothing)

        let allMoved = AntigravityGenerationParser.parseDatabase([step, .init(kind: .generation, index: 0, data: moved)])
        XCTAssertTrue(allMoved.countedNothing, "rows with nothing countable are an error, not a quiet $0")
    }

    func testBadHexFromSQLiteCountsAsUndecodable() async throws {
        let directory = try makeDirectory(["c.db"])
        let path = directory.appendingPathComponent("c.db").path
        let sqlite = AntigravityFakeSQLite(results: [path: #"[{"k":"g","i":0,"h":"ZZ"}]"#])
        let scanner = AntigravityConversationScanner(sqlite: sqlite, conversationsDirectory: { directory })
        let scan = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(scan?.series.daily.count, 0)
        XCTAssertNil(AntigravityConversationScanner.data(fromHex: "ZZ"))
        XCTAssertNil(ProtobufWireReader.fields(in: AntigravityConversationScanner.undecodableBlob))
    }

    // MARK: - Aggregation and pricing

    func testEnumNamesComeFromAnyDatabaseAndUnknownEnumsAreFlaggedNotDropped() throws {
        let day = now.addingTimeInterval(-60)
        let named = AntigravityDatabaseParse(
            generations: [generation(enum: 9001, name: "gemini-4-neon-medium", at: day)],
            modelNames: [9001: "gemini-4-neon-medium"], undatedCount: 0
        )
        let unnamed = AntigravityDatabaseParse(
            generations: [generation(enum: 9001, at: day), generation(enum: 4242, at: day)],
            modelNames: [:], undatedCount: 0
        )
        let scan = AntigravityConversationScanner.aggregate([named, unnamed], since: since, pricing: TestPricing.bundled)
        let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
        XCTAssertEqual(models.map(\.model), ["gemini-4-neon-medium"])
        XCTAssertEqual(models.first?.totalTokens, 2 * 2_100_000)
        XCTAssertEqual(scan.unknownModelsByDay.values.first, ["antigravity-model-4242"])
    }

    func testCostPricesInputCacheReadAndOutputSeparately() throws {
        // Gemini 4 Neon: $3 input, $0.15 cache read, $15 output per million.
        let parse = AntigravityDatabaseParse(
            generations: [generation(enum: 1533, name: "gemini-4-neon-medium", at: now.addingTimeInterval(-60))],
            modelNames: [:], undatedCount: 0
        )
        let scan = AntigravityConversationScanner.aggregate([parse], since: since, pricing: TestPricing.bundled)
        let entry = try XCTUnwrap(scan.series.daily.first)
        XCTAssertEqual(entry.totalTokens, 2_100_000)
        // 1M input $3 + 1M cache read $0.15 + 0.1M output $1.50.
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), 4.65, accuracy: 0.000_001)
    }

    func testDuplicateResponseIDsCountOnceAndOldGenerationsAreOutsideTheWindow() {
        var copy = generation(enum: 1533, name: "gemini-4-neon-medium", at: now.addingTimeInterval(-60))
        copy.responseID = "same"
        let old = generation(enum: 1533, name: "gemini-4-neon-medium", at: since.addingTimeInterval(-1))
        let parse = AntigravityDatabaseParse(generations: [copy, copy, old], modelNames: [:], undatedCount: 0)
        let scan = AntigravityConversationScanner.aggregate([parse], since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [2_100_000])
    }

    func testAntigravityModelNamesResolveToGoogleListPrices() throws {
        let pricing = TestPricing.bundled
        func rates(_ model: String) throws -> ModelRates {
            try XCTUnwrap(AntigravityUsagePricing.rates(for: model, pricing: pricing), model)
        }
        XCTAssertEqual(pricing.supplement.canonicalName(for: "gemini-4-neon-medium"), "gemini-4-neon")
        XCTAssertEqual(pricing.supplement.canonicalName(for: "gemini-4-hydrogen-tiered-high"), "gemini-4-hydrogen")
        XCTAssertEqual(pricing.supplement.canonicalName(for: "gemini-4-carbon-high"), "gemini-4-carbon")
        XCTAssertEqual(pricing.supplement.canonicalName(for: "gemini-4-argon-tiered-high"), "gemini-4-argon")
        XCTAssertEqual(pricing.supplement.canonicalName(for: "gemini-3-flash-agent"), "gemini-3-flash-preview")

        XCTAssertEqual(try rates("gemini-4-neon-medium").inputPerMillion, 3)
        XCTAssertEqual(try rates("gemini-4-neon-medium").outputPerMillion, 15)
        XCTAssertEqual(try rates("gemini-4-hydrogen-tiered-high").outputPerMillion, 7.5)
        XCTAssertEqual(try rates("gemini-4-carbon-medium").outputPerMillion, 10)
        XCTAssertEqual(try rates("gemini-4-argon-tiered-high").outputPerMillion, 10)
        // Google's list price ($3.75 output), not the Cursor-table supplement rate ($3.50).
        XCTAssertEqual(try rates("gemini-3.8-flash-medium").outputPerMillion, 3.75)
        XCTAssertEqual(try rates("gemini-3.6-flash-high").outputPerMillion, 3.75)
        XCTAssertEqual(try rates("gemini-3-flash-agent").outputPerMillion, 3)
        XCTAssertEqual(try rates("gemini-3.6-flash-high").cacheReadPerMillion, 0.075, accuracy: 0.000_001)
        // Claude models used inside Antigravity keep the shared Claude pricing.
        XCTAssertEqual(try rates("claude-opus-4-6-thinking"), try XCTUnwrap(pricing.resolve(model: "claude-opus-4-6")))
        XCTAssertNil(AntigravityUsagePricing.rates(for: "antigravity-model-4242", pricing: pricing))
    }

    func testCursorKeepsItsOwnGeminiFlashRate() throws {
        XCTAssertEqual(try XCTUnwrap(TestPricing.bundled.resolve(model: "gemini-3.8-flash-medium")).outputPerMillion, 3.5)
    }

    // MARK: - Scanner

    func testMissingDirectoryYieldsNoDataNotZero() async {
        let scan = await AntigravityConversationScanner.emptyForTesting.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertNil(scan)
    }

    func testUnreadableDatabaseIsSkippedAndUnchangedDatabasesAreNotReread() async throws {
        let directory = try makeDirectory(["good.db", "bad.db"])
        let good = directory.appendingPathComponent("good.db").path
        let bad = directory.appendingPathComponent("bad.db").path
        let stepTime = now.addingTimeInterval(-120)
        let sqlite = AntigravityFakeSQLite(results: [
            good: AntigravityFakeSQLite.json(
                generations: [(0, ProtoFixture.generation(modelEnum: 1533, input: 100, output: 50, steps: [1], configName: "gemini-4-neon-medium"))],
                steps: [(1, ProtoFixture.step(at: stepTime))]
            ),
            bad: String?.none
        ])
        let scanner = AntigravityConversationScanner(sqlite: sqlite, conversationsDirectory: { directory })

        let first = try await XCTUnwrapAsync(await scanner.scan(now: now, pricing: TestPricing.bundled))
        XCTAssertEqual(first.series.daily.map(\.totalTokens), [150])
        _ = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(sqlite.queries.filter { $0 == good }.count, 1, "an unchanged database is served from the cache")
        XCTAssertEqual(sqlite.queries.filter { $0 == bad }.count, 2, "a failed database is retried")

        // A write that lands only in the WAL sidecar still invalidates the cache.
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: good + "-wal"))
        _ = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(sqlite.queries.filter { $0 == good }.count, 2)
    }

    func testDatabasesUntouchedSinceBeforeTheWindowAreNotRead() async throws {
        let directory = try makeDirectory(["old.db"])
        let path = directory.appendingPathComponent("old.db").path
        try FileManager.default.setAttributes([.modificationDate: since.addingTimeInterval(-86_400)], ofItemAtPath: path)
        let sqlite = AntigravityFakeSQLite(results: [path: "[]"])
        let scanner = AntigravityConversationScanner(sqlite: sqlite, conversationsDirectory: { directory })
        let scan = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(scan?.series.daily.count, 0)
        XCTAssertTrue(sqlite.queries.isEmpty)
    }

    // MARK: - Provider

    @MainActor
    func testProviderDeclaresTrendAndSpendTilesAfterTheQuotaMeters() {
        let ids = AntigravityProvider(conversationScanner: .emptyForTesting).widgetDescriptors.map(\.id)
        XCTAssertEqual(Array(ids.suffix(4)), [
            "antigravity.trend", "antigravity.today", "antigravity.yesterday", "antigravity.last30"
        ])
        XCTAssertEqual(ids.count, 9)
    }

    // MARK: - Helpers

    private func generation(enum value: Int, name: String? = nil, at date: Date) -> AntigravityGeneration {
        AntigravityGeneration(
            timestamp: date, modelEnum: value, modelName: name, responseID: nil,
            input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 0, output: 100_000
        )
    }

    private func makeDirectory(_ files: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("godusage-antigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in files {
            try Data("db".utf8).write(to: directory.appendingPathComponent(name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
