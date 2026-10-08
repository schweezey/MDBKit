//
//  Support.swift
//  MDBKit
//
//  Created by Josh McBroom on 10/7/26.
//

import Foundation

/// Errors thrown while opening or reading an Access database.
public enum MDBError: Error, LocalizedError, Equatable {
    case notAnAccessDatabase
    case unsupportedVersion(UInt8)
    case encrypted
    case tableNotFound(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notAnAccessDatabase: return "The file is not a Microsoft Access (Jet/ACE) database."
        case .unsupportedVersion(let v): return "Unsupported Access file format version (\(v))."
        case .encrypted: return "The database is encrypted with a scheme this library cannot read."
        case .tableNotFound(let n): return "No table named \"\(n)\" in the database."
        case .corrupt(let why): return "The database appears to be damaged: \(why)"
        }
    }
}

// MARK: - Bounds-checked little-endian readers

@inline(__always)
func u8(_ b: [UInt8], _ o: Int) throws -> Int {
    guard o >= 0, o < b.count else { throw MDBError.corrupt("read past end of buffer") }
    return Int(b[o])
}

@inline(__always)
func le16(_ b: [UInt8], _ o: Int) throws -> Int {
    guard o >= 0, o + 2 <= b.count else { throw MDBError.corrupt("read past end of buffer") }
    return Int(b[o]) | (Int(b[o + 1]) << 8)
}

@inline(__always)
func le32(_ b: [UInt8], _ o: Int) throws -> UInt32 {
    guard o >= 0, o + 4 <= b.count else { throw MDBError.corrupt("read past end of buffer") }
    return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}

@inline(__always)
func le64(_ b: [UInt8], _ o: Int) throws -> UInt64 {
    let lo = UInt64(try le32(b, o))
    let hi = UInt64(try le32(b, o + 4))
    return lo | (hi << 32)
}

// MARK: - RC4 (used by Jet for the file header and for "encoded" databases)

struct RC4 {
    private var s: [UInt8]
    private var i: UInt8 = 0
    private var j: UInt8 = 0

    init(key: [UInt8]) {
        precondition(!key.isEmpty)
        s = (0...255).map { UInt8($0) }
        var j: UInt8 = 0
        for i in 0..<256 {
            j = j &+ s[i] &+ key[i % key.count]
            s.swapAt(i, Int(j))
        }
    }

    mutating func apply(_ buf: inout [UInt8], range: Range<Int>) {
        for n in range {
            i = i &+ 1
            j = j &+ s[Int(i)]
            s.swapAt(Int(i), Int(j))
            let k = s[Int(s[Int(i)] &+ s[Int(j)])]
            buf[n] ^= k
        }
    }
}

// MARK: - On-disk layout constants

struct JetFormat {
    let isJet3: Bool
    let pageSize: Int

    // Data page
    let dataRowCountOffset: Int
    // Table definition page
    let tdefRowCount: Int
    let tdefVarColCount: Int
    let tdefColCount: Int
    let tdefRealIndexCount: Int
    let tdefColumnsStart: Int
    let realIndexEntrySize: Int
    let columnEntrySize: Int
    // Column entry
    let colNumber: Int
    let colVarIndex: Int
    let colPrecision: Int
    let colScale: Int
    let colFlags: Int
    let colFixedOffset: Int
    let colSize: Int

    static let jet3 = JetFormat(
        isJet3: true, pageSize: 2048, dataRowCountOffset: 0x08,
        tdefRowCount: 12, tdefVarColCount: 23, tdefColCount: 25, tdefRealIndexCount: 31,
        tdefColumnsStart: 43, realIndexEntrySize: 8, columnEntrySize: 18,
        colNumber: 1, colVarIndex: 3, colPrecision: 9, colScale: 10,
        colFlags: 13, colFixedOffset: 14, colSize: 16)

    static let jet4 = JetFormat(
        isJet3: false, pageSize: 4096, dataRowCountOffset: 0x0C,
        tdefRowCount: 16, tdefVarColCount: 43, tdefColCount: 45, tdefRealIndexCount: 51,
        tdefColumnsStart: 63, realIndexEntrySize: 12, columnEntrySize: 25,
        colNumber: 5, colVarIndex: 7, colPrecision: 11, colScale: 12,
        colFlags: 15, colFixedOffset: 21, colSize: 23)
}
