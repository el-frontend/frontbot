# Frontbot Fase 1 — Base funcional (walking skeleton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Una app Mac que guarda marcas, posts, tareas e ideas en SQLite y conversa con un agente (Claude Agent SDK en un sidecar Node) que puede leer y crear esos datos mediante herramientas propias, con una UI mínima (marcas + chat + ajustes).

**Architecture:** Paquete SwiftPM en `app/` con una librería `FrontbotCore` (modelos, store GRDB, reglas, JSON-RPC, cliente del agente, Keychain) y un ejecutable `FrontbotApp` (SwiftUI). El sidecar `agent/` (TypeScript) habla JSON-RPC 2.0 delimitado por saltos de línea sobre stdio: la app le pide `agent.run`, y el sidecar llama de vuelta a la app con `tool.*` para leer/escribir datos y emite `agent.event` / `agent.done`.

**Tech Stack:** Swift 6.3, SwiftUI, GRDB.swift 7.x, XCTest · Node 24, TypeScript, `@anthropic-ai/claude-agent-sdk` 0.3.x, zod 4, vitest.

**Spec:** `docs/superpowers/specs/2026-10-13-frontbot-design.md`

**Fases siguientes (planes aparte, no en este):** Fase 2 — calendario, biblioteca de imágenes, aprobación de posts, "Entrevístame" y guía desde PDF. Fase 3 — publicación asistida con Playwright (Instagram, LinkedIn). Fase 4 — notch, atajo global, vistas de tareas e ideas.

**Desviación del spec:** el spec menciona XcodeGen; no está instalado y no hace falta en esta fase. Se usa SwiftPM (`swift build` / `swift test` / `swift run`). El empaquetado `.app` se resuelve en la Fase 4.

## Global Constraints

- macOS 14+ (`platforms: [.macOS(.v14)]`), Swift tools 6.0, modo de lenguaje Swift 6.
- Única dependencia Swift: GRDB.swift (`from: "7.0.0"`).
- Secretos solo en el Keychain (servicio `app.frontbot.credentials`), nunca en disco ni en git.
- Datos en `~/Library/Application Support/Frontbot/` (`frontbot.sqlite`, `brands/<brand_id>/guide.md`, `brands/<brand_id>/assets/`, `ideas/<id>.md`, `runs/<id>.log`).
- Todo registro cuelga de un `workspace_id`; en v1 existe un único workspace creado al iniciar.
- El agente **nunca** puede aprobar, preparar ni publicar posts: solo crear y editar posts en estado `draft`.
- Herramientas del SDK permitidas: solo `WebSearch` y `WebFetch` + las herramientas propias `mcp__frontbot__*`. `permissionMode: 'dontAsk'`, `settingSources: []`, `strictMcpConfig: true`.
- Modelo por defecto `claude-sonnet-5-5`; autenticación por `ANTHROPIC_API_KEY` (pasada al sidecar como variable de entorno).
- Límites: Instagram 2200 caracteres de caption y máx. 30 hashtags; LinkedIn 3000 caracteres.
- Estados de post (código ↔ spec): `draft`=borrador, `approved`=aprobado, `preparing`=preparando, `scheduled`=programado, `published`=publicado, `archived`=archivado.
- Sin telemetría. Red solo hacia Anthropic (y la web vía WebSearch/WebFetch).
- No reutilizar nombres, personaje, íconos ni sonidos de coucou.

## Review Focus

1. **Texto con emojis/acentos y límites de caracteres** — un caption de 2200 emojis debe contar como 2200 (caracteres visibles, `String.count`), no como bytes ni UTF-16. Test en Task 3.
2. **El agente intenta editar un post ya aprobado** — `posts_update_draft` sobre un post `approved` debe fallar con un error legible, sin modificar el post. Test en Task 6.
3. **El sidecar muere a mitad de un run** — el `agent_run` queda `failed`, la UI deja de mostrar "pensando" y el siguiente run funciona tras el reinicio. Test en Task 9.
4. **Mensajes JSON-RPC partidos o varios en un mismo chunk de stdout** — el framer debe reensamblar líneas parciales y separar múltiples mensajes. Tests en Tasks 5 y 7.
5. **Sin API key configurada** — enviar un prompt muestra "Configura tu API key en Ajustes" en vez de arrancar el sidecar y fallar con un error opaco. Test en Task 10.

---

## Estructura de archivos

```
frontbot/
├── .gitignore
├── THIRD_PARTY_NOTICES.md
├── app/
│   ├── Package.swift
│   ├── Sources/FrontbotCore/
│   │   ├── Models/Enums.swift            # Network, PostStatus, Actor, RunStatus
│   │   ├── Models/Records.swift          # Workspace, Brand, BrandAsset, Post, TaskItem, BusinessIdea, AgentRun
│   │   ├── Store/AppDatabase.swift       # apertura + migraciones
│   │   ├── Store/Repositories.swift      # consultas CRUD por entidad
│   │   ├── Store/AppPaths.swift          # rutas en Application Support
│   │   ├── Store/BrandFiles.swift        # guide.md, ideas/<id>.md
│   │   ├── Rules/PostRules.swift         # validación por red
│   │   ├── Rules/PostStateMachine.swift  # transiciones permitidas por actor
│   │   ├── RPC/JSONValue.swift           # JSON dinámico Codable
│   │   ├── RPC/RPCMessage.swift          # request/response/notification + framer
│   │   ├── Agent/ToolHandler.swift       # tool.* → store
│   │   ├── Agent/AgentClient.swift       # proceso sidecar, run/cancel, reinicio
│   │   └── Credentials/CredentialStore.swift
│   ├── Sources/FrontbotApp/
│   │   ├── FrontbotApp.swift
│   │   ├── AppModel.swift
│   │   ├── BrandsView.swift
│   │   ├── ChatView.swift
│   │   └── SettingsView.swift
│   └── Tests/FrontbotCoreTests/
│       ├── PostRulesTests.swift
│       ├── PostStateMachineTests.swift
│       ├── StoreTests.swift
│       ├── BrandFilesTests.swift
│       ├── RPCTests.swift
│       ├── ToolHandlerTests.swift
│       ├── AgentClientTests.swift
│       └── CredentialStoreTests.swift
└── agent/
    ├── package.json
    ├── tsconfig.json
    ├── vitest.config.ts
    ├── src/rpc.ts          # RpcPeer bidireccional sobre streams
    ├── src/tools.ts        # herramientas propias → llamadas tool.* a la app
    ├── src/prompt.ts       # system prompt
    ├── src/runner.ts       # RealRunner (Agent SDK) y FakeRunner (guionado)
    ├── src/main.ts         # entrypoint stdio
    └── test/*.test.ts
```

---

### Task 1: Repo, paquete Swift y modelos con reglas de validación

**Files:**
- Create: `.gitignore`, `THIRD_PARTY_NOTICES.md`, `app/Package.swift`
- Create: `app/Sources/FrontbotCore/Models/Enums.swift`, `app/Sources/FrontbotCore/Rules/PostRules.swift`
- Create: `app/Sources/FrontbotApp/FrontbotApp.swift` (placeholder mínimo para que compile el ejecutable)
- Test: `app/Tests/FrontbotCoreTests/PostRulesTests.swift`

**Interfaces:**
- Produces: `enum Network: String, Codable, CaseIterable, Sendable { case instagram, linkedin }`; `enum PostStatus: String, Codable, CaseIterable, Sendable { case draft, approved, preparing, scheduled, published, archived }`; `enum Actor: Sendable { case user, agent }`; `enum RunStatus: String, Codable, Sendable { case running, done, failed }`; `enum PostRules { static func validate(body: String, network: Network) throws(ValidationError) }`; `struct ValidationError: Error, Equatable, Sendable { let message: String }`.

- [ ] **Step 1: Inicializar git y archivos base**

```bash
cd /Users/chao/Documents/projects/startups/frontbot
git init
```

`.gitignore`:
```
.DS_Store
app/.build/
app/.swiftpm/
agent/node_modules/
agent/dist/
*.log
```

`THIRD_PARTY_NOTICES.md`:
```markdown
# Third-party notices

Partes de Frontbot se basan en código de **coucou** (https://github.com/Louis-CFM/coucou), bajo licencia MIT:

MIT License — Copyright (c) 2026 Louis Raillé

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Los nombres "Coucou" y "Mochi", el personaje, los íconos, los sonidos y los medios de coucou NO están cubiertos por esa licencia y no se usan en Frontbot.
```

- [ ] **Step 2: Crear `app/Package.swift`**

```swift
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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "FrontbotCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "FrontbotApp", dependencies: ["FrontbotCore"]),
        .testTarget(name: "FrontbotCoreTests", dependencies: ["FrontbotCore"]),
    ]
)
```

`app/Sources/FrontbotApp/FrontbotApp.swift` (se reemplaza en Task 10):
```swift
import FrontbotCore
print("Frontbot")
```

- [ ] **Step 3: Escribir el test que falla**

`app/Tests/FrontbotCoreTests/PostRulesTests.swift`:
```swift
import XCTest
@testable import FrontbotCore

final class PostRulesTests: XCTestCase {
    func testInstagramAcceptsExactly2200Characters() throws {
        try PostRules.validate(body: String(repeating: "a", count: 2200), network: .instagram)
    }

    func testInstagramRejects2201Characters() {
        XCTAssertThrowsError(try PostRules.validate(body: String(repeating: "a", count: 2201), network: .instagram)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "El texto de instagram tiene 2201 caracteres; el máximo es 2200.")
        }
    }

    func testEmojisCountAsVisibleCharacters() throws {
        // 2200 emojis con modificador de tono: muchos más bytes/UTF-16, pero 2200 caracteres visibles.
        try PostRules.validate(body: String(repeating: "👍🏽", count: 2200), network: .instagram)
    }

    func testInstagramRejects31Hashtags() {
        let body = (1...31).map { "#tag\($0)" }.joined(separator: " ")
        XCTAssertThrowsError(try PostRules.validate(body: body, network: .instagram)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Instagram admite máximo 30 hashtags; el texto tiene 31.")
        }
    }

    func testInstagramAccepts30HashtagsWithAccents() throws {
        let body = (1...30).map { "#canción\($0)" }.joined(separator: " ")
        try PostRules.validate(body: body, network: .instagram)
    }

    func testLinkedInLimitIs3000() throws {
        try PostRules.validate(body: String(repeating: "é", count: 3000), network: .linkedin)
        XCTAssertThrowsError(try PostRules.validate(body: String(repeating: "é", count: 3001), network: .linkedin))
    }

    func testEmptyBodyIsRejected() {
        XCTAssertThrowsError(try PostRules.validate(body: "   \n", network: .linkedin)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "El texto del post está vacío.")
        }
    }
}
```

- [ ] **Step 4: Correr y verificar que falla**

Run: `cd app && swift test --filter PostRulesTests`
Expected: FAIL de compilación — `cannot find 'PostRules' in scope`.

- [ ] **Step 5: Implementar**

`app/Sources/FrontbotCore/Models/Enums.swift`:
```swift
import Foundation

public enum Network: String, Codable, CaseIterable, Sendable {
    case instagram, linkedin
}

public enum PostStatus: String, Codable, CaseIterable, Sendable {
    case draft, approved, preparing, scheduled, published, archived
}

public enum Actor: Sendable {
    case user, agent
}

public enum RunStatus: String, Codable, Sendable {
    case running, done, failed
}

public struct ValidationError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
```

`app/Sources/FrontbotCore/Rules/PostRules.swift`:
```swift
import Foundation

public enum PostRules {
    public static func maxLength(for network: Network) -> Int {
        switch network {
        case .instagram: 2200
        case .linkedin: 3000
        }
    }

    public static let instagramMaxHashtags = 30

    public static func validate(body: String, network: Network) throws(ValidationError) {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("El texto del post está vacío.")
        }
        let count = body.count
        let max = maxLength(for: network)
        if count > max {
            throw ValidationError("El texto de \(network.rawValue) tiene \(count) caracteres; el máximo es \(max).")
        }
        if network == .instagram {
            let hashtags = hashtagCount(in: body)
            if hashtags > instagramMaxHashtags {
                throw ValidationError("Instagram admite máximo \(instagramMaxHashtags) hashtags; el texto tiene \(hashtags).")
            }
        }
    }

    static func hashtagCount(in body: String) -> Int {
        body.split(whereSeparator: \.isWhitespace)
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .count
    }
}
```

- [ ] **Step 6: Correr y verificar que pasa**

Run: `cd app && swift test --filter PostRulesTests`
Expected: PASS (7 tests). La primera vez descarga GRDB.

- [ ] **Step 7: Commit**

```bash
git add .gitignore THIRD_PARTY_NOTICES.md app docs
git commit -m "feat: scaffold Swift package with post validation rules"
```

---

### Task 2: Máquina de estados de posts

