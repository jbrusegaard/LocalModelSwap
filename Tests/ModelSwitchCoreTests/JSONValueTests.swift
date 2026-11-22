import Foundation
import XCTest
@testable import ModelSwitchCore

final class JSONValueTests: XCTestCase {
    func testRoundTripPreservesObjectOrderAndNumberKinds() throws {
        let source = #"{"b":1,"a":1.0,"nested":{"z":"x","y":[true,null]},"s":"café","big":9223372036854775807}"#
        let value = try JSONValue.parse(source)
        XCTAssertEqual(value.compactText, #"{"b":1,"a":1.0,"nested":{"z":"x","y":[true,null]},"s":"café","big":9223372036854775807}"#)

        guard case .object(let root) = value else { return XCTFail("root is not an object") }
        XCTAssertEqual(root.map(\.key), ["b", "a", "nested", "s", "big"])
        XCTAssertEqual(value["b"], .int(1))
        XCTAssertEqual(value["a"], .double(1.0))
        XCTAssertEqual(value["s"]?.stringValue, "café")
        XCTAssertEqual(value["big"], .int(9223372036854775807))
    }

    func testDuplicateKeyKeepsFirstPositionLastValue() throws {
        let value = try JSONValue.parse(#"{"a":1,"b":2,"a":3}"#)
        XCTAssertEqual(value.compactText, #"{"a":3,"b":2}"#)
    }

    func testUnicodeSurrogatePairDecodes() throws {
        let value = try JSONValue.parse(#"{"emoji":"😀"}"#)
        XCTAssertEqual(value["emoji"]?.stringValue, "😀")
    }

    func testEscapesSerialize() throws {
        let value = JSONValue.makeObject([
            ("quote", .string("he said \"hi\"")),
            ("path", .string("/tmp/a")),
            ("newline", .string("a\nb")),
        ])
        let text = value.jsonText(pretty: false)
        XCTAssertEqual(text, #"{"quote":"he said \"hi\"","path":"/tmp/a","newline":"a\nb"}"#)
        XCTAssertEqual(try JSONValue.parse(text).compactText, text)
    }

    func testSetAndRemoveKeepOrder() throws {
        var value = try JSONValue.parse(#"{"env":{"A":1,"B":2},"other":true}"#)
        var env = value["env"] ?? .object([])
        env.setValue(.int(3), forKey: "B")
        env.setValue(.int(4), forKey: "C")
        env.removeValue(forKey: "A")
        XCTAssertEqual(env.compactText, #"{"B":3,"C":4}"#)
        value.setValue(env, forKey: "env")
        XCTAssertEqual(keys(value), ["env", "other"])
    }

    func testInvalidJSONThrowsWithOffset() {
        XCTAssertThrowsError(try JSONValue.parse(#"{"a": }"#))
        XCTAssertThrowsError(try JSONValue.parse("[1,2,"))
        XCTAssertThrowsError(try JSONValue.parse(#""abc"#))
    }

    func testScalarStringFromNumber() {
        XCTAssertEqual(JSONValue.int(42).scalarString, "42")
        XCTAssertEqual(JSONValue.string(" 42 ").intValue, 42)
        XCTAssertNil(JSONValue.bool(true).scalarString)
    }

    func testPrettyOutputIsParseable() throws {
        let value = JSONValue.makeObject([
            ("version", .int(1)),
            ("providers", .makeObject([("x", .makeObject([("k", .string("v"))]))])),
        ])
        let pretty = value.jsonText(pretty: true)
        XCTAssertTrue(pretty.contains("\n  \"version\": 1,"))
        XCTAssertEqual(try JSONValue.parse(pretty), value)
    }
}
