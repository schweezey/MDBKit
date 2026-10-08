//
//  MDBTable.swift
//  MDBKit
//
//  Created by Josh McBroom on 10/7/26.
//

import Foundation

/// A table in an Access database.
public final class MDBTable {
    public let name: String
    /// Row count recorded in the table definition.
    public let rowCount: Int
    public var columns: [MDBColumn] { schema.columns }

    let database: MDBDatabase
    let tdefPage: Int
    let varColumnCount: Int
    let schema: MDBSchema

    init(database: MDBDatabase, name: String, tdefPage: Int, rowCount: Int, varColumnCount: Int, schema: MDBSchema) {
        self.database = database
        self.name = name
        self.tdefPage = tdefPage
        self.rowCount = rowCount
        self.varColumnCount = varColumnCount
        self.schema = schema
    }

    /// Reads every row into memory.
    public func rows() throws -> [MDBRow] {
        var out: [MDBRow] = []
        out.reserveCapacity(max(0, min(rowCount, 1_000_000)))
        try forEachRow { out.append($0) }
        return out
    }

    /// Streams rows in storage order without holding the whole table in memory.
    public func forEachRow(_ body: (MDBRow) throws -> Void) throws {
        let db = database
        for pageNumber in db.dataPages(ownedBy: tdefPage) {
            let pg = try db.page(pageNumber)
            guard pg[0] == 0x01 else { continue }
            let count = try le16(pg, db.format.dataRowCountOffset)
            for r in 0..<count {
                var buf = pg
                var range = try db.rowRange(in: buf, row: r)
                // 0x8000: deleted, or the relocated body of a row that is reached through its
                // original slot instead. Either way it is not a row to emit from here.
                if range.raw & 0x8000 != 0 { continue }
                // 0x4000: the row outgrew its page; the slot holds a pointer to its new home.
                var hops = 0
                var broken = false
                while range.raw & 0x4000 != 0 {
                    hops += 1
                    guard hops <= 16, range.end - range.start >= 4 else { broken = true; break }
                    let pointer = try le32(buf, range.start)
                    buf = try db.page(Int(pointer >> 8))
                    range = try db.rowRange(in: buf, row: Int(pointer & 0xFF))
                }
                if broken || range.end <= range.start { continue }
                if let row = try crack(buf, start: range.start, end: range.end) {
                    try body(row)
                }
            }
        }
    }

    // MARK: - Row decoding

    private func crack(_ buf: [UInt8], start s: Int, end e: Int) throws -> MDBRow? {
        let jet3 = database.format.isJet3
        let countSize = jet3 ? 1 : 2
        guard e - s >= countSize else { return nil }
        let rowCols = try jet3 ? u8(buf, s) : le16(buf, s)
        let maskSize = (rowCols + 7) / 8
        let maskStart = e - maskSize
        guard maskStart >= s + countSize else { return nil }

        // Offsets of the variable-length columns, plus one trailing end-of-data offset.
        var rowVarCols = 0
        var varOffsets: [Int] = []
        if varColumnCount > 0 {
            if jet3 {
                guard maskStart - 1 >= s else { return nil }
                rowVarCols = Int(buf[maskStart - 1])
                // Offsets are one byte each; a "jump table" records where they wrap past 255.
                var numJumps = (e - 1 - s) / 256
                let colPtr = maskStart - 2 - numJumps
                if (colPtr - s - rowVarCols) / 256 < numJumps { numJumps -= 1 }
                guard colPtr - rowVarCols >= s else { return nil }
                var jumpsUsed = 0
                for i in 0...rowVarCols {
                    while jumpsUsed < numJumps && i == Int(buf[maskStart - 2 - jumpsUsed]) { jumpsUsed += 1 }
                    varOffsets.append(Int(buf[colPtr - i]) + jumpsUsed * 256)
                }
            } else {
                guard maskStart - 2 >= s else { return nil }
                rowVarCols = try le16(buf, maskStart - 2)
                guard maskStart - 4 - 2 * rowVarCols >= s else { return nil }
                for i in 0...rowVarCols {
                    varOffsets.append(try le16(buf, maskStart - 4 - 2 * i))
                }
            }
        }
        let rowFixedCols = rowCols - rowVarCols
        var fixedFound = 0

        var values: [MDBValue] = []
        values.reserveCapacity(schema.columns.count)
        for col in schema.columns {
            // A set bit in the mask means "has a value" (and for Yes/No columns, "true").
            var present = false
            if col.number < rowCols {
                present = buf[maskStart + col.number / 8] & (1 << UInt8(col.number % 8)) != 0
            }
            var fieldStart = 0
            var fieldSize = 0
            var located = false
            if col.isFixed {
                if fixedFound < rowFixedCols {
                    fieldStart = s + countSize + col.fixedOffset
                    fieldSize = col.size
                    fixedFound += 1
                    located = true
                }
            } else if col.varIndex < rowVarCols, col.varIndex + 1 < varOffsets.count {
                fieldStart = s + varOffsets[col.varIndex]
                fieldSize = varOffsets[col.varIndex + 1] - varOffsets[col.varIndex]
                located = true
            }

            if col.type == .boolean {
                values.append(.bool(present))
                continue
            }
            guard present, located, fieldSize >= 0, fieldStart >= s, fieldStart + fieldSize <= maskStart else {
                values.append(.null)
                continue
            }
            values.append(try decode(col, buf, fieldStart, fieldSize))
        }
        return MDBRow(values: values, schema: schema)
    }

