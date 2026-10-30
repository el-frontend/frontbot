# Guía de marca desde links — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Botón "Desde links" que crea la guía de marca leyendo cualquier link e importa el logo y algunas fotos como assets de la marca.

**Architecture:** Mismo patrón que "Desde un PDF": la app manda al chat un prompt fijo (`GuideSources.linksPrompt`) y el agente hace el trabajo con WebFetch y el navegador. Se añade una herramienta `brands_import_image` que ejecuta la app de forma asíncrona (descarga protegida → `AssetImporter`). La marca guarda sus links (migración v14) y la guía anterior queda respaldada en `guide.prev.md`.

**Tech Stack:** Swift 6 / SwiftUI / GRDB / XCTest (`app/`), Node + Claude Agent SDK + zod + vitest (`agent/`).

**Spec:** `docs/superpowers/specs/2026-10-30-frontbot-guia-desde-links-design.md`

## Global Constraints

- Ninguna herramienta publica ni aprueba posts. `brands_import_image` solo escribe en la marca.
- `brands_import_image` no está en el modo estudio (`STUDY_BASE`).
- Imágenes: máximo 8 MB (`AssetImporter.maxImageBytes`); JPEG y PNG se guardan tal cual, WebP y GIF se convierten a PNG (primer cuadro), todo lo demás da error.
- Por run: como máximo 1 logo y 8 imágenes.
- Links: solo `http`/`https` con host; sin esquema se antepone `https://`; máximo 10.
- Descargas: solo `https` (`http` se mejora a `https`); se rechazan `localhost`, `.local` y los hosts con cualquier dirección privada, loopback, link-local, CGNAT 100.64/10, IPv6 ULA/link-local o IPv4 mapeada en IPv6. Se comprueba de nuevo en cada redirección. Sesión efímera, sin cookies, timeout de 20 s.
- Nueva sección de guía: `## Identidad visual`.
- Los textos de la UI se escriben en español (son las claves) y se traducen en `app/Localization/en/`.
- Corrección al spec: `memoryOnly` solo existe en el modo resumen y no es un tipo de agente. "Agente que no lee la web" equivale a `agent.provider != .claude`.

## Review Focus

1. Links pegados con espacios, mayúsculas en el esquema o `www.` sin esquema → se normalizan y no se rechazan (Task 2).
2. Una URL de imagen que devuelve HTML (muro de login, error del CDN) → error claro al agente y no se guarda nada (Task 5).
3. Una respuesta sin `Content-Length` que pasa de 8 MB → se corta y no se guarda (Task 5).
4. `brands_import_image` llamado con un `run_id` que ya terminó o fue cancelado → se rechaza y no cuenta para el límite (Task 6).
5. Dos escrituras de guía seguidas → `guide.prev.md` tiene la inmediatamente anterior. Restaurar intercambia las dos, así que restaurar dos veces vuelve al estado inicial (Task 3).

---

### Task 1: La marca guarda sus links

**Files:**
- Modify: `app/Sources/FrontbotCore/Models/Records.swift` (`Brand`)
- Modify: `app/Sources/FrontbotCore/Store/AppDatabase.swift` (migración nueva después de `v13-cost-availability`)
- Modify: `app/Sources/FrontbotCore/Store/Repositories.swift` (junto a `createBrand`)
- Modify: `app/Sources/FrontbotCore/Agent/ToolHandler.swift` (`tool.brands_list`)
- Test: `app/Tests/FrontbotCoreTests/StoreTests.swift`, `app/Tests/FrontbotCoreTests/ToolHandlerTests.swift`

**Interfaces:**
- Produces: `Brand.links: [String]` (con valor por defecto `[]`, declarado después de `networks`, para que los inicializadores actuales sigan compilando); `AppDatabase.setBrandLinks(brandId: String, links: [String]) throws`; `tool.brands_list` devuelve `"links": [String]` por marca.

- [ ] **Step 1: Write the failing tests**

