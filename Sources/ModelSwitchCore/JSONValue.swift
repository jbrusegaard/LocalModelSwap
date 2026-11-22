import Foundation

/// One key/value pair of a JSON object. Kept as an array of these rather than a
/// dictionary so a read/write round trip keeps the file's original key order.
public struct JSONPair: Equatable, Sendable {
    public let key: String
    public let value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// A JSON document with order-preserving objects and Int/Double distinction.
/// `settings.json` must survive a rewrite without losing keys Claude Code does
/// not know about, so it is never coerced into a typed model.
public enum JSONValue: Equatable, Sendable {
    case object([JSONPair])
    case array([JSONValue])
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    // MARK: Access

    public var objectPairs: [JSONPair]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    public var arrayValues: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    /// Only real JSON strings. Numbers are not silently stringified; use
    /// `scalarString` for fields the servers sometimes send as either.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// String for a JSON string or a number (sushi sends `bytes_on_disk` as
    /// either), never for booleans/objects/arrays/null.
    public var scalarString: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return value == value.rounded() ? String(format: "%.0f", value) : String(value)
        case .bool, .object, .array, .null: return nil
        }
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard value.isFinite,
                  value >= Double(Int64.min),
                  value <= Double(Int64.max),
                  value == value.rounded() else { return nil }
            return Int64(value)
        case .string(let value):
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool(let value): return value ? 1 : 0
        case .object, .array, .null: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    // MARK: Mutation helpers

    public mutating func setValue(_ value: JSONValue, forKey key: String) {
        guard case .object(var pairs) = self else {
            self = .object([JSONPair(key: key, value: value)])
            return
        }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            pairs[index] = JSONPair(key: key, value: value)
        } else {
            pairs.append(JSONPair(key: key, value: value))
        }
        self = .object(pairs)
    }

    public mutating func removeValue(forKey key: String) {
        guard case .object(var pairs) = self else { return }
        pairs.removeAll { $0.key == key }
        self = .object(pairs)
    }

    // MARK: Construction

    public static func makeObject(_ pairs: [(String, JSONValue)]) -> JSONValue {
        return .object(pairs.map { JSONPair(key: $0.0, value: $0.1) })
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data))
        return try parser.parseDocument()
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    // MARK: Serialization

    public func serializedData(pretty: Bool = true, sortedKeys: Bool = false) throws -> Data {
        let text = jsonText(pretty: pretty, sortedKeys: sortedKeys)
        return Data(text.utf8)
    }

    public func jsonText(pretty: Bool = true, sortedKeys: Bool = false) -> String {
        var out = ""
        appendJSON(to: &out, pretty: pretty, sortedKeys: sortedKeys, depth: 0)
        return out
    }

    public var compactText: String {
        jsonText(pretty: false)
    }

    private func appendJSON(to out: inout String, pretty: Bool, sortedKeys: Bool, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let childIndent = String(repeating: "  ", count: depth + 1)

        switch self {
        case .object(let pairs):
            let list = sortedKeys ? pairs.sorted(by: { $0.key < $1.key }) : pairs
            if list.isEmpty {
                out += "{}"
                return
            }
            out += "{"
            if pretty { out += "\n" }
            for (index, pair) in list.enumerated() {
                if pretty { out += childIndent }
                out += JSONValue.escapeString(pair.key)
                out += pretty ? ": " : ":"
                pair.value.appendJSON(to: &out, pretty: pretty, sortedKeys: sortedKeys, depth: depth + 1)
                if index < list.count - 1 { out += "," }
                if pretty { out += "\n" }
            }
            if pretty { out += indent }
            out += "}"

        case .array(let values):
            if values.isEmpty {
                out += "[]"
                return
            }
            out += "["
            if pretty { out += "\n" }
            for (index, value) in values.enumerated() {
                if pretty { out += childIndent }
                value.appendJSON(to: &out, pretty: pretty, sortedKeys: sortedKeys, depth: depth + 1)
                if index < values.count - 1 { out += "," }
                if pretty { out += "\n" }
            }
            if pretty { out += indent }
            out += "]"

        case .string(let value):
            out += JSONValue.escapeString(value)

        case .int(let value):
            out += String(value)

        case .double(let value):
            // JSON has no NaN/Infinity. Callers validate before writing.
            if value.isNaN || value.isInfinite {
                out += "null"
            } else {
                out += String(value)
            }

        case .bool(let value):
            out += value ? "true" : "false"

        case .null:
            out += "null"
        }
    }

    static func escapeString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

