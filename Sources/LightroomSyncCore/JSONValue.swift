import Foundation

/// A decoded JSON value, for the parts of Lightroom's payload whose shape Adobe varies.
///
/// `payload.xmp` mirrors the XMP packet of the original file, so what is in it depends on the
/// camera, the catalog and how much the photo has been worked on. Modelling every namespace as a
/// `Decodable` struct would mean a decoding failure every time Adobe sends a field in a shape the
/// struct did not predict; keeping it as a tree and reading the paths that matter cannot fail.
public indirect enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    // MARK: - Reading

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// Walks nested objects: `xmp.path("dc", "title")`.
    public func path(_ keys: String...) -> JSONValue? {
        var value: JSONValue? = self
        for key in keys {
            value = value?[key]
            if value == nil { return nil }
        }
        return value
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var int: Int? {
        guard let double, double.isFinite else { return nil }
        return Int(double)
    }

    public var array: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    /// A human-readable string, unwrapping XMP's language alternatives.
    ///
    /// XMP stores a title or a caption per language, which Adobe serializes as
    /// `{"x-default": "…"}` — sometimes as a bare string, sometimes as a one-element array.
    public var localizedString: String? {
        switch self {
        case .string(let value):
            return value.isEmpty ? nil : value
        case .array(let values):
            return values.lazy.compactMap(\.localizedString).first
        case .object(let members):
            if let value = members["x-default"]?.localizedString { return value }
            // One entry under some other language tag is still the only text there is.
            return members.count == 1 ? members.values.first?.localizedString : nil
        default:
            return nil
        }
    }

    /// The strings of an XMP bag or sequence, such as `dc:subject` (keywords).
    public var stringList: [String] {
        switch self {
        case .string(let value):
            return value.isEmpty ? [] : [value]
        case .array(let values):
            return values.compactMap(\.localizedString)
        case .object(let members):
            // XMP arrays occasionally arrive wrapped, e.g. {"bag": ["a", "b"]}.
            return members.values.flatMap(\.stringList).sorted()
        default:
            return []
        }
    }

    /// A number XMP may have written as a rational: `[28, 10]` or `"28/10"`, both meaning 2.8.
    public var rational: Double? {
        if let double { return double }
        if case .array(let values) = self, values.count == 2,
           let numerator = values[0].double, let denominator = values[1].double, denominator != 0 {
            return numerator / denominator
        }
        if case .string(let text) = self {
            let parts = text.split(separator: "/")
            if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 {
                return numerator / denominator
            }
        }
        return nil
    }
}