```swift
// StoreTests
func testBrandLinksDefaultEmptyAndPersist() throws {
    let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
    XCTAssertEqual(try db.brand(id: brand.id)?.links, [])
    try db.setBrandLinks(brandId: brand.id, links: ["https://a.com", "https://instagram.com/a"])
    XCTAssertEqual(try db.brand(id: brand.id)?.links, ["https://a.com", "https://instagram.com/a"])
}
func testSetBrandLinksUnknownBrandThrows() {
    XCTAssertThrowsError(try db.setBrandLinks(brandId: UUID().uuidString, links: []))
}
// ToolHandlerTests
func testBrandsListIncludesLinks() throws { /* setBrandLinks ["https://a.com"]; brands_list → brands[0]["links"] == ["https://a.com"] */ }
```

- [ ] **Step 2: Run them and check they fail**

Run: `cd app && FRONTBOT_NODE=$(which node) swift test --filter 'StoreTests|ToolHandlerTests'`
Expected: compile error, because `links` and `setBrandLinks` don't exist.

- [ ] **Step 3: Implement**

Migration `v14-brand-links`: `alter(table: "brand") { t.add(column: "links", .text).notNull().defaults(to: "[]") }`. GRDB stores `[String]` as JSON, the same way it stores `networks`.

- [ ] **Step 4: Run the tests and check they pass**

Same command. Expected: PASS. Also run the full `swift test` to confirm the existing databases still migrate.

- [ ] **Step 5: Commit** — `feat(brands): store brand links`

### Task 2: Normalize links

**Files:**
- Create: `app/Sources/FrontbotCore/Content/BrandLinks.swift`
- Test: `app/Tests/FrontbotCoreTests/BrandLinksTests.swift`

**Interfaces:**
- Produces: `public enum BrandLinks { public static let maxLinks = 10; public static func parse(_ text: String) -> BrandLinks.Result }` with `public struct Result: Equatable { public var links: [String]; public var invalid: [String] }`. The separators are line breaks, spaces and commas. Lines are deduplicated and keep their order.

- [ ] **Step 1: Write the failing tests**

```swift
func testAddsHttpsAndTrims() {
    XCTAssertEqual(BrandLinks.parse("  www.cafesol.com \nHTTPS://instagram.com/cafesol").links,
                   ["https://www.cafesol.com", "https://instagram.com/cafesol"])
}
func testCommaAndSpaceSeparated() { XCTAssertEqual(BrandLinks.parse("a.com, b.com c.com").links.count, 3) }
func testRejectsOtherSchemesAndHostless() {
    let r = BrandLinks.parse("ftp://a.com\nfile:///etc/passwd\nhttps://\nhola")
    XCTAssertEqual(r.links, []); XCTAssertEqual(r.invalid.count, 4)
}
func testDeduplicates() { XCTAssertEqual(BrandLinks.parse("a.com\nhttps://a.com").links, ["https://a.com"]) }
func testMoreThanTenIsInvalid() { /* 11 valid links → links.count == 10, invalid contains the 11th */ }
```

A host must contain a dot or be an IP literal, so that "hola" is rejected.

- [ ] **Step 2: Run them and check they fail.** `swift test --filter BrandLinksTests`. Expected: compile error.
- [ ] **Step 3: Implement `BrandLinks.parse`** using `URLComponents`, after lowercasing the scheme.
- [ ] **Step 4: Run them and check they pass.**
- [ ] **Step 5: Commit** — `feat(brands): parse and normalize brand links`

### Task 3: Back up the guide

**Files:**
- Modify: `app/Sources/FrontbotCore/Store/AppPaths.swift` (next to `guide(_:)`)
- Modify: `app/Sources/FrontbotCore/Store/BrandFiles.swift`
- Test: `app/Tests/FrontbotCoreTests/BrandFilesTests.swift`

**Interfaces:**
- Produces: `AppPaths.previousGuide(_ brandId: String) -> URL` (`guide.prev.md`); `BrandFiles.hasPreviousGuide(brandId:) throws -> Bool`; `BrandFiles.restorePreviousGuide(brandId:) throws` swaps `guide.md` and `guide.prev.md`. If there is no current guide, it moves the previous one into place and `guide.prev.md` is left absent.
- `writeGuide` copies the current guide to `guide.prev.md` before writing, but only if one exists and its content is different.

