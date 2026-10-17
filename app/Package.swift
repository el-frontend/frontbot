// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Frontbot",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FrontbotCore", targets: ["FrontbotCore"]),
        .executable(name: "FrontbotApp", targets: ["FrontbotApp"]),
    ],
    dependencies: [
        .package(path: "Vendor/GRDB"), // GRDB.swift 7.11.1 vendorizado
    ],
    targets: [
        .target(name: "FrontbotCore", dependencies: [.product(name: "GRDB", package: "GRDB")]),
        // Los recursos de la mascota los copia build-app.sh (Bundle.module no funciona dentro de un .app).
        .executableTarget(name: "FrontbotApp", dependencies: ["FrontbotCore"], exclude: ["Resources"]),
        .testTarget(name: "FrontbotCoreTests", dependencies: ["FrontbotCore"]),
    ]
)
