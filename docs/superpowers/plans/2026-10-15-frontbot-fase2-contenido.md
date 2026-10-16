# Frontbot Fase 2 — Contenido: imágenes, calendario, aprobación y guía de marca — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el usuario suba imágenes a cada marca, vea y apruebe los posts en un calendario semanal/mensual, edite cada post con validación en vivo, y cree la guía de marca con una entrevista guiada o a partir de un PDF; y que el agente recuerde la conversación del chat y pueda usar las imágenes de la marca.

**Architecture:** La lógica nueva vive en `FrontbotCore` con tests (importador de imágenes, edición de posts por el usuario, agrupación del calendario, extracción de texto de PDF, prompts guiados). El sidecar recibe un historial de conversación junto a cada run y una herramienta nueva para listar imágenes. La UI SwiftUI (sin tests automáticos en esta fase) se reorganiza en tres secciones: Marcas, Calendario y Chat.

**Tech Stack:** Swift 6.3, SwiftUI, GRDB (vendorizado), PDFKit, UniformTypeIdentifiers, XCTest · Node 24, TypeScript, Claude Agent SDK 0.3.x, zod 4, vitest.

**Spec:** `docs/superpowers/specs/2026-10-13-frontbot-design.md` (secciones 4, 5.1–5.4, 5.8, 6.2).

**Fuera de esta fase:** publicación asistida con Playwright y el estado `preparing` en la UI (Fase 3); notch, atajo global, vistas de tareas e ideas, empaquetado `.app` (Fase 4).

## Global Constraints

- Las mismas de la Fase 1 (`docs/superpowers/plans/2026-10-13-frontbot-fase1-base.md`), en particular: el agente **nunca** aprueba ni publica; secretos solo en Keychain; datos en `~/Library/Application Support/Frontbot/`.
- Imágenes admitidas: JPEG y PNG, máximo **8 MB** cada una (límite de Instagram, el más estricto de las dos redes). Se copian a `brands/<brand_id>/assets/<asset_id>.<ext>`.
- Guías desde PDF: se extraen como máximo **60 000 caracteres** de texto; si el PDF no tiene texto (escaneado) se muestra "Este PDF no tiene texto seleccionable." El PDF se guarda como `brand_asset` de tipo `guide_source`.
- Historial de chat enviado al agente: los últimos **20** mensajes de usuario/agente (sin mensajes de herramienta ni de error).
- El usuario puede editar el texto, las imágenes y la fecha de un post en `draft` o `approved`; el agente solo en `draft` (ya implementado).
- Los tests Swift que lanzan el sidecar se corren con `FRONTBOT_NODE=$(which node)` tras `cd agent && npm run build`.

## Review Focus

1. **Imagen con extensión engañosa** (un `.png` que en realidad es un PDF o un archivo de 0 bytes) — se rechaza por contenido, no por extensión. Test en Task 1.
2. **El agente adjunta una imagen de otra marca o un id inventado** a un borrador — falla con error legible y no modifica el post. Test en Task 2.
3. **Posts en el borde de la semana/mes y zona horaria** — un post el domingo 23:30 local cae en esa semana, no en la siguiente; la semana empieza en lunes. Test en Task 3.
4. **PDF escaneado sin texto o archivo que no es PDF** — error claro, no se lanza un run vacío. Test en Task 4.
5. **Historial con mensajes muy largos o muchos turnos** — se recorta a 20 mensajes y cada uno a 4 000 caracteres, para no reventar el contexto. Test en Task 5.

---

## Estructura de archivos

```
app/Sources/FrontbotCore/
├── Store/AssetImporter.swift        # NUEVO: validar y copiar imágenes/PDF, registrar brand_asset
├── Store/Repositories.swift         # MOD: assets(brandId:), updatePost(byUser), validación de media
├── Content/ContentCalendar.swift    # NUEVO: rangos semana/mes y agrupación de posts por día
├── Content/GuideSources.swift       # NUEVO: texto de PDF + prompts de entrevista y de PDF
├── Agent/ChatHistory.swift          # NUEVO: turnos de conversación recortados
├── Agent/AgentClient.swift          # MOD: run(prompt:brand:history:)
└── Agent/ToolHandler.swift          # MOD: brands_list_assets, media en create/update_draft
app/Sources/FrontbotApp/
├── AppModel.swift                   # MOD: secciones, posts, assets, guía, historial
├── RootView.swift                   # NUEVO: barra lateral con secciones
├── BrandDetailView.swift            # NUEVO: guía, imágenes, Entrevístame, desde PDF
├── CalendarView.swift               # NUEVO: semana/mes, filtros, sin fecha
├── PostEditorView.swift             # NUEVO: editar, contador, imágenes, aprobar/archivar
├── ChatView.swift                   # MOD: Enter no borra el borrador durante un run
├── BrandsView.swift                 # MOD: solo lista + hoja de nueva marca
└── FrontbotApp.swift                # MOD: usa RootView
agent/src/
├── tools.ts                         # MOD: brands_list_assets, media en drafts
├── runner.ts                        # MOD: history en RunParams y en el prompt
└── prompt.ts                        # MOD: buildUserPrompt(history, prompt)
```

---

### Task 1: Importador de imágenes y PDFs de marca

**Files:**
- Create: `app/Sources/FrontbotCore/Store/AssetImporter.swift`
- Modify: `app/Sources/FrontbotCore/Store/Repositories.swift` (añadir sección `// MARK: Assets`)
- Modify: `app/Sources/FrontbotCore/Store/AppPaths.swift` (añadir `assetsDir`)
- Test: `app/Tests/FrontbotCoreTests/AssetImporterTests.swift`

**Interfaces:**
- Consumes: `AppDatabase`, `BrandAsset`, `AppPaths`, `ValidationError`, `Date.dbNow()` (Fase 1).
- Produces:
  - `enum AssetKind: String, Sendable { case image, guideSource = "guide_source", logo }`
  - `AppPaths.assetsDir(_ brandId: String) -> URL` = `brandDir(brandId)/assets/`
  - `struct AssetImporter: Sendable { init(db: AppDatabase, paths: AppPaths); static let maxImageBytes = 8 * 1024 * 1024; func importImage(from url: URL, brandId: String) throws -> BrandAsset; func importGuidePDF(from url: URL, brandId: String) throws -> BrandAsset }`
  - `extension AppDatabase { func assets(brandId: String, kind: AssetKind?) throws -> [BrandAsset]; func asset(id: String) throws -> BrandAsset? }`
  - `BrandAsset.path` guarda la ruta absoluta del archivo copiado.
