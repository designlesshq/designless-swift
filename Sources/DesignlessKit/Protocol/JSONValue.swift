/// A JSON tree that can cross a concurrency boundary.
///
/// `[String: Any]` cannot: `Any` is not `Sendable`, and a payload held by a
/// brand is read from whatever thread a view happens to be built on. Marking
/// the containing type `@unchecked Sendable` would compile and would be a
/// promise made without proof — `Any` can hold a mutable reference, and the
/// fact that `JSONSerialization` happens to return immutable Foundation
/// objects today is not something a type system can hold anyone to.
///
/// So the payload is converted once, at parse, into values that genuinely are
/// `Sendable`. The cost is one walk of the tree per fetch; the alternative is
/// a data race that appears under load and nowhere else.

import Foundation

/// One JSON value.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// Convert a `JSONSerialization` result into a tree that can be shared.
    ///
    /// `NSNumber` is checked for boolean-ness before being read as a number:
    /// Foundation bridges `true` to an `NSNumber` that is also equal to 1, so
    /// reading in the other order turns every boolean in a payload into the
    /// number 1 and loses the distinction for good.
    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case let v as String:
            return .string(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            return .number(v.doubleValue)
        case let v as [String: Any]:
            return .object(v.mapValues(JSONValue.from))
        case let v as [Any]:
            return .array(v.map(JSONValue.from))
        default:
            return .null
        }
    }

    public var stringValue: String? {
        switch self {
        case let .string(s): return s
        case let .number(n): return n == n.rounded() ? String(Int(n)) : String(n)
        case let .bool(b): return String(b)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(n): return n
        case let .string(s): return Double(s)
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    /// True for anything that is not a leaf. A branch is not a value, and a
    /// caller asking for `color.bg` wants nil rather than a dictionary it will
    /// print into a label.
    public var isBranch: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }
}
