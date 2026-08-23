import Foundation

extension JSONValue {
    public func toJSONObject() throws -> Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(values):
            try values.map { try $0.toJSONObject() }
        case let .object(values):
            try values.mapValues { try $0.toJSONObject() }
        }
    }

    public func toJSONData() throws -> Data {
        let object = try toJSONObject()
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AgentError.llmFailed("Invalid JSON object")
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

public enum JSONValueDecoder {
    public static func decode(from data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data)
        return try parse(object)
    }

    public static func decode(from string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            throw AgentError.llmFailed("Invalid UTF-8 JSON string")
        }
        return try decode(from: data)
    }

    private static func parse(_ value: Any) throws -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let doubleValue = number.doubleValue
            if floor(doubleValue) == doubleValue {
                return .int(number.intValue)
            }
            return .double(doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.map { try parse($0) })
        case let dictionary as [String: Any]:
            return .object(try dictionary.mapValues { try parse($0) })
        default:
            throw AgentError.llmFailed("Unsupported JSON value")
        }
    }
}