    private func decode(_ col: MDBColumn, _ buf: [UInt8], _ o: Int, _ n: Int) throws -> MDBValue {
        switch col.type {
        case .boolean:
            return .bool(true)
        case .byte:
            guard n >= 1 else { return .null }
            return .int(Int(buf[o]))
        case .integer:
            guard n >= 2 else { return .null }
            return .int(Int(Int16(bitPattern: UInt16(try le16(buf, o)))))
        case .longInteger, .complex, .attachment:
            guard n >= 4 else { return .null }
            return .int(Int(Int32(bitPattern: try le32(buf, o))))
        case .bigInt:
            guard n >= 8 else { return .null }
            return .int(Int(Int64(bitPattern: try le64(buf, o))))
        case .currency:
            guard n >= 8 else { return .null }
            let v = Int64(bitPattern: try le64(buf, o))
            return .decimal(Decimal(sign: v < 0 ? .minus : .plus, exponent: -4,
                                    significand: Decimal(v.magnitude)))
        case .single:
            guard n >= 4 else { return .null }
            let f = Float(bitPattern: try le32(buf, o))
            // Go through the shortest decimal form so 1.1 does not become 1.100000023841858.
            return .double(Double("\(f)") ?? Double(f))
        case .double:
            guard n >= 8 else { return .null }
            return .double(Double(bitPattern: try le64(buf, o)))
        case .dateTime:
            guard n >= 8 else { return .null }
            return .date(MDBTable.date(fromAccessDays: Double(bitPattern: try le64(buf, o))))
        case .numeric:
            guard n >= 17 else { return .null }
            // Sign byte, then a 128-bit magnitude as four little-endian words, most significant first.
            var magnitude = Decimal(0)
            let base = Decimal(UInt64(4_294_967_296))
            for g in 0..<4 {
                magnitude = magnitude * base + Decimal(UInt64(try le32(buf, o + 1 + 4 * g)))
            }
            return .decimal(Decimal(sign: buf[o] & 0x80 != 0 ? .minus : .plus,
                                    exponent: -col.scale, significand: magnitude))
        case .guid:
            guard n >= 16 else { return .null }
            // Stored as a Windows GUID: the first three fields are little-endian.
            let b = Array(buf[o..<(o + 16)])
            return .uuid(UUID(uuid: (b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6],
                                     b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])))
        case .text:
            return .string(decodeText(buf, o, n))
        case .memo:
            let bytes = try database.longValue(buf, start: o, count: n)
            return .string(decodeText(bytes, 0, bytes.count))
        case .ole:
            return .data(Data(try database.longValue(buf, start: o, count: n)))
        case .binary, .unknown:
            return .data(Data(buf[o..<(o + n)]))
        case .dateTimeExtended:
            return .string(String(decoding: buf[o..<(o + n)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")))
        }
    }

    func decodeText(_ buf: [UInt8], _ o: Int, _ n: Int) -> String {
        if database.format.isJet3 {
            let bytes = Array(buf[o..<(o + n)])
            return String(bytes: bytes, encoding: database.legacyEncoding) ?? String(decoding: bytes, as: UTF8.self)
        }
        return MDBTable.decodeJet4Text(buf, o, n)
    }

    /// Jet4 text is UTF-16LE, optionally "Unicode-compressed": after an FF FE marker each byte is one
    /// character, and a zero byte switches between one-byte and two-byte mode.
    static func decodeJet4Text(_ buf: [UInt8], _ o: Int, _ n: Int) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(n)
        let end = o + n
        var i = o
        if n >= 2 && buf[o] == 0xFF && buf[o + 1] == 0xFE {
            i += 2
            var compressed = true
            while i < end {
                if buf[i] == 0 {
                    compressed.toggle()
                    i += 1
                } else if compressed {
                    units.append(UInt16(buf[i]))
                    i += 1
                } else if i + 1 < end {
                    units.append(UInt16(buf[i]) | (UInt16(buf[i + 1]) << 8))
                    i += 2
                } else {
                    break
                }
            }
        } else {
            while i + 1 < end {
                units.append(UInt16(buf[i]) | (UInt16(buf[i + 1]) << 8))
                i += 2
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Access dates count days from 1899-12-30; the fraction is the time of day (its sign is ignored).
    static func date(fromAccessDays d: Double) -> Date {
        let day = d.rounded(.towardZero)
        let fraction = abs(d - day)
        let seconds = (day - 25569) * 86400 + (fraction * 86_400_000).rounded() / 1000
        return Date(timeIntervalSince1970: seconds)
    }
}