- Detección por contenido (bytes mágicos): JPEG `FF D8 FF`, PNG `89 50 4E 47 0D 0A 1A 0A`, PDF `25 50 44 46` (`%PDF`).
- Errores: `"La imagen pesa X MB; el máximo es 8 MB."` (X con 1 decimal), `"Formato no admitido: solo JPEG o PNG."`, `"El archivo no es un PDF."`, `"No existe marca con id <id>."`.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class AssetImporterTests: XCTestCase {
    var db: AppDatabase!
    var brand: Brand!
    var root: URL!
    var importer: AssetImporter!
    var tmp: URL!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        importer = AssetImporter(db: db, paths: AppPaths(root: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: tmp)
    }

    func write(_ bytes: [UInt8], padTo size: Int = 0, name: String) throws -> URL {
        var data = Data(bytes)
        if size > data.count { data.append(Data(count: size - data.count)) }
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]

    func testImportsPngAndCopiesItIntoBrandAssets() throws {
        let source = try write(Self.png, padTo: 1024, name: "foto.png")
        let asset = try importer.importImage(from: source, brandId: brand.id)
        XCTAssertEqual(asset.kind, AssetKind.image.rawValue)
        XCTAssertTrue(asset.path.hasPrefix(AppPaths(root: root).assetsDir(brand.id).path))
        XCTAssertTrue(asset.path.hasSuffix(".png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: asset.path)).count, 1024)
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: .image), [asset])
    }

    func testJpegWithWrongExtensionIsStoredAsJpg() throws {
        let source = try write(Self.jpeg, padTo: 100, name: "foto.png")
        XCTAssertTrue(try importer.importImage(from: source, brandId: brand.id).path.hasSuffix(".jpg"))
    }

    func testRejectsFakeImageByContent() throws {
        let pdfNamedPng = try write(Array("%PDF-1.4".utf8), name: "falso.png")
        XCTAssertThrowsError(try importer.importImage(from: pdfNamedPng, brandId: brand.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Formato no admitido: solo JPEG o PNG.")
        }
        let empty = try write([], name: "vacio.jpg")
        XCTAssertThrowsError(try importer.importImage(from: empty, brandId: brand.id))
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: nil), [])
    }

    func testRejectsImagesOver8MB() throws {
        let big = try write(Self.png, padTo: 8 * 1024 * 1024 + 1, name: "grande.png")
        XCTAssertThrowsError(try importer.importImage(from: big, brandId: brand.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La imagen pesa 8.0 MB; el máximo es 8 MB.")
        }
    }

    func testImportsGuidePdfAndRejectsNonPdf() throws {
        let pdf = try write(Array("%PDF-1.4\n".utf8), padTo: 200, name: "guia.pdf")
        let asset = try importer.importGuidePDF(from: pdf, brandId: brand.id)
        XCTAssertEqual(asset.kind, "guide_source")
        let notPdf = try write(Self.png, name: "guia.pdf")
        XCTAssertThrowsError(try importer.importGuidePDF(from: notPdf, brandId: brand.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "El archivo no es un PDF.")
        }
    }

    func testUnknownBrand() throws {
        let source = try write(Self.png, name: "a.png")
        XCTAssertThrowsError(try importer.importImage(from: source, brandId: UUID().uuidString))
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter AssetImporterTests`
Expected: FAIL — `cannot find 'AssetImporter' in scope`.

- [ ] **Step 3: Implementar**

`AppPaths.swift`, añadir dentro del struct:
```swift
    public func assetsDir(_ brandId: String) -> URL { brandDir(brandId).appendingPathComponent("assets", isDirectory: true) }
```

`Repositories.swift`, añadir al final de la extensión (antes de la última `}`):
```swift
    // MARK: Assets
    public func assets(brandId: String, kind: AssetKind?) throws -> [BrandAsset] {
        try writer.read { db in
            var request = BrandAsset.filter(Column("brandId") == brandId)
            if let kind { request = request.filter(Column("kind") == kind.rawValue) }
            return try request.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func asset(id: String) throws -> BrandAsset? {
        try writer.read { try BrandAsset.fetchOne($0, key: id) }
    }

    func insertAsset(_ asset: BrandAsset) throws {
        try writer.write { try asset.insert($0) }
    }
```

`AssetImporter.swift`:
```swift
import Foundation

public enum AssetKind: String, Sendable {
    case image
    case guideSource = "guide_source"
    case logo
}

/// Copia archivos del usuario a la carpeta de la marca y los registra como `brand_asset`.
/// El tipo se detecta por contenido (bytes mágicos), nunca por la extensión.
public struct AssetImporter: Sendable {
    public static let maxImageBytes = 8 * 1024 * 1024
    let db: AppDatabase
    let paths: AppPaths

    public init(db: AppDatabase, paths: AppPaths) {
        self.db = db
        self.paths = paths
    }

    public func importImage(from url: URL, brandId: String) throws -> BrandAsset {
        try requireBrand(brandId)
        let data = try Data(contentsOf: url)
        if data.count > Self.maxImageBytes {
            let mb = Double(data.count) / 1_048_576
            throw ValidationError("La imagen pesa \(String(format: "%.1f", mb)) MB; el máximo es 8 MB.")
        }
        let ext: String
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { ext = "jpg" }
        else if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { ext = "png" }
        else { throw ValidationError("Formato no admitido: solo JPEG o PNG.") }
        return try store(data, ext: ext, kind: .image, brandId: brandId)
    }

    public func importGuidePDF(from url: URL, brandId: String) throws -> BrandAsset {
        try requireBrand(brandId)
        let data = try Data(contentsOf: url)
        guard data.starts(with: Array("%PDF".utf8)) else { throw ValidationError("El archivo no es un PDF.") }
        return try store(data, ext: "pdf", kind: .guideSource, brandId: brandId)
    }

    private func requireBrand(_ brandId: String) throws {
        guard try db.brand(id: brandId) != nil else { throw ValidationError("No existe marca con id \(brandId).") }
    }

    private func store(_ data: Data, ext: String, kind: AssetKind, brandId: String) throws -> BrandAsset {
        let id = UUID().uuidString
        let dir = paths.assetsDir(brandId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(id).\(ext)")
        try data.write(to: dest, options: .atomic)
        let asset = BrandAsset(id: id, brandId: brandId, kind: kind.rawValue, path: dest.path, createdAt: .dbNow())
        do {
            try db.insertAsset(asset)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return asset
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd app && swift test --filter AssetImporterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat: import brand images and guide PDFs with content-based validation"
```

---

### Task 2: Posts con imágenes y edición por el usuario

**Files:**
- Modify: `app/Sources/FrontbotCore/Store/Repositories.swift` (createDraft/updateDraft validan media; nuevo `updatePostByUser`)
- Modify: `app/Sources/FrontbotCore/Agent/ToolHandler.swift` (`brands_list_assets`; `media` en `posts_create_draft` y `posts_update_draft`)
- Modify: `agent/src/tools.ts` (spec de `brands_list_assets`; `media` opcional)
- Test: `app/Tests/FrontbotCoreTests/PostMediaTests.swift`, `agent/test/tools.test.ts`

**Interfaces:**
- Consumes: `assets(brandId:kind:)`, `asset(id:)` (Task 1).
- Produces:
  - `AppDatabase.updatePostByUser(id: String, body: String?, media: [String]?, scheduledFor: Date??) throws -> Post` — permitido en `draft` y `approved`; `scheduledFor: .some(nil)` borra la fecha.
  - Regla compartida: todo id de `media` debe ser un `brand_asset` de tipo `image` de **la misma marca** del post; si no: `ValidationError("La imagen <id> no pertenece a esta marca.")`. Máximo 10 imágenes por post: `"Un post admite máximo 10 imágenes."`.
  - Herramienta `tool.brands_list_assets {"brand_id"}` → `{"assets":[{"id","kind","file_name"}]}` (solo nombre de archivo, nunca la ruta completa).
  - `tool.posts_create_draft` y `tool.posts_update_draft` aceptan `"media": [asset_id]` opcional.
  - En TS: `TOOL_SPECS` gana `brands_list_assets` (11 herramientas) y `media: z.array(z.string()).optional()` en ambos drafts.

- [ ] **Step 1: Escribir los tests que fallan**

`app/Tests/FrontbotCoreTests/PostMediaTests.swift`:
```swift
import XCTest
@testable import FrontbotCore

final class PostMediaTests: XCTestCase {
    var db: AppDatabase!
    var a: Brand!
    var b: Brand!
    var imgA: BrandAsset!
    var imgB: BrandAsset!
    var root: URL!
    var handler: ToolHandler!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        a = try db.createBrand(workspaceId: ws.id, name: "A", industry: "", networks: [.instagram])
        b = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let importer = AssetImporter(db: db, paths: AppPaths(root: root))
        let png = root.appendingPathComponent("x.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
        imgA = try importer.importImage(from: png, brandId: a.id)
        imgB = try importer.importImage(from: png, brandId: b.id)
        handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDraftAcceptsOwnBrandImage() throws {
        let post = try db.createDraft(brandId: a.id, network: .instagram, body: "hola", media: [imgA.id], scheduledFor: nil)
        XCTAssertEqual(post.media, [imgA.id])
    }

    func testDraftRejectsOtherBrandOrUnknownImage() throws {
        XCTAssertThrowsError(try db.createDraft(brandId: a.id, network: .instagram, body: "hola", media: [imgB.id], scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La imagen \(self.imgB.id) no pertenece a esta marca.")
        }
        let post = try db.createDraft(brandId: a.id, network: .instagram, body: "hola", media: [], scheduledFor: nil)
        XCTAssertThrowsError(try db.updateDraft(id: post.id, body: nil, media: ["inventado"], scheduledFor: nil))
        XCTAssertEqual(try db.posts(brandId: a.id, status: nil).first?.media, [])
    }

    func testAtMostTenImages() throws {
        XCTAssertThrowsError(try db.createDraft(brandId: a.id, network: .instagram, body: "hola", media: Array(repeating: imgA.id, count: 11), scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Un post admite máximo 10 imágenes.")
        }
    }

    func testUserCanEditApprovedPostAndClearDate() throws {
        let post = try db.createDraft(brandId: a.id, network: .instagram, body: "v1", media: [], scheduledFor: Date())
        _ = try db.transitionPost(id: post.id, to: .approved, actor: .user)
        let edited = try db.updatePostByUser(id: post.id, body: "v2", media: [imgA.id], scheduledFor: .some(nil))
        XCTAssertEqual(edited.body, "v2")
        XCTAssertEqual(edited.media, [imgA.id])
        XCTAssertNil(edited.scheduledFor)
        XCTAssertEqual(edited.status, .approved)
    }

    func testUserCannotEditPublishedPost() throws {
        let post = try db.createDraft(brandId: a.id, network: .instagram, body: "v1", media: [], scheduledFor: nil)
        _ = try db.transitionPost(id: post.id, to: .archived, actor: .user)
        XCTAssertThrowsError(try db.updatePostByUser(id: post.id, body: "v2", media: nil, scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Este post ya no se puede editar (archived).")
        }
    }

    func testToolListsAssetsWithoutPaths() throws {
        let result = try handler.handle(method: "tool.brands_list_assets", params: ["brand_id": .string(a.id)])
        let first = result["assets"]?.arrayValue?.first
        XCTAssertEqual(first?["id"]?.stringValue, imgA.id)
        XCTAssertEqual(first?["file_name"]?.stringValue, "\(imgA.id).png")
        XCTAssertFalse(String(describing: result).contains(root.path))
    }

    func testToolCreateDraftWithMedia() throws {
        let created = try handler.handle(method: "tool.posts_create_draft", params: [
            "brand_id": .string(a.id), "network": "instagram", "body": "hola", "media": [.string(imgA.id)],
        ])
        XCTAssertEqual(try db.posts(brandId: a.id, status: nil).first { $0.id == created["post_id"]?.stringValue }?.media, [imgA.id])
    }
}
```

Añadir a `agent/test/tools.test.ts`, dentro del `describe`, y actualizar la lista esperada del primer test para incluir `"brands_list_assets"` (orden alfabético: después de `"brands_get_guide"`):
```ts
  it("draft tools accept optional media ids", () => {
    const create = TOOL_SPECS.find((t) => t.name === "posts_create_draft")!;
    const update = TOOL_SPECS.find((t) => t.name === "posts_update_draft")!;
    expect(Object.keys(create.shape)).toContain("media");
    expect(Object.keys(update.shape)).toContain("media");
  });
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd app && swift test --filter PostMediaTests` y `cd agent && npx vitest run test/tools.test.ts`
Expected: Swift FAIL de compilación — `value of type 'AppDatabase' has no member 'updatePostByUser'`. TS FAIL en la lista de herramientas (falta `brands_list_assets`) y en `media`.

- [ ] **Step 3: Implementar en Swift**

En `Repositories.swift`, añadir dentro de `// MARK: Posts`:
```swift
    public static let maxMediaPerPost = 10

    private func checkMedia(_ media: [String], brandId: String) throws {
        guard media.count <= Self.maxMediaPerPost else { throw ValidationError("Un post admite máximo 10 imágenes.") }
        for id in media {
            guard let asset = try asset(id: id), asset.brandId == brandId, asset.kind == AssetKind.image.rawValue else {
                throw ValidationError("La imagen \(id) no pertenece a esta marca.")
            }
        }
    }

    public func updatePostByUser(id: String, body: String?, media: [String]?, scheduledFor: Date??) throws -> Post {
        guard var post = try writer.read({ try Post.fetchOne($0, key: id) }) else { throw notFound("post", id) }
        guard post.status == .draft || post.status == .approved else {
            throw ValidationError("Este post ya no se puede editar (\(post.status.rawValue)).")
        }
        if let body {
            try PostRules.validate(body: body, network: post.network)
            post.body = body
        }
        if let media {
            try checkMedia(media, brandId: post.brandId)
            post.media = media
        }
        if let scheduledFor { post.scheduledFor = scheduledFor }
        post.updatedAt = .dbNow()
        try writer.write { try post.update($0) }
        return post
    }
```

En `createDraft`, justo después de `try PostRules.validate(body: body, network: network)`:
```swift
        try checkMedia(media, brandId: brandId)
```

En `updateDraft`, reemplazar `if let media { post.media = media }` por:
```swift
            if let media {
                try checkMedia(media, brandId: post.brandId)
                post.media = media
            }
```
Nota: `updateDraft` corre dentro de `writer.write { db in ... }`; `checkMedia` usa `asset(id:)`, que hace `writer.read` — GRDB no permite un `read` anidado dentro de un `write` en `DatabaseQueue` (reentrancia). Para evitarlo, en `updateDraft` leer el post **fuera** del write y validar antes, siguiendo el mismo patrón que `updatePostByUser`:
```swift
    public func updateDraft(id: String, body: String?, media: [String]?, scheduledFor: Date?) throws -> Post {
        guard var post = try writer.read({ try Post.fetchOne($0, key: id) }) else { throw notFound("post", id) }
        guard post.status == .draft else {
            throw ValidationError("Solo se pueden editar posts en borrador; este está en \(post.status.rawValue).")
        }
        if let body {
            try PostRules.validate(body: body, network: post.network)
            post.body = body
        }
        if let media {
            try checkMedia(media, brandId: post.brandId)
            post.media = media
        }
        if let scheduledFor { post.scheduledFor = scheduledFor }
        post.updatedAt = .dbNow()
        return try writer.write { db in
            // Re-chequeo dentro de la transacción: el usuario pudo aprobarlo entre medio.
            guard let current = try Post.fetchOne(db, key: id), current.status == .draft else {
                throw ValidationError("Solo se pueden editar posts en borrador; este está en \(post.status.rawValue).")
            }
            try post.update(db)
            return post
        }
    }
```

En `ToolHandler.swift`, añadir el caso (antes de `case "tool.posts_list":`):
```swift
        case "tool.brands_list_assets":
            let id = try string(params, "brand_id")
            let assets = try db.assets(brandId: id, kind: nil)
            return ["assets": .array(assets.map { a in
                ["id": .string(a.id), "kind": .string(a.kind), "file_name": .string(URL(fileURLWithPath: a.path).lastPathComponent)]
            })]
```
y en `posts_create_draft` / `posts_update_draft` pasar `media`:
```swift
        case "tool.posts_create_draft":
            let post = try db.createDraft(
                brandId: try string(params, "brand_id"), network: try parseNetwork(try string(params, "network")),
                body: try string(params, "body"), media: mediaIds(params) ?? [], scheduledFor: try optionalDate(params, "scheduled_for"))
            return ["post_id": .string(post.id)]
        case "tool.posts_update_draft":
            _ = try db.updateDraft(id: try string(params, "post_id"), body: params["body"]?.stringValue,
                                   media: mediaIds(params), scheduledFor: try optionalDate(params, "scheduled_for"))
            return ["ok": true]
```
con el helper:
```swift
    private func mediaIds(_ params: JSONValue) -> [String]? {
        params["media"]?.arrayValue?.compactMap(\.stringValue)
    }
```

- [ ] **Step 4: Implementar en TS**

En `agent/src/tools.ts`, en `TOOL_SPECS`, añadir tras `brands_write_guide`:
```ts
  { name: "brands_list_assets", description: "Lista las imágenes y archivos de una marca (id, tipo, nombre). Usa los id de tipo image en media.", shape: { brand_id: z.string() } },
```
y en los dos drafts añadir `media: z.array(z.string()).optional()` a `shape`:
```ts
  { name: "posts_create_draft", description: "Crea un post en borrador para una marca. No lo publica: el usuario lo revisa y aprueba. media: ids de imágenes de la marca (máx. 10).", shape: { brand_id: z.string(), network, body: z.string(), scheduled_for: date.optional(), media: z.array(z.string()).optional() } },
  { name: "posts_update_draft", description: "Edita un post que sigue en borrador.", shape: { post_id: z.string(), body: z.string().optional(), scheduled_for: date.optional(), media: z.array(z.string()).optional() } },
```

- [ ] **Step 5: Correr y verificar que pasa**

Run: `cd agent && npx vitest run && npm run build && cd ../app && FRONTBOT_NODE=$(which node) swift test`
Expected: PASS — vitest 16, Swift todos (incluye `StoreTests` y `ToolHandlerTests` de Fase 1 sin cambios).

- [ ] **Step 6: Commit**

```bash
git add app agent/src agent/test
git commit -m "feat: attach brand images to posts and let the user edit approved posts"
```

---

### Task 3: Calendario de contenido (lógica)

**Files:**
- Create: `app/Sources/FrontbotCore/Content/ContentCalendar.swift`
- Test: `app/Tests/FrontbotCoreTests/ContentCalendarTests.swift`

**Interfaces:**
- Consumes: `Post`, `Network`, `PostStatus`.
- Produces:
  - `enum CalendarScope: Sendable { case week, month }`
  - `struct CalendarDay: Identifiable, Equatable, Sendable { let date: Date; let inScope: Bool; let posts: [Post]; var id: Date { date } }`
  - `struct ContentCalendar: Sendable { init(calendar: Calendar = ContentCalendar.defaultCalendar()); static func defaultCalendar() -> Calendar; func range(_ scope: CalendarScope, containing date: Date) -> DateInterval; func days(_ scope: CalendarScope, containing date: Date, posts: [Post], brandId: String?, network: Network?) -> [CalendarDay]; func unscheduled(_ posts: [Post], brandId: String?, network: Network?) -> [Post]; func shift(_ date: Date, scope: CalendarScope, by n: Int) -> Date }`
- Reglas: semana de lunes a domingo (`firstWeekday = 2`), zona horaria local. `week` → 7 días. `month` → cuadrícula de semanas completas que cubren el mes (35 o 42 días); los días fuera del mes tienen `inScope == false`. Posts `archived` se excluyen de todo. Dentro de un día, posts ordenados por `scheduledFor`.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class ContentCalendarTests: XCTestCase {
    var cal: Calendar!
    var content: ContentCalendar!

    override func setUp() {
        cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Mexico_City")!
        cal.firstWeekday = 2
        content = ContentCalendar(calendar: cal)
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func post(_ at: Date?, brand: String = "b1", network: Network = .instagram, status: PostStatus = .draft) -> Post {
        Post(id: UUID().uuidString, brandId: brand, network: network, body: "x", media: [], status: status,
             scheduledFor: at, publishedUrl: nil, createdAt: Date(), updatedAt: Date())
    }

    func testWeekStartsOnMonday() {
        // Miércoles 14 de octubre de 2026 → semana lunes 12 a domingo 18.
        let days = content.days(.week, containing: date(2026, 10, 14), posts: [], brandId: nil, network: nil)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first?.date, cal.startOfDay(for: date(2026, 10, 12)))
        XCTAssertEqual(days.last?.date, cal.startOfDay(for: date(2026, 10, 18)))
    }

    func testSundayLateNightStaysInThatWeek() {
        let late = post(date(2026, 10, 18, 23, 30))
        let days = content.days(.week, containing: date(2026, 10, 14), posts: [late], brandId: nil, network: nil)
        XCTAssertEqual(days.last?.posts, [late])
        let next = content.days(.week, containing: date(2026, 10, 19), posts: [late], brandId: nil, network: nil)
        XCTAssertTrue(next.allSatisfy { $0.posts.isEmpty })
    }

    func testMonthGridCoversWholeWeeksAndMarksOutOfScope() {
        // Octubre 2026: 1 = jueves, 31 = sábado → del lunes 28 sep al domingo 1 nov = 35 días.
        let days = content.days(.month, containing: date(2026, 10, 14), posts: [], brandId: nil, network: nil)
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(days.first?.date, cal.startOfDay(for: date(2026, 9, 28)))
        XCTAssertFalse(days.first!.inScope)
        XCTAssertTrue(days[3].inScope) // 1 de octubre
        XCTAssertFalse(days.last!.inScope)
    }

    func testFiltersAndExcludesArchived() {
        let ig = post(date(2026, 10, 14), brand: "b1", network: .instagram)
        let li = post(date(2026, 10, 14, 10), brand: "b1", network: .linkedin)
        let other = post(date(2026, 10, 14), brand: "b2")
        let archived = post(date(2026, 10, 14), status: .archived)
        let days = content.days(.week, containing: date(2026, 10, 14), posts: [li, ig, other, archived], brandId: "b1", network: nil)
        XCTAssertEqual(days[2].posts, [ig, li]) // ordenados por hora
        let onlyLi = content.days(.week, containing: date(2026, 10, 14), posts: [li, ig], brandId: nil, network: .linkedin)
        XCTAssertEqual(onlyLi[2].posts, [li])
    }

    func testUnscheduled() {
        let a = post(nil)
        let b = post(date(2026, 10, 14))
        let c = post(nil, status: .archived)
        XCTAssertEqual(content.unscheduled([a, b, c], brandId: nil, network: nil), [a])
    }

    func testShift() {
        XCTAssertEqual(cal.component(.day, from: content.shift(date(2026, 10, 14), scope: .week, by: 1)), 21)
        XCTAssertEqual(cal.component(.month, from: content.shift(date(2026, 10, 31), scope: .month, by: 1)), 11)
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter ContentCalendarTests`
Expected: FAIL — `cannot find 'ContentCalendar' in scope`.

- [ ] **Step 3: Implementar**

```swift
import Foundation

public enum CalendarScope: Sendable {
    case week, month
}

public struct CalendarDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public let inScope: Bool
    public let posts: [Post]
    public var id: Date { date }
}

/// Agrupa posts por día para las vistas semanal y mensual. Semana de lunes a domingo, hora local.
public struct ContentCalendar: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar = ContentCalendar.defaultCalendar()) {
        self.calendar = calendar
    }

    public static func defaultCalendar() -> Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    public func range(_ scope: CalendarScope, containing date: Date) -> DateInterval {
        switch scope {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!
            let start = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
            let lastDay = calendar.date(byAdding: .second, value: -1, to: month.end)!
            let end = calendar.dateInterval(of: .weekOfYear, for: lastDay)!.end
            return DateInterval(start: start, end: end)
        }
    }

    public func days(_ scope: CalendarScope, containing date: Date, posts: [Post], brandId: String?, network: Network?) -> [CalendarDay] {
        let interval = range(scope, containing: date)
        let month = calendar.dateInterval(of: .month, for: date)!
        let visible = filter(posts, brandId: brandId, network: network)
        var result: [CalendarDay] = []
        var day = interval.start
        while day < interval.end {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let dayPosts = visible
                .filter { p in p.scheduledFor.map { $0 >= day && $0 < next } ?? false }
                .sorted { ($0.scheduledFor ?? .distantPast) < ($1.scheduledFor ?? .distantPast) }
            let inScope = scope == .week || month.contains(day)
            result.append(CalendarDay(date: day, inScope: inScope, posts: dayPosts))
            day = next
        }
        return result
    }

    public func unscheduled(_ posts: [Post], brandId: String?, network: Network?) -> [Post] {
        filter(posts, brandId: brandId, network: network).filter { $0.scheduledFor == nil }
    }

    public func shift(_ date: Date, scope: CalendarScope, by n: Int) -> Date {
        calendar.date(byAdding: scope == .week ? .weekOfYear : .month, value: n, to: date)!
    }

    private func filter(_ posts: [Post], brandId: String?, network: Network?) -> [Post] {
        posts.filter { p in
            p.status != .archived
                && (brandId == nil || p.brandId == brandId)
                && (network == nil || p.network == network)
        }
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd app && swift test --filter ContentCalendarTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat: add week/month content calendar grouping"
```

---

### Task 4: Fuentes de guía — texto de PDF y prompts guiados

**Files:**
- Create: `app/Sources/FrontbotCore/Content/GuideSources.swift`
- Test: `app/Tests/FrontbotCoreTests/GuideSourcesTests.swift`

**Interfaces:**
- Produces:
  - `enum GuideSources { static let maxPDFCharacters = 60_000; static func text(fromPDF url: URL) throws -> String; static func interviewPrompt(brandName: String) -> String; static func pdfPrompt(brandName: String, pdfText: String) -> String }`
  - Errores: `"No se pudo abrir el PDF."`, `"Este PDF no tiene texto seleccionable."`.
  - Los prompts piden explícitamente guardar con `brands_write_guide` y las secciones: Tono de voz, Público, Pilares de contenido, Palabras sí / palabras no, Ejemplos.
  - `pdfPrompt` recorta el texto a `maxPDFCharacters` y añade `"[texto recortado]"` si se recortó.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
import AppKit
@testable import FrontbotCore

final class GuideSourcesTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// PDF de una página con texto real, dibujado con AppKit.
    func makePDF(text: String?) throws -> URL {
        let url = tmp.appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        if let text {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    func testExtractsTextFromPDF() throws {
        let url = try makePDF(text: "Tono cercano y cálido")
        XCTAssertTrue(try GuideSources.text(fromPDF: url).contains("Tono cercano y cálido"))
    }

    func testPDFWithoutTextFails() throws {
        let url = try makePDF(text: nil)
        XCTAssertThrowsError(try GuideSources.text(fromPDF: url)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Este PDF no tiene texto seleccionable.")
        }
    }

    func testNonPDFFails() throws {
        let url = tmp.appendingPathComponent("x.pdf")
        try Data("hola".utf8).write(to: url)
        XCTAssertThrowsError(try GuideSources.text(fromPDF: url)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "No se pudo abrir el PDF.")
        }
    }

    func testPromptsMentionToolAndSections() {
        for p in [GuideSources.interviewPrompt(brandName: "Café Sol"), GuideSources.pdfPrompt(brandName: "Café Sol", pdfText: "x")] {
            XCTAssertTrue(p.contains("Café Sol"))
            XCTAssertTrue(p.contains("brands_write_guide"))
            for section in ["Tono de voz", "Público", "Pilares de contenido", "Palabras sí / palabras no", "Ejemplos"] {
                XCTAssertTrue(p.contains(section), section)
            }
        }
        XCTAssertTrue(GuideSources.interviewPrompt(brandName: "X").contains("una pregunta a la vez"))
    }

    func testPdfPromptTruncatesLongText() {
        let long = String(repeating: "a", count: GuideSources.maxPDFCharacters + 10)
        let p = GuideSources.pdfPrompt(brandName: "X", pdfText: long)
        XCTAssertTrue(p.contains("[texto recortado]"))
        XCTAssertFalse(p.contains(long))
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter GuideSourcesTests`
Expected: FAIL — `cannot find 'GuideSources' in scope`.

- [ ] **Step 3: Implementar**

```swift
import Foundation
import PDFKit

/// Material para crear la guía de marca: texto de un PDF y los prompts que guían al agente.
public enum GuideSources {
    public static let maxPDFCharacters = 60_000

    static let sections = "## Tono de voz, ## Público, ## Pilares de contenido, ## Palabras sí / palabras no, ## Ejemplos"

    public static func text(fromPDF url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ValidationError("No se pudo abrir el PDF.") }
        let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError("Este PDF no tiene texto seleccionable.") }
        return text
    }

    public static func interviewPrompt(brandName: String) -> String {
        """
        Entrevístame para crear la guía de marca de \(brandName). Hazme una pregunta a la vez y espera mi respuesta \
        antes de la siguiente; cubre tono, público, pilares de contenido, palabras que sí y que no usamos, y ejemplos \
        de publicaciones que nos gustan. Cuando tengas suficiente (máximo 8 preguntas), escribe la guía en markdown con \
        estas secciones: \(sections). Guárdala con brands_write_guide y muéstrame un resumen.
        """
    }

    public static func pdfPrompt(brandName: String, pdfText: String) -> String {
        let clipped = pdfText.count > maxPDFCharacters
            ? String(pdfText.prefix(maxPDFCharacters)) + "\n[texto recortado]"
            : pdfText
        return """
        Este es el texto de la guía de marca de \(brandName), extraído de un PDF. Conviértelo en una guía en markdown con \
        estas secciones: \(sections). No inventes datos que no estén en el texto; si falta una sección, déjala con \
        "(por definir)". Guárdala con brands_write_guide y dime qué secciones quedaron por definir.

        --- TEXTO DEL PDF ---
        \(clipped)
        """
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd app && swift test --filter GuideSourcesTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat: extract guide text from PDFs and add guided guide prompts"
```

---

### Task 5: Memoria del chat (historial enviado al agente)

**Files:**
- Create: `app/Sources/FrontbotCore/Agent/ChatHistory.swift`
- Modify: `app/Sources/FrontbotCore/Agent/AgentClient.swift` (`run(prompt:brand:history:)`)
- Modify: `agent/src/runner.ts`, `agent/src/prompt.ts`
- Test: `app/Tests/FrontbotCoreTests/ChatHistoryTests.swift`, `agent/test/prompt.test.ts`, `agent/test/main.test.ts`

**Interfaces:**
- Produces:
  - Swift: `struct ChatTurn: Equatable, Sendable { enum Role: String, Sendable { case user, agent }; let role: Role; let text: String }`; `enum ChatHistory { static let maxTurns = 20; static let maxCharsPerTurn = 4_000; static func trimmed(_ turns: [ChatTurn]) -> [ChatTurn]; static func json(_ turns: [ChatTurn]) -> JSONValue }` — `trimmed` se queda con los últimos 20 y corta cada texto a 4 000 caracteres añadiendo `"…"`.
  - `AgentClient.run(prompt: String, brand: Brand?, history: [ChatTurn] = []) async throws -> AgentRun` — envía `"history": [{"role","text"}]` en `agent.run`.
  - TS: `RunParams.history?: { role: "user" | "agent"; text: string }[]`; `buildUserPrompt(history, prompt): string` — sin historial devuelve `prompt` tal cual; con historial devuelve `"Conversación hasta ahora:\nUsuario: …\nFrontbot: …\n\nMensaje nuevo del usuario:\n<prompt>"`. `RealRunner` pasa `buildUserPrompt(params.history ?? [], params.prompt)` como `prompt` de `query`. `FakeRunner` emite además un evento `text` `"Historial: N"` cuando N > 0.

- [ ] **Step 1: Escribir los tests que fallan**

`app/Tests/FrontbotCoreTests/ChatHistoryTests.swift`:
```swift
import XCTest
@testable import FrontbotCore

final class ChatHistoryTests: XCTestCase {
    func testKeepsLast20Turns() {
        let turns = (1...25).map { ChatTurn(role: $0 % 2 == 0 ? .agent : .user, text: "m\($0)") }
        let t = ChatHistory.trimmed(turns)
        XCTAssertEqual(t.count, 20)
        XCTAssertEqual(t.first?.text, "m6")
        XCTAssertEqual(t.last?.text, "m25")
    }

    func testClipsLongTurns() {
        let t = ChatHistory.trimmed([ChatTurn(role: .user, text: String(repeating: "é", count: 5_000))])
        XCTAssertEqual(t.first?.text.count, 4_001)
        XCTAssertEqual(t.first?.text.last, "…")
    }

    func testJSON() {
        XCTAssertEqual(ChatHistory.json([ChatTurn(role: .agent, text: "hola")]), [["role": "agent", "text": "hola"]])
    }

    func testFakeAgentReceivesHistory() async throws {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "usa FRONTBOT_NODE=$(which node)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = AgentClient(config: AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true),
                                 db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        let stream = await client.updates()
        let run = try await client.run(prompt: "hola", brand: nil, history: [ChatTurn(role: .user, text: "a"), ChatTurn(role: .agent, text: "b")])
        var texts: [String] = []
        for await update in stream {
            if case .event(let id, "text", let text) = update, id == run.id { texts.append(text) }
            if case .finished(let r) = update, r.id == run.id { break }
        }
        XCTAssertTrue(texts.contains("Historial: 2"))
        await client.stop()
    }
}
```

Añadir a `agent/test/prompt.test.ts`:
```ts
import { buildUserPrompt } from "../src/prompt.js";

describe("buildUserPrompt", () => {
  it("returns the prompt unchanged without history", () => {
    expect(buildUserPrompt([], "hola")).toBe("hola");
  });

  it("prefixes the conversation so far", () => {
    const p = buildUserPrompt([{ role: "user", text: "¿tono?" }, { role: "agent", text: "Cercano" }], "sigue");
    expect(p).toBe("Conversación hasta ahora:\nUsuario: ¿tono?\nFrontbot: Cercano\n\nMensaje nuevo del usuario:\nsigue");
  });
});
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd agent && npx vitest run test/prompt.test.ts` y `cd app && swift test --filter ChatHistoryTests`
Expected: TS FAIL — `buildUserPrompt` no exportado. Swift FAIL — `cannot find 'ChatTurn' in scope`.

- [ ] **Step 3: Implementar en TS**

En `agent/src/prompt.ts`, añadir:
```ts
export type HistoryTurn = { role: "user" | "agent"; text: string };

export function buildUserPrompt(history: HistoryTurn[], prompt: string): string {
  if (history.length === 0) return prompt;
  const lines = history.map((t) => `${t.role === "user" ? "Usuario" : "Frontbot"}: ${t.text}`);
  return `Conversación hasta ahora:\n${lines.join("\n")}\n\nMensaje nuevo del usuario:\n${prompt}`;
}
```

En `agent/src/runner.ts`:
- Import: `import { buildSystemPrompt, buildUserPrompt, type HistoryTurn } from "./prompt.js";`
- `export type RunParams = { run_id: string; prompt: string; model: string; brand?: Brand; history?: HistoryTurn[] };`
- En `RealRunner.run`: `const stream = query({ prompt: buildUserPrompt(params.history ?? [], params.prompt), options: buildQueryOptions(params, server, abortController, today) });`
- En `FakeRunner.run`, justo después de emitir `summary`:
```ts
    if (params.history?.length) emit({ run_id: params.run_id, type: "text", text: `Historial: ${params.history.length}` });
```

- [ ] **Step 4: Implementar en Swift**

`app/Sources/FrontbotCore/Agent/ChatHistory.swift`:
```swift
import Foundation

public struct ChatTurn: Equatable, Sendable {
    public enum Role: String, Sendable { case user, agent }
    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Historial que se manda al agente con cada mensaje: acotado para no agotar el contexto.
public enum ChatHistory {
    public static let maxTurns = 20
    public static let maxCharsPerTurn = 4_000

    public static func trimmed(_ turns: [ChatTurn]) -> [ChatTurn] {
        turns.suffix(maxTurns).map { t in
            t.text.count > maxCharsPerTurn ? ChatTurn(role: t.role, text: String(t.text.prefix(maxCharsPerTurn)) + "…") : t
        }
    }

    public static func json(_ turns: [ChatTurn]) -> JSONValue {
        .array(turns.map { ["role": .string($0.role.rawValue), "text": .string($0.text)] })
    }
}
```

En `AgentClient.swift`, cambiar la firma de `run` y añadir el historial a `params`:
```swift
    public func run(prompt: String, brand: Brand?, history: [ChatTurn] = []) async throws -> AgentRun {
```
y dentro del `do`, tras crear `params`:
```swift
            if !history.isEmpty { params["history"] = ChatHistory.json(ChatHistory.trimmed(history)) }
```

- [ ] **Step 5: Correr y verificar que pasa**

Run: `cd agent && npx vitest run && npm run build && cd ../app && FRONTBOT_NODE=$(which node) swift test`
Expected: PASS — vitest 18; Swift todos.

- [ ] **Step 6: Commit**

```bash
git add app agent/src agent/test
git commit -m "feat: send recent chat history to the agent"
```

---

### Task 6: UI — secciones, detalle de marca, calendario y editor de posts

**Files:**
- Create: `app/Sources/FrontbotApp/RootView.swift`, `BrandDetailView.swift`, `CalendarView.swift`, `PostEditorView.swift`
- Modify: `app/Sources/FrontbotApp/AppModel.swift`, `BrandsView.swift`, `ChatView.swift`, `FrontbotApp.swift`

**Interfaces:**
- Consumes: todo lo de Tasks 1–5.
- `AppModel` gana:
  - `enum Section: Hashable { case brand(String), calendar, chat }` y `var section: Section = .chat`
  - `var posts: [Post]`, `var assets: [BrandAsset]` (de la marca seleccionada), `var guide: String?`
  - `var calendarScope: CalendarScope = .week`, `var calendarDate = Date()`, `var calendarNetwork: Network?`, `var calendarBrandId: String?`
  - `func reloadContent()` (posts de todas las marcas + assets y guía de la seleccionada)
  - `func importImages(_ urls: [URL])`, `func saveGuide(_ markdown: String)`
  - `func startInterview()` — limpia el chat, cambia a `.chat` y envía `GuideSources.interviewPrompt`
  - `func guideFromPDF(_ url: URL)` — importa el PDF (Task 1), extrae texto (Task 4), cambia a `.chat` y envía `pdfPrompt`; errores en `errorMessage`
  - `func updatePost(_ post: Post, body: String, media: [String], scheduledFor: Date?) -> Bool`, `func approve(_ post: Post)`, `func archive(_ post: Post)`
  - `send(prompt:)` pasa `history:` con los mensajes `.user`/`.agent` anteriores (sin el actual) y, al terminar cada run o al recibir un `tool_call`, llama `reloadContent()` para que el calendario muestre los borradores nuevos.
- Sin tests automáticos (el target `FrontbotApp` no tiene target de tests en esta fase); se verifica con `swift build` y la checklist manual.

- [ ] **Step 1: `AppModel`** — reemplazar el archivo completo:

```swift
import Foundation
import Observation
import FrontbotCore

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, agent, tool, error }
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor @Observable
final class AppModel {
    enum Section: Hashable { case brand(String), calendar, chat }

    var section: Section = .chat
    var brands: [Brand] = []
    var selectedBrandId: String?
    var messages: [ChatMessage] = []
    var isRunning = false
    var errorMessage: String?
    var apiKeyPresent = false

    var posts: [Post] = []
    var assets: [BrandAsset] = []
    var guide: String?
    var calendarScope: CalendarScope = .week
    var calendarDate = Date()
    var calendarNetwork: Network?
    var calendarBrandId: String?

    private let db: AppDatabase
    private let paths: AppPaths
    private let workspace: Workspace
    private let credentials = CredentialStore()
    private let client: AgentClient
    private var currentRunId: String?
    /// Runs que terminaron antes de que `run()` devolviera su id (no deben perderse).
    private var earlyFinished: [String: AgentRun] = [:]
    private var keyAccount: String { "\(workspace.id).\(CredentialStore.anthropicKey)" }

    init() throws {
        paths = AppPaths.standard()
        db = try AppDatabase.open(at: paths.database)
        try db.failRunningRuns() // runs que quedaron "running" de una sesión anterior
        workspace = try db.ensureDefaultWorkspace()
        let key = try? credentials.get("\(workspace.id).\(CredentialStore.anthropicKey)")
        apiKeyPresent = CredentialStore.normalizedApiKey(key) != nil
        client = AgentClient(config: Self.makeConfig(apiKey: key), db: db, files: BrandFiles(paths: paths), workspaceId: workspace.id)
        brands = try db.brands(workspaceId: workspace.id)
        selectedBrandId = brands.first?.id
        reloadContent()
        Task { await listen() }
    }

    static func makeConfig(apiKey: String?) -> AgentConfig {
        let env = ProcessInfo.processInfo.environment
        return AgentConfig(
            nodePath: env["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node",
            scriptPath: env["FRONTBOT_AGENT_SCRIPT"] ?? "",
            apiKey: apiKey,
            model: env["FRONTBOT_MODEL"] ?? AgentConfig.defaultModel,
            fakeAgent: env["FRONTBOT_FAKE_AGENT"] == "1")
    }

    var selectedBrand: Brand? { brands.first { $0.id == selectedBrandId } }
    func brand(id: String) -> Brand? { brands.first { $0.id == id } }

    func select(brandId: String) {
        selectedBrandId = brandId
        section = .brand(brandId)
        reloadContent()
    }

    func reloadContent() {
        posts = (try? db.posts(brandId: nil, status: nil)) ?? []
        if let id = selectedBrandId {
            assets = (try? db.assets(brandId: id, kind: .image)) ?? []
            guide = try? BrandFiles(paths: paths).readGuide(brandId: id)
        } else {
            assets = []
            guide = nil
        }
    }

    // MARK: Marcas

    func createBrand(name: String, industry: String, networks: [Network]) {
        perform {
            let brand = try db.createBrand(workspaceId: workspace.id, name: name, industry: industry, networks: networks)
            brands = try db.brands(workspaceId: workspace.id)
            select(brandId: brand.id)
        }
    }

    func importImages(_ urls: [URL]) {
        guard let id = selectedBrandId else { return }
        let importer = AssetImporter(db: db, paths: paths)
        var failures: [String] = []
        for url in urls {
            do { _ = try importer.importImage(from: url, brandId: id) }
            catch let e as ValidationError { failures.append("\(url.lastPathComponent): \(e.message)") }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        reloadContent()
    }

    func saveGuide(_ markdown: String) {
        guard let id = selectedBrandId else { return }
        perform { try BrandFiles(paths: paths).writeGuide(brandId: id, markdown: markdown) }
        reloadContent()
    }

    func startInterview() {
        guard let brand = selectedBrand else { return }
        messages = []
        section = .chat
        send(prompt: GuideSources.interviewPrompt(brandName: brand.name))
    }

    func guideFromPDF(_ url: URL) {
        guard let brand = selectedBrand else { return }
        perform {
            _ = try AssetImporter(db: db, paths: paths).importGuidePDF(from: url, brandId: brand.id)
            let text = try GuideSources.text(fromPDF: url)
            messages = []
            section = .chat
            send(prompt: GuideSources.pdfPrompt(brandName: brand.name, pdfText: text))
        }
    }

    // MARK: Posts

    @discardableResult
    func updatePost(_ post: Post, body: String, media: [String], scheduledFor: Date?) -> Bool {
        let ok = perform { _ = try db.updatePostByUser(id: post.id, body: body, media: media, scheduledFor: .some(scheduledFor)) }
        reloadContent()
        return ok
    }

    func approve(_ post: Post) {
        perform { _ = try db.transitionPost(id: post.id, to: .approved, actor: .user) }
        reloadContent()
    }

    func archive(_ post: Post) {
        perform { _ = try db.transitionPost(id: post.id, to: .archived, actor: .user) }
        reloadContent()
    }

    func assetPath(_ id: String) -> String? { try? db.asset(id: id)?.path }

    // MARK: Chat

    func send(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        let history = messages.compactMap { m -> ChatTurn? in
            switch m.role {
            case .user: ChatTurn(role: .user, text: m.text)
            case .agent: ChatTurn(role: .agent, text: m.text)
            case .tool, .error: nil
            }
        }
        messages.append(ChatMessage(role: .user, text: text))
        isRunning = true
        Task {
            do {
                let id = try await client.run(prompt: text, brand: selectedBrand, history: history).id
                if let run = earlyFinished.removeValue(forKey: id) { finish(run) } else { currentRunId = id }
            } catch {
                isRunning = false
                messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
        }
    }

    func cancel() {
        guard let id = currentRunId else { return }
        Task { await client.cancel(runId: id) }
    }

    @discardableResult
    func saveApiKey(_ key: String) -> Bool {
        guard let key = CredentialStore.normalizedApiKey(key) else {
            errorMessage = "La API key está vacía."
            return false
        }
        let ok = perform { try credentials.set(keyAccount, value: key) }
        if ok {
            apiKeyPresent = true
            Task { await client.setConfig(Self.makeConfig(apiKey: key)) }
        }
        return ok
    }

    @discardableResult
    private func perform(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            errorMessage = nil
            return true
        } catch let e as ValidationError {
            errorMessage = e.message
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    private func finish(_ run: AgentRun) {
        isRunning = false
        currentRunId = nil
        if run.status == .failed { messages.append(ChatMessage(role: .error, text: run.resultSummary ?? "Error")) }
        brands = (try? db.brands(workspaceId: workspace.id)) ?? brands
        reloadContent()
    }

    private func listen() async {
        for await update in await client.updates() {
            switch update {
            case .event(let runId, let type, let text) where runId == currentRunId:
                if type == "text" { messages.append(ChatMessage(role: .agent, text: text)) }
                if type == "tool_call" {
                    messages.append(ChatMessage(role: .tool, text: "→ \(text)"))
                    reloadContent()
                }
            case .finished(let run) where run.id == currentRunId:
                finish(run)
            case .finished(let run) where isRunning && currentRunId == nil:
                earlyFinished[run.id] = run
            default:
                break
            }
        }
    }
}
```

Nota para el implementador: el `tool_call` llega cuando el modelo **pide** la herramienta, antes de que la app la ejecute; por eso `finish` vuelve a recargar al final del run.

- [ ] **Step 2: `RootView`, `BrandsView`, `FrontbotApp`**

`RootView.swift`:
```swift
import SwiftUI
import FrontbotCore

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            BrandsView(model: model)
        } detail: {
            switch model.section {
            case .brand(let id):
                if let brand = model.brand(id: id) { BrandDetailView(model: model, brand: brand) }
            case .calendar:
                CalendarView(model: model)
            case .chat:
                ChatView(model: model)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .alert("Frontbot", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
```

`BrandsView.swift` — reemplazar `BrandsView` (la hoja `NewBrandSheet` se queda igual, pero quitar su línea `if let error = model.errorMessage { ... }` porque ahora los errores se muestran con la alerta de `RootView`; y en el botón Crear cerrar la hoja solo si `model.errorMessage == nil` como hasta ahora):
```swift
struct BrandsView: View {
    @Bindable var model: AppModel
    @State private var showingNew = false

    var body: some View {
        List {
            Section {
                Button { model.section = .chat } label: { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .buttonStyle(.plain).bold(model.section == .chat)
                Button { model.section = .calendar } label: { Label("Calendario", systemImage: "calendar") }
                    .buttonStyle(.plain).bold(model.section == .calendar)
            }
            Section("Marcas") {
                ForEach(model.brands) { brand in
                    Button { model.select(brandId: brand.id) } label: {
                        VStack(alignment: .leading) {
                            Text(brand.name).bold(model.section == .brand(brand.id))
                            Text(brand.networks.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .toolbar { Button("Nueva marca", systemImage: "plus") { showingNew = true } }
        .sheet(isPresented: $showingNew) { NewBrandSheet(model: model) }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}
```

`FrontbotApp.swift` — reemplazar el bloque `NavigationSplitView { ... }.frame(...)` por `RootView(model: model)`.

- [ ] **Step 3: `BrandDetailView`**

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FrontbotCore

struct BrandDetailView: View {
    @Bindable var model: AppModel
    let brand: Brand
    @State private var editingGuide = false
    @State private var guideDraft = ""
    @State private var pickingImages = false
    @State private var pickingPDF = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(brand.name).font(.largeTitle).bold()
                Text([brand.industry, brand.networks.map(\.rawValue).joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: " — "))
                    .foregroundStyle(.secondary)

                GroupBox("Guía de marca") {
                    VStack(alignment: .leading, spacing: 10) {
                        if editingGuide {
                            TextEditor(text: $guideDraft).font(.body.monospaced()).frame(minHeight: 260)
                            HStack {
                                Button("Cancelar") { editingGuide = false }
                                Spacer()
                                Button("Guardar") { model.saveGuide(guideDraft); editingGuide = false }.keyboardShortcut(.defaultAction)
                            }
                        } else if let guide = model.guide {
                            Text((try? AttributedString(markdown: guide, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(guide))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("Esta marca aún no tiene guía.").foregroundStyle(.secondary)
                        }
                        if !editingGuide {
                            HStack {
                                Button("Entrevístame") { model.startInterview() }.disabled(model.isRunning)
                                Button("Desde un PDF…") { pickingPDF = true }.disabled(model.isRunning)
                                Button(model.guide == nil ? "Escribirla a mano" : "Editar") {
                                    guideDraft = model.guide ?? ""
                                    editingGuide = true
                                }
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("Imágenes") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.assets.isEmpty {
                            Text("Sube imágenes JPEG o PNG (máx. 8 MB) para usarlas en los posts.").foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 10) {
                            ForEach(model.assets) { asset in
                                AssetThumbnail(path: asset.path)
                            }
                        }
                        Button("Subir imágenes…") { pickingImages = true }
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
        .fileImporter(isPresented: $pickingImages, allowedContentTypes: [.jpeg, .png], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importImages(withAccess(urls)) }
        }
        .fileImporter(isPresented: $pickingPDF, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result, let local = withAccess([url]).first { model.guideFromPDF(local) }
        }
    }

    /// Los archivos del selector pueden requerir acceso con ámbito de seguridad.
    private func withAccess(_ urls: [URL]) -> [URL] {
        urls.map { url in
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            // Copia temporal para leer fuera del bloque de acceso.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: tmp)) != nil { return tmp }
            return url
        }
    }
}

struct AssetThumbnail: View {
    let path: String

    var body: some View {
        Group {
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 4: `CalendarView`**

```swift
import SwiftUI
import FrontbotCore

struct CalendarView: View {
    @Bindable var model: AppModel
    @State private var editing: Post?
    private let content = ContentCalendar()

    private var days: [CalendarDay] {
        content.days(model.calendarScope, containing: model.calendarDate, posts: model.posts,
                     brandId: model.calendarBrandId, network: model.calendarNetwork)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.calendarDate = content.shift(model.calendarDate, scope: model.calendarScope, by: -1) } label: { Image(systemName: "chevron.left") }
                Button("Hoy") { model.calendarDate = Date() }
                Button { model.calendarDate = content.shift(model.calendarDate, scope: model.calendarScope, by: 1) } label: { Image(systemName: "chevron.right") }
                Text(title).font(.title2).bold()
                Spacer()
                Picker("Marca", selection: $model.calendarBrandId) {
                    Text("Todas las marcas").tag(String?.none)
                    ForEach(model.brands) { Text($0.name).tag(String?.some($0.id)) }
                }.frame(width: 180)
                Picker("Red", selection: $model.calendarNetwork) {
                    Text("Todas las redes").tag(Network?.none)
                    ForEach(Network.allCases, id: \.self) { Text($0.rawValue).tag(Network?.some($0)) }
                }.frame(width: 160)
                Picker("", selection: $model.calendarScope) {
                    Text("Semana").tag(CalendarScope.week)
                    Text("Mes").tag(CalendarScope.month)
                }.pickerStyle(.segmented).frame(width: 150)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.date.formatted(.dateTime.day())).font(.caption).bold()
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Color.accentColor : .primary)
                        ForEach(day.posts) { post in PostChip(model: model, post: post).onTapGesture { editing = post } }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: model.calendarScope == .week ? 220 : 90, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(day.inScope ? Color.secondary.opacity(0.08) : Color.clear))
                    .opacity(day.inScope ? 1 : 0.5)
                }
            }

            let pending = content.unscheduled(model.posts, brandId: model.calendarBrandId, network: model.calendarNetwork)
            if !pending.isEmpty {
                Text("Sin fecha").font(.headline)
                ScrollView(.horizontal) {
                    HStack { ForEach(pending) { post in PostChip(model: model, post: post).frame(width: 200).onTapGesture { editing = post } } }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .sheet(item: $editing) { post in PostEditorView(model: model, post: post) }
    }

    private var title: String {
        model.calendarScope == .week
            ? "Semana del " + content.range(.week, containing: model.calendarDate).start.formatted(.dateTime.day().month(.wide))
            : model.calendarDate.formatted(.dateTime.month(.wide).year())
    }
}

struct PostChip: View {
    let model: AppModel
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(model.brand(id: post.brandId)?.name ?? "").font(.caption2).bold()
                Text(post.network == .instagram ? "IG" : "in").font(.caption2).foregroundStyle(.secondary)
                if let at = post.scheduledFor { Text(at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(post.body).font(.caption).lineLimit(2)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch post.status {
        case .draft: .orange
        case .approved: .green
        case .preparing, .scheduled: .blue
        case .published: .purple
        case .archived: .gray
        }
    }
}
```

- [ ] **Step 5: `PostEditorView`**

```swift
import SwiftUI
import FrontbotCore

struct PostEditorView: View {
    let model: AppModel
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @State private var body_: String
    @State private var media: [String]
    @State private var hasDate: Bool
    @State private var date: Date

    init(model: AppModel, post: Post) {
        self.model = model
        self.post = post
        _body_ = State(initialValue: post.body)
        _media = State(initialValue: post.media)
        _hasDate = State(initialValue: post.scheduledFor != nil)
        _date = State(initialValue: post.scheduledFor ?? Date())
    }

    private var editable: Bool { post.status == .draft || post.status == .approved }
    private var validationError: String? {
        do { try PostRules.validate(body: body_, network: post.network); return nil } catch { return error.message }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.brand(id: post.brandId)?.name ?? "") · \(post.network.rawValue)").font(.headline)
                Spacer()
                Text(statusLabel).font(.caption).padding(4).background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            TextEditor(text: $body_).frame(minHeight: 200).disabled(!editable)
            HStack {
                Text("\(body_.count) / \(PostRules.maxLength(for: post.network))")
                    .font(.caption).foregroundStyle(body_.count > PostRules.maxLength(for: post.network) ? .red : .secondary)
                if let validationError { Text(validationError).font(.caption).foregroundStyle(.red) }
            }

            Text("Imágenes").font(.subheadline).bold()
            ScrollView(.horizontal) {
                HStack {
                    ForEach(model.brandAssets(post.brandId)) { asset in
                        AssetThumbnail(path: asset.path)
                            .overlay(alignment: .topTrailing) {
                                if let i = media.firstIndex(of: asset.id) {
                                    Text("\(i + 1)").font(.caption.bold()).padding(5).background(Circle().fill(Color.accentColor)).foregroundStyle(.white).padding(4)
                                }
                            }
                            .onTapGesture {
                                guard editable else { return }
                                if let i = media.firstIndex(of: asset.id) { media.remove(at: i) } else { media.append(asset.id) }
                            }
                    }
                }
            }

            Toggle("Fecha programada", isOn: $hasDate).disabled(!editable)
            if hasDate { DatePicker("", selection: $date).labelsHidden().disabled(!editable) }

            HStack {
                Button("Archivar", role: .destructive) { model.archive(post); dismiss() }.disabled(post.status == .archived)
                Spacer()
                Button("Cerrar") { dismiss() }
                if editable {
                    Button("Guardar") { if save() { dismiss() } }.disabled(validationError != nil)
                }
                if post.status == .draft {
                    Button("Guardar y aprobar") { if save() { model.approve(post); dismiss() } }
                        .keyboardShortcut(.defaultAction).disabled(validationError != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func save() -> Bool {
        model.updatePost(post, body: body_, media: media, scheduledFor: hasDate ? date : nil)
    }

    private var statusLabel: String {
        switch post.status {
        case .draft: "Borrador"
        case .approved: "Aprobado"
        case .preparing: "Preparando"
        case .scheduled: "Programado"
        case .published: "Publicado"
        case .archived: "Archivado"
        }
    }
}
```

Añadir a `AppModel` (sección `// MARK: Posts`):
```swift
    func brandAssets(_ brandId: String) -> [BrandAsset] { (try? db.assets(brandId: brandId, kind: .image)) ?? [] }
```

`ValidationError` ya expone `message`; `catch` en `validationError` atrapa `ValidationError` por el `throws(ValidationError)` tipado de `PostRules.validate`.

- [ ] **Step 6: `ChatView`** — que Enter no borre el texto mientras corre un run: reemplazar `submit()`:

```swift
    private func submit() {
        guard !model.isRunning else { return }
        model.send(prompt: draft)
        draft = ""
    }
```

- [ ] **Step 7: Compilar y correr la suite**

Run: `cd app && swift build && FRONTBOT_NODE=$(which node) swift test`
Expected: `Build complete!` sin errores; todos los tests en verde.

- [ ] **Step 8: Verificación manual (agente falso)**

```bash
cd agent && npm run build && cd ../app
FRONTBOT_FAKE_AGENT=1 FRONTBOT_NODE=$(which node) FRONTBOT_AGENT_SCRIPT=$(cd ../agent && pwd)/dist/main.js swift run FrontbotApp
```
- [ ] Barra lateral con Chat, Calendario y Marcas; elegir una marca abre su detalle.
- [ ] Subir un PNG y un JPEG: aparecen como miniaturas. Subir un archivo de 9 MB: alerta "La imagen pesa 9.0 MB; el máximo es 8 MB."
- [ ] "Escribirla a mano": guardar una guía y verla renderizada.
- [ ] Chat con la marca seleccionada: "crear post" → aparece en Calendario › Sin fecha.
- [ ] Abrir el post: contador `14 / 2200`; seleccionar dos imágenes (números 1 y 2); fijar fecha → pasa a la cuadrícula; "Guardar y aprobar" → punto verde.
- [ ] Vista Mes, filtros por marca y red, flechas y "Hoy".
- [ ] Segundo mensaje en el chat: el agente falso responde "Historial: 2".

- [ ] **Step 9: Commit**

```bash
git add app
git commit -m "feat: add brand detail, content calendar and post editor views"
```

---

## Self-review

- **Cobertura del spec (Fase 2):** subir marca con archivos y "Entrevístame" / guía desde PDF (5.1 → Tasks 1, 4, 5, 6); imágenes subidas por el usuario y sugeridas por el agente (5.3 → Tasks 1, 2); calendario semanal y mensual filtrable con edición y aprobación (5.4 → Tasks 3, 6); `brands_list_assets` (6.2 → Task 2); el agente sigue sin poder aprobar (Task 2 no añade transiciones). Fuera: "Preparar publicación" (Fase 3).
- **Decisión no cubierta por el spec:** memoria del chat mediante historial (Task 5) — necesaria para "Entrevístame", que es multi-turno.
- **Nombres consistentes:** `AssetKind`, `assets(brandId:kind:)`, `updatePostByUser(id:body:media:scheduledFor:)`, `ChatTurn`, `run(prompt:brand:history:)`, `ContentCalendar.days/unscheduled/shift/range` se usan igual en Tasks 1–6.
- **Riesgo conocido:** `checkMedia` hace lecturas; por eso `updateDraft` se reescribe para validar fuera del `write` y re-chequear el estado dentro (Task 2, Step 3).
