// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "MDBKit",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "MDBKit", targets: ["MDBKit"]),
        .executable(name: "mdbdump", targets: ["mdbdump"]),
    ],
    targets: [
        .target(name: "MDBKit"),
        .executableTarget(name: "mdbdump", dependencies: ["MDBKit"]),
        .testTarget(name: "MDBKitTests", dependencies: ["MDBKit"]),
    ]
)
