//
//  main.swift
//  MDBKit
//
//  Created by Josh McBroom on 10/7/26.
//

import Foundation
import MDBKit

// Usage:
//   mdbdump file.mdb            list tables with column and row counts
//   mdbdump file.mdb TableName  print the table as CSV

func csv(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: mdbdump <file.mdb> [table]\n".data(using: .utf8)!)
    exit(2)
}

do {
    let db = try MDBDatabase(path: args[1])
    if args.count >= 3 {
        let table = try db.table(named: args[2])
        print(table.columns.map { csv($0.name) }.joined(separator: ","))
        try table.forEachRow { row in
            print(row.values.map { csv($0.description) }.joined(separator: ","))
        }
    } else {
        print("Format: \(db.version)")
        for table in try db.tables() {
            print("\(table.name)\t\(table.columns.count) columns\t\(table.rowCount) rows")
        }
    }
} catch {
    FileHandle.standardError.write("mdbdump: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
