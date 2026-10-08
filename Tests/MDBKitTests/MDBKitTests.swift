import XCTest
@testable import MDBKit

final class MDBKitTests: XCTestCase {

    func testRC4KnownVector() {
        var rc4 = RC4(key: Array("Key".utf8))
        var buf = Array("Plaintext".utf8)
        rc4.apply(&buf, range: 0..<buf.count)
        XCTAssertEqual(buf, [0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3])
    }

    func testCompressedText() {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x41, 0x42, 0x00, 0xAC, 0x20, 0x00, 0x43]
        XCTAssertEqual(MDBTable.decodeJet4Text(bytes, 0, bytes.count), "AB\u{20AC}C")
    }

    func testPlainUTF16Text() {
        let bytes: [UInt8] = [0x48, 0x00, 0x69, 0x00]
        XCTAssertEqual(MDBTable.decodeJet4Text(bytes, 0, bytes.count), "Hi")
    }

    func testDates() {
        XCTAssertEqual(MDBTable.date(fromAccessDays: 25569).timeIntervalSince1970, 0)
        XCTAssertEqual(MDBTable.date(fromAccessDays: 25569.5).timeIntervalSince1970, 43200)
        // Before the epoch day the fraction still counts forward: -1.25 is 1899-12-29 06:00.
        XCTAssertEqual(MDBTable.date(fromAccessDays: -1.25).timeIntervalSince1970,
                       (-1 - 25569) * 86400 + 21600)
    }

    func testRejectsNonDatabase() {
        XCTAssertThrowsError(try MDBDatabase(data: Data(count: 8192))) { error in
            XCTAssertEqual(error as? MDBError, .notAnAccessDatabase)
        }
    }

    /// Set MDB_TEST_FILE to a real database to smoke-test every table in it.
    func testRealFile() throws {
        guard let path = ProcessInfo.processInfo.environment["MDB_TEST_FILE"] else {
            throw XCTSkip("MDB_TEST_FILE not set")
        }
        let db = try MDBDatabase(path: path)
        let tables = try db.tables()
        XCTAssertFalse(tables.isEmpty)
        for table in tables {
            let rows = try table.rows()
            XCTAssertEqual(rows.count, table.rowCount, "row count mismatch in \(table.name)")
        }
    }
}
