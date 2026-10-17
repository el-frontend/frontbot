// Uso: swift cutout.swift <dibujo.jpeg> <logo.png>
// Aísla la mascota del fondo (como "aislar sujeto" en Fotos) y la guarda recortada a 512 px como máximo.
import Vision
import CoreImage

let args = CommandLine.arguments
guard args.count == 3, let source = CIImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    print("Uso: swift cutout.swift <dibujo.jpeg> <logo.png>"); exit(2)
}
let handler = VNImageRequestHandler(ciImage: source)
let request = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([request])
guard let result = request.results?.first, !result.allInstances.isEmpty else { print("✗ Vision no encontró la mascota en el dibujo."); exit(1) }
let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
var cut = CIImage(cvPixelBuffer: buffer)
let scale = min(1, 512 / max(cut.extent.width, cut.extent.height))
cut = cut.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
try CIContext().writePNGRepresentation(of: cut, to: URL(fileURLWithPath: args[2]), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
print("✓ \(args[2]): \(Int(cut.extent.width))×\(Int(cut.extent.height))")
