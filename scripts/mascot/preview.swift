// Uso: swift preview.swift <modelo.usdz> <salida.png> [grados de giro]
import SceneKit
import AppKit

let args = CommandLine.arguments
let scene = try SCNScene(url: URL(fileURLWithPath: args[1]))
let pivot = SCNNode()
scene.rootNode.childNodes.forEach { pivot.addChildNode($0) }
scene.rootNode.addChildNode(pivot)
pivot.eulerAngles.y = CGFloat((args.count > 3 ? Double(args[3])! : 0) * .pi / 180)
let camera = SCNNode()
camera.camera = SCNCamera(); camera.camera!.fieldOfView = 30; camera.position = SCNVector3(0, 0, 2.2)
scene.rootNode.addChildNode(camera)
let key = SCNNode()
key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 900; key.eulerAngles = SCNVector3(-0.6, 0.4, 0)
scene.rootNode.addChildNode(key)
let ambient = SCNNode()
ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 500
scene.rootNode.addChildNode(ambient)
scene.background.contents = NSColor(white: 0.12, alpha: 1)
let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = scene; renderer.pointOfView = camera
let image = renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 512), antialiasingMode: .multisampling4X)
try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[2]))
