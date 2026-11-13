import Foundation

/// A JSON value: what event properties become as they're tracked, so they can be stored
/// on the device and sent exactly as they were.
enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Converts what the app passed. Values JSON can't hold are left out and named in
    /// `dropped`, as the web SDK's `JSON.stringify` leaves them out; dates become ISO 8601
    /// strings, and numbers that aren't finite become null, as there.
    static func from(_ value: Any, path: String = "", dropped: inout [String]) -> JSONValue? {
        guard let unwrapped = unwrapOptional(value) else { return .null }
        switch unwrapped {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as Substring:
            return .string(String(value))
        case let value as Character:
            return .string(String(value))
        case let value as Bool:
            // `NSNumber` bridges to `Bool` too, so only a real boolean lands here first.
            if let number = unwrapped as? NSNumber, !isBoolean(number) {
                return fromNumber(number)
            }
            return .bool(value)
        case let value as Int: return .int(Int64(value))
        case let value as Int8: return .int(Int64(value))
        case let value as Int16: return .int(Int64(value))
        case let value as Int32: return .int(Int64(value))
        case let value as Int64: return .int(value)
        case let value as UInt8: return .int(Int64(value))
        case let value as UInt16: return .int(Int64(value))
        case let value as UInt32: return .int(Int64(value))
        case let value as UInt: return value <= UInt(Int64.max) ? .int(Int64(value)) : .double(Double(value))
        case let value as UInt64: return value <= UInt64(Int64.max) ? .int(Int64(value)) : .double(Double(value))
        case let value as Double: return finite(value)
        case let value as Float: return finite(Double(value))
        case let value as Decimal: return finite(NSDecimalNumber(decimal: value).doubleValue)
        case let value as NSNumber: return fromNumber(value)
        case let value as Date: return .string(isoTimestamp(value))
        case let value as URL: return .string(value.absoluteString)
        case let value as UUID: return .string(value.uuidString.lowercased())
        case let value as JSONValue: return value
        case let value as [Any]:
            var items: [JSONValue] = []
            for (index, item) in value.enumerated() {
                // In an array, JSON.stringify writes null for what it can't hold.
                items.append(from(item, path: "\(path)[\(index)]", dropped: &dropped) ?? .null)
            }
            return .array(items)
        case let value as [String: Any]:
            return .object(fromObject(value, path: path, dropped: &dropped))
        case let value as [AnyHashable: Any]:
            var object: [String: Any] = [:]
            for (key, item) in value {
                guard let key = key.base as? String else {
                    dropped.append(path.isEmpty ? "\(key)" : "\(path).\(key)")
                    continue
                }
                object[key] = item
            }
            return .object(fromObject(object, path: path, dropped: &dropped))
        default:
            dropped.append(path.isEmpty ? "(value)" : path)
            return nil
        }
    }

    static func fromObject(
        _ object: [String: Any], path: String = "", dropped: inout [String]
    ) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, item) in object {
            let itemPath = path.isEmpty ? key : "\(path).\(key)"
            if let converted = from(item, path: itemPath, dropped: &dropped) {
                result[key] = converted
            }
        }
        return result
    }

    private static func finite(_ value: Double) -> JSONValue {
        value.isFinite ? .double(value) : .null
    }

    private static func fromNumber(_ number: NSNumber) -> JSONValue {
        if isBoolean(number) { return .bool(number.boolValue) }
        let type = String(cString: number.objCType)
        if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) {
            return .int(number.int64Value)
        }
        return finite(number.doubleValue)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `Any` can hold an `Optional`; a `nil` one is JSON's null. One cast, no reflection.
    private static func unwrapOptional(_ value: Any) -> Any? {
        guard let optional = value as? AnyOptional else { return value }
        return optional.wrapped.flatMap(unwrapOptional)
    }
}

/// Lets an `Optional` inside an `Any` be opened without reflection.
private protocol AnyOptional {
    var wrapped: Any? { get }
}

extension Optional: AnyOptional {
    fileprivate var wrapped: Any? { self.map { $0 as Any } }
}
