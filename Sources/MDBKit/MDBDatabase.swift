//
//  MDBDatabase.swift
//  MDBKit
//
//  Created by Josh McBroom on 10/7/26.
//

import Foundation

/// A read-only Microsoft Access database (`.mdb`, or an unencrypted `.accdb`).
///
///     let db = try MDBDatabase(url: fileURL)
///     for name in try db.tableNames() {
///         let table = try db.table(named: name)
///         try table.forEachRow { row in print(row.dictionary) }
///     }
///
/// Instances are not thread-safe; use one per thread or serialize access.
public final class MDBDatabase {

    public enum Version: Equatable {
        case jet3          // Access 97
        case jet4          // Access 2000–2003
        case ace(Int)      // Access 2007 and later (.accdb); payload is the raw version byte
    }

    /// An entry in the system catalog (`MSysObjects`).
    public struct CatalogEntry {
        public let name: String
        /// Raw object type: 1 = table, 5 = query, 6 = linked table, 4 = linked ODBC table; forms, reports and modules are negative.
        public let type: Int
        public let flags: UInt32
        let tdefPage: Int

        public var isTable: Bool { type == 1 }
        public var isSystem: Bool { flags & 0x8000_0002 != 0 }
        public var isUserTable: Bool { isTable && !isSystem }
    }

    public let version: Version
    /// Encoding used for text in Access 97 files. Ignored for newer files, which are Unicode.
    public let legacyEncoding: String.Encoding

    let format: JetFormat
    private let data: Data
    private let dbKey: UInt32
    private var pageCache: [Int: [UInt8]] = [:]
    private var dataPageIndex: [Int: [Int]]?
    private var catalogCache: [CatalogEntry]?

