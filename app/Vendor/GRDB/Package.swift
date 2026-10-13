// swift-tools-version:6.1
// GRDB.swift v7.11.1 vendorizado (https://github.com/groue/GRDB.swift, MIT). Solo fuentes; sin tests ni docs.
import PackageDescription

let package = Package(
    name: "GRDB",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
    ],
    targets: [
        .systemLibrary(name: "GRDBSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "GRDB",
            dependencies: [.target(name: "GRDBSQLite")],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
