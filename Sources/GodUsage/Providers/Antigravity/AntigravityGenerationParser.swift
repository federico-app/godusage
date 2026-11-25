import Foundation

/// One model generation from an Antigravity conversation database, reduced to the numbers the spend
/// tiles need. Never carries prompt or response content.
struct AntigravityGeneration: Sendable, Equatable {
    var timestamp: Date
    /// `ModelUsageStats.model`, Antigravity's internal model enum.
    var modelEnum: Int?
    /// The model name from the generation's request config, when this row carries one.
    var modelName: String?
    /// `ModelUsageStats.response_id`, used to count a generation once if a database is copied.
    var responseID: String?
    /// Input billed at the plain input rate. Antigravity reports cache reads separately: across real
    /// databases `cache_read_tokens` routinely exceeds `input_tokens`, which is impossible if input
    /// included the cached prefix.
    var input: Int
    var cacheRead: Int
    var cacheWrite: Int
    /// All output, thinking included.
    var output: Int

    var tokens: TokenBreakdown {
        TokenBreakdown(input: input, cacheWrite5m: cacheWrite, cacheRead: cacheRead, output: output)
    }
}

/// What one conversation database contributed: its generations and the model enum → name pairs
/// seen in request configs (the name is only stored on some rows).
struct AntigravityDatabaseParse: Sendable, Equatable {
    var generations: [AntigravityGeneration]
    var modelNames: [Int: String]
    /// Generations with usage but no linked step timestamp. They cannot be put on a day.
    var undatedCount: Int
    /// `gen_metadata` rows read from the database.
    var generationRowCount = 0
    /// Rows whose blob is not valid protobuf (or not valid hex from `sqlite3`).
    var undecodableCount = 0
    /// Valid rows with no `ModelUsageStats` at field 1 → 4.
    var withoutUsageCount = 0

    /// Rows were read but none produced a countable generation: the format likely changed.
    var countedNothing: Bool { generationRowCount > 0 && generations.isEmpty }

    /// Every row that was read but left out of the tiles.
    var droppedCount: Int { undatedCount + undecodableCount + withoutUsageCount }
}

/// Decodes the protobuf blobs in Antigravity's `~/.gemini/antigravity/conversations/<id>.db`.
///
/// Reverse-engineered layout (field numbers from the `language_server` binary's descriptors):
/// - `gen_metadata.data`: field 1 → field 4 is `codeium_common.ModelUsageStats` (1 model enum,
///   2 input, 3 output, 4 cache write, 5 cache read, 9 thinking output, 10 response output,
///   11 response id). Field 2 is the packed list of `steps.idx` the generation produced. Field 3 is
///   the request config, with the model enum at 1 and the model name at 28, present on some rows.
/// - `steps.metadata`: field 1 is the step's creation time as a `google.protobuf.Timestamp`.
///
/// A generation's time is the earliest creation time among its linked steps.
enum AntigravityGenerationParser {
    enum RowKind: Sendable {
        case generation
        case step
    }

    struct Row: Sendable {
        var kind: RowKind
        var index: Int
        var data: Data
    }

    static func parseDatabase(_ rows: [Row]) -> AntigravityDatabaseParse {
        var stepTimes: [Int: Date] = [:]
        for row in rows where row.kind == .step {
            if let time = stepCreatedAt(row.data) {
                stepTimes[row.index] = time
            }
        }
        var result = AntigravityDatabaseParse(generations: [], modelNames: [:], undatedCount: 0)
        for row in rows where row.kind == .generation {
            result.generationRowCount += 1
            guard let parsed = parseGeneration(row.data) else {
                result.undecodableCount += 1
                continue
            }
            if let pair = parsed.namedModel {
                result.modelNames[pair.enumValue] = pair.name
            }
            guard var generation = parsed.generation else {
                result.withoutUsageCount += 1
                continue
            }
            guard let timestamp = parsed.stepIndices.compactMap({ stepTimes[$0] }).min() else {
                result.undatedCount += 1
                continue
            }
            generation.timestamp = timestamp
            result.generations.append(generation)
        }
        return result
    }

    struct ParsedGeneration {
        /// `nil` when the row carries no usage stats. The timestamp is a placeholder until steps link it.
        var generation: AntigravityGeneration?
        var stepIndices: [Int]
        var namedModel: (enumValue: Int, name: String)?
    }

    static func parseGeneration(_ data: Data) -> ParsedGeneration? {
        guard let top = ProtobufWireReader.fields(in: data) else { return nil }
        let stepIndices = top.repeatedVarints(2).compactMap { Int(exactly: $0) }

        var namedModel: (Int, String)?
        if let config = top.message(3),
           let rawEnum = config.varint(1), let enumValue = Int(exactly: rawEnum),
           let name = config.string(28)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            namedModel = (enumValue, name)
        }

        var generation: AntigravityGeneration?
        if let usage = top.message(1)?.message(4) {
            func count(_ number: Int) -> Int {
                // Clamp so a corrupt count can never trap the Int conversion.
                Int(min(usage.varint(number) ?? 0, 1_000_000_000_000))
            }
            let modelEnum = usage.varint(1).flatMap { Int(exactly: $0) }
            // `output_tokens` already includes thinking (it equals thinking + response on every
            // observed row). Taking the larger of the two keeps thinking counted exactly once even
            // if a build ever reports response-only output.
            let output = max(count(3), count(9) + count(10))
            generation = AntigravityGeneration(
                timestamp: .distantPast,
                modelEnum: modelEnum,
                modelName: namedModel.flatMap { $0.0 == modelEnum ? $0.1 : nil },
                responseID: usage.string(11).flatMap { $0.isEmpty ? nil : $0 },
                input: count(2),
                cacheRead: count(5),
                cacheWrite: count(4),
                output: output
            )
        }
        return ParsedGeneration(generation: generation, stepIndices: stepIndices, namedModel: namedModel)
    }

    /// `steps.metadata` field 1: `{1: seconds, 2: nanos}`.
    static func stepCreatedAt(_ data: Data) -> Date? {
        guard let timestamp = ProtobufWireReader.fields(in: data)?.message(1),
              let seconds = timestamp.varint(1), seconds > 0, seconds < 32_503_680_000
        else { return nil }
        let nanos = Double(timestamp.varint(2) ?? 0) / 1_000_000_000
        return Date(timeIntervalSince1970: Double(seconds) + nanos)
    }
}
