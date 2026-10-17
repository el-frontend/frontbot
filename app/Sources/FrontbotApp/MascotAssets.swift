import AppKit
import FrontbotCore

/// Archivos de la mascota de esta app (los copia build-app.sh; con `swift run` se leen de las fuentes).
enum MascotAssets {
    private static let candidates: [URL] = [
        Bundle.main.resourceURL?.appendingPathComponent("Mascot", isDirectory: true),
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Mascot", isDirectory: true),
    ].compactMap { $0 }

    static var model: URL? { MascotResources.locate("frontbot.usdz", candidates: candidates) }
    static let logo: NSImage? = MascotResources.locate("logo.png", candidates: candidates).flatMap(NSImage.init(contentsOf:))
}
