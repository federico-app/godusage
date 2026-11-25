import Foundation

/// A minimal protobuf wire-format reader for schemaless blobs (Antigravity's conversation
/// databases store protobuf messages without a published schema). It decodes one message level at a
/// time; length-delimited fields stay raw bytes so callers descend only into the fields they know.
///
/// Malformed input (truncated varints or lengths, field number 0, group or unknown wire types) makes
/// `fields(in:)` return `nil` rather than a partial list, so a caller never mistakes a cut-off
/// message for a complete one.
enum ProtobufWireReader {
    enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    struct Field: Equatable, Sendable {
        var number: Int
        var value: Value
    }

    static func fields(in data: Data) -> [Field]? {
        fields(in: ArraySlice([UInt8](data)))
    }

    static func fields(in bytes: ArraySlice<UInt8>) -> [Field]? {
        var result: [Field] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let key = readVarint(bytes, &index) else { return nil }
            let number = key >> 3
            guard number > 0, number <= UInt64(Int32.max) else { return nil }
            let value: Value
            switch key & 7 {
            case 0:
                guard let raw = readVarint(bytes, &index) else { return nil }
                value = .varint(raw)
            case 1:
                guard let raw = readFixed(bytes, &index, width: 8) else { return nil }
                value = .fixed64(raw)
            case 2:
                guard let length = readVarint(bytes, &index),
                      length <= UInt64(bytes.endIndex - index)
                else { return nil }
                let end = index + Int(length)
                value = .bytes(bytes[index..<end])
                index = end
            case 5:
                guard let raw = readFixed(bytes, &index, width: 4) else { return nil }
                value = .fixed32(UInt32(truncatingIfNeeded: raw))
            default:
                return nil
            }
            result.append(Field(number: Int(number), value: value))
        }
        return result
    }

    /// A packed `repeated` varint field's payload. `nil` when the payload is truncated.
    static func packedVarints(_ bytes: ArraySlice<UInt8>) -> [UInt64]? {
        var values: [UInt64] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let value = readVarint(bytes, &index) else { return nil }
            values.append(value)
        }
        return values
    }

    private static func readVarint(_ bytes: ArraySlice<UInt8>, _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    private static func readFixed(_ bytes: ArraySlice<UInt8>, _ index: inout Int, width: Int) -> UInt64? {
        guard bytes.endIndex - index >= width else { return nil }
        var result: UInt64 = 0
        for offset in 0..<width {
            result |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
        }
        index += width
        return result
    }
}

extension Array where Element == ProtobufWireReader.Field {
    /// The first varint carried by field `number`.
    func varint(_ number: Int) -> UInt64? {
        for field in self where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    /// The first length-delimited payload carried by field `number`.
    func bytes(_ number: Int) -> ArraySlice<UInt8>? {
        for field in self where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    /// Field `number` decoded as an embedded message.
    func message(_ number: Int) -> [ProtobufWireReader.Field]? {
        bytes(number).flatMap { ProtobufWireReader.fields(in: $0) }
    }

    /// Every value of a `repeated` varint field, accepting both packed and unpacked encodings.
    func repeatedVarints(_ number: Int) -> [UInt64] {
        var values: [UInt64] = []
        for field in self where field.number == number {
            switch field.value {
            case .varint(let value): values.append(value)
            case .bytes(let payload): values += ProtobufWireReader.packedVarints(payload) ?? []
            default: continue
            }
        }
        return values
    }

    /// Field `number` decoded as UTF-8 text.
    func string(_ number: Int) -> String? {
        bytes(number).flatMap { String(bytes: $0, encoding: .utf8) }
    }
}
