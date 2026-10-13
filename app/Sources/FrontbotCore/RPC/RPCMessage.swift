import Foundation

public enum RPCMessage: Equatable, Sendable {
    case request(id: Int, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: Int, result: JSONValue)
    case error(id: Int, code: Int, message: String)

    public func encodedLine() throws -> Data {
        var obj: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            obj["id"] = .number(Double(id)); obj["method"] = .string(method); obj["params"] = params
        case .notification(let method, let params):
            obj["method"] = .string(method); obj["params"] = params
        case .response(let id, let result):
            obj["id"] = .number(Double(id)); obj["result"] = result
        case .error(let id, let code, let message):
            obj["id"] = .number(Double(id))
            obj["error"] = ["code": .number(Double(code)), "message": .string(message)]
        }
        var data = try JSONEncoder().encode(JSONValue.object(obj))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func decode(_ line: Data) throws -> RPCMessage {
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        guard case .object = value else { throw ValidationError("Mensaje RPC no es un objeto.") }
        let id = value["id"]?.intValue
        if let method = value["method"]?.stringValue {
            let params = value["params"] ?? .null
            if let id { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id else { throw ValidationError("Respuesta RPC sin id.") }
        if let err = value["error"] {
            return .error(id: id, code: err["code"]?.intValue ?? -32000, message: err["message"]?.stringValue ?? "Error desconocido")
        }
        return .response(id: id, result: value["result"] ?? .null)
    }
}

public struct LineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<idx]
            buffer = Data(buffer[buffer.index(after: idx)...])
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}