- [ ] **Step 1: Write the failing tests**

```swift
func testWriteKeepsPrevious() throws {
    try files.writeGuide(brandId: id, markdown: "v1"); XCTAssertFalse(try files.hasPreviousGuide(brandId: id))
    try files.writeGuide(brandId: id, markdown: "v2")
    XCTAssertEqual(try String(contentsOf: paths.previousGuide(id), encoding: .utf8), "v1")
}
func testSameContentDoesNotOverwriteBackup() throws { /* v1, v2, v2 → prev == "v1" */ }
func testRestoreSwapsAndIsReversible() throws {
    try files.writeGuide(brandId: id, markdown: "v1"); try files.writeGuide(brandId: id, markdown: "v2")
    try files.restorePreviousGuide(brandId: id); XCTAssertEqual(try files.readGuide(brandId: id), "v1")
    try files.restorePreviousGuide(brandId: id); XCTAssertEqual(try files.readGuide(brandId: id), "v2")
}
func testRestoreWithoutBackupThrows() { /* ValidationError */ }
```

- [ ] **Step 2: Run them and check they fail.** `swift test --filter BrandFilesTests`.
- [ ] **Step 3: Implement.** Do the swap with a temporary file in the same folder.
- [ ] **Step 4: Run them and check they pass.**
- [ ] **Step 5: Commit** — `feat(brands): keep the previous brand guide`

### Task 4: Guide sections and links prompt

**Files:**
- Modify: `app/Sources/FrontbotCore/Content/GuideSources.swift`
- Test: `app/Tests/FrontbotCoreTests/GuideSourcesTests.swift`

