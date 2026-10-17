// Uso: swift make-icon.swift <logo.png> <icono-1024.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]) else { print("Uso: swift make-icon.swift <logo.png> <salida.png>"); exit(2) }
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // Margen y radio de la plantilla de iconos de macOS (824 px de 1024, radio ~185).
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185).fill()
    let w = plate.width * 0.78, h = w * logo.size.height / logo.size.width
    logo.draw(in: NSRect(x: plate.midX - w / 2, y: plate.midY - h / 2, width: w, height: h))
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("✓ \(args[2])")