**Files:**
- Create: `app/Sources/FrontbotCore/Rules/PostStateMachine.swift`
- Test: `app/Tests/FrontbotCoreTests/PostStateMachineTests.swift`

**Interfaces:**
- Consumes: `PostStatus`, `Actor`, `ValidationError` (Task 1).
- Produces: `enum PostStateMachine { static func canTransition(from: PostStatus, to: PostStatus, actor: Actor) -> Bool; static func checkTransition(from: PostStatus, to: PostStatus, actor: Actor) throws(ValidationError) }`.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class PostStateMachineTests: XCTestCase {
    func testUserFlowHappyPath() {
        XCTAssertTrue(PostStateMachine.canTransition(from: .draft, to: .approved, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .approved, to: .preparing, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .preparing, to: .published, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .preparing, to: .scheduled, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .scheduled, to: .published, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .preparing, to: .approved, actor: .user))
    }

    func testUserCanArchiveFromAnyState() {
        for status in PostStatus.allCases where status != .archived {
            XCTAssertTrue(PostStateMachine.canTransition(from: status, to: .archived, actor: .user), "\(status)")
        }
    }

    func testUserCannotSkipSteps() {
        XCTAssertFalse(PostStateMachine.canTransition(from: .draft, to: .published, actor: .user))
        XCTAssertFalse(PostStateMachine.canTransition(from: .draft, to: .preparing, actor: .user))
        XCTAssertFalse(PostStateMachine.canTransition(from: .published, to: .draft, actor: .user))
    }

    func testAgentCannotMovePostsAtAll() {
        for from in PostStatus.allCases {
            for to in PostStatus.allCases where to != from {
                XCTAssertFalse(PostStateMachine.canTransition(from: from, to: to, actor: .agent), "\(from)->\(to)")
            }
        }
    }

    func testCheckTransitionThrowsReadableError() {
        XCTAssertThrowsError(try PostStateMachine.checkTransition(from: .draft, to: .published, actor: .user)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "No se puede pasar un post de draft a published.")
        }
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter PostStateMachineTests`
Expected: FAIL — `cannot find 'PostStateMachine' in scope`.

- [ ] **Step 3: Implementar**

```swift
import Foundation

public enum PostStateMachine {
    private static let userTransitions: [PostStatus: Set<PostStatus>] = [
        .draft: [.approved],
        .approved: [.preparing],
        .preparing: [.published, .scheduled, .approved],
        .scheduled: [.published],
        .published: [],
        .archived: [],
    ]

    public static func canTransition(from: PostStatus, to: PostStatus, actor: Actor) -> Bool {
        guard actor == .user else { return false }
        if to == .archived { return from != .archived }
        return userTransitions[from, default: []].contains(to)
    }

    public static func checkTransition(from: PostStatus, to: PostStatus, actor: Actor) throws(ValidationError) {
        guard canTransition(from: from, to: to, actor: actor) else {
            throw ValidationError("No se puede pasar un post de \(from.rawValue) a \(to.rawValue).")
        }
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd app && swift test --filter PostStateMachineTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat: add post state machine restricting transitions to the user"
```

---

### Task 3: Base de datos, migraciones y repositorios

**Files:**
- Create: `app/Sources/FrontbotCore/Models/Records.swift`, `app/Sources/FrontbotCore/Store/AppDatabase.swift`, `app/Sources/FrontbotCore/Store/Repositories.swift`
- Test: `app/Tests/FrontbotCoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `Network`, `PostStatus`, `RunStatus`, `Actor`, `PostRules`, `PostStateMachine`, `ValidationError`.
- Produces:
  - Records (todos `Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable`, `id: String` UUID, fechas `Date`): `Workspace(id, name, createdAt)`, `Brand(id, workspaceId, name, industry, networks: [Network], createdAt)`, `BrandAsset(id, brandId, kind: String, path: String, createdAt)`, `Post(id, brandId, network: Network, body, media: [String], status: PostStatus, scheduledFor: Date?, publishedUrl: String?, createdAt, updatedAt)`, `TaskItem(id, workspaceId, title, dueDate: Date?, done: Bool, brandId: String?, createdAt)`, `BusinessIdea(id, workspaceId, title, summary, sources: [String], score: Int, reportPath: String?, createdAt)`, `AgentRun(id, workspaceId, brandId: String?, prompt, status: RunStatus, resultSummary: String?, inputTokens: Int, outputTokens: Int, costUsd: Double, logPath: String?, createdAt)`.
  - `final class AppDatabase: Sendable { let writer: any DatabaseWriter; static func inMemory() throws -> AppDatabase; static func open(at url: URL) throws -> AppDatabase; func ensureDefaultWorkspace() throws -> Workspace }`.
  - En `extension AppDatabase`: `createBrand(workspaceId:name:industry:networks:) throws -> Brand`, `brands(workspaceId:) throws -> [Brand]`, `brand(id:) throws -> Brand?`, `createDraft(brandId:network:body:media:scheduledFor:) throws -> Post`, `updateDraft(id:body:media:scheduledFor:) throws -> Post` (lanza si no es `draft`), `transitionPost(id:to:actor:) throws -> Post`, `posts(brandId: String?, status: PostStatus?) throws -> [Post]`, `createTask(workspaceId:title:dueDate:brandId:) throws -> TaskItem`, `tasks(workspaceId:on day: Date?) throws -> [TaskItem]`, `completeTask(id:) throws -> TaskItem`, `createIdea(workspaceId:title:summary:sources:score:) throws -> BusinessIdea`, `setIdeaReportPath(id:path:) throws`, `startRun(workspaceId:brandId:prompt:) throws -> AgentRun`, `finishRun(id:status:summary:inputTokens:outputTokens:costUsd:) throws -> AgentRun`, `failRunningRuns() throws -> Int`, `runs(workspaceId:) throws -> [AgentRun]`.
  - Errores de "no existe" se lanzan como `ValidationError("No existe <entidad> con id <id>.")`.

- [ ] **Step 1: Escribir el test que falla**

`app/Tests/FrontbotCoreTests/StoreTests.swift`:
```swift
import XCTest
@testable import FrontbotCore

final class StoreTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
    }

    func testEnsureDefaultWorkspaceIsIdempotent() throws {
        let again = try db.ensureDefaultWorkspace()
        XCTAssertEqual(again.id, ws.id)
    }

    func testCreateAndListBrands() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "Café Sol", industry: "Cafetería", networks: [.instagram, .linkedin])
        XCTAssertEqual(try db.brands(workspaceId: ws.id), [brand])
        XCTAssertEqual(try db.brand(id: brand.id)?.networks, [.instagram, .linkedin])
    }

    func testBrandNameIsRequired() {
        XCTAssertThrowsError(try db.createBrand(workspaceId: ws.id, name: "  ", industry: "", networks: [.instagram]))
    }

    func testCreateDraftValidatesBody() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        XCTAssertThrowsError(try db.createDraft(brandId: brand.id, network: .instagram, body: String(repeating: "x", count: 2201), media: [], scheduledFor: nil))
        let post = try db.createDraft(brandId: brand.id, network: .instagram, body: "Hola ☕️", media: [], scheduledFor: nil)
        XCTAssertEqual(post.status, .draft)
    }

    func testCreateDraftRejectsNetworkNotEnabledForBrand() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        XCTAssertThrowsError(try db.createDraft(brandId: brand.id, network: .linkedin, body: "Hola", media: [], scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La marca B no tiene linkedin configurado.")
        }
    }

    func testCreateDraftRejectsUnknownBrand() {
        XCTAssertThrowsError(try db.createDraft(brandId: "nope", network: .instagram, body: "Hola", media: [], scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "No existe marca con id nope.")
        }
    }

    func testUpdateDraftFailsWhenPostIsApproved() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        let post = try db.createDraft(brandId: brand.id, network: .instagram, body: "v1", media: [], scheduledFor: nil)
        _ = try db.transitionPost(id: post.id, to: .approved, actor: .user)
        XCTAssertThrowsError(try db.updateDraft(id: post.id, body: "v2", media: nil, scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Solo se pueden editar posts en borrador; este está en approved.")
        }
        XCTAssertEqual(try db.posts(brandId: brand.id, status: nil).first?.body, "v1")
    }

    func testAgentCannotTransitionPost() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        let post = try db.createDraft(brandId: brand.id, network: .instagram, body: "v1", media: [], scheduledFor: nil)
        XCTAssertThrowsError(try db.transitionPost(id: post.id, to: .approved, actor: .agent))
    }

    func testTasksForDayAndComplete() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let t1 = try db.createTask(workspaceId: ws.id, title: "Grabar reel", dueDate: today.addingTimeInterval(3600), brandId: nil)
        _ = try db.createTask(workspaceId: ws.id, title: "Mañana", dueDate: tomorrow.addingTimeInterval(60), brandId: nil)
        XCTAssertEqual(try db.tasks(workspaceId: ws.id, on: today).map(\.title), ["Grabar reel"])
        XCTAssertTrue(try db.completeTask(id: t1.id).done)
    }

    func testIdeaScoreMustBe1To5() throws {
        XCTAssertThrowsError(try db.createIdea(workspaceId: ws.id, title: "X", summary: "Y", sources: [], score: 6))
        let idea = try db.createIdea(workspaceId: ws.id, title: "X", summary: "Y", sources: ["https://a.com"], score: 4)
        XCTAssertEqual(idea.sources, ["https://a.com"])
    }

    func testRunsLifecycleAndCrashRecovery() throws {
        let run = try db.startRun(workspaceId: ws.id, brandId: nil, prompt: "hola")
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(try db.failRunningRuns(), 1)
        XCTAssertEqual(try db.runs(workspaceId: ws.id).first?.status, .failed)
        let run2 = try db.startRun(workspaceId: ws.id, brandId: nil, prompt: "otra")
        let done = try db.finishRun(id: run2.id, status: .done, summary: "ok", inputTokens: 10, outputTokens: 5, costUsd: 0.01)
        XCTAssertEqual(done.costUsd, 0.01)
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter StoreTests`
Expected: FAIL — `cannot find 'AppDatabase' in scope`.

- [ ] **Step 3: Implementar records**

`app/Sources/FrontbotCore/Models/Records.swift`:
```swift
import Foundation
import GRDB

public struct Workspace: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
}

public struct Brand: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var name: String
    public var industry: String
    public var networks: [Network]
    public var createdAt: Date
}

public struct BrandAsset: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var brandId: String
    public var kind: String
    public var path: String
    public var createdAt: Date
}

public struct Post: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var brandId: String
    public var network: Network
    public var body: String
    public var media: [String]
    public var status: PostStatus
    public var scheduledFor: Date?
    public var publishedUrl: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct TaskItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "task"
    public var id: String
    public var workspaceId: String
    public var title: String
    public var dueDate: Date?
    public var done: Bool
    public var brandId: String?
    public var createdAt: Date
}

public struct BusinessIdea: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var title: String
    public var summary: String
    public var sources: [String]
    public var score: Int
    public var reportPath: String?
    public var createdAt: Date
}

public struct AgentRun: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var brandId: String?
    public var prompt: String
    public var status: RunStatus
    public var resultSummary: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUsd: Double
    public var logPath: String?
    public var createdAt: Date
}
```

Notas: GRDB guarda los arrays (`networks`, `media`, `sources`) como JSON en columnas de texto automáticamente porque son `Codable`. Los nombres de tabla por defecto son el nombre del tipo en lowerCamelCase (`workspace`, `brand`, `brandAsset`, `post`, `businessIdea`, `agentRun`); `TaskItem` fuerza `task`.

- [ ] **Step 4: Implementar `AppDatabase` con migraciones**

`app/Sources/FrontbotCore/Store/AppDatabase.swift`:
```swift
import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "brand") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("industry", .text).notNull()
                t.column("networks", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "brandAsset") { t in
                t.primaryKey("id", .text)
                t.column("brandId", .text).notNull().references("brand", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "post") { t in
                t.primaryKey("id", .text)
                t.column("brandId", .text).notNull().references("brand", onDelete: .cascade)
                t.column("network", .text).notNull()
                t.column("body", .text).notNull()
                t.column("media", .text).notNull()
                t.column("status", .text).notNull()
                t.column("scheduledFor", .datetime)
                t.column("publishedUrl", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("dueDate", .datetime)
                t.column("done", .boolean).notNull().defaults(to: false)
                t.column("brandId", .text).references("brand", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "businessIdea") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("sources", .text).notNull()
                t.column("score", .integer).notNull()
                t.column("reportPath", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "agentRun") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("brandId", .text).references("brand", onDelete: .setNull)
                t.column("prompt", .text).notNull()
                t.column("status", .text).notNull()
                t.column("resultSummary", .text)
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("costUsd", .double).notNull()
                t.column("logPath", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }
        return m
    }

    public func ensureDefaultWorkspace() throws -> Workspace {
        try writer.write { db in
            if let existing = try Workspace.order(Column("createdAt")).fetchOne(db) { return existing }
            let ws = Workspace(id: UUID().uuidString, name: "Mi espacio", createdAt: Date())
            try ws.insert(db)
            return ws
        }
    }
}
```

- [ ] **Step 5: Implementar repositorios**

`app/Sources/FrontbotCore/Store/Repositories.swift`:
```swift
import Foundation
import GRDB

private func notFound(_ entity: String, _ id: String) -> ValidationError {
    ValidationError("No existe \(entity) con id \(id).")
}

extension AppDatabase {
    // MARK: Brands
    public func createBrand(workspaceId: String, name: String, industry: String, networks: [Network]) throws -> Brand {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError("La marca necesita un nombre.") }
        let brand = Brand(id: UUID().uuidString, workspaceId: workspaceId, name: trimmed, industry: industry, networks: networks, createdAt: Date())
        try writer.write { try brand.insert($0) }
        return brand
    }

    public func brands(workspaceId: String) throws -> [Brand] {
        try writer.read { try Brand.filter(Column("workspaceId") == workspaceId).order(Column("name")).fetchAll($0) }
    }

    public func brand(id: String) throws -> Brand? {
        try writer.read { try Brand.fetchOne($0, key: id) }
    }

    // MARK: Posts
    public func createDraft(brandId: String, network: Network, body: String, media: [String], scheduledFor: Date?) throws -> Post {
        guard let brand = try brand(id: brandId) else { throw notFound("marca", brandId) }
        guard brand.networks.contains(network) else {
            throw ValidationError("La marca \(brand.name) no tiene \(network.rawValue) configurado.")
        }
        try PostRules.validate(body: body, network: network)
        let now = Date()
        let post = Post(id: UUID().uuidString, brandId: brandId, network: network, body: body, media: media,
                        status: .draft, scheduledFor: scheduledFor, publishedUrl: nil, createdAt: now, updatedAt: now)
        try writer.write { try post.insert($0) }
        return post
    }

    public func updateDraft(id: String, body: String?, media: [String]?, scheduledFor: Date?) throws -> Post {
        try writer.write { db in
            guard var post = try Post.fetchOne(db, key: id) else { throw notFound("post", id) }
            guard post.status == .draft else {
                throw ValidationError("Solo se pueden editar posts en borrador; este está en \(post.status.rawValue).")
            }
            if let body {
                try PostRules.validate(body: body, network: post.network)
                post.body = body
            }
            if let media { post.media = media }
            if let scheduledFor { post.scheduledFor = scheduledFor }
            post.updatedAt = Date()
            try post.update(db)
            return post
        }
    }

    public func transitionPost(id: String, to status: PostStatus, actor: Actor) throws -> Post {
        try writer.write { db in
            guard var post = try Post.fetchOne(db, key: id) else { throw notFound("post", id) }
            try PostStateMachine.checkTransition(from: post.status, to: status, actor: actor)
            post.status = status
            post.updatedAt = Date()
            try post.update(db)
            return post
        }
    }

    public func posts(brandId: String?, status: PostStatus?) throws -> [Post] {
        try writer.read { db in
            var request = Post.all()
            if let brandId { request = request.filter(Column("brandId") == brandId) }
            if let status { request = request.filter(Column("status") == status.rawValue) }
            return try request.order(Column("scheduledFor"), Column("createdAt")).fetchAll(db)
        }
    }

    // MARK: Tasks
    public func createTask(workspaceId: String, title: String, dueDate: Date?, brandId: String?) throws -> TaskItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError("La tarea necesita un título.") }
        if let brandId, try brand(id: brandId) == nil { throw notFound("marca", brandId) }
        let task = TaskItem(id: UUID().uuidString, workspaceId: workspaceId, title: trimmed, dueDate: dueDate, done: false, brandId: brandId, createdAt: Date())
        try writer.write { try task.insert($0) }
        return task
    }

    public func tasks(workspaceId: String, on day: Date?) throws -> [TaskItem] {
        try writer.read { db in
            var request = TaskItem.filter(Column("workspaceId") == workspaceId)
            if let day {
                let start = Calendar.current.startOfDay(for: day)
                let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
                request = request.filter(Column("dueDate") >= start && Column("dueDate") < end)
            }
            return try request.order(Column("done"), Column("dueDate")).fetchAll(db)
        }
    }

    public func completeTask(id: String) throws -> TaskItem {
        try writer.write { db in
            guard var task = try TaskItem.fetchOne(db, key: id) else { throw notFound("tarea", id) }
            task.done = true
            try task.update(db)
            return task
        }
    }

    // MARK: Ideas
    public func createIdea(workspaceId: String, title: String, summary: String, sources: [String], score: Int) throws -> BusinessIdea {
        guard (1...5).contains(score) else { throw ValidationError("El puntaje debe estar entre 1 y 5; recibido \(score).") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("La idea necesita un título.") }
        let idea = BusinessIdea(id: UUID().uuidString, workspaceId: workspaceId, title: title, summary: summary, sources: sources, score: score, reportPath: nil, createdAt: Date())
        try writer.write { try idea.insert($0) }
        return idea
    }

    public func setIdeaReportPath(id: String, path: String) throws {
        try writer.write { db in
            guard var idea = try BusinessIdea.fetchOne(db, key: id) else { throw notFound("idea", id) }
            idea.reportPath = path
            try idea.update(db)
        }
    }

    // MARK: Runs
    public func startRun(workspaceId: String, brandId: String?, prompt: String) throws -> AgentRun {
        let run = AgentRun(id: UUID().uuidString, workspaceId: workspaceId, brandId: brandId, prompt: prompt, status: .running,
                           resultSummary: nil, inputTokens: 0, outputTokens: 0, costUsd: 0, logPath: nil, createdAt: Date())
        try writer.write { try run.insert($0) }
        return run
    }

    public func finishRun(id: String, status: RunStatus, summary: String?, inputTokens: Int, outputTokens: Int, costUsd: Double) throws -> AgentRun {
        try writer.write { db in
            guard var run = try AgentRun.fetchOne(db, key: id) else { throw notFound("ejecución", id) }
            run.status = status
            run.resultSummary = summary
            run.inputTokens = inputTokens
            run.outputTokens = outputTokens
            run.costUsd = costUsd
            try run.update(db)
            return run
        }
    }

    @discardableResult
    public func failRunningRuns() throws -> Int {
        try writer.write { db in
            try AgentRun.filter(Column("status") == RunStatus.running.rawValue)
                .updateAll(db, Column("status").set(to: RunStatus.failed.rawValue))
        }
    }

    public func runs(workspaceId: String) throws -> [AgentRun] {
        try writer.read { try AgentRun.filter(Column("workspaceId") == workspaceId).order(Column("createdAt").desc).fetchAll($0) }
    }
}
```

- [ ] **Step 6: Correr y verificar que pasa**

Run: `cd app && swift test --filter StoreTests`
Expected: PASS (11 tests).

- [ ] **Step 7: Commit**

```bash
git add app
git commit -m "feat: add SQLite store with migrations and repositories"
```

---

### Task 4: Rutas y archivos de marca (guide.md, reportes)

**Files:**
- Create: `app/Sources/FrontbotCore/Store/AppPaths.swift`, `app/Sources/FrontbotCore/Store/BrandFiles.swift`
- Test: `app/Tests/FrontbotCoreTests/BrandFilesTests.swift`

**Interfaces:**
- Produces: `struct AppPaths: Sendable { let root: URL; static func standard() -> AppPaths; var database: URL; func brandDir(_ brandId: String) -> URL; func guide(_ brandId: String) -> URL; func ideaReport(_ ideaId: String) -> URL; func runLog(_ runId: String) -> URL }`; `struct BrandFiles: Sendable { init(paths: AppPaths); func readGuide(brandId:) throws -> String?; func writeGuide(brandId:markdown:) throws; func writeIdeaReport(ideaId:markdown:) throws -> URL }`.
- `brandId`/`ideaId` deben ser UUID válidos (protege contra rutas tipo `../`).

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class BrandFilesTests: XCTestCase {
    var root: URL!
    var files: BrandFiles!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = BrandFiles(paths: AppPaths(root: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testGuideRoundTrip() throws {
        let id = UUID().uuidString
        XCTAssertNil(try files.readGuide(brandId: id))
        try files.writeGuide(brandId: id, markdown: "# Tono\nCercano ☕️")
        XCTAssertEqual(try files.readGuide(brandId: id), "# Tono\nCercano ☕️")
    }

    func testRejectsPathTraversalIds() {
        XCTAssertThrowsError(try files.writeGuide(brandId: "../../etc", markdown: "x"))
        XCTAssertThrowsError(try files.readGuide(brandId: "../x"))
    }

    func testIdeaReportIsWritten() throws {
        let url = try files.writeIdeaReport(ideaId: UUID().uuidString, markdown: "# Reporte")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Reporte")
        XCTAssertTrue(url.path.hasPrefix(root.path))
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter BrandFilesTests`
Expected: FAIL — `cannot find 'BrandFiles' in scope`.

- [ ] **Step 3: Implementar**

`app/Sources/FrontbotCore/Store/AppPaths.swift`:
```swift
import Foundation

public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard() -> AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: support.appendingPathComponent("Frontbot", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("frontbot.sqlite") }
    public func brandDir(_ brandId: String) -> URL { root.appendingPathComponent("brands/\(brandId)", isDirectory: true) }
    public func guide(_ brandId: String) -> URL { brandDir(brandId).appendingPathComponent("guide.md") }
    public func ideaReport(_ ideaId: String) -> URL { root.appendingPathComponent("ideas/\(ideaId).md") }
    public func runLog(_ runId: String) -> URL { root.appendingPathComponent("runs/\(runId).log") }
}
```

`app/Sources/FrontbotCore/Store/BrandFiles.swift`:
```swift
import Foundation

public struct BrandFiles: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    private func checkId(_ id: String) throws(ValidationError) {
        guard UUID(uuidString: id) != nil else { throw ValidationError("Id inválido: \(id).") }
    }

    public func readGuide(brandId: String) throws -> String? {
        try checkId(brandId)
        let url = paths.guide(brandId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeGuide(brandId: String, markdown: String) throws {
        try checkId(brandId)
        try write(markdown, to: paths.guide(brandId))
    }

    public func writeIdeaReport(ideaId: String, markdown: String) throws -> URL {
        try checkId(ideaId)
        let url = paths.ideaReport(ideaId)
        try write(markdown, to: url)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd app && swift test --filter BrandFilesTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat: add app paths and brand guide/report files"
```

---

### Task 5: JSON-RPC en Swift (JSONValue, mensajes, framer)

**Files:**
- Create: `app/Sources/FrontbotCore/RPC/JSONValue.swift`, `app/Sources/FrontbotCore/RPC/RPCMessage.swift`
- Test: `app/Tests/FrontbotCoreTests/RPCTests.swift`

**Interfaces:**
- Produces:
  - `enum JSONValue: Codable, Equatable, Sendable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }` con accesores `subscript(key: String) -> JSONValue?`, `var stringValue: String?`, `var intValue: Int?`, `var doubleValue: Double?`, `var boolValue: Bool?`, `var arrayValue: [JSONValue]?`; e inicializadores literales (`ExpressibleByStringLiteral`, `...IntegerLiteral`, `...FloatLiteral`, `...BooleanLiteral`, `...ArrayLiteral`, `...DictionaryLiteral`, `...NilLiteral`).
  - `enum RPCMessage: Equatable, Sendable { case request(id: Int, method: String, params: JSONValue); case notification(method: String, params: JSONValue); case response(id: Int, result: JSONValue); case error(id: Int, code: Int, message: String) }` con `func encodedLine() throws -> Data` (JSON + `\n`) y `static func decode(_ line: Data) throws -> RPCMessage`.
  - `struct LineFramer { mutating func append(_ data: Data) -> [Data] }` — devuelve las líneas completas (sin `\n`), conserva el resto parcial.
- Formato en el cable: `{"jsonrpc":"2.0","id":1,"method":"...","params":{...}}`, `{"jsonrpc":"2.0","method":"...","params":{...}}`, `{"jsonrpc":"2.0","id":1,"result":...}`, `{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"..."}}`.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class RPCTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let msg = RPCMessage.request(id: 7, method: "tool.brands_list", params: ["limit": 5, "name": "Café ☕️"])
        let line = try msg.encodedLine()
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        XCTAssertEqual(try RPCMessage.decode(line.dropLast()), msg)
    }

    func testDecodesAllShapes() throws {
        XCTAssertEqual(try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","method":"agent.event","params":{"type":"text"}}"#.utf8)),
                       .notification(method: "agent.event", params: ["type": "text"]))
        XCTAssertEqual(try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8)),
                       .response(id: 3, result: ["ok": true]))
        XCTAssertEqual(try RPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"mal"}}"#.utf8)),
                       .error(id: 3, code: -32000, message: "mal"))
    }

    func testDecodeGarbageThrows() {
        XCTAssertThrowsError(try RPCMessage.decode(Data("no json".utf8)))
    }

    func testFramerReassemblesPartialLines() {
        var framer = LineFramer()
        XCTAssertEqual(framer.append(Data(#"{"a":"#.utf8)), [])
        XCTAssertEqual(framer.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8)), [Data(#"{"a":1}"#.utf8), Data(#"{"b":2}"#.utf8)])
        XCTAssertEqual(framer.append(Data(":3}\n".utf8)), [Data(#"{"c":3}"#.utf8)])
    }

    func testFramerSkipsEmptyLines() {
        var framer = LineFramer()
        XCTAssertEqual(framer.append(Data("\n\n{\"a\":1}\n".utf8)), [Data(#"{"a":1}"#.utf8)])
    }

    func testJSONValueAccessors() {
        let v: JSONValue = ["n": 3, "s": "x", "arr": ["a"], "b": true, "nil": nil]
        XCTAssertEqual(v["n"]?.intValue, 3)
        XCTAssertEqual(v["s"]?.stringValue, "x")
        XCTAssertEqual(v["arr"]?.arrayValue, ["a"])
        XCTAssertEqual(v["b"]?.boolValue, true)
        XCTAssertEqual(v["nil"], .null)
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter RPCTests`
Expected: FAIL — `cannot find 'RPCMessage' in scope`.

- [ ] **Step 3: Implementar `JSONValue`**

```swift
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(nilLiteral: ()) { self = .null }
}
```

- [ ] **Step 4: Implementar `RPCMessage` y `LineFramer`**

```swift
import Foundation

public enum RPCMessage: Equatable, Sendable {
    case request(id: Int, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: Int, result: JSONValue)
    case error(id: Int, code: Int, message: String)

    public func encodedLine() throws -> Data {
        var obj: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            obj["id"] = .number(Double(id)); obj["method"] = .string(method); obj["params"] = params
        case .notification(let method, let params):
            obj["method"] = .string(method); obj["params"] = params
        case .response(let id, let result):
            obj["id"] = .number(Double(id)); obj["result"] = result
        case .error(let id, let code, let message):
            obj["id"] = .number(Double(id))
            obj["error"] = ["code": .number(Double(code)), "message": .string(message)]
        }
        var data = try JSONEncoder().encode(JSONValue.object(obj))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func decode(_ line: Data) throws -> RPCMessage {
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        guard case .object = value else { throw ValidationError("Mensaje RPC no es un objeto.") }
        let id = value["id"]?.intValue
        if let method = value["method"]?.stringValue {
            let params = value["params"] ?? .null
            if let id { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id else { throw ValidationError("Respuesta RPC sin id.") }
        if let err = value["error"] {
            return .error(id: id, code: err["code"]?.intValue ?? -32000, message: err["message"]?.stringValue ?? "Error desconocido")
        }
        return .response(id: id, result: value["result"] ?? .null)
    }
}

public struct LineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<idx]
            buffer = Data(buffer[buffer.index(after: idx)...])
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}
```

- [ ] **Step 5: Correr y verificar que pasa**

Run: `cd app && swift test --filter RPCTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add app
git commit -m "feat: add JSON-RPC message codec and line framer"
```

---

### Task 6: ToolHandler — herramientas `tool.*` contra el store

**Files:**
- Create: `app/Sources/FrontbotCore/Agent/ToolHandler.swift`
- Test: `app/Tests/FrontbotCoreTests/ToolHandlerTests.swift`

**Interfaces:**
- Consumes: `AppDatabase` y sus métodos (Task 3), `BrandFiles` (Task 4), `JSONValue` (Task 5).
- Produces: `struct ToolHandler: Sendable { init(db: AppDatabase, files: BrandFiles, workspaceId: String); func handle(method: String, params: JSONValue) throws -> JSONValue }`.
- Métodos atendidos (el prefijo `tool.` viene del sidecar; los parámetros usan snake_case):
  - `tool.brands_list {}` → `{"brands":[{"id","name","industry","networks":[...]}]}`
  - `tool.brands_get_guide {"brand_id"}` → `{"guide": "<md>"|null}`
  - `tool.brands_write_guide {"brand_id","markdown"}` → `{"ok":true}`
  - `tool.posts_list {"brand_id"?, "status"?}` → `{"posts":[{"id","brand_id","network","body","status","scheduled_for"}]}` (fecha ISO-8601 o null)
  - `tool.posts_create_draft {"brand_id","network","body","scheduled_for"?}` → `{"post_id"}`
  - `tool.posts_update_draft {"post_id","body"?,"scheduled_for"?}` → `{"ok":true}`
  - `tool.tasks_list {"date"?: "YYYY-MM-DD"}` → `{"tasks":[{"id","title","due_date","done"}]}`
  - `tool.tasks_create {"title","due_date"?: ISO-8601 o "YYYY-MM-DD","brand_id"?}` → `{"task_id"}`
  - `tool.tasks_complete {"task_id"}` → `{"ok":true}`
  - `tool.ideas_create {"title","summary","sources":[...],"score","report_markdown"}` → `{"idea_id"}`
- Cualquier otro método lanza `ValidationError("Herramienta desconocida: <method>.")`. Faltantes lanzan `ValidationError("Falta el parámetro <nombre>.")`. No existe ninguna herramienta que apruebe ni publique.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class ToolHandlerTests: XCTestCase {
    var db: AppDatabase!
    var handler: ToolHandler!
    var brand: Brand!
    var root: URL!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        brand = try db.createBrand(workspaceId: ws.id, name: "Café Sol", industry: "Cafetería", networks: [.instagram])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testBrandsList() throws {
        let result = try handler.handle(method: "tool.brands_list", params: [:])
        XCTAssertEqual(result["brands"]?.arrayValue?.first?["name"]?.stringValue, "Café Sol")
        XCTAssertEqual(result["brands"]?.arrayValue?.first?["networks"], ["instagram"])
    }

    func testGuideWriteAndRead() throws {
        XCTAssertEqual(try handler.handle(method: "tool.brands_get_guide", params: ["brand_id": .string(brand.id)])["guide"], .null)
        _ = try handler.handle(method: "tool.brands_write_guide", params: ["brand_id": .string(brand.id), "markdown": "# Tono"])
        XCTAssertEqual(try handler.handle(method: "tool.brands_get_guide", params: ["brand_id": .string(brand.id)])["guide"], "# Tono")
    }

    func testCreateDraftThenList() throws {
        let created = try handler.handle(method: "tool.posts_create_draft", params: [
            "brand_id": .string(brand.id), "network": "instagram", "body": "Lunes de café ☕️", "scheduled_for": "2026-10-20T09:00:00Z",
        ])
        XCTAssertNotNil(created["post_id"]?.stringValue)
        let list = try handler.handle(method: "tool.posts_list", params: ["brand_id": .string(brand.id)])
        let post = list["posts"]?.arrayValue?.first
        XCTAssertEqual(post?["status"], "draft")
        XCTAssertEqual(post?["scheduled_for"], "2026-10-20T09:00:00Z")
    }

    func testUpdateDraftOnApprovedPostFailsAndKeepsBody() throws {
        let created = try handler.handle(method: "tool.posts_create_draft", params: ["brand_id": .string(brand.id), "network": "instagram", "body": "v1"])
        let id = created["post_id"]!.stringValue!
        _ = try db.transitionPost(id: id, to: .approved, actor: .user)
        XCTAssertThrowsError(try handler.handle(method: "tool.posts_update_draft", params: ["post_id": .string(id), "body": "v2"])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Solo se pueden editar posts en borrador; este está en approved.")
        }
        XCTAssertEqual(try db.posts(brandId: brand.id, status: nil).first?.body, "v1")
    }

    func testInvalidNetworkAndMissingParams() {
        XCTAssertThrowsError(try handler.handle(method: "tool.posts_create_draft", params: ["brand_id": .string(brand.id), "network": "tiktok", "body": "x"])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Red no soportada: tiktok. Usa instagram o linkedin.")
        }
        XCTAssertThrowsError(try handler.handle(method: "tool.posts_create_draft", params: ["brand_id": .string(brand.id), "network": "instagram"])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Falta el parámetro body.")
        }
    }

    func testTasksCreateWithDateOnlyAndList() throws {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let today = fmt.string(from: Date())
        let created = try handler.handle(method: "tool.tasks_create", params: ["title": "Grabar reel", "due_date": .string(today)])
        let list = try handler.handle(method: "tool.tasks_list", params: ["date": .string(today)])
        XCTAssertEqual(list["tasks"]?.arrayValue?.first?["title"], "Grabar reel")
        _ = try handler.handle(method: "tool.tasks_complete", params: ["task_id": created["task_id"]!])
        XCTAssertEqual(try handler.handle(method: "tool.tasks_list", params: ["date": .string(today)])["tasks"]?.arrayValue?.first?["done"], true)
    }

    func testIdeasCreateWritesReport() throws {
        let result = try handler.handle(method: "tool.ideas_create", params: [
            "title": "Café de especialidad a domicilio", "summary": "Suscripción mensual", "sources": ["https://ejemplo.com"],
            "score": 4, "report_markdown": "# Reporte\nDetalle",
        ])
        let id = result["idea_id"]!.stringValue!
        let report = AppPaths(root: root).ideaReport(id)
        XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "# Reporte\nDetalle")
    }

    func testUnknownToolAndNoPublishTool() {
        for method in ["tool.posts_publish", "tool.posts_approve", "tool.nope"] {
            XCTAssertThrowsError(try handler.handle(method: method, params: [:])) { error in
                XCTAssertEqual((error as? ValidationError)?.message, "Herramienta desconocida: \(method).")
            }
        }
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter ToolHandlerTests`
Expected: FAIL — `cannot find 'ToolHandler' in scope`.

- [ ] **Step 3: Implementar**

```swift
import Foundation

public struct ToolHandler: Sendable {
    let db: AppDatabase
    let files: BrandFiles
    let workspaceId: String

    public init(db: AppDatabase, files: BrandFiles, workspaceId: String) {
        self.db = db
        self.files = files
        self.workspaceId = workspaceId
    }

    public func handle(method: String, params: JSONValue) throws -> JSONValue {
        switch method {
        case "tool.brands_list":
            let brands = try db.brands(workspaceId: workspaceId)
            return ["brands": .array(brands.map { b in
                ["id": .string(b.id), "name": .string(b.name), "industry": .string(b.industry),
                 "networks": .array(b.networks.map { .string($0.rawValue) })]
            })]
        case "tool.brands_get_guide":
            let id = try string(params, "brand_id")
            return ["guide": try files.readGuide(brandId: id).map(JSONValue.string) ?? .null]
        case "tool.brands_write_guide":
            let id = try string(params, "brand_id")
            guard try db.brand(id: id) != nil else { throw ValidationError("No existe marca con id \(id).") }
            try files.writeGuide(brandId: id, markdown: try string(params, "markdown"))
            return ["ok": true]
        case "tool.posts_list":
            let status = try params["status"]?.stringValue.map(parseStatus)
            let posts = try db.posts(brandId: params["brand_id"]?.stringValue, status: status)
            return ["posts": .array(posts.map { p in
                ["id": .string(p.id), "brand_id": .string(p.brandId), "network": .string(p.network.rawValue),
                 "body": .string(p.body), "status": .string(p.status.rawValue),
                 "scheduled_for": p.scheduledFor.map { .string(Self.iso.string(from: $0)) } ?? .null]
            })]
        case "tool.posts_create_draft":
            let post = try db.createDraft(
                brandId: try string(params, "brand_id"), network: try parseNetwork(try string(params, "network")),
                body: try string(params, "body"), media: [], scheduledFor: try optionalDate(params, "scheduled_for"))
            return ["post_id": .string(post.id)]
        case "tool.posts_update_draft":
            _ = try db.updateDraft(id: try string(params, "post_id"), body: params["body"]?.stringValue,
                                   media: nil, scheduledFor: try optionalDate(params, "scheduled_for"))
            return ["ok": true]
        case "tool.tasks_list":
            let day = try optionalDate(params, "date")
            let tasks = try db.tasks(workspaceId: workspaceId, on: day)
            return ["tasks": .array(tasks.map { t in
                ["id": .string(t.id), "title": .string(t.title), "done": .bool(t.done),
                 "due_date": t.dueDate.map { .string(Self.iso.string(from: $0)) } ?? .null]
            })]
        case "tool.tasks_create":
            let task = try db.createTask(workspaceId: workspaceId, title: try string(params, "title"),
                                         dueDate: try optionalDate(params, "due_date"), brandId: params["brand_id"]?.stringValue)
            return ["task_id": .string(task.id)]
        case "tool.tasks_complete":
            _ = try db.completeTask(id: try string(params, "task_id"))
            return ["ok": true]
        case "tool.ideas_create":
            guard let score = params["score"]?.intValue else { throw ValidationError("Falta el parámetro score.") }
            let sources = (params["sources"]?.arrayValue ?? []).compactMap(\.stringValue)
            let idea = try db.createIdea(workspaceId: workspaceId, title: try string(params, "title"),
                                         summary: try string(params, "summary"), sources: sources, score: score)
            let url = try files.writeIdeaReport(ideaId: idea.id, markdown: try string(params, "report_markdown"))
            try db.setIdeaReportPath(id: idea.id, path: url.path)
            return ["idea_id": .string(idea.id)]
        default:
            throw ValidationError("Herramienta desconocida: \(method).")
        }
    }

    // MARK: Helpers

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    private func string(_ params: JSONValue, _ key: String) throws -> String {
        guard let value = params[key]?.stringValue else { throw ValidationError("Falta el parámetro \(key).") }
        return value
    }

    private func parseNetwork(_ raw: String) throws -> Network {
        guard let n = Network(rawValue: raw) else { throw ValidationError("Red no soportada: \(raw). Usa instagram o linkedin.") }
        return n
    }

    private func parseStatus(_ raw: String) throws -> PostStatus {
        guard let s = PostStatus(rawValue: raw) else { throw ValidationError("Estado desconocido: \(raw).") }
        return s
    }

    /// Acepta ISO-8601 completo ("2026-10-20T09:00:00Z") o solo fecha ("2026-10-20", hora local 09:00).
    private func optionalDate(_ params: JSONValue, _ key: String) throws -> Date? {
        guard let raw = params[key]?.stringValue else { return nil }
        if let d = Self.iso.date(from: raw) { return d }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        if let d = fmt.date(from: raw) { return Calendar.current.date(byAdding: .hour, value: 9, to: d) }
        throw ValidationError("Fecha inválida en \(key): \(raw). Usa YYYY-MM-DD o ISO-8601.")
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd app && swift test --filter ToolHandlerTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat: add agent tool handler backed by the store"
```

---

### Task 7: Sidecar — proyecto TS y RpcPeer bidireccional

**Files:**
- Create: `agent/package.json`, `agent/tsconfig.json`, `agent/vitest.config.ts`, `agent/src/rpc.ts`
- Test: `agent/test/rpc.test.ts`

**Interfaces:**
- Produces: `class RpcPeer { constructor(input: Readable, output: Writable); onRequest(method: string, handler: (params: any) => Promise<unknown>): void; onNotification(method: string, handler: (params: any) => void): void; request<T = unknown>(method: string, params: unknown): Promise<T>; notify(method: string, params: unknown): void; }`. Errores remotos llegan como `RpcError extends Error { code: number }`. Mismo formato de cable que la Task 5.

- [ ] **Step 1: Crear el proyecto**

`agent/package.json`:
```json
{
  "name": "frontbot-agent",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "start": "node dist/main.js",
    "test": "vitest run",
    "typecheck": "tsc -p tsconfig.json --noEmit"
  }
}
```

```bash
cd agent
npm install @anthropic-ai/claude-agent-sdk@^0.3.296 zod@^4 @anthropic-ai/sdk @modelcontextprotocol/sdk
npm install -D typescript@^5 vitest@^3 @types/node@^24
```

`agent/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

`agent/vitest.config.ts`:
```ts
import { defineConfig } from "vitest/config";
export default defineConfig({ test: { include: ["test/**/*.test.ts"] } });
```

- [ ] **Step 2: Escribir el test que falla**

`agent/test/rpc.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { PassThrough } from "node:stream";
import { RpcPeer, RpcError } from "../src/rpc.js";

function pair() {
  const aToB = new PassThrough();
  const bToA = new PassThrough();
  return { a: new RpcPeer(bToA, aToB), b: new RpcPeer(aToB, bToA) };
}

describe("RpcPeer", () => {
  it("request/response round trip with unicode", async () => {
    const { a, b } = pair();
    b.onRequest("echo", async (p) => ({ got: p.text }));
    await expect(a.request("echo", { text: "café ☕️" })).resolves.toEqual({ got: "café ☕️" });
  });

  it("propagates handler errors as RpcError", async () => {
    const { a, b } = pair();
    b.onRequest("boom", async () => { throw new Error("se rompió"); });
    await expect(a.request("boom", {})).rejects.toMatchObject({ message: "se rompió", code: -32000 });
  });

  it("unknown method returns -32601", async () => {
    const { a } = pair();
    const err = await a.request("nope", {}).catch((e) => e);
    expect(err).toBeInstanceOf(RpcError);
    expect(err.code).toBe(-32601);
  });

  it("delivers notifications", async () => {
    const { a, b } = pair();
    const got = new Promise((resolve) => b.onNotification("ping", resolve));
    a.notify("ping", { n: 1 });
    await expect(got).resolves.toEqual({ n: 1 });
  });

  it("handles messages split across chunks and several per chunk", async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const peer = new RpcPeer(input, output);
    const seen: unknown[] = [];
    peer.onNotification("n", (p) => seen.push(p));
    input.write('{"jsonrpc":"2.0","method":"n","par');
    input.write('ams":{"i":1}}\n{"jsonrpc":"2.0","method":"n","params":{"i":2}}\n');
    await new Promise((r) => setImmediate(r));
    expect(seen).toEqual([{ i: 1 }, { i: 2 }]);
  });
});
```

- [ ] **Step 3: Correr y verificar que falla**

Run: `cd agent && npx vitest run test/rpc.test.ts`
Expected: FAIL — `Cannot find module '../src/rpc.js'`.

- [ ] **Step 4: Implementar**

`agent/src/rpc.ts`:
```ts
import type { Readable, Writable } from "node:stream";

export class RpcError extends Error {
  constructor(message: string, public code: number) {
    super(message);
  }
}

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void };

export class RpcPeer {
  private nextId = 1;
  private buffer = "";
  private pending = new Map<number, Pending>();
  private requestHandlers = new Map<string, (params: any) => Promise<unknown>>();
  private notificationHandlers = new Map<string, (params: any) => void>();

  constructor(input: Readable, private output: Writable) {
    input.setEncoding("utf8");
    input.on("data", (chunk: string) => this.onData(chunk));
    input.on("end", () => {
      for (const p of this.pending.values()) p.reject(new RpcError("Conexión cerrada", -32001));
      this.pending.clear();
    });
  }

  onRequest(method: string, handler: (params: any) => Promise<unknown>) {
    this.requestHandlers.set(method, handler);
  }

  onNotification(method: string, handler: (params: any) => void) {
    this.notificationHandlers.set(method, handler);
  }

  request<T = unknown>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.send({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params: unknown) {
    this.send({ jsonrpc: "2.0", method, params });
  }

  private send(msg: unknown) {
    this.output.write(JSON.stringify(msg) + "\n");
  }

  private onData(chunk: string) {
    this.buffer += chunk;
    let idx: number;
    while ((idx = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (line) this.dispatch(line);
    }
  }

  private dispatch(line: string) {
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      return; // línea corrupta: se ignora
    }
    if (typeof msg.method === "string") {
      if (msg.id === undefined) {
        this.notificationHandlers.get(msg.method)?.(msg.params);
        return;
      }
      const handler = this.requestHandlers.get(msg.method);
      if (!handler) {
        this.send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: `Método desconocido: ${msg.method}` } });
        return;
      }
      handler(msg.params).then(
        (result) => this.send({ jsonrpc: "2.0", id: msg.id, result: result ?? null }),
        (err: Error) => this.send({ jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: err.message } }),
      );
      return;
    }
    const pending = this.pending.get(msg.id);
    if (!pending) return;
    this.pending.delete(msg.id);
    if (msg.error) pending.reject(new RpcError(msg.error.message, msg.error.code));
    else pending.resolve(msg.result);
  }
}
```

- [ ] **Step 5: Correr y verificar que pasa**

Run: `cd agent && npx vitest run test/rpc.test.ts && npm run typecheck`
Expected: PASS (5 tests), typecheck sin errores.

- [ ] **Step 6: Commit**

```bash
git add agent/package.json agent/package-lock.json agent/tsconfig.json agent/vitest.config.ts agent/src agent/test
git commit -m "feat: scaffold agent sidecar with bidirectional JSON-RPC peer"
```

---

### Task 8: Sidecar — herramientas, system prompt y runners (real + falso)

**Files:**
- Create: `agent/src/tools.ts`, `agent/src/prompt.ts`, `agent/src/runner.ts`, `agent/src/main.ts`
- Test: `agent/test/tools.test.ts`, `agent/test/prompt.test.ts`, `agent/test/main.test.ts`

**Interfaces:**
- Consumes: `RpcPeer` (Task 7); métodos `tool.*` de la app (Task 6).
- Produces:
  - `type AppCall = (method: string, params: Record<string, unknown>) => Promise<unknown>`
  - `const TOOL_SPECS: { name: string; description: string; shape: ZodRawShape }[]` y `function buildTools(call: AppCall)` → array de `SdkMcpToolDefinition` cuyo handler hace `call("tool." + name, args)` y devuelve `{ content: [{ type: "text", text: JSON.stringify(result) }] }`, o `{ isError: true, content: [{ type: "text", text: err.message }] }` si la app responde error.
  - `const ALLOWED_TOOLS: string[]` = `["WebSearch", "WebFetch", ...TOOL_SPECS.map(t => "mcp__frontbot__" + t.name)]`.
  - `function buildSystemPrompt(input: { today: string; brand?: { id: string; name: string; guide: string | null } }): string`
  - `type RunParams = { run_id: string; prompt: string; model: string; brand?: { id: string; name: string; guide: string | null } }`
  - `type RunEvent = { run_id: string; type: "text" | "tool_call" | "status"; text: string }`
  - `type RunDone = { run_id: string; ok: boolean; summary: string; input_tokens: number; output_tokens: number; cost_usd: number; error?: string }`
  - `interface Runner { run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> }`; `class RealRunner implements Runner { constructor(call: AppCall) }`; `class FakeRunner implements Runner { constructor(call: AppCall) }`.
  - `function startServer(peer: RpcPeer, runner: Runner): void` — atiende `agent.run` (request; responde `{accepted:true}` de inmediato y luego emite notificaciones `agent.event` y una `agent.done`) y `agent.cancel {run_id}` (request; responde `{ok:true}`).
  - `main.ts` elige `FakeRunner` si `FRONTBOT_FAKE_AGENT=1`, si no `RealRunner`.
- **FakeRunner (guionado, sin red):** emite `status` "pensando", llama `tool.brands_list`, emite `text` `"Tienes N marca(s)."`; si el prompt contiene "crear post" y hay `brand`, llama `tool.posts_create_draft` con `{brand_id, network: "instagram", body: "Post de prueba"}` y emite `tool_call` `"posts_create_draft"`. Si el prompt contiene "lento", espera 5 s (respetando `signal`) antes de terminar. Si el prompt es `"crash"`, hace `process.exit(1)`. Termina con `ok: true, summary: "Tienes N marca(s).", tokens 0, cost 0`.

- [ ] **Step 1: Escribir los tests que fallan**

`agent/test/tools.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { buildTools, ALLOWED_TOOLS, TOOL_SPECS } from "../src/tools.js";

describe("tools", () => {
  it("allows only web tools plus frontbot tools, never publish/approve", () => {
    expect(ALLOWED_TOOLS).toContain("WebSearch");
    expect(ALLOWED_TOOLS).toContain("WebFetch");
    expect(ALLOWED_TOOLS).toContain("mcp__frontbot__posts_create_draft");
    expect(ALLOWED_TOOLS.some((t) => /publish|approve|Bash|Write|Edit/.test(t))).toBe(false);
    expect(TOOL_SPECS.map((t) => t.name).sort()).toEqual([
      "brands_get_guide", "brands_list", "brands_write_guide", "ideas_create",
      "posts_create_draft", "posts_list", "posts_update_draft",
      "tasks_complete", "tasks_create", "tasks_list",
    ]);
  });

  it("handler forwards to app with tool. prefix and returns JSON text", async () => {
    const calls: [string, unknown][] = [];
    const tools = buildTools(async (m, p) => { calls.push([m, p]); return { post_id: "p1" }; });
    const create = tools.find((t) => t.name === "posts_create_draft")!;
    const res = await create.handler({ brand_id: "b", network: "instagram", body: "hola" }, {});
    expect(calls).toEqual([["tool.posts_create_draft", { brand_id: "b", network: "instagram", body: "hola" }]]);
    expect(res.content[0]).toEqual({ type: "text", text: '{"post_id":"p1"}' });
  });

  it("app errors become isError results the model can read", async () => {
    const tools = buildTools(async () => { throw new Error("Solo se pueden editar posts en borrador; este está en approved."); });
    const update = tools.find((t) => t.name === "posts_update_draft")!;
    const res = await update.handler({ post_id: "p1", body: "v2" }, {});
    expect(res.isError).toBe(true);
    expect(res.content[0]).toEqual({ type: "text", text: "Solo se pueden editar posts en borrador; este está en approved." });
  });
});
```

`agent/test/prompt.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { buildSystemPrompt } from "../src/prompt.js";

describe("buildSystemPrompt", () => {
  it("includes today's date and the no-publish rule", () => {
    const p = buildSystemPrompt({ today: "2026-10-13" });
    expect(p).toContain("2026-10-13");
    expect(p).toContain("Nunca publicas");
    expect(p).not.toContain("Guía de marca");
  });

  it("injects the brand guide when a brand is active", () => {
    const p = buildSystemPrompt({ today: "2026-10-13", brand: { id: "b1", name: "Café Sol", guide: "# Tono\nCercano" } });
    expect(p).toContain("Marca activa: Café Sol (id b1)");
    expect(p).toContain("# Tono\nCercano");
  });

  it("asks to define a guide when the brand has none", () => {
    const p = buildSystemPrompt({ today: "2026-10-13", brand: { id: "b1", name: "Café Sol", guide: null } });
    expect(p).toContain("aún no tiene guía");
  });
});
```

`agent/test/main.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { PassThrough } from "node:stream";
import { RpcPeer } from "../src/rpc.js";
import { startServer } from "../src/main.js";
import { FakeRunner } from "../src/runner.js";

function setup() {
  const appToAgent = new PassThrough();
  const agentToApp = new PassThrough();
  const app = new RpcPeer(agentToApp, appToAgent);
  const agent = new RpcPeer(appToAgent, agentToApp);
  startServer(agent, new FakeRunner((m, p) => agent.request(m, p)));
  return app;
}

describe("agent server with FakeRunner", () => {
  it("runs, calls back the app, streams events and finishes", async () => {
    const app = setup();
    const calls: string[] = [];
    app.onRequest("tool.brands_list", async () => { calls.push("brands_list"); return { brands: [{ id: "b1" }] }; });
    app.onRequest("tool.posts_create_draft", async (p) => { calls.push(`create:${p.brand_id}`); return { post_id: "p1" }; });
    const events: any[] = [];
    app.onNotification("agent.event", (e) => events.push(e));
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));

    await expect(app.request("agent.run", { run_id: "r1", prompt: "crear post", model: "m", brand: { id: "b1", name: "B", guide: null } }))
      .resolves.toEqual({ accepted: true });
    const result = await done;

    expect(calls).toEqual(["brands_list", "create:b1"]);
    expect(events.map((e) => e.type)).toEqual(["status", "text", "tool_call"]);
    expect(result).toMatchObject({ run_id: "r1", ok: true, summary: "Tienes 1 marca(s)." });
  });

  it("cancel stops a slow run with ok=false", async () => {
    const app = setup();
    app.onRequest("tool.brands_list", async () => ({ brands: [] }));
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));
    await app.request("agent.run", { run_id: "r2", prompt: "lento", model: "m" });
    await app.request("agent.cancel", { run_id: "r2" });
    await expect(done).resolves.toMatchObject({ run_id: "r2", ok: false, error: "Cancelado" });
  });
});
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd agent && npx vitest run`
Expected: FAIL — módulos `tools.js`, `prompt.js`, `main.js`, `runner.js` no existen.

- [ ] **Step 3: Implementar `tools.ts`**

```ts
import { tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

export type AppCall = (method: string, params: Record<string, unknown>) => Promise<unknown>;

const network = z.enum(["instagram", "linkedin"]);
const date = z.string().describe("Fecha YYYY-MM-DD o ISO-8601");

export const TOOL_SPECS = [
  { name: "brands_list", description: "Lista las marcas del usuario con sus redes.", shape: {} },
  { name: "brands_get_guide", description: "Lee la guía de marca (markdown) de una marca.", shape: { brand_id: z.string() } },
  { name: "brands_write_guide", description: "Escribe o reemplaza la guía de marca completa en markdown.", shape: { brand_id: z.string(), markdown: z.string() } },
  { name: "posts_list", description: "Lista posts, opcionalmente por marca y estado (draft, approved, preparing, scheduled, published, archived).", shape: { brand_id: z.string().optional(), status: z.string().optional() } },
  { name: "posts_create_draft", description: "Crea un post en borrador para una marca. No lo publica: el usuario lo revisa y aprueba.", shape: { brand_id: z.string(), network, body: z.string(), scheduled_for: date.optional() } },
  { name: "posts_update_draft", description: "Edita un post que sigue en borrador.", shape: { post_id: z.string(), body: z.string().optional(), scheduled_for: date.optional() } },
  { name: "tasks_list", description: "Lista tareas; con date, solo las de ese día.", shape: { date: date.optional() } },
  { name: "tasks_create", description: "Crea una tarea del usuario.", shape: { title: z.string(), due_date: date.optional(), brand_id: z.string().optional() } },
  { name: "tasks_complete", description: "Marca una tarea como hecha.", shape: { task_id: z.string() } },
  { name: "ideas_create", description: "Guarda una oportunidad de negocio investigada, con fuentes, puntaje 1-5 y reporte en markdown.", shape: { title: z.string(), summary: z.string(), sources: z.array(z.string()), score: z.number().int().min(1).max(5), report_markdown: z.string() } },
] as const;

export const ALLOWED_TOOLS = ["WebSearch", "WebFetch", ...TOOL_SPECS.map((t) => `mcp__frontbot__${t.name}`)];

export function buildTools(call: AppCall) {
  return TOOL_SPECS.map((spec) =>
    tool(spec.name, spec.description, spec.shape, async (args: Record<string, unknown>) => {
      try {
        const result = await call(`tool.${spec.name}`, args);
        return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
      } catch (err) {
        return { isError: true, content: [{ type: "text" as const, text: (err as Error).message }] };
      }
    }),
  );
}
```

- [ ] **Step 4: Implementar `prompt.ts`**

```ts
export function buildSystemPrompt(input: { today: string; brand?: { id: string; name: string; guide: string | null } }): string {
  const parts = [
    "Eres Frontbot, un agente que ayuda a gestionar marcas y redes sociales (Instagram y LinkedIn), tareas diarias e investigación de oportunidades de negocio.",
    `Hoy es ${input.today}.`,
    "Reglas:",
    "- Nunca publicas ni apruebas nada. Creas borradores con posts_create_draft; el usuario los revisa, aprueba y publica.",
    "- Investiga en la web (WebSearch, WebFetch) antes de escribir contenido o evaluar negocios, y cita fuentes.",
    "- Respeta los límites: Instagram 2200 caracteres y máximo 30 hashtags; LinkedIn 3000 caracteres.",
    "- Si una herramienta devuelve un error, léelo y corrige la llamada.",
    "- Responde en el idioma del usuario, de forma breve.",
  ];
  if (input.brand) {
    parts.push("", `Marca activa: ${input.brand.name} (id ${input.brand.id}).`);
    if (input.brand.guide) {
      parts.push("Guía de marca (síguela en todo el contenido):", input.brand.guide);
    } else {
      parts.push("Esta marca aún no tiene guía. Si vas a crear contenido, sugiere primero definirla.");
    }
  }
  return parts.join("\n");
}
```

- [ ] **Step 5: Implementar `runner.ts`**

```ts
import { query, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { buildTools, ALLOWED_TOOLS, type AppCall } from "./tools.js";
import { buildSystemPrompt } from "./prompt.js";

export type Brand = { id: string; name: string; guide: string | null };
export type RunParams = { run_id: string; prompt: string; model: string; brand?: Brand };
export type RunEvent = { run_id: string; type: "text" | "tool_call" | "status"; text: string };
export type RunDone = { run_id: string; ok: boolean; summary: string; input_tokens: number; output_tokens: number; cost_usd: number; error?: string };

export interface Runner {
  run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone>;
}

const cancelled = (run_id: string): RunDone => ({ run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: "Cancelado" });

export class RealRunner implements Runner {
  constructor(private call: AppCall) {}

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    const abortController = new AbortController();
    signal.addEventListener("abort", () => abortController.abort());
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: buildTools(this.call) });
    const today = new Date().toISOString().slice(0, 10);
    emit({ run_id: params.run_id, type: "status", text: "pensando" });
    try {
      const stream = query({
        prompt: params.prompt,
        options: {
          model: params.model,
          systemPrompt: buildSystemPrompt({ today, brand: params.brand }),
          tools: ["WebSearch", "WebFetch"],
          allowedTools: ALLOWED_TOOLS,
          mcpServers: { frontbot: server },
          strictMcpConfig: true,
          settingSources: [],
          permissionMode: "dontAsk",
          maxTurns: 30,
          abortController,
        },
      });
      for await (const msg of stream) {
        if (msg.type === "assistant") {
          for (const block of msg.message.content) {
            if (block.type === "text") emit({ run_id: params.run_id, type: "text", text: block.text });
            if (block.type === "tool_use") emit({ run_id: params.run_id, type: "tool_call", text: block.name.replace("mcp__frontbot__", "") });
          }
        } else if (msg.type === "result") {
          const usage = msg.usage as { input_tokens?: number; output_tokens?: number };
          const base = { run_id: params.run_id, input_tokens: usage.input_tokens ?? 0, output_tokens: usage.output_tokens ?? 0, cost_usd: msg.total_cost_usd ?? 0 };
          if (msg.subtype === "success" && !msg.is_error) return { ...base, ok: true, summary: msg.result };
          return { ...base, ok: false, summary: "", error: msg.subtype === "success" ? msg.result : msg.subtype };
        }
      }
      return signal.aborted ? cancelled(params.run_id) : { ...cancelled(params.run_id), error: "El agente terminó sin resultado" };
    } catch (err) {
      if (signal.aborted) return cancelled(params.run_id);
      return { ...cancelled(params.run_id), error: (err as Error).message };
    }
  }
}

export class FakeRunner implements Runner {
  constructor(private call: AppCall) {}

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    if (params.prompt === "crash") process.exit(1);
    emit({ run_id: params.run_id, type: "status", text: "pensando" });
    const { brands } = (await this.call("tool.brands_list", {})) as { brands: unknown[] };
    const summary = `Tienes ${brands.length} marca(s).`;
    emit({ run_id: params.run_id, type: "text", text: summary });
    if (params.prompt.includes("crear post") && params.brand) {
      await this.call("tool.posts_create_draft", { brand_id: params.brand.id, network: "instagram", body: "Post de prueba" });
      emit({ run_id: params.run_id, type: "tool_call", text: "posts_create_draft" });
    }
    if (params.prompt.includes("lento")) {
      const aborted = await new Promise<boolean>((resolve) => {
        const timer = setTimeout(() => resolve(false), 5000);
        signal.addEventListener("abort", () => { clearTimeout(timer); resolve(true); });
      });
      if (aborted) return cancelled(params.run_id);
    }
    return { run_id: params.run_id, ok: true, summary, input_tokens: 0, output_tokens: 0, cost_usd: 0 };
  }
}
```

Nota para el implementador: si `tsc` se queja de tipos en `msg.message.content` o `msg.usage`, revisa `node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts` (`SDKAssistantMessage`, `SDKResultSuccess`, `SDKResultError`) y ajusta solo los casts; no cambies la lógica.

- [ ] **Step 6: Implementar `main.ts`**

```ts
import { fileURLToPath } from "node:url";
import { RpcPeer } from "./rpc.js";
import { RealRunner, FakeRunner, type Runner, type RunParams } from "./runner.js";

export function startServer(peer: RpcPeer, runner: Runner) {
  const active = new Map<string, AbortController>();

  peer.onRequest("agent.run", async (params: RunParams) => {
    const controller = new AbortController();
    active.set(params.run_id, controller);
    runner
      .run(params, (e) => peer.notify("agent.event", e), controller.signal)
      .then((done) => peer.notify("agent.done", done))
      .catch((err: Error) => peer.notify("agent.done", { run_id: params.run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: err.message }))
      .finally(() => active.delete(params.run_id));
    return { accepted: true };
  });

  peer.onRequest("agent.cancel", async ({ run_id }: { run_id: string }) => {
    active.get(run_id)?.abort();
    return { ok: true };
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const peer = new RpcPeer(process.stdin, process.stdout);
  const call = (m: string, p: Record<string, unknown>) => peer.request(m, p);
  const runner = process.env.FRONTBOT_FAKE_AGENT === "1" ? new FakeRunner(call) : new RealRunner(call);
  startServer(peer, runner);
  process.stdin.on("end", () => process.exit(0));
}
```

Importante: el sidecar usa stdout solo para JSON-RPC. Cualquier log va a `process.stderr`.

- [ ] **Step 7: Correr y verificar que pasa**

Run: `cd agent && npx vitest run && npm run typecheck && npm run build`
Expected: PASS (todas las pruebas: rpc 5, tools 3, prompt 3, main 2), typecheck limpio, `dist/main.js` generado.

- [ ] **Step 8: Commit**

```bash
git add agent/src agent/test
git commit -m "feat: add agent tools, system prompt, real and fake runners"
```

---

### Task 9: AgentClient en Swift — proceso sidecar, runs, cancelación y reinicio

**Files:**
- Create: `app/Sources/FrontbotCore/Agent/AgentClient.swift`
- Test: `app/Tests/FrontbotCoreTests/AgentClientTests.swift`

**Interfaces:**
- Consumes: `RPCMessage`, `LineFramer`, `JSONValue` (Task 5); `ToolHandler` (Task 6); `AppDatabase.startRun/finishRun/failRunningRuns` (Task 3); `BrandFiles.readGuide` (Task 4); sidecar compilado `agent/dist/main.js` (Task 8).
- Produces:
  - `struct AgentConfig: Sendable { var nodePath: String; var scriptPath: String; var apiKey: String?; var model: String; var fakeAgent: Bool }` con `static let defaultModel = "claude-sonnet-5-5"`.
  - `enum AgentUpdate: Sendable, Equatable { case event(runId: String, type: String, text: String); case finished(AgentRun) }`
  - `actor AgentClient { init(config: AgentConfig, db: AppDatabase, files: BrandFiles, workspaceId: String); func setConfig(_ config: AgentConfig); func updates() -> AsyncStream<AgentUpdate>; func run(prompt: String, brand: Brand?) async throws -> AgentRun; func cancel(runId: String) async; func stop() }`
  - `run` lanza `AgentClientError.missingApiKey` si `apiKey` está vacía y `fakeAgent == false`. Arranca el proceso si no está vivo.
  - Si el proceso termina (EOF en su stdout): todos los runs en curso pasan a `failed` con `resultSummary = "El agente se detuvo inesperadamente."` y se emite `.finished` por cada uno. El siguiente `run` lo vuelve a lanzar; máximo 3 lanzamientos por 60 s, si no `AgentClientError.restartLimit`.
- Lanzamiento: `Process` con `executableURL = nodePath`, `arguments = [scriptPath]`, entorno `PATH`/`HOME`/`TMPDIR`/`USER` heredados + `ANTHROPIC_API_KEY` (si hay) + `FRONTBOT_FAKE_AGENT=1` (si `fakeAgent`) + `CLAUDE_AGENT_SDK_CLIENT_APP=frontbot/0.1.0`. En Fase 1 el stderr del sidecar se descarta (`FileHandle.nullDevice`); los logs por run llegan en una fase posterior.
- Los chunks de stdout se consumen en orden mediante un único `AsyncStream<Data>`; un contador `generation` evita que el EOF de un proceso viejo afecte a uno nuevo.

- [ ] **Step 1: Escribir el test que falla (usa el sidecar real en modo falso)**

```swift
import XCTest
@testable import FrontbotCore

final class AgentClientTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!
    var root: URL!

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func makeClient(apiKey: String? = nil, fake: Bool = true) throws -> AgentClient {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = Self.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "Compila el sidecar: cd agent && npm run build")
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: apiKey, model: AgentConfig.defaultModel, fakeAgent: fake)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    /// Siempre suscribirse ANTES de llamar a run(): el agente falso puede terminar en milisegundos.
    /// Cada llamada usa un stream nuevo (un AsyncStream no se reitera tras un `break`).
    func finished(_ stream: AsyncStream<AgentUpdate>, _ runId: String) async -> AgentRun? {
        for await update in stream { if case .finished(let r) = update, r.id == runId { return r } }
        return nil
    }

    func testFakeRunCreatesDraftThroughTools() async throws {
        let client = try makeClient()
        let brand = try db.createBrand(workspaceId: ws.id, name: "Café Sol", industry: "", networks: [.instagram])
        let stream = await client.updates()
        let run = try await client.run(prompt: "crear post", brand: brand)
        let result = await finished(stream, run.id)
        XCTAssertEqual(result?.status, .done)
        XCTAssertEqual(result?.resultSummary, "Tienes 1 marca(s).")
        XCTAssertEqual(try db.posts(brandId: brand.id, status: .draft).map(\.body), ["Post de prueba"])
        await client.stop()
    }

    func testMissingApiKeyFailsFastWithoutFakeMode() async throws {
        let client = try makeClient(apiKey: nil, fake: false)
        do {
            _ = try await client.run(prompt: "hola", brand: nil)
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .missingApiKey)
            XCTAssertEqual(error.localizedDescription, "Configura tu API key de Anthropic en Ajustes.")
        }
        XCTAssertEqual(try db.runs(workspaceId: ws.id).count, 0)
    }

    func testSidecarCrashFailsRunAndNextRunWorks() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let crashed = try await client.run(prompt: "crash", brand: nil)
        let failed = await finished(stream, crashed.id)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.resultSummary, "El agente se detuvo inesperadamente.")

        let stream2 = await client.updates()
        let next = try await client.run(prompt: "hola", brand: nil)
        let done = await finished(stream2, next.id)
        XCTAssertEqual(done?.status, .done)
        await client.stop()
    }

    func testCancelMarksRunFailed() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let run = try await client.run(prompt: "lento", brand: nil)
        await client.cancel(runId: run.id)
        let result = await finished(stream, run.id)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(result?.resultSummary, "Cancelado")
        await client.stop()
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd agent && npm run build && cd ../app && swift test --filter AgentClientTests`
Expected: FAIL — `cannot find 'AgentClient' in scope`.

- [ ] **Step 3: Implementar**

```swift
import Foundation

public struct AgentConfig: Sendable {
    public static let defaultModel = "claude-sonnet-5-5"
    public var nodePath: String
    public var scriptPath: String
    public var apiKey: String?
    public var model: String
    public var fakeAgent: Bool

    public init(nodePath: String, scriptPath: String, apiKey: String?, model: String, fakeAgent: Bool) {
        self.nodePath = nodePath; self.scriptPath = scriptPath; self.apiKey = apiKey; self.model = model; self.fakeAgent = fakeAgent
    }
}

public enum AgentUpdate: Sendable, Equatable {
    case event(runId: String, type: String, text: String)
    case finished(AgentRun)
}

public enum AgentClientError: Error, Equatable, LocalizedError {
    case missingApiKey
    case restartLimit
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey: "Configura tu API key de Anthropic en Ajustes."
        case .restartLimit: "El agente se reinició demasiadas veces. Revisa los logs y vuelve a intentar en un minuto."
        case .launchFailed(let why): "No se pudo iniciar el agente: \(why)"
        }
    }
}

public actor AgentClient {
    private var config: AgentConfig
    private let db: AppDatabase
    private let files: BrandFiles
    private let tools: ToolHandler

    private var process: Process?
    private var stdin: FileHandle?
    private var framer = LineFramer()
    private var nextId = 1
    private var activeRuns: Set<String> = []
    private var launches: [Date] = []
    private var subscribers: [UUID: AsyncStream<AgentUpdate>.Continuation] = [:]

    public init(config: AgentConfig, db: AppDatabase, files: BrandFiles, workspaceId: String) {
        self.config = config
        self.db = db
        self.files = files
        self.tools = ToolHandler(db: db, files: files, workspaceId: workspaceId)
        self.workspaceId = workspaceId
    }

    private let workspaceId: String

    public func setConfig(_ config: AgentConfig) {
        self.config = config
        stop() // el próximo run relanza con la nueva config (p. ej. nueva API key)
    }

    public func updates() -> AsyncStream<AgentUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentUpdate>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func broadcast(_ update: AgentUpdate) {
        for c in subscribers.values { c.yield(update) }
    }

    public func run(prompt: String, brand: Brand?) async throws -> AgentRun {
        if !config.fakeAgent, (config.apiKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw AgentClientError.missingApiKey
        }
        try ensureProcess()
        let run = try db.startRun(workspaceId: workspaceId, brandId: brand?.id, prompt: prompt)
        activeRuns.insert(run.id)
        var params: [String: JSONValue] = ["run_id": .string(run.id), "prompt": .string(prompt), "model": .string(config.model)]
        if let brand {
            let guide = try files.readGuide(brandId: brand.id)
            params["brand"] = ["id": .string(brand.id), "name": .string(brand.name), "guide": guide.map(JSONValue.string) ?? .null]
        }
        try send(.request(id: takeId(), method: "agent.run", params: .object(params)))
        return run
    }

    public func cancel(runId: String) async {
        try? send(.request(id: takeId(), method: "agent.cancel", params: ["run_id": .string(runId)]))
    }

    public func stop() {
        guard let process else { return }
        generation += 1 // ignora el EOF de este proceso
        if process.isRunning { process.terminate() }
        self.process = nil
        stdin = nil
        handleExit()
    }

    // MARK: Proceso

    private func takeId() -> Int { defer { nextId += 1 }; return nextId }

    private func ensureProcess() throws {
        if let process, process.isRunning { return }
        let now = Date()
        launches = launches.filter { now.timeIntervalSince($0) < 60 }
        guard launches.count < 3 else { throw AgentClientError.restartLimit }
        launches.append(now)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.nodePath)
        p.arguments = [config.scriptPath]
        var env = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR", "USER"].contains($0.key) }
        env["CLAUDE_AGENT_SDK_CLIENT_APP"] = "frontbot/0.1.0"
        if let key = config.apiKey, !key.isEmpty { env["ANTHROPIC_API_KEY"] = key }
        if config.fakeAgent { env["FRONTBOT_FAKE_AGENT"] = "1" }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        // Un único stream ordenado: lanzar un Task por chunk podría reordenar los datos.
        let (chunks, chunkSink) = AsyncStream<Data>.makeStream()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                chunkSink.finish() // EOF: el proceso cerró stdout
            } else {
                chunkSink.yield(data)
            }
        }
        generation += 1
        let gen = generation
        do { try p.run() } catch { throw AgentClientError.launchFailed(error.localizedDescription) }
        framer = LineFramer()
        process = p
        stdin = inPipe.fileHandleForWriting
        Task { [weak self] in
            for await data in chunks { await self?.receive(data) }
            // Se procesa todo lo leído antes de declarar el proceso muerto.
            await self?.processExited(generation: gen)
        }
    }

    private var generation = 0

    private func processExited(generation gen: Int) {
        guard gen == generation else { return } // salida de un proceso ya reemplazado
        process = nil
        stdin = nil
        handleExit()
    }

    private func handleExit() {
        for runId in activeRuns {
            if let run = try? db.finishRun(id: runId, status: .failed, summary: "El agente se detuvo inesperadamente.", inputTokens: 0, outputTokens: 0, costUsd: 0) {
                broadcast(.finished(run))
            }
        }
        activeRuns.removeAll()
    }

    private func send(_ message: RPCMessage) throws {
        guard let stdin else { throw AgentClientError.launchFailed("proceso no disponible") }
        try stdin.write(contentsOf: message.encodedLine())
    }

    // MARK: Mensajes entrantes

    private func receive(_ data: Data) {
        for line in framer.append(data) {
            guard let message = try? RPCMessage.decode(line) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: RPCMessage) {
        switch message {
        case .request(let id, let method, let params):
            do {
                let result = try tools.handle(method: method, params: params)
                try? send(.response(id: id, result: result))
            } catch let error as ValidationError {
                try? send(.error(id: id, code: -32000, message: error.message))
            } catch {
                try? send(.error(id: id, code: -32000, message: error.localizedDescription))
            }
        case .notification("agent.event", let params):
            broadcast(.event(runId: params["run_id"]?.stringValue ?? "", type: params["type"]?.stringValue ?? "", text: params["text"]?.stringValue ?? ""))
        case .notification("agent.done", let params):
            guard let runId = params["run_id"]?.stringValue else { return }
            activeRuns.remove(runId)
            let ok = params["ok"]?.boolValue ?? false
            let summary = ok ? params["summary"]?.stringValue : (params["error"]?.stringValue ?? "Error desconocido")
            if let run = try? db.finishRun(id: runId, status: ok ? .done : .failed, summary: summary,
                                           inputTokens: params["input_tokens"]?.intValue ?? 0,
                                           outputTokens: params["output_tokens"]?.intValue ?? 0,
                                           costUsd: params["cost_usd"]?.doubleValue ?? 0) {
                broadcast(.finished(run))
            }
        default:
            break // respuestas a agent.run / agent.cancel: no se necesitan
        }
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd agent && npm run build && cd ../app && swift test --filter AgentClientTests`
Expected: PASS (4 tests). Si `node` no está en `/opt/homebrew/bin/node`, correr con `FRONTBOT_NODE=$(which node) swift test --filter AgentClientTests`.

- [ ] **Step 5: Correr toda la suite**

Run: `cd app && swift test`
Expected: PASS en todas las clases de test.

- [ ] **Step 6: Commit**

```bash
git add app
git commit -m "feat: add AgentClient that drives the sidecar over JSON-RPC"
```

---

### Task 10: CredentialStore (Keychain) y app SwiftUI mínima (marcas + chat + ajustes)

**Files:**
- Create: `app/Sources/FrontbotCore/Credentials/CredentialStore.swift`
- Create: `app/Sources/FrontbotApp/AppModel.swift`, `app/Sources/FrontbotApp/BrandsView.swift`, `app/Sources/FrontbotApp/ChatView.swift`, `app/Sources/FrontbotApp/SettingsView.swift`
- Modify: `app/Sources/FrontbotApp/FrontbotApp.swift` (reemplazar el placeholder)
- Test: `app/Tests/FrontbotCoreTests/CredentialStoreTests.swift`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: `struct CredentialStore: Sendable { init(service: String = "app.frontbot.credentials"); func get(_ account: String) throws -> String?; func set(_ account: String, value: String) throws; func delete(_ account: String) throws }` con constante `static let anthropicKey = "anthropic_api_key"` (en v1 la cuenta es `"<workspaceId>.anthropic_api_key"`).
- `@MainActor @Observable final class AppModel` con `brands: [Brand]`, `selectedBrandId: String?`, `messages: [ChatMessage]`, `isRunning: Bool`, `errorMessage: String?`, `apiKeyPresent: Bool`, y métodos `createBrand(name:industry:networks:)`, `send(prompt:)`, `cancel()`, `saveApiKey(_:)`.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class CredentialStoreTests: XCTestCase {
    func testSetGetDelete() throws {
        let store = CredentialStore(service: "app.frontbot.tests.\(UUID().uuidString)")
        XCTAssertNil(try store.get("k"))
        try store.set("k", value: "sk-ant-123")
        XCTAssertEqual(try store.get("k"), "sk-ant-123")
        try store.set("k", value: "sk-ant-456")
        XCTAssertEqual(try store.get("k"), "sk-ant-456")
        try store.delete("k")
        XCTAssertNil(try store.get("k"))
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter CredentialStoreTests`
Expected: FAIL — `cannot find 'CredentialStore' in scope`.

- [ ] **Step 3: Implementar `CredentialStore`**

```swift
import Foundation
import Security

public struct CredentialStore: Sendable {
    public static let anthropicKey = "anthropic_api_key"
    let service: String

    public init(service: String = "app.frontbot.credentials") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func get(_ account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ValidationError("Error de Keychain \(status).") }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ account: String, value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ValidationError("Error de Keychain \(addStatus).") }
        } else if status != errSecSuccess {
            throw ValidationError("Error de Keychain \(status).")
        }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ValidationError("Error de Keychain \(status).") }
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd app && swift test --filter CredentialStoreTests`
Expected: PASS. (macOS puede pedir acceso al Keychain la primera vez; aceptar.)

- [ ] **Step 5: Commit de CredentialStore**

```bash
git add app
git commit -m "feat: store API key in the Keychain"
```

- [ ] **Step 6: Implementar `AppModel`**

`app/Sources/FrontbotApp/AppModel.swift`:
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
    var brands: [Brand] = []
    var selectedBrandId: String?
    var messages: [ChatMessage] = []
    var isRunning = false
    var errorMessage: String?
    var apiKeyPresent = false

    private let db: AppDatabase
    private let workspace: Workspace
    private let credentials = CredentialStore()
    private let client: AgentClient
    private var currentRunId: String?
    private var keyAccount: String { "\(workspace.id).\(CredentialStore.anthropicKey)" }

    init() throws {
        let paths = AppPaths.standard()
        db = try AppDatabase.open(at: paths.database)
        try db.failRunningRuns() // runs que quedaron "running" de una sesión anterior
        workspace = try db.ensureDefaultWorkspace()
        let key = try? credentials.get("\(workspace.id).\(CredentialStore.anthropicKey)")
        apiKeyPresent = !(key ?? "").isEmpty
        client = AgentClient(config: Self.makeConfig(apiKey: key), db: db, files: BrandFiles(paths: paths), workspaceId: workspace.id)
        brands = try db.brands(workspaceId: workspace.id)
        selectedBrandId = brands.first?.id
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

    func createBrand(name: String, industry: String, networks: [Network]) {
        do {
            let brand = try db.createBrand(workspaceId: workspace.id, name: name, industry: industry, networks: networks)
            brands = try db.brands(workspaceId: workspace.id)
            selectedBrandId = brand.id
        } catch let e as ValidationError { errorMessage = e.message } catch { errorMessage = error.localizedDescription }
    }

    func send(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        messages.append(ChatMessage(role: .user, text: text))
        isRunning = true
        Task {
            do {
                currentRunId = try await client.run(prompt: text, brand: selectedBrand).id
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

    func saveApiKey(_ key: String) {
        do {
            try credentials.set(keyAccount, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKeyPresent = true
            Task { await client.setConfig(Self.makeConfig(apiKey: key)) }
        } catch let e as ValidationError { errorMessage = e.message } catch { errorMessage = error.localizedDescription }
    }

    private func listen() async {
        for await update in await client.updates() {
            switch update {
            case .event(let runId, let type, let text) where runId == currentRunId:
                if type == "text" { messages.append(ChatMessage(role: .agent, text: text)) }
                if type == "tool_call" { messages.append(ChatMessage(role: .tool, text: "→ \(text)")) }
            case .finished(let run) where run.id == currentRunId:
                isRunning = false
                currentRunId = nil
                if run.status == .failed { messages.append(ChatMessage(role: .error, text: run.resultSummary ?? "Error")) }
                brands = (try? db.brands(workspaceId: workspace.id)) ?? brands
            default:
                break
            }
        }
    }
}
```

- [ ] **Step 7: Implementar las vistas**

`app/Sources/FrontbotApp/FrontbotApp.swift` (reemplaza el placeholder):
```swift
import SwiftUI
import AppKit

@main
struct FrontbotApp: App {
    @State private var model: AppModel? = try? AppModel()

    init() {
        // Ejecutable SwiftPM: hay que pedir explícitamente una app con ventana y foco.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Frontbot") {
            if let model {
                NavigationSplitView {
                    BrandsView(model: model)
                } detail: {
                    ChatView(model: model)
                }
                .frame(minWidth: 900, minHeight: 600)
            } else {
                Text("No se pudo abrir la base de datos de Frontbot.").padding()
            }
        }
        Settings {
            if let model { SettingsView(model: model) }
        }
    }
}
```

`app/Sources/FrontbotApp/BrandsView.swift`:
```swift
import SwiftUI
import FrontbotCore

struct BrandsView: View {
    @Bindable var model: AppModel
    @State private var showingNew = false

    var body: some View {
        List(selection: $model.selectedBrandId) {
            Section("Marcas") {
                ForEach(model.brands) { brand in
                    VStack(alignment: .leading) {
                        Text(brand.name)
                        Text(brand.networks.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(brand.id)
                }
            }
        }
        .toolbar { Button("Nueva marca", systemImage: "plus") { showingNew = true } }
        .sheet(isPresented: $showingNew) { NewBrandSheet(model: model) }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}

struct NewBrandSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var industry = ""
    @State private var instagram = true
    @State private var linkedin = false

    var body: some View {
        Form {
            TextField("Nombre", text: $name)
            TextField("Rubro", text: $industry)
            Toggle("Instagram", isOn: $instagram)
            Toggle("LinkedIn", isOn: $linkedin)
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Crear") {
                    model.errorMessage = nil
                    let networks = [instagram ? Network.instagram : nil, linkedin ? Network.linkedin : nil].compactMap { $0 }
                    model.createBrand(name: name, industry: industry, networks: networks)
                    if model.errorMessage == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!instagram && !linkedin)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
```

`app/Sources/FrontbotApp/ChatView.swift`:
```swift
import SwiftUI
import FrontbotCore

struct ChatView: View {
    @Bindable var model: AppModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if !model.apiKeyPresent && ProcessInfo.processInfo.environment["FRONTBOT_FAKE_AGENT"] != "1" {
                Text("Configura tu API key de Anthropic en Ajustes (⌘,).")
                    .frame(maxWidth: .infinity).padding(8).background(.yellow.opacity(0.2))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.messages) { message in
                        Text(message.text)
                            .textSelection(.enabled)
                            .foregroundStyle(color(for: message.role))
                            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                    }
                    if model.isRunning { ProgressView().controlSize(.small) }
                }
                .padding()
            }
            Divider()
            HStack {
                TextField(model.selectedBrand.map { "Pídele algo para \($0.name)…" } ?? "Pídele algo a Frontbot…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                if model.isRunning {
                    Button("Detener") { model.cancel() }
                } else {
                    Button("Enviar", action: submit).keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
    }

    private func submit() {
        model.send(prompt: draft)
        draft = ""
    }

    private func color(for role: ChatMessage.Role) -> Color {
        switch role {
        case .user: .primary
        case .agent: .primary
        case .tool: .secondary
        case .error: .red
        }
    }
}
```

`app/Sources/FrontbotApp/SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        Form {
            SecureField("API key de Anthropic", text: $key)
            Text(model.apiKeyPresent ? "Hay una key guardada en el Keychain." : "No hay key guardada.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Guardar") {
                model.saveApiKey(key)
                key = ""
                saved = true
            }
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            if saved { Text("Guardada.").font(.caption) }
        }
        .padding()
        .frame(width: 420)
    }
}
```

- [ ] **Step 8: Compilar**

Run: `cd app && swift build`
Expected: `Build complete!` sin errores.

- [ ] **Step 9: Verificación manual en modo agente falso**

```bash
cd agent && npm run build && cd ../app
FRONTBOT_FAKE_AGENT=1 FRONTBOT_NODE=$(which node) FRONTBOT_AGENT_SCRIPT=$(cd ../agent && pwd)/dist/main.js swift run FrontbotApp
```

Checklist:
- [ ] Se abre la ventana "Frontbot" con la barra lateral vacía.
- [ ] "Nueva marca" con nombre vacío muestra "La marca necesita un nombre." y no cierra la hoja.
- [ ] Crear "Café Sol" (Instagram) la muestra seleccionada.
- [ ] Enviar "crear post" muestra "Tienes 1 marca(s)." y "→ posts_create_draft"; el spinner desaparece.
- [ ] Enviar "lento" y pulsar "Detener" muestra "Cancelado" en rojo.
- [ ] Enviar "crash" muestra "El agente se detuvo inesperadamente." y el siguiente mensaje funciona.
- [ ] Cerrar y reabrir la app: la marca sigue ahí.

- [ ] **Step 10: Verificación manual con el agente real**

```bash
FRONTBOT_NODE=$(which node) FRONTBOT_AGENT_SCRIPT=$(cd ../agent && pwd)/dist/main.js swift run FrontbotApp
```

- [ ] Sin key: enviar un mensaje muestra "Configura tu API key de Anthropic en Ajustes." sin arrancar nada.
- [ ] Guardar la key en Ajustes (⌘,). Con "Café Sol" seleccionada, enviar: "Investiga tendencias de cafeterías en Instagram y crea 2 borradores para esta semana".
- [ ] Se ven las llamadas a herramientas, el run termina y en SQLite hay 2 posts `draft`: `sqlite3 ~/Library/Application\ Support/Frontbot/frontbot.sqlite "select status, substr(body,1,60) from post;"`.
- [ ] `select status, costUsd from agentRun order by createdAt desc limit 1;` muestra `done` y un costo > 0.

- [ ] **Step 11: Commit**

```bash
git add app
git commit -m "feat: add minimal SwiftUI app with brands, agent chat and settings"
```

---

## Self-review (hecho al escribir el plan)

- **Cobertura del spec en Fase 1:** arquitectura app + sidecar + JSON-RPC (Tasks 5–9), modelo de datos completo (3), máquina de estados (2), validaciones por red (1), guía de marca como contexto (4, 8), herramientas sin publicar/aprobar (6, 8), Keychain (10), workspace_id (3), errores de sidecar/API key/herramientas (6, 8, 9, 10), modo agente falso (8). Quedan para fases 2–4, como dice el encabezado: calendario, biblioteca de imágenes (`brand_asset` ya existe en el esquema), aprobación en UI, "Entrevístame"/PDF, publicación asistida, notch y vistas de tareas e ideas.
- **Consistencia de nombres:** `tool.<name>` en Swift (Task 6) = `TOOL_SPECS[].name` con prefijo en TS (Task 8); `agent.run`/`agent.cancel`/`agent.event`/`agent.done` iguales en Tasks 8 y 9; mensajes de error idénticos entre store, ToolHandler y tests.
