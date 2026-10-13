import XCTest
@testable import FrontbotCore

final class RPCTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let msg = RPCMessage.request(id: 7, method: "tool.brands_list", params: ["limit": 5, "name": "Café ☕️"])
        let line = try msg.encodedLine()
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        XCTAssertEqual(try RPCMessage.decode(line.dropLast()), msg)
    }

    func testDecodesAllShapes() throws {
        XCTAssertEqual(try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","method":"agent.event","params":{"type":"text"}}"#.utf8)),
                       .notification(method: "agent.event", params: ["type": "text"]))
        XCTAssertEqual(try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8)),
                       .response(id: 3, result: ["ok": true]))
        XCTAssertEqual(try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"mal"}}"#.utf8)),
                       .error(id: 3, code: -32000, message: "mal"))
    }

    func testDecodeGarbageThrows() {
        XCTAssertThrowsError(try RPCMessage.decode(Data("no json".utf8)))
    }

    func testFramerReassemblesPartialLines() {
        var framer = LineFramer()
        XCTAssertEqual(framer.append(Data(#"{"a":"#.utf8)), [])
        XCTAssertEqual(framer.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8)), [Data(#"{"a":1}"#.utf8), Data(#"{"b":2}"#.utf8)])
        XCTAssertEqual(framer.append(Data(":3}\n".utf8)), [Data(#"{"c":3}"#.utf8)])
    }

    func testFramerSkipsEmptyLines() {
        var framer = LineFramer()
        XCTAssertEqual(framer.append(Data("\n\n{\"a\":1}\n".utf8)), [Data(#"{"a":1}"#.utf8)])
    }

    func testJSONValueAccessors() {
        let v: JSONValue = ["n": 3, "s": "x", "arr": ["a"], "b": true, "nil": nil]
        XCTAssertEqual(v["n"]?.intValue, 3)
        XCTAssertEqual(v["s"]?.stringValue, "x")
        XCTAssertEqual(v["arr"]?.arrayValue, ["a"])
        XCTAssertEqual(v["b"]?.boolValue, true)
        XCTAssertEqual(v["nil"], .null)
    }
}
