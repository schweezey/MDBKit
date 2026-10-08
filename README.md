
# MDBKit

Pure-Swift, read-only access to Microsoft Access databases. No dependencies beyond Foundation,
no mdbtools, no ODBC.

```swift
import MDBKit

let db = try MDBDatabase(url: url)
print(try db.tableNames())

let table = try db.table(named: "Customers")
for column in table.columns { print(column.name, column.type) }

try table.forEachRow { row in
    let name = row["CompanyName"]?.stringValue
    let id   = row["ID"]?.intValue
    print(id ?? 0, name ?? "")
}
```

Add it to an app with *File ▸ Add Package Dependencies ▸ Add Local…*, or in `Package.swift`:
`.package(path: "../MDBKit")`.

## Supported

- Access 97 (Jet 3), 2000–2003 (Jet 4) `.mdb`, and unencrypted 2007+ `.accdb`
- "Encoded" Jet databases (the RC4 page obfuscation); database passwords on `.mdb` files do not block reading
- All scalar column types, memo and OLE fields of any length, rows relocated to overflow pages

## Not supported

- Writing
- Password-encrypted `.accdb` files (throws `MDBError.encrypted`)
- Queries, relationships, indexes (tables are scanned in storage order)
- Attachment and multi-value fields: the cell is returned as its integer link id

## Command-line check

    swift run mdbdump path/to/file.mdb            # list tables
    swift run mdbdump path/to/file.mdb TableName  # dump as CSV

    MDB_TEST_FILE=path/to/file.mdb swift test     # reads every table and checks row counts