    public convenience init(url: URL, legacyEncoding: String.Encoding = .windowsCP1252) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data, legacyEncoding: legacyEncoding)
    }

    public convenience init(path: String, legacyEncoding: String.Encoding = .windowsCP1252) throws {
        try self.init(url: URL(fileURLWithPath: path), legacyEncoding: legacyEncoding)
    }

    public init(data: Data, legacyEncoding: String.Encoding = .windowsCP1252) throws {
        guard data.count >= 2048 else { throw MDBError.notAnAccessDatabase }
        var header = [UInt8](data.prefix(2048))
        let magic = String(decoding: header[4..<19], as: UTF8.self)
        guard magic == "Standard Jet DB" || magic == "Standard ACE DB" else {
            throw MDBError.notAnAccessDatabase
        }
        let versionByte = header[0x14]
        switch versionByte {
        case 0:
            version = .jet3
            format = .jet3
        case 1:
            version = .jet4
            format = .jet4
        case 2...6:
            version = .ace(Int(versionByte))
            format = .jet4
        default:
            throw MDBError.unsupportedVersion(versionByte)
        }
        guard data.count >= format.pageSize * 3 else { throw MDBError.corrupt("file is too short") }

        // Part of the header is obfuscated with a fixed RC4 key.
        var rc4 = RC4(key: [0xC7, 0xDA, 0x39, 0x6B])
        rc4.apply(&header, range: 0x18..<(0x18 + (format.isJet3 ? 126 : 128)))
        dbKey = try le32(header, 0x3E)

        self.data = data
        self.legacyEncoding = legacyEncoding

        // The catalog's table definition always lives on page 2. If that does not decode to a
        // table-definition page, the file uses an encryption scheme we cannot undo.
        let catalogPage = try page(2)
        guard catalogPage[0] == 0x02 else {
            throw MDBError.encrypted
        }
    }

    // MARK: - Public API

    /// Every object in the system catalog, including queries, forms and system tables.
    public func catalog() throws -> [CatalogEntry] {
        if let c = catalogCache { return c }
        let sys = try loadTable(tdefPage: 2, name: "MSysObjects")
        var entries: [CatalogEntry] = []
        try sys.forEachRow { row in
            guard let name = row["Name"]?.stringValue,
                  let type = row["Type"]?.intValue,
                  let id = row["Id"]?.intValue else { return }
            let flags = UInt32(truncatingIfNeeded: row["Flags"]?.intValue ?? 0)
            entries.append(CatalogEntry(name: name, type: type, flags: flags,
                                        tdefPage: id & 0x00FF_FFFF))
        }
        catalogCache = entries
        return entries
    }

    /// Names of the user tables stored in this file (linked tables and system tables are excluded).
    public func tableNames() throws -> [String] {
        try catalog().filter { $0.isUserTable }.map { $0.name }
    }

    /// Opens a table by name (case-insensitive). System tables such as `MSysObjects` can be opened too.
    public func table(named name: String) throws -> MDBTable {
        let wanted = name.lowercased()
        guard let entry = try catalog().first(where: { $0.isTable && $0.name.lowercased() == wanted }) else {
            throw MDBError.tableNotFound(name)
        }
        return try loadTable(tdefPage: entry.tdefPage, name: entry.name)
    }

    /// All user tables.
    public func tables() throws -> [MDBTable] {
        try catalog().filter { $0.isUserTable }.map { try loadTable(tdefPage: $0.tdefPage, name: $0.name) }
    }

    // MARK: - Pages

    var pageCount: Int { data.count / format.pageSize }

    private func pageKey(_ n: Int) -> [UInt8] {
        let k = dbKey ^ UInt32(truncatingIfNeeded: n)
        return [UInt8(k & 0xFF), UInt8((k >> 8) & 0xFF), UInt8((k >> 16) & 0xFF), UInt8((k >> 24) & 0xFF)]
    }

    func page(_ n: Int) throws -> [UInt8] {
        if let cached = pageCache[n] { return cached }
        let size = format.pageSize
        guard n >= 0, n < pageCount else { throw MDBError.corrupt("reference to page \(n), which is outside the file") }
        let base = data.startIndex + n * size
        var bytes = [UInt8](data[base..<(base + size)])
        if n != 0 && dbKey != 0 {
            var rc4 = RC4(key: pageKey(n))
            rc4.apply(&bytes, range: 0..<size)
        }
        if pageCache.count >= 128 { pageCache.removeAll(keepingCapacity: true) }
        pageCache[n] = bytes
        return bytes
    }

    /// Data pages grouped by the table-definition page that owns them, in file order.
    func dataPages(ownedBy tdefPage: Int) -> [Int] {
        if dataPageIndex == nil {
            var index: [Int: [Int]] = [:]
            let size = format.pageSize
            if pageCount > 1 {
                for n in 1..<pageCount {
                    let base = data.startIndex + n * size
                    var h = [UInt8](data[base..<(base + 8)])
                    if dbKey != 0 {
                        // RC4 is a stream cipher, so decoding just the prefix is enough.
                        var rc4 = RC4(key: pageKey(n))
                        rc4.apply(&h, range: 0..<8)
                    }
                    guard h[0] == 0x01 else { continue }
                    let owner = Int(h[4]) | (Int(h[5]) << 8) | (Int(h[6]) << 16) | (Int(h[7]) << 24)
                    index[owner, default: []].append(n)
                }
            }
            dataPageIndex = index
        }
        return dataPageIndex?[tdefPage] ?? []
    }

    /// Locates row `row` on a data page. Returns the byte range and the raw offset-table entry (with flag bits).
    func rowRange(in pg: [UInt8], row: Int) throws -> (start: Int, end: Int, raw: Int) {
        let countOffset = format.dataRowCountOffset
        let count = try le16(pg, countOffset)
        guard row >= 0, row < count else { throw MDBError.corrupt("row pointer outside page") }
        let table = countOffset + 2
        let raw = try le16(pg, table + 2 * row)
        let start = raw & 0x1FFF
        var end = format.pageSize
        if row > 0 { end = try le16(pg, table + 2 * (row - 1)) & 0x1FFF }
        guard start <= end, end <= pg.count else { throw MDBError.corrupt("invalid row offsets") }
        return (start, end, raw)
    }

    // MARK: - Table definitions

    func loadTable(tdefPage: Int, name: String) throws -> MDBTable {
        let f = format
        var buf = try page(tdefPage)
        guard buf[0] == 0x02 else { throw MDBError.corrupt("page \(tdefPage) is not a table definition") }

        // A definition can spill onto further pages; stitch them into one buffer.
        var next = Int(try le32(buf, 4))
        var seen: Set<Int> = [tdefPage]
        while next != 0 {
            guard seen.insert(next).inserted else { throw MDBError.corrupt("table definition page loop") }
            let more = try page(next)
            guard more[0] == 0x02 else { throw MDBError.corrupt("broken table definition chain") }
            buf.append(contentsOf: more[8...])
            next = Int(try le32(more, 4))
        }

        let rowCount = Int(try le32(buf, f.tdefRowCount))
        let varColCount = try le16(buf, f.tdefVarColCount)
        let colCount = try le16(buf, f.tdefColCount)
        let realIndexCount = Int(try le32(buf, f.tdefRealIndexCount))
        guard realIndexCount >= 0, realIndexCount < 4096 else { throw MDBError.corrupt("implausible index count") }

        var pos = f.tdefColumnsStart + realIndexCount * f.realIndexEntrySize
        struct RawColumn { var type: UInt8; var number, varIndex, precision, scale, flags, fixedOffset, size: Int }
        var raws: [RawColumn] = []
        raws.reserveCapacity(colCount)
        for _ in 0..<colCount {
            raws.append(RawColumn(
                type: UInt8(try u8(buf, pos)),
                number: try le16(buf, pos + f.colNumber),
                varIndex: try le16(buf, pos + f.colVarIndex),
                precision: try u8(buf, pos + f.colPrecision),
                scale: try u8(buf, pos + f.colScale),
                flags: try u8(buf, pos + f.colFlags),
                fixedOffset: try le16(buf, pos + f.colFixedOffset),
                size: try le16(buf, pos + f.colSize)))
            pos += f.columnEntrySize
        }

        var columns: [MDBColumn] = []
        columns.reserveCapacity(colCount)
        for raw in raws {
            let name: String
            if f.isJet3 {
                let len = try u8(buf, pos)
                pos += 1
                guard pos + len <= buf.count else { throw MDBError.corrupt("column name runs past definition") }
                let bytes = Array(buf[pos..<(pos + len)])
                name = String(bytes: bytes, encoding: legacyEncoding) ?? String(decoding: bytes, as: UTF8.self)
                pos += len
            } else {
                let len = try le16(buf, pos)
                pos += 2
                guard pos + len <= buf.count else { throw MDBError.corrupt("column name runs past definition") }
                var units: [UInt16] = []
                units.reserveCapacity(len / 2)
                var i = pos
                while i + 1 < pos + len {
                    units.append(UInt16(buf[i]) | (UInt16(buf[i + 1]) << 8))
                    i += 2
                }
                name = String(decoding: units, as: UTF16.self)
                pos += len
            }
            let type = MDBColumnType(code: raw.type)
            let isNumeric = type == .numeric
            columns.append(MDBColumn(
                name: name, type: type, size: raw.size,
                precision: isNumeric ? raw.precision : 0,
                scale: isNumeric ? raw.scale : 0,
                isAutoNumber: raw.flags & 0x04 != 0,
                number: raw.number,
                isFixed: raw.flags & 0x01 != 0,
                fixedOffset: raw.fixedOffset,
                varIndex: raw.varIndex))
        }
        columns.sort { $0.number < $1.number }

        return MDBTable(database: self, name: name, tdefPage: tdefPage,
                        rowCount: rowCount, varColumnCount: varColCount,
                        schema: MDBSchema(columns: columns))
    }

    // MARK: - Long values (memo / OLE)

    /// Resolves a 12-byte memo/OLE field descriptor (plus any inline payload) to the full value.
    func longValue(_ buf: [UInt8], start: Int, count: Int) throws -> [UInt8] {
        guard count >= 12 else { return [] }
        let header = try le32(buf, start)
        let length = Int(header & 0x3FFF_FFFF)
        if header & 0x8000_0000 != 0 {
            // Stored inline, right after the descriptor.
            let n = min(length, count - 12)
            return Array(buf[(start + 12)..<(start + 12 + n)])
        }
        var pointer = try le32(buf, start + 4)
        if header & 0x4000_0000 != 0 {
            // Whole value in one row of a long-value page.
            let pg = try page(Int(pointer >> 8))
            let r = try rowRange(in: pg, row: Int(pointer & 0xFF))
            return Array(pg[r.start..<min(r.end, r.start + length)])
        }
        // Chain of rows, each starting with a pointer to the next.
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var hops = 0
        while pointer != 0 && out.count < length {
            hops += 1
            guard hops <= 1_000_000 else { throw MDBError.corrupt("long value chain loop") }
            let pg = try page(Int(pointer >> 8))
            let r = try rowRange(in: pg, row: Int(pointer & 0xFF))
            guard r.end - r.start >= 4 else { break }
            pointer = try le32(pg, r.start)
            out.append(contentsOf: pg[(r.start + 4)..<r.end])
        }
        if out.count > length { out.removeLast(out.count - length) }
        return out
    }
}