**Interfaces:**
- Produces: `GuideSources.sections` ends with `, ## Identidad visual`; `public static func linksPrompt(brandName: String, links: [String], hasGuide: Bool) -> String`.
- The prompt follows the 5 numbered steps in the spec ("Prompt" section): read each link (WebFetch, and the browser for profiles that need a login; report the ones it can't read); write the guide with `sections`, quoting real examples verbatim and marking missing parts "(por definir)", inventing nothing; if `hasGuide`, show a summary and ask before saving; import with `brands_import_image` at most 1 logo (`kind: logo`) and 8 photos (`kind: image`), avoiding icons, banners, screenshots and stock photos; end by saying what came from each link, which sections were left undefined and which images were imported.

- [ ] **Step 1: Write the failing tests**

```swift
func testSectionsIncludeVisualIdentity() { XCTAssertTrue(GuideSources.interviewPrompt(brandName: "B").contains("## Identidad visual")) }
func testLinksPromptListsLinksAndTools() {
    let p = GuideSources.linksPrompt(brandName: "Café Sol", links: ["https://a.com", "https://instagram.com/a"], hasGuide: false)
    for s in ["https://a.com", "https://instagram.com/a", "brands_write_guide", "brands_import_image", "## Identidad visual", "(por definir)"] { XCTAssertTrue(p.contains(s), s) }
}
func testLinksPromptAsksBeforeReplacing() {
    XCTAssertTrue(GuideSources.linksPrompt(brandName: "B", links: ["https://a.com"], hasGuide: true).contains("antes de guardar"))
    XCTAssertFalse(GuideSources.linksPrompt(brandName: "B", links: ["https://a.com"], hasGuide: false).contains("antes de guardar"))
}
```

- [ ] **Step 2: Run them and check they fail.** `swift test --filter GuideSourcesTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and check they pass** (including the existing `testPromptsMentionToolAndSections`).
- [ ] **Step 5: Commit** — `feat(guide): links prompt and visual identity section`

### Task 5: Safe image download

**Files:**
- Create: `app/Sources/FrontbotCore/Store/RemoteImageFetcher.swift`
- Modify: `app/Sources/FrontbotCore/Store/AssetImporter.swift`
- Test: `app/Tests/FrontbotCoreTests/RemoteImageFetcherTests.swift`, `app/Tests/FrontbotCoreTests/AssetImporterTests.swift`

**Interfaces:**
- Produces:
  - `public struct RemoteImageFetcher: Sendable` with `init(configuration: URLSessionConfiguration = .ephemeral, resolve: @escaping @Sendable (String) throws -> [String] = RemoteImageFetcher.systemResolve)` and `public func fetch(_ url: String) async throws -> Data`.
  - `public static func validate(_ url: URL, resolve:) throws -> URL` returns the URL upgraded to https.
  - `public static func isPublic(ip: String) -> Bool`.
  - `systemResolve` uses `getaddrinfo` and returns the IPs as text.
  - The session sets `httpCookieStorage = nil`, `timeoutIntervalForRequest = 20` and `timeoutIntervalForResource = 20`. A delegate calls `validate` in `willPerformHTTPRedirection` and cancels the redirect if it fails. The body is read with `bytes(for:)` and the download is cut off at `AssetImporter.maxImageBytes + 1`.
  - `AssetImporter.importImage(data: Data, brandId: String, kind: AssetKind) throws -> BrandAsset` sniffs the bytes: JPEG/PNG are kept as they are; WebP (`RIFF....WEBP`) and GIF (`GIF8`) are converted to PNG with `CGImageSource`/`CGImageDestination` (first frame); anything else throws `"Formato no admitido: solo JPEG, PNG, WebP o GIF."`. `kind` is only `.image` or `.logo`. The current `importImage(from:brandId:)` keeps its behavior.

- [ ] **Step 1: Write the failing tests**

```swift
// RemoteImageFetcherTests — use a fake resolver and a URLProtocol stub registered in configuration.protocolClasses
func testIsPublic() {
    for ip in ["10.0.0.1", "172.16.5.4", "192.168.1.1", "127.0.0.1", "169.254.1.1", "100.64.0.1", "0.0.0.0", "::1", "fe80::1", "fd00::1", "::ffff:192.168.1.1"] { XCTAssertFalse(RemoteImageFetcher.isPublic(ip: ip), ip) }
    for ip in ["93.184.216.34", "2606:2800:220:1::1"] { XCTAssertTrue(RemoteImageFetcher.isPublic(ip: ip), ip) }
}
func testValidateUpgradesHttpAndRejects() throws {
    let pub: @Sendable (String) throws -> [String] = { _ in ["93.184.216.34"] }
    XCTAssertEqual(try RemoteImageFetcher.validate(URL(string: "http://a.com/x.png")!, resolve: pub).scheme, "https")
    for u in ["ftp://a.com/x", "https://localhost/x", "https://printer.local/x", "https://10.0.0.1/x"] { XCTAssertThrowsError(try RemoteImageFetcher.validate(URL(string: u)!, resolve: pub), u) }
    XCTAssertThrowsError(try RemoteImageFetcher.validate(URL(string: "https://a.com/x")!, resolve: { _ in ["93.184.216.34", "192.168.0.2"] }))
}
func testFetchCutsOffOver8MBWithoutContentLength() async { /* the stub returns 8 MB + 1 with no Content-Length → throws */ }
func testFetchReturnsBody() async throws { /* the stub returns PNG bytes → equal */ }
// AssetImporterTests
func testImportDataStoresLogoKind() throws { /* PNG data, kind .logo → asset.kind == "logo" */ }
func testImportDataConvertsWebPToPNG() throws { /* tiny valid WebP fixture generated in the test with CGImageDestination if available; otherwise a base64 constant → file ends in .png and starts with the PNG magic bytes */ }
func testImportDataRejectsHTMLAndSVG() { /* "<!doctype html>" and "<svg" → throws; no file in assetsDir */ }
```

- [ ] **Step 2: Run them and check they fail.** `swift test --filter 'RemoteImageFetcherTests|AssetImporterTests'`.
- [ ] **Step 3: Implement** `RemoteImageFetcher` and `AssetImporter.importImage(data:brandId:kind:)` with the interfaces above.
- [ ] **Step 4: Run them and check they pass.**
- [ ] **Step 5: Commit** — `feat(assets): safe remote image download`

### Task 6: The `brands_import_image` tool

**Files:**
- Modify: `agent/src/tools.ts` (`TOOL_SPECS`, and the `run_id` line inside `executeFrontbotTool`)
- Modify: `app/Sources/FrontbotCore/Agent/AgentClient.swift` (dedicated case before the generic `case .request(let id, let method, let params)`)
- Test: `agent/test/tools.test.ts`, `app/Tests/FrontbotCoreTests/AgentClientCallTests.swift`

**Interfaces:**
- Consumes: `RemoteImageFetcher.fetch(_:)` and `AssetImporter.importImage(data:brandId:kind:)` (Task 5).
- Produces:
  - Spec: `{ name: "brands_import_image", description: "Descarga una imagen pública (JPEG, PNG, WebP o GIF; máx. 8 MB) a los assets de la marca. kind: logo para el logo (1 por corrida) o image para fotos (8 por corrida). Devuelve el id del asset.", shape: { brand_id: z.string(), url: z.string(), kind: z.enum(["image", "logo"]) } }`.
  - `executeFrontbotTool` adds `params.run_id = ctx.runId` for this tool too.
  - The app replies `{ "asset_id": String, "kind": String }`.
  - `AgentClient` gets an injectable `imageFetcher: RemoteImageFetcher` (in its `init`, with a default value) so the tests can use the stub.

- [ ] **Step 1: Write the failing tests**

```ts
// tools.test.ts
it("brands_import_image is in chat but not in study", () => {
  expect(allowedToolsFor({ isDefault: true })).toContain("mcp__frontbot__brands_import_image");
  expect(STUDY_TOOL_NAMES).not.toContain("brands_import_image");
});
it("brands_import_image sends run_id", async () => { /* fake call captures params; ctx.runId "r1" → params.run_id === "r1" */ });
```

Also update the expected list in `tools.test.ts:16` if the test compares the full list.

```swift
// AgentClientCallTests — follow the file's existing pattern for simulating sidecar requests
func testImportImageRejectsInactiveRun() { /* run_id not active → error, no asset */ }
func testImportImageLimitsPerRun() { /* active run: 2nd logo → error "1 logo"; 9th image → error "8 imágenes"; another run starts from zero */ }
func testImportImageStoresAsset() { /* stub PNG → result has asset_id; db.assets(kind: .image) has 1 */ }
```

- [ ] **Step 2: Run them and check they fail.** `cd agent && npx vitest run test/tools.test.ts` and `cd app && FRONTBOT_NODE=$(which node) swift test --filter AgentClientCallTests`.
- [ ] **Step 3: Implement.**
  - In `AgentClient`, keep `imageImports: [String: (logos: Int, images: Int)]` per `runId`, reserve the slot before the download (and free it if the download fails), and clear the entry wherever the run is removed from `activeRuns`.
  - Run the download inside a `Task` and answer with `reply(id, …)`, like `workdir.approve` does.
  - Validate `brand_id` with `db.brand(id:)` before downloading.
- [ ] **Step 4: Run them and check they pass.** Also run the full `npm test` in `agent/`.
- [ ] **Step 5: Commit** — `feat(agent): brands_import_image tool`

### Task 7: Brand page — button, sheet, restore and logo

**Files:**
- Modify: `app/Sources/FrontbotApp/BrandDetailView.swift` (`guideSection`, `imagesSection`)
- Create: `app/Sources/FrontbotApp/BrandLinksSheet.swift`
- Modify: `app/Sources/FrontbotApp/AppModel.swift` (next to `guideFromPDF`; line 167 for assets)
- Modify: `app/Sources/FrontbotApp/Theme.swift` (`BrandAvatar`)
- Modify: `app/Localization/en/` (new strings)

**Interfaces:**
- Consumes: `BrandLinks.parse` (Task 2), `setBrandLinks` (Task 1), `linksPrompt` (Task 4), `hasPreviousGuide`/`restorePreviousGuide` (Task 3).
- Produces:
  - `AppModel.guideFromLinks(_ links: [String])` saves the links, then empties `messages`, sets `section = .chat` and sends `linksPrompt(hasGuide: guide != nil)`.
  - `AppModel.canReadWeb: Bool` (`selectedAgent?.provider ?? .claude == .claude`).
  - `AppModel.restorePreviousGuide()`.
  - `AppModel.hasPreviousGuide: Bool`, recalculated in `reloadContent`.
  - `AppModel.logoPath(_ brandId: String) -> String?`, the most recent `.logo`.

Steps:

- [ ] **Step 1:** "Desde links" button next to "Desde un PDF". It is disabled when `model.isRunning || !model.canReadWeb`, with `.help("Este agente no puede leer la web; elige un agente de Claude")` when `!canReadWeb`.
- [ ] **Step 2:** `BrandLinksSheet`: a multi-line `TextEditor` ("Pega uno o más links, uno por línea") prefilled with `brand.links.joined(separator: "\n")`. The invalid entries are listed in red under the field. "Leer links" (`AccentButtonStyle`) is disabled while there are invalid entries or no valid ones. "Cancelar" closes the sheet.
- [ ] **Step 3:** "Restaurar anterior" (`OutlineButtonStyle`) in `guideSection` when `model.hasPreviousGuide && !editingGuide`.
- [ ] **Step 4:** Logo:
  - `BrandAvatar` shows the image at `logoPath` (rounded corners, same size) and falls back to the initials. Pass the path in: add `var logoPath: String? = nil` and update the 4 places where it's used.
  - In `imagesSection`, the logo goes first, labeled "Logo", and can be deleted like the other images.
  - `assets` (line 167) keeps loading only `.image`.
- [ ] **Step 5:** English strings in `app/Localization/en/`.
- [ ] **Step 6: Verify.** `./scripts/build-app.sh && open build/Frontbot.app`, then:
  - Pasting "cafesol.com" (or a real web page) starts the chat with the prompt.
  - The sheet rejects "ftp://x".
  - With a Codex agent, the button is disabled and shows the help text.
  - After the agent saves a guide over an existing one, "Restaurar anterior" brings back the old one.
  - An imported logo shows up in the avatar.

  Take a screenshot of each check.
- [ ] **Step 7: Commit** — `feat(brands): guide from links button`

### Task 8: Onboarding with links

**Files:**
- Modify: `app/Sources/FrontbotApp/OnboardingView.swift` (`brandStep`, `createBrand`, `suggestions`)
- Modify: `app/Sources/FrontbotApp/AppModel.swift` (`createBrand`, `finishOnboarding`)
- Modify: `app/Localization/en/`

**Interfaces:**
- Consumes: `BrandLinks.parse`, `setBrandLinks`, `guideFromLinks`, `canReadWeb`.
- Produces:
  - `AppModel.createBrand(name:industry:networks:links:)`, where `links` defaults to `[]`.
  - `AppModel.finishOnboarding(guideFromLinks: Bool)`, which opens a conversation with the default agent and calls `guideFromLinks(brand.links)`.

Steps:

- [ ] **Step 1:** The "Web (opcional)" field becomes "Links (opcional)" with the placeholder "cafesol.com, instagram.com/cafesol". It is parsed with `BrandLinks.parse`, and if there are invalid entries an error is shown and the brand is not created. New subtitle: "Para quién escribe Frontbot. Si nos das sus links (web, Instagram, LinkedIn…), los leerá para aprender su tono, su estilo y sus imágenes."
- [ ] **Step 2:** In `suggestions`, if there are links and the default agent can read the web, the first entry is "Crear la guía de {marca} desde sus links" and it calls `finishOnboarding(guideFromLinks: true)` instead of sending text. This replaces the old "Lee {web} y escribe la guía…" entry.
- [ ] **Step 3: Verify.** Run a fresh install with `FRONTBOT_DATA_DIR=$(mktemp -d) build/Frontbot.app/Contents/MacOS/Frontbot`, create a brand with two links, pick the suggestion, and check that the chat starts with the links prompt and that `brand.links` was saved (reopen the sheet). Take a screenshot.
- [ ] **Step 4: Commit** — `feat(onboarding): brand links and guide from links`
