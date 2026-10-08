//
//  MDBValue.swift
//  MDBKit
//
//  Created by Josh McBroom on 10/7/26.
//

import Foundation

/// A single cell value read from a table.
public enum MDBValue: Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    /// Byte, Integer, Long Integer, Large Number, and complex-column ids.
    case int(Int)
    /// Single and Double.
    case double(Double)
    /// Currency and Decimal.
    case decimal(Decimal)
    /// Date/Time. Access stores wall-clock time with no zone; it is returned as if it were UTC.
    case date(Date)
    /// Short Text and Long Text (memo).
    case string(String)
    /// Binary and OLE Object.
    case data(Data)
    /// Replication ID.
    case uuid(UUID)

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    public var dateValue: Date? { if case .date(let v) = self { return v } else { return nil } }
    public var dataValue: Data? { if case .data(let v) = self { return v } else { return nil } }
    public var uuidValue: UUID? { if case .uuid(let v) = self { return v } else { return nil } }
    public var decimalValue: Decimal? {
        switch self {
        case .decimal(let v): return v
        case .int(let v): return Decimal(v)
        default: return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .bool(let v): return v ? 1 : 0
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .decimal(let v): return NSDecimalNumber(decimal: v).doubleValue
        default: return nil
        }
    }

    /// The underlying Swift value, or `nil` for null.
    public var any: Any? {
        switch self {
        case .null: return nil
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .decimal(let v): return v
        case .date(let v): return v
        case .string(let v): return v
        case .data(let v): return v
        case .uuid(let v): return v
        }
    }

    public var description: String {
        switch self {
        case .null: return ""
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .decimal(let v): return "\(v)"
        case .date(let v): return MDBValue.isoFormatter.string(from: v)
        case .string(let v): return v
        case .data(let v): return v.map { String(format: "%02x", $0) }.joined()
        case .uuid(let v): return "{\(v.uuidString)}"
        }
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

/// Access column data types.
public enum MDBColumnType: Equatable {
    case boolean, byte, integer, longInteger, currency, single, double, dateTime
    case binary, text, ole, memo, guid, numeric, attachment, complex, bigInt, dateTimeExtended
    case unknown(UInt8)

    init(code: UInt8) {
        switch code {
        case 0x01: self = .boolean
        case 0x02: self = .byte
        case 0x03: self = .integer
        case 0x04: self = .longInteger
        case 0x05: self = .currency
        case 0x06: self = .single
        case 0x07: self = .double
        case 0x08: self = .dateTime
        case 0x09: self = .binary
        case 0x0A: self = .text
        case 0x0B: self = .ole
        case 0x0C: self = .memo
        case 0x0F: self = .guid
        case 0x10: self = .numeric
        case 0x11: self = .attachment
        case 0x12: self = .complex
        case 0x13: self = .bigInt
        case 0x14: self = .dateTimeExtended
        default: self = .unknown(code)
        }
    }
}

/// A column in a table definition.
public struct MDBColumn {
    public let name: String
    public let type: MDBColumnType
    /// Declared size in bytes (for text in Jet4+, two bytes per character).
    public let size: Int
    public let precision: Int
    public let scale: Int
    public let isAutoNumber: Bool

    let number: Int
    let isFixed: Bool
    let fixedOffset: Int
    let varIndex: Int
}

/// One row of a table. Values are in the same order as `MDBTable.columns`.
public struct MDBRow {
    public let values: [MDBValue]
    let schema: MDBSchema

    public var columns: [MDBColumn] { schema.columns }

    public subscript(index: Int) -> MDBValue { values[index] }

    /// Looks a value up by column name (case-insensitive, as in Access). Returns `nil` if there is no such column.
    public subscript(name: String) -> MDBValue? {
        guard let i = schema.indexByName[name.lowercased()] else { return nil }
        return values[i]
    }

    /// Column name → Swift value, omitting nulls.
    public var dictionary: [String: Any] {
        var d: [String: Any] = [:]
        for (i, c) in schema.columns.enumerated() {
            if let v = values[i].any { d[c.name] = v }
        }
        return d
    }
}

final class MDBSchema {
    let columns: [MDBColumn]
    let indexByName: [String: Int]

    init(columns: [MDBColumn]) {
        self.columns = columns
        var idx: [String: Int] = [:]
        for (i, c) in columns.enumerated() where idx[c.name.lowercased()] == nil {
            idx[c.name.lowercased()] = i
        }
        indexByName = idx
    }
}