public struct JSONParseError: Error, Equatable, LocalizedError {
    public let message: String
    public let byteOffset: Int

    public init(message: String, byteOffset: Int) {
        self.message = message
        self.byteOffset = byteOffset
    }

    public var errorDescription: String? {
        "Invalid JSON at byte \(byteOffset): \(message)"
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw error("trailing data")
        }
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw error("unexpected character")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        index += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object([])
        }

        var pairs: [JSONPair] = []
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw error("expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue()

            // Python/Go both keep the first position and last value for a
            // repeated key. Match that rather than failing the file.
            if let existing = pairs.firstIndex(where: { $0.key == key }) {
                pairs[existing] = JSONPair(key: key, value: value)
            } else {
                pairs.append(JSONPair(key: key, value: value))
            }

            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                return .object(pairs)
            default:
                throw error("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        index += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array([])
        }

        var values: [JSONValue] = []
        while true {
            skipWhitespace()
            values.append(try parseValue())
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                return .array(values)
            default:
                throw error("expected ',' or ']'")
            }
        }
    }

    private mutating func parseString() throws -> String {
        precondition(peek() == UInt8(ascii: "\""))
        index += 1
        var out = ""
        var rawStart = index

        func flushRaw(upTo end: Int) {
            guard end > rawStart else { return }
            let slice = Array(bytes[rawStart..<end])
            out += String(decoding: slice, as: UTF8.self)
            rawStart = end
        }

        while index < bytes.count {
            let byte = bytes[index]

            if byte == UInt8(ascii: "\"") {
                flushRaw(upTo: index)
                index += 1
                return out
            }

            if byte == UInt8(ascii: "\\") {
                flushRaw(upTo: index)
                index += 1
                guard index < bytes.count else { throw error("unterminated escape") }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""): out += "\""
                case UInt8(ascii: "\\"): out += "\\"
                case UInt8(ascii: "/"): out += "/"
                case UInt8(ascii: "b"): out.unicodeScalars.append(UnicodeScalar(0x08))
                case UInt8(ascii: "f"): out.unicodeScalars.append(UnicodeScalar(0x0C))
                case UInt8(ascii: "n"): out.unicodeScalars.append(UnicodeScalar(0x0A))
                case UInt8(ascii: "r"): out.unicodeScalars.append(UnicodeScalar(0x0D))
                case UInt8(ascii: "t"): out.unicodeScalars.append(UnicodeScalar(0x09))
                case UInt8(ascii: "u"):
                    let first = try parseHex4()
                    var scalarValue = first
                    if first >= 0xD800 && first <= 0xDBFF {
                        guard index + 1 < bytes.count,
                              bytes[index] == UInt8(ascii: "\\"),
                              bytes[index + 1] == UInt8(ascii: "u") else {
                            throw error("high surrogate without low surrogate")
                        }
                        index += 2
                        let second = try parseHex4()
                        guard second >= 0xDC00 && second <= 0xDFFF else {
                            throw error("invalid low surrogate")
                        }
                        scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    } else if first >= 0xDC00 && first <= 0xDFFF {
                        throw error("unexpected low surrogate")
                    }
                    guard let scalar = UnicodeScalar(scalarValue) else {
                        throw error("invalid unicode escape")
                    }
                    out.unicodeScalars.append(scalar)
                default:
                    throw error("invalid escape")
                }
                rawStart = index
                continue
            }

            if byte < 0x20 {
                throw error("unescaped control character in string")
            }

            index += 1
        }

        throw error("unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("short unicode escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = hexValue(bytes[index]) else { throw error("invalid hex digit") }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }

    private func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        var isDouble = false

        if peek() == UInt8(ascii: "-") {
            index += 1
        }

        guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
            if index < bytes.count, isDigit(bytes[index]) {
                throw error("leading zero in number")
            }
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }

        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isDouble = true
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid fraction") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }

        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isDouble = true
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid exponent") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }

        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        if isDouble {
            guard let value = Double(token), value.isFinite else { throw error("number out of range") }
            return .double(value)
        }
        guard let value = Int64(token) else { throw error("integer out of range") }
        return .int(value)
    }

    private mutating func expect(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count else { throw error("unexpected end of input") }
        for (offset, byte) in literalBytes.enumerated() {
            guard bytes[index + offset] == byte else { throw error("invalid literal") }
        }
        index += literalBytes.count
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(message: message, byteOffset: index)
    }
}
