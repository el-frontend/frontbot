// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Frontbot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrontbotCore", targets: ["FrontbotCore"]),
        .executable(name: "FrontbotApp", targets: ["FrontbotApp"]),
    ],
    dependencies: [
        .package(path: "Vendor/GRDB"), // GRDB.swift 7.11.1 vendorizado
    ],
    targets: [
        .target(name: "FrontbotCore", dependencies: [.product(name: "GRDB", package: "GRDB")]),
        .executableTarget(name: "FrontbotApp", dependencies: ["FrontbotCore"]),
        .testTarget(name: "FrontbotCoreTests", dependencies: ["FrontbotCore"]),
    ]
)
