# Frontbot Fase 4 — Tareas, ideas, notch, atajo global y empaquetado `.app` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vistas de Tareas e Ideas en la ventana principal; un panel en el notch (atajo global ⌥Espacio) con prompt rápido, tareas de hoy y avisos de posts por revisar/publicar; y un `Frontbot.app` autocontenido (Node y el sidecar dentro) que se abre con doble clic.

**Architecture:** La lógica nueva va a `FrontbotCore` con tests: agrupación de tareas, resumen del día, geometría del notch (adaptada de coucou, MIT) y localización del agente dentro del bundle. La UI añade dos secciones, un `NSPanel` sin activación en el notch con contenido SwiftUI, y un registro de atajo global vía Carbon (adaptado de coucou). Un script arma el `.app` con el binario release, `Resources/node/bin/node`, `Resources/agent/` y firma ad-hoc; `--self-check` verifica el bundle sin abrir la UI.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit (NSPanel, NSScreen.safeAreaInsets), Carbon.HIToolbox (RegisterEventHotKey), GRDB, XCTest · bash, codesign.

**Spec:** `docs/superpowers/specs/2026-10-13-frontbot-design.md` (secciones 3, 5.6, 5.7, 5.9, 10).

## Global Constraints

- Las de Fases 1–3.
- Atajo global: **⌥Espacio** (Option+Space). Si `RegisterEventHotKey` falla (otra app lo usa), Ajustes muestra "⌥Espacio está ocupado por otra app." y el panel sigue accesible haciendo clic en el notch.
- Panel del notch: `NSPanel` `[.borderless, .nonactivatingPanel]`, nivel `.statusBar`, en todos los Espacios y sobre apps a pantalla completa; colapsado mide el ancho del notch + 120 pt y su alto; expandido **520 × 400** pt, alineado arriba y centrado. En Macs sin notch: 80 × min(24, alto de la barra de menú) colapsado.
- "Tareas de hoy" = no hechas con fecha de hoy **o atrasadas**.
- Bundle: `build/Frontbot.app`, `CFBundleIdentifier` `app.frontbot.Frontbot`, `LSMinimumSystemVersion` `14.0`, firma ad-hoc (`codesign --force --deep -s -`). `build/` está en `.gitignore`.
- Localización del agente (orden): variables `FRONTBOT_NODE` + `FRONTBOT_AGENT_SCRIPT` → `Contents/Resources/node/bin/node` + `Contents/Resources/agent/dist/main.js` → no encontrado (`"No encontré el agente de Frontbot. Reinstala la app o define FRONTBOT_NODE y FRONTBOT_AGENT_SCRIPT."`).
- Código adaptado de coucou queda atribuido en `THIRD_PARTY_NOTICES.md` (ya existe la licencia MIT).

## Review Focus

1. **Tarea con fecha de ayer sin hacer** — aparece en "Atrasadas" de la vista de tareas y en las tareas de hoy del notch. Test en Task 1.
2. **Mac sin notch o con monitor externo como principal** — el panel se coloca arriba al centro de la pantalla correcta con tamaño de respaldo, nunca fuera de pantalla. Test en Task 2.
3. **`.app` movido a otra carpeta o abierto con doble clic (sin variables de entorno)** — encuentra Node y el sidecar dentro del bundle. Tests en Tasks 3 y 6.
4. **⌥Espacio ocupado por otra app** — no rompe el arranque; se informa en Ajustes. Verificación manual en Task 5.
5. **Posts de otro workspace o archivados** — no cuentan en el resumen del notch. Test en Task 1.

---

## Estructura de archivos

```
app/Sources/FrontbotCore/
├── Content/TodaySummary.swift     # NUEVO: grupos de tareas y resumen del día
├── Store/Repositories.swift       # MOD: setTaskDone, deleteTask, ideas, deleteIdea
├── Notch/NotchGeometry.swift      # NUEVO: adaptado de coucou IslandScreenGeometry + marcos del panel
└── Agent/AgentLocator.swift       # NUEVO: dónde están node y el sidecar
app/Sources/FrontbotApp/
├── TasksView.swift, IdeasView.swift          # NUEVO
├── Notch/NotchPanel.swift, NotchView.swift   # NUEVO
├── Notch/HotKey.swift                        # NUEVO: adaptado de coucou HotKeyCenter
├── AppModel.swift, RootView.swift, BrandsView.swift, SettingsView.swift, FrontbotApp.swift  # MOD
scripts/build-app.sh                           # NUEVO
```

---

### Task 1: Tareas e ideas en el store, y resumen del día

**Files:**
- Create: `app/Sources/FrontbotCore/Content/TodaySummary.swift`
- Modify: `app/Sources/FrontbotCore/Store/Repositories.swift`
- Test: `app/Tests/FrontbotCoreTests/TodaySummaryTests.swift`

**Interfaces:**
- Produces:
  - `AppDatabase.setTaskDone(id: String, done: Bool) throws -> TaskItem`, `deleteTask(id: String) throws`, `ideas(workspaceId: String) throws -> [BusinessIdea]` (puntaje desc, luego más recientes), `deleteIdea(id: String) throws -> BusinessIdea?` (devuelve la borrada para que la app borre su reporte).
  - `enum TaskBucket: String, CaseIterable, Sendable { case overdue = "Atrasadas", today = "Hoy", upcoming = "Próximas", someday = "Sin fecha", done = "Hechas" }`
  - `enum TaskGrouping { static func bucket(_ t: TaskItem, now: Date, calendar: Calendar) -> TaskBucket; static func group(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [(TaskBucket, [TaskItem])] }` — solo grupos no vacíos, en el orden de `allCases`.
  - `struct TodaySummary: Equatable, Sendable { let tasks: [TaskItem]; let draftsToReview: Int; let readyToPublish: Int; let postsToday: [Post] }`
  - `AppDatabase.todaySummary(workspaceId: String, now: Date = Date(), calendar: Calendar = .current) throws -> TodaySummary` — `tasks` = atrasadas + hoy no hechas (por fecha); conteos y `postsToday` solo de marcas del workspace y sin archivados/publicados; `postsToday` = programados para hoy, ordenados por hora.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class TodaySummaryTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!
    var brand: Brand!
    var cal: Calendar!
    var now: Date!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram, .linkedin])
        cal = Calendar.current
        now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    func day(_ offset: Int, hour: Int = 10) -> Date {
        cal.date(bySettingHour: hour, minute: 0, second: 0, of: cal.date(byAdding: .day, value: offset, to: now)!)!
    }

    func testBuckets() throws {
        let overdue = try db.createTask(workspaceId: ws.id, title: "ayer", dueDate: day(-1), brandId: nil)
        let today = try db.createTask(workspaceId: ws.id, title: "hoy", dueDate: day(0), brandId: nil)
        let later = try db.createTask(workspaceId: ws.id, title: "mañana", dueDate: day(1), brandId: nil)
        let someday = try db.createTask(workspaceId: ws.id, title: "algún día", dueDate: nil, brandId: nil)
        let done = try db.setTaskDone(id: try db.createTask(workspaceId: ws.id, title: "hecha", dueDate: day(-3), brandId: nil).id, done: true)
        let groups = TaskGrouping.group([later, done, someday, today, overdue], now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.0), [.overdue, .today, .upcoming, .someday, .done])
        XCTAssertEqual(groups.map { $0.1.map(\.title) }, [["ayer"], ["hoy"], ["mañana"], ["algún día"], ["hecha"]])
    }

    func testSetTaskDoneTogglesAndDelete() throws {
        let t = try db.createTask(workspaceId: ws.id, title: "x", dueDate: nil, brandId: nil)
        XCTAssertTrue(try db.setTaskDone(id: t.id, done: true).done)
        XCTAssertFalse(try db.setTaskDone(id: t.id, done: false).done)
        try db.deleteTask(id: t.id)
        XCTAssertEqual(try db.tasks(workspaceId: ws.id, on: nil), [])
    }

    func testIdeasSortedByScoreAndDelete() throws {
        let low = try db.createIdea(workspaceId: ws.id, title: "baja", summary: "", sources: [], score: 2)
        _ = try db.createIdea(workspaceId: ws.id, title: "alta", summary: "", sources: [], score: 5)
        XCTAssertEqual(try db.ideas(workspaceId: ws.id).map(\.title), ["alta", "baja"])
        XCTAssertEqual(try db.deleteIdea(id: low.id)?.title, "baja")
        XCTAssertEqual(try db.ideas(workspaceId: ws.id).map(\.title), ["alta"])
    }

    func testTodaySummary() throws {
        _ = try db.createTask(workspaceId: ws.id, title: "ayer", dueDate: day(-1), brandId: nil)
        _ = try db.createTask(workspaceId: ws.id, title: "hoy", dueDate: day(0), brandId: nil)
        _ = try db.createTask(workspaceId: ws.id, title: "mañana", dueDate: day(1), brandId: nil)
        _ = try db.createDraft(brandId: brand.id, network: .linkedin, body: "borrador", media: [], scheduledFor: day(0, hour: 18))
        let approved = try db.createDraft(brandId: brand.id, network: .linkedin, body: "aprobado", media: [], scheduledFor: day(0, hour: 9))
        _ = try db.transitionPost(id: approved.id, to: .approved, actor: .user)
        let archived = try db.createDraft(brandId: brand.id, network: .linkedin, body: "archivado", media: [], scheduledFor: day(0))
        _ = try db.transitionPost(id: archived.id, to: .archived, actor: .user)
        // Otro workspace: no debe contar.
        let other = Workspace(id: UUID().uuidString, name: "otro", createdAt: Date())
        try db.writer.write { try other.insert($0) }
        let foreign = try db.createBrand(workspaceId: other.id, name: "F", industry: "", networks: [.linkedin])
        _ = try db.createDraft(brandId: foreign.id, network: .linkedin, body: "ajeno", media: [], scheduledFor: day(0))

        let s = try db.todaySummary(workspaceId: ws.id, now: now, calendar: cal)
        XCTAssertEqual(s.tasks.map(\.title), ["ayer", "hoy"])
        XCTAssertEqual(s.draftsToReview, 1)
        XCTAssertEqual(s.readyToPublish, 1)
        XCTAssertEqual(s.postsToday.map(\.body), ["aprobado", "borrador"])
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter TodaySummaryTests`
Expected: FAIL — `cannot find 'TaskGrouping' in scope` / `has no member 'setTaskDone'`.

- [ ] **Step 3: Implementar**

En `Repositories.swift` (sección Tasks) reemplazar `completeTask` por una llamada a `setTaskDone` y añadir:
```swift
    public func completeTask(id: String) throws -> TaskItem {
        try setTaskDone(id: id, done: true)
    }

    public func setTaskDone(id: String, done: Bool) throws -> TaskItem {
        try writer.write { db in
            guard var task = try TaskItem.fetchOne(db, key: id) else { throw notFound("tarea", id) }
            task.done = done
            try task.update(db)
            return task
        }
    }

    public func deleteTask(id: String) throws {
        _ = try writer.write { try TaskItem.deleteOne($0, key: id) }
    }
```
En la sección Ideas:
```swift
    public func ideas(workspaceId: String) throws -> [BusinessIdea] {
        try writer.read { try BusinessIdea.filter(Column("workspaceId") == workspaceId)
            .order(Column("score").desc, Column("createdAt").desc).fetchAll($0) }
    }

    @discardableResult
    public func deleteIdea(id: String) throws -> BusinessIdea? {
        try writer.write { db in
            let idea = try BusinessIdea.fetchOne(db, key: id)
            _ = try BusinessIdea.deleteOne(db, key: id)
            return idea
        }
    }
```

`app/Sources/FrontbotCore/Content/TodaySummary.swift`:
```swift
import Foundation
import GRDB

public enum TaskBucket: String, CaseIterable, Sendable {
    case overdue = "Atrasadas", today = "Hoy", upcoming = "Próximas", someday = "Sin fecha", done = "Hechas"
}

public enum TaskGrouping {
    public static func bucket(_ t: TaskItem, now: Date, calendar: Calendar) -> TaskBucket {
        if t.done { return .done }
        guard let due = t.dueDate else { return .someday }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        if due < start { return .overdue }
        if due < end { return .today }
        return .upcoming
    }

    public static func group(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [(TaskBucket, [TaskItem])] {
        let sorted = tasks.sorted { ($0.dueDate ?? .distantFuture, $0.createdAt) < ($1.dueDate ?? .distantFuture, $1.createdAt) }
        return TaskBucket.allCases.compactMap { bucket in
            let items = sorted.filter { self.bucket($0, now: now, calendar: calendar) == bucket }
            return items.isEmpty ? nil : (bucket, items)
        }
    }
}

public struct TodaySummary: Equatable, Sendable {
    public let tasks: [TaskItem]
    public let draftsToReview: Int
    public let readyToPublish: Int
    public let postsToday: [Post]
}

extension AppDatabase {
    public func todaySummary(workspaceId: String, now: Date = Date(), calendar: Calendar = .current) throws -> TodaySummary {
        let tasks = try writer.read { try TaskItem.filter(Column("workspaceId") == workspaceId && Column("done") == false).fetchAll($0) }
            .filter { [.overdue, .today].contains(TaskGrouping.bucket($0, now: now, calendar: calendar)) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let brandIds = Set(try brands(workspaceId: workspaceId).map(\.id))
        let posts = try posts(brandId: nil, status: nil).filter { brandIds.contains($0.brandId) }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let active: Set<PostStatus> = [.draft, .approved, .preparing, .scheduled]
        let today = posts
            .filter { p in active.contains(p.status) && (p.scheduledFor.map { $0 >= start && $0 < end } ?? false) }
            .sorted { $0.scheduledFor! < $1.scheduledFor! }
        return TodaySummary(
            tasks: tasks,
            draftsToReview: posts.filter { $0.status == .draft }.count,
            readyToPublish: posts.filter { $0.status == .approved }.count,
            postsToday: today)
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa** — `cd app && swift test --filter TodaySummaryTests` → PASS (4 tests); luego `FRONTBOT_NODE=$(which node) swift test` → todo verde.

- [ ] **Step 5: Commit** — `git add app && git commit -m "feat: add task grouping, idea listing and today summary"`

---

### Task 2: Geometría del notch y marcos del panel

**Files:**
- Create: `app/Sources/FrontbotCore/Notch/NotchGeometry.swift`
- Modify: `THIRD_PARTY_NOTICES.md` (archivos adaptados)
- Test: `app/Tests/FrontbotCoreTests/NotchGeometryTests.swift`

**Interfaces:**
- Produces: `struct NotchGeometry: Equatable, Sendable { static let fallbackNotchWidth: CGFloat = 184; let hasNotch: Bool; let width: CGFloat; let height: CGFloat; init(screenWidth:safeAreaTop:auxiliaryLeftWidth:auxiliaryRightWidth:menuBarHeight:); static let expandedSize = CGSize(width: 520, height: 400); func panelFrame(in screenFrame: CGRect, expanded: Bool) -> CGRect }`
- Marco colapsado: ancho `width + 120`, alto `height`; expandido: `expandedSize`, recortado al ancho de la pantalla. Siempre centrado en `screenFrame.midX` y pegado arriba (`origin.y = screenFrame.maxY - alto`, coordenadas AppKit).

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class NotchGeometryTests: XCTestCase {
    func testMeasuresNotchFromAuxiliaryAreas() {
        let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 38, auxiliaryLeftWidth: 664, auxiliaryRightWidth: 664, menuBarHeight: 38)
        XCTAssertTrue(g.hasNotch)
        XCTAssertEqual(g.width, 184)
        XCTAssertEqual(g.height, 38)
    }

    func testNoNotchFallback() {
        let g = NotchGeometry(screenWidth: 2560, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 25)
        XCTAssertFalse(g.hasNotch)
        XCTAssertEqual(g.width, 80)
        XCTAssertEqual(g.height, 24)
    }

    func testBogusAuxiliaryWidthsFallBack() {
        let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 38, auxiliaryLeftWidth: 900, auxiliaryRightWidth: 900, menuBarHeight: 38)
        XCTAssertEqual(g.width, NotchGeometry.fallbackNotchWidth)
    }

    func testPanelFramesAreTopCenteredOnTheGivenScreen() {
        let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 38, auxiliaryLeftWidth: 664, auxiliaryRightWidth: 664, menuBarHeight: 38)
        // Pantalla secundaria a la derecha de la principal.
        let screen = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        XCTAssertEqual(g.panelFrame(in: screen, expanded: false), CGRect(x: 1512 + 756 - 152, y: 982 - 38, width: 304, height: 38))
        XCTAssertEqual(g.panelFrame(in: screen, expanded: true), CGRect(x: 1512 + 756 - 260, y: 982 - 400, width: 520, height: 400))
    }

    func testExpandedPanelNeverWiderThanScreen() {
        let g = NotchGeometry(screenWidth: 400, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 24)
        let f = g.panelFrame(in: CGRect(x: 0, y: 0, width: 400, height: 300), expanded: true)
        XCTAssertEqual(f.width, 400)
        XCTAssertEqual(f.minX, 0)
        XCTAssertEqual(f.height, 300)
    }
}
```

- [ ] **Step 2: Correr y verificar que falla** — `swift test --filter NotchGeometryTests` → FAIL `cannot find 'NotchGeometry'`.

- [ ] **Step 3: Implementar**

```swift
import Foundation
import CoreGraphics

/// Dimensiones del notch, midiendo el notch físico cuando la pantalla lo tiene.
/// Adaptado de coucou `IslandScreenGeometry` (MIT, © 2026 Louis Raillé).
public struct NotchGeometry: Equatable, Sendable {
    public static let fallbackNotchWidth: CGFloat = 184
    public static let expandedSize = CGSize(width: 520, height: 400)
    private static let noNotchWidth: CGFloat = 80
    private static let noNotchHeight: CGFloat = 24
    private static let collapsedExtraWidth: CGFloat = 120

    public let hasNotch: Bool
    public let width: CGFloat
    public let height: CGFloat

    public init(screenWidth: CGFloat, safeAreaTop: CGFloat, auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?, menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measured = screenWidth - left - right
                width = measured > 0 && measured < screenWidth ? measured : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }

    /// Marco del panel en coordenadas AppKit: centrado arriba de `screenFrame`.
    public func panelFrame(in screenFrame: CGRect, expanded: Bool) -> CGRect {
        let size = expanded
            ? CGSize(width: min(Self.expandedSize.width, screenFrame.width), height: min(Self.expandedSize.height, screenFrame.height))
            : CGSize(width: width + Self.collapsedExtraWidth, height: height)
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }
}
```

Nota: en `testBogusAuxiliaryWidthsFallBack` la medida da `1512 - 1800 < 0`, por eso cae al respaldo.

En `THIRD_PARTY_NOTICES.md`, bajo la sección coucou, añadir: `Archivos adaptados: app/Sources/FrontbotCore/Notch/NotchGeometry.swift (de IslandScreenGeometry.swift) y app/Sources/FrontbotApp/Notch/HotKey.swift (de HotKeyCenter.swift).`

- [ ] **Step 4: Correr y verificar que pasa** — `swift test --filter NotchGeometryTests` → PASS (5).

- [ ] **Step 5: Commit** — `git add app THIRD_PARTY_NOTICES.md && git commit -m "feat: add notch geometry adapted from coucou"`

---

### Task 3: Localizar Node y el sidecar (variables o dentro del bundle)

**Files:**
- Create: `app/Sources/FrontbotCore/Agent/AgentLocator.swift`
- Test: `app/Tests/FrontbotCoreTests/AgentLocatorTests.swift`

**Interfaces:**
- Produces: `struct AgentLocation: Equatable, Sendable { let node: String; let script: String }`; `enum AgentLocator { static let notFoundMessage = "No encontré el agente de Frontbot. Reinstala la app o define FRONTBOT_NODE y FRONTBOT_AGENT_SCRIPT."; static func locate(environment: [String: String], resources: URL?, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> AgentLocation? }`.
- Reglas: si `FRONTBOT_NODE` y `FRONTBOT_AGENT_SCRIPT` existen y ambos archivos existen → esos. Si no, `resources/node/bin/node` + `resources/agent/dist/main.js` si ambos existen. Si no, `nil`.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class AgentLocatorTests: XCTestCase {
    let res = URL(fileURLWithPath: "/Applications/Frontbot.app/Contents/Resources")
    let bundled = AgentLocation(node: "/Applications/Frontbot.app/Contents/Resources/node/bin/node",
                                script: "/Applications/Frontbot.app/Contents/Resources/agent/dist/main.js")

    func testEnvironmentWins() {
        let env = ["FRONTBOT_NODE": "/n", "FRONTBOT_AGENT_SCRIPT": "/s.js"]
        XCTAssertEqual(AgentLocator.locate(environment: env, resources: res, exists: { _ in true }), AgentLocation(node: "/n", script: "/s.js"))
    }

    func testBundleWhenNoEnvironment() {
        XCTAssertEqual(AgentLocator.locate(environment: [:], resources: res, exists: { _ in true }), bundled)
    }

    func testEnvironmentPointingToMissingFilesFallsBackToBundle() {
        let env = ["FRONTBOT_NODE": "/n", "FRONTBOT_AGENT_SCRIPT": "/s.js"]
        XCTAssertEqual(AgentLocator.locate(environment: env, resources: res, exists: { $0.hasPrefix("/Applications") }), bundled)
    }

    func testNothingFound() {
        XCTAssertNil(AgentLocator.locate(environment: [:], resources: res, exists: { _ in false }))
        XCTAssertNil(AgentLocator.locate(environment: [:], resources: nil, exists: { _ in true }))
    }
}
```

- [ ] **Step 2: Correr y verificar que falla** — `swift test --filter AgentLocatorTests` → FAIL `cannot find 'AgentLocator'`.

- [ ] **Step 3: Implementar**

```swift
import Foundation

public struct AgentLocation: Equatable, Sendable {
    public let node: String
    public let script: String
}

/// Dónde están Node y el sidecar: variables de entorno (desarrollo) o dentro del `.app`.
public enum AgentLocator {
    public static let notFoundMessage = "No encontré el agente de Frontbot. Reinstala la app o define FRONTBOT_NODE y FRONTBOT_AGENT_SCRIPT."

    public static func locate(environment: [String: String], resources: URL?,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> AgentLocation? {
        if let node = environment["FRONTBOT_NODE"], let script = environment["FRONTBOT_AGENT_SCRIPT"], exists(node), exists(script) {
            return AgentLocation(node: node, script: script)
        }
        if let resources {
            let node = resources.appendingPathComponent("node/bin/node").path
            let script = resources.appendingPathComponent("agent/dist/main.js").path
            if exists(node), exists(script) { return AgentLocation(node: node, script: script) }
        }
        return nil
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa** — PASS (4).

- [ ] **Step 5: Usarlo en la app** — en `AppModel.makeConfig`, reemplazar `nodePath`/`scriptPath`:
```swift
        let location = AgentLocator.locate(environment: env, resources: Bundle.main.resourceURL)
        return AgentConfig(
            nodePath: location?.node ?? "/usr/bin/false",
            scriptPath: location?.script ?? "",
            ...
```
y en `init`, tras crear el cliente: `if AgentLocator.locate(environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL) == nil { errorMessage = AgentLocator.notFoundMessage }`.

Compilar: `swift build` sin errores.

- [ ] **Step 6: Commit** — `git add app && git commit -m "feat: locate node and the agent inside the app bundle"`

---

### Task 4: Vistas de Tareas e Ideas

**Files:**
- Create: `app/Sources/FrontbotApp/TasksView.swift`, `app/Sources/FrontbotApp/IdeasView.swift`
- Modify: `AppModel.swift`, `RootView.swift`, `BrandsView.swift`

**Interfaces:**
- `AppModel.Section` gana `.tasks` y `.ideas`. `AppModel` gana `var tasks: [TaskItem]`, `var ideas: [BusinessIdea]`, `var today: TodaySummary?` (se recargan en `reloadContent()`), y `addTask(title:dueDate:)`, `setTaskDone(_:done:)`, `deleteTask(_:)`, `deleteIdea(_:)` (borra también el reporte), `ideaReport(_:) -> String?`.
- Sin tests automáticos (UI). Verificación manual en Task 6.

- [ ] **Step 1: `AppModel`** — añadir:

```swift
    var tasks: [TaskItem] = []
    var ideas: [BusinessIdea] = []
    var today: TodaySummary?
```
En `reloadContent()` al principio:
```swift
        tasks = (try? db.tasks(workspaceId: workspace.id, on: nil)) ?? []
        ideas = (try? db.ideas(workspaceId: workspace.id)) ?? []
        today = try? db.todaySummary(workspaceId: workspace.id)
```
Métodos:
```swift
    // MARK: Tareas e ideas

    func addTask(title: String, dueDate: Date?) {
        perform { _ = try db.createTask(workspaceId: workspace.id, title: title, dueDate: dueDate, brandId: nil) }
        reloadContent()
    }

    func setTaskDone(_ task: TaskItem, done: Bool) {
        perform { _ = try db.setTaskDone(id: task.id, done: done) }
        reloadContent()
    }

    func deleteTask(_ task: TaskItem) {
        perform { try db.deleteTask(id: task.id) }
        reloadContent()
    }

    func deleteIdea(_ idea: BusinessIdea) {
        perform {
            let removed = try db.deleteIdea(id: idea.id)
            if let path = removed?.reportPath { try? FileManager.default.removeItem(atPath: path) }
        }
        reloadContent()
    }

    func ideaReport(_ idea: BusinessIdea) -> String? {
        idea.reportPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }
```
`Section`: `enum Section: Hashable { case brand(String), calendar, chat, tasks, ideas }`.

- [ ] **Step 2: `TasksView.swift`**

```swift
import SwiftUI
import FrontbotCore

struct TasksView: View {
    @Bindable var model: AppModel
    @State private var title = ""
    @State private var hasDate = true
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tareas").font(.largeTitle).bold()
            HStack {
                TextField("Nueva tarea…", text: $title).onSubmit(add)
                Toggle("Fecha", isOn: $hasDate).toggleStyle(.checkbox)
                if hasDate { DatePicker("", selection: $date, displayedComponents: .date).labelsHidden().frame(width: 120) }
                Button("Añadir", action: add).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(TaskGrouping.group(model.tasks, now: Date()), id: \.0) { bucket, items in
                    Section(bucket.rawValue) {
                        ForEach(items) { task in
                            HStack {
                                Toggle(isOn: Binding(get: { task.done }, set: { model.setTaskDone(task, done: $0) })) {
                                    Text(task.title).strikethrough(task.done)
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                if let due = task.dueDate {
                                    Text(due.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                                        .foregroundStyle(bucket == .overdue ? .red : .secondary)
                                }
                            }
                            .contextMenu { Button("Eliminar", role: .destructive) { model.deleteTask(task) } }
                        }
                    }
                }
            }
            if model.tasks.isEmpty {
                Text("Sin tareas. También puedes pedírselas al agente: «recuérdame grabar el reel el jueves».")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.addTask(title: t, dueDate: hasDate ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) : nil)
        title = ""
    }
}
```

- [ ] **Step 3: `IdeasView.swift`**

```swift
import SwiftUI
import FrontbotCore

struct IdeasView: View {
    @Bindable var model: AppModel
    @State private var selected: String?

    var body: some View {
        HSplitView {
            List(model.ideas, selection: $selected) { idea in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(idea.title).bold()
                        Spacer()
                        Text(String(repeating: "★", count: idea.score)).foregroundStyle(.orange)
                    }
                    Text(idea.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(idea.id)
                .contextMenu { Button("Eliminar", role: .destructive) { model.deleteIdea(idea) } }
            }
            .frame(minWidth: 260)
            .overlay {
                if model.ideas.isEmpty {
                    Text("Pídele al agente: «busca oportunidades de negocio en…»").foregroundStyle(.secondary).padding()
                }
            }

            ScrollView {
                if let idea = model.ideas.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(idea.title).font(.title).bold()
                        Text(idea.summary)
                        if !idea.sources.isEmpty {
                            Text("Fuentes").font(.headline)
                            ForEach(idea.sources, id: \.self) { s in
                                if let url = URL(string: s) { Link(s, destination: url) } else { Text(s) }
                            }
                        }
                        if let report = model.ideaReport(idea) {
                            Divider()
                            Text((try? AttributedString(markdown: report, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(report))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Elige una idea").foregroundStyle(.secondary).padding()
                }
            }
        }
    }
}
```

- [ ] **Step 4: Navegación** — en `RootView` añadir `case .tasks: TasksView(model: model)` y `case .ideas: IdeasView(model: model)`; en `BrandsView`, en la primera `Section`, añadir botones "Tareas" (`checklist`) e "Ideas" (`lightbulb`) con el mismo estilo que Chat/Calendario.

- [ ] **Step 5: Compilar y suite** — `swift build` sin errores; `FRONTBOT_NODE=$(which node) swift test` verde.

- [ ] **Step 6: Commit** — `git add app && git commit -m "feat: add tasks and business ideas views"`

---

### Task 5: Panel del notch y atajo global ⌥Espacio

**Files:**
- Create: `app/Sources/FrontbotApp/Notch/HotKey.swift`, `Notch/NotchPanel.swift`, `Notch/NotchView.swift`
- Modify: `AppModel.swift`, `FrontbotApp.swift`, `SettingsView.swift`

**Interfaces:**
- `@MainActor final class HotKey { static let shared; private(set) var registered: Bool; func register(onPress: @escaping @MainActor () -> Void) }` — registra ⌥Espacio (`kVK_Space`, `optionKey`) con `RegisterEventHotKey`; `registered == false` si falla.
- `@MainActor final class NotchController { init(model: AppModel); func show(); func toggle(); func collapse() }` — crea el `NotchPanel` en la pantalla con notch (o la principal), lo coloca con `NotchGeometry.panelFrame`, y se recoloca al cambiar pantallas (`NSApplication.didChangeScreenParametersNotification`).
- `AppModel` gana `var notchExpanded = false`, `var lastAgentReply: String?` (último texto del agente), `var hotKeyRegistered = true`, y `func showMainWindow(section: Section)`.
- Sin tests automáticos (AppKit/Carbon); la geometría ya está probada en Task 2.

- [ ] **Step 1: `HotKey.swift`** (adaptado de coucou HotKeyCenter, un solo atajo):

```swift
import AppKit
import Carbon.HIToolbox

// Carbon exige un manejador C de nivel superior; el estado vive en globales que solo se tocan en el hilo principal.
private nonisolated(unsafe) var gHandler: EventHandlerRef?
private nonisolated(unsafe) var gOnPress: (() -> Void)?

private func frontbotHotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { gOnPress?() }
    return noErr
}

/// Atajo global ⌥Espacio vía `RegisterEventHotKey` (no requiere permisos de Accesibilidad).
/// Adaptado de coucou `HotKeyCenter` (MIT, © 2026 Louis Raillé).
@MainActor
final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private(set) var registered = false

    func register(onPress: @escaping @MainActor () -> Void) {
        gOnPress = { MainActor.assumeIsolated { onPress() } }
        if gHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), frontbotHotKeyHandler, 1, &spec, nil, &gHandler)
        }
        if let ref { UnregisterEventHotKey(ref) }
        let id = EventHotKeyID(signature: OSType(0x46524254), id: 1) // "FRBT"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
    }
}
```

- [ ] **Step 2: `NotchPanel.swift`**

```swift
import AppKit
import SwiftUI
import FrontbotCore

/// Panel sin bordes que no roba el foco al abrirse, pero acepta teclado para el prompt.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchController {
    private let model: AppModel
    private var panel: NotchPanel?

    init(model: AppModel) {
        self.model = model
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
    }

    /// La pantalla con notch si hay una; si no, la principal.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func geometry(for screen: NSScreen) -> NotchGeometry {
        NotchGeometry(
            screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width, auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }

    func show() {
        if panel == nil {
            let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: NotchView(model: model, controller: self))
            panel = p
        }
        layout(animated: false)
        panel?.orderFrontRegardless()
    }

    func toggle() {
        model.notchExpanded.toggle()
        layout(animated: true)
        if model.notchExpanded {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKey()
        }
    }

    func collapse() {
        guard model.notchExpanded else { return }
        model.notchExpanded = false
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        guard let panel, let screen else { return }
        let frame = geometry(for: screen).panelFrame(in: screen.frame, expanded: model.notchExpanded)
        panel.setFrame(frame, display: true, animate: animated)
    }
}
```

- [ ] **Step 3: `NotchView.swift`**

```swift
import SwiftUI
import FrontbotCore

struct NotchView: View {
    @Bindable var model: AppModel
    let controller: NotchController
    @State private var prompt = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.notchExpanded { expanded } else { collapsed }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18).fill(.black))
        .foregroundStyle(.white)
    }

    /// Colapsado: indicadores a los lados del notch; clic para abrir.
    private var collapsed: some View {
        HStack {
            if let n = model.today?.tasks.count, n > 0 { Label("\(n)", systemImage: "checklist").font(.caption2) }
            Spacer()
            if let n = model.today?.draftsToReview, n > 0 { Label("\(n)", systemImage: "doc.badge.ellipsis").font(.caption2) }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { controller.toggle() }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Pídele algo a Frontbot…", text: $prompt)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit { model.send(prompt: prompt); prompt = "" }
                if model.isRunning { ProgressView().controlSize(.small) }
                Button { controller.collapse() } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))

            if let reply = model.lastAgentReply {
                ScrollView { Text(reply).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 110)
            }

            if let today = model.today {
                if !today.tasks.isEmpty {
                    Text("Hoy").font(.caption).foregroundStyle(.white.opacity(0.6))
                    ForEach(today.tasks.prefix(5)) { task in
                        Toggle(isOn: Binding(get: { task.done }, set: { model.setTaskDone(task, done: $0) })) { Text(task.title) }
                            .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    if today.draftsToReview > 0 {
                        Button("\(today.draftsToReview) por revisar") { model.showMainWindow(section: .calendar); controller.collapse() }
                    }
                    if today.readyToPublish > 0 {
                        Button("\(today.readyToPublish) listos para publicar") { model.showMainWindow(section: .calendar); controller.collapse() }
                    }
                    Spacer()
                    Button("Abrir Frontbot") { model.showMainWindow(section: .chat); controller.collapse() }
                }
                .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 34).padding(.horizontal, 16).padding(.bottom, 12)
        .onAppear { focused = true }
        .onExitCommand { controller.collapse() }
    }
}
```

- [ ] **Step 4: `AppModel`** — añadir:

```swift
    var notchExpanded = false
    var lastAgentReply: String?
    var hotKeyRegistered = true

    func showMainWindow(section: Section) {
        self.section = section
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
```
y en `listen()`, en el caso `type == "text"`: `lastAgentReply = text` además de añadir el mensaje.

- [ ] **Step 5: Arranque** — en `FrontbotApp`, añadir `@State private var notch: NotchController?` y en la vista raíz `.task { if notch == nil, let model { let c = NotchController(model: model); c.show(); HotKey.shared.register { c.toggle() }; model.hotKeyRegistered = HotKey.shared.registered; notch = c } }` (en el `RootView(model: model)`).

En `SettingsView`, al final:
```swift
            Divider()
            Text(model.hotKeyRegistered ? "Atajo global: ⌥Espacio abre Frontbot en el notch." : "⌥Espacio está ocupado por otra app. Abre el panel haciendo clic en el notch.")
                .font(.caption).foregroundStyle(model.hotKeyRegistered ? Color.secondary : Color.orange)
```

- [ ] **Step 6: Compilar y suite** — `swift build` sin errores ni avisos nuevos; suite verde.

- [ ] **Step 7: Commit** — `git add app && git commit -m "feat: add notch panel with quick prompt and global Option-Space shortcut"`

---

### Task 6: Empaquetado `Frontbot.app` y `--self-check`

**Files:**
- Create: `scripts/build-app.sh`
- Modify: `app/Sources/FrontbotApp/FrontbotApp.swift` (`--self-check`), `.gitignore` (`build/`)

**Interfaces:**
- `scripts/build-app.sh` produce `build/Frontbot.app`:
  - `Contents/MacOS/Frontbot` (binario `swift build -c release --product FrontbotApp`)
  - `Contents/Info.plist` (id `app.frontbot.Frontbot`, `CFBundleExecutable` `Frontbot`, `LSMinimumSystemVersion` `14.0`, `NSHighResolutionCapable`, versión `0.4.0`)
  - `Contents/Resources/node/bin/node` (copia de `$(which node)`)
  - `Contents/Resources/agent/{dist,node_modules,package.json}` (`npm run build` y `npm prune --omit=dev` sobre una copia, nunca sobre `agent/`)
  - Firma ad-hoc de todo el bundle.
- `Frontbot --self-check` imprime `node: OK (<versión>)` y `agente: OK (<ruta>)` o `agente: NO ENCONTRADO`, y sale con 0 si todo está, 1 si no; no abre ventanas.

- [ ] **Step 1: `--self-check` (test primero, como comando)**

Run: `cd app && swift build && .build/debug/FrontbotApp --self-check; echo exit=$?`
Expected (antes de implementar): la app intenta abrir la UI (no imprime nada útil) — matar con Ctrl-C si se queda abierta; esto confirma que la bandera aún no existe.

Implementar al principio de `FrontbotApp.init()`:
```swift
        if CommandLine.arguments.contains("--self-check") { SelfCheck.run() }
```
y al final del archivo:
```swift
import FrontbotCore

/// `Frontbot --self-check`: comprueba que el bundle trae Node y el sidecar, sin abrir la UI.
enum SelfCheck {
    static func run() -> Never {
        guard let loc = AgentLocator.locate(environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL) else {
            print("agente: NO ENCONTRADO — \(AgentLocator.notFoundMessage)")
            exit(1)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: loc.node)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        do { try p.run(); p.waitUntilExit() } catch { print("node: ERROR — \(error.localizedDescription)"); exit(1) }
        let version = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        print("node: OK (\(version))")
        print("agente: OK (\(loc.script))")
        exit(p.terminationStatus == 0 ? 0 : 1)
    }
}
```
(Si `FrontbotApp.swift` ya importa `FrontbotCore`, no repetir el import.)

Run: `cd app && swift build && .build/debug/FrontbotApp --self-check; echo exit=$?`
Expected: `agente: NO ENCONTRADO — …` y `exit=1` (sin variables y fuera del bundle). Con `FRONTBOT_NODE=$(which node) FRONTBOT_AGENT_SCRIPT=$(cd ../agent && pwd)/dist/main.js .build/debug/FrontbotApp --self-check` → `node: OK (v24…)`, `agente: OK (…)`, `exit=0`.

- [ ] **Step 2: `scripts/build-app.sh`**

```bash
#!/bin/bash
# Arma build/Frontbot.app: binario release + Node + sidecar, firmado ad-hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Frontbot.app"
NODE_BIN="${NODE_BIN:-$(command -v node)}"

echo "→ Compilando la app (release)"
swift build --package-path "$ROOT/app" -c release --product FrontbotApp
BIN="$(swift build --package-path "$ROOT/app" -c release --show-bin-path)/FrontbotApp"

echo "→ Compilando el sidecar"
(cd "$ROOT/agent" && npm run build >/dev/null)

echo "→ Armando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/node/bin" "$APP/Contents/Resources/agent"
cp "$BIN" "$APP/Contents/MacOS/Frontbot"
cp "$NODE_BIN" "$APP/Contents/Resources/node/bin/node"
cp -R "$ROOT/agent/dist" "$ROOT/agent/package.json" "$ROOT/agent/package-lock.json" "$ROOT/agent/node_modules" "$APP/Contents/Resources/agent/"
(cd "$APP/Contents/Resources/agent" && npm prune --omit=dev --no-audit --no-fund >/dev/null)
# Recursos que SwiftPM genera junto al binario (p. ej. el bundle de GRDB).
for b in "$(dirname "$BIN")"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Frontbot</string>
  <key>CFBundleDisplayName</key><string>Frontbot</string>
  <key>CFBundleIdentifier</key><string>app.frontbot.Frontbot</string>
  <key>CFBundleExecutable</key><string>Frontbot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "→ Firmando (ad-hoc)"
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "✓ $APP ($(du -sh "$APP" | cut -f1))"
```
`chmod +x scripts/build-app.sh`; añadir `build/` a `.gitignore`.

- [ ] **Step 3: Construir y verificar el bundle**

Run: `scripts/build-app.sh && build/Frontbot.app/Contents/MacOS/Frontbot --self-check; echo exit=$?`
Expected: `✓ …/build/Frontbot.app (…MB)`, luego `node: OK (v24…)`, `agente: OK (…/Frontbot.app/Contents/Resources/agent/dist/main.js)`, `exit=0` — **sin** variables de entorno.

Run: `codesign --verify --deep build/Frontbot.app && echo firmado`
Expected: `firmado`.

Run (bundle movido): `cp -R build/Frontbot.app "$TMPDIR/Frontbot.app" && "$TMPDIR/Frontbot.app/Contents/MacOS/Frontbot" --self-check; rm -rf "$TMPDIR/Frontbot.app"`
Expected: `agente: OK ($TMPDIR/Frontbot.app/…)`.

- [ ] **Step 4: Arranque de humo del bundle** — `FRONTBOT_FAKE_AGENT=1 build/Frontbot.app/Contents/MacOS/Frontbot &` durante 6 s; el proceso sigue vivo y no imprime errores; matarlo.

- [ ] **Step 5: Verificación manual**
- [ ] Doble clic en `build/Frontbot.app`: abre la ventana; aparece el indicador negro en el notch.
- [ ] ⌥Espacio abre el panel; escribir "hola" + Enter: aparece la respuesta del agente; Esc lo colapsa.
- [ ] Tareas: crear una para ayer → "Atrasadas" y aparece en el panel; marcarla hecha desde el panel.
- [ ] Ideas: tras pedir "busca oportunidades en…", la idea aparece con estrellas, fuentes y reporte.
- [ ] Ajustes muestra el estado del atajo.

- [ ] **Step 6: Commit** — `git add scripts .gitignore app && git commit -m "feat: package Frontbot.app with bundled node and agent, add --self-check"`

---

## Self-review

- **Cobertura del spec:** notch con prompt rápido, tareas de hoy y avisos (5.9 → Tasks 1, 2, 5); tareas del día (5.6 → Tasks 1, 4); ideas de negocio (5.7 → Tasks 1, 4); `.app` con Node incluido (3.1, 10 → Tasks 3, 6); macOS 14+ y Macs sin notch (10 → Task 2).
- **Atajo:** el spec no fija cuál; se elige ⌥Espacio y se informa si está ocupado.
- **Nombres consistentes:** `TaskGrouping.group`, `TodaySummary`, `NotchGeometry.panelFrame(in:expanded:)`, `AgentLocator.locate(environment:resources:exists:)`, `AppModel.showMainWindow(section:)`, `lastAgentReply`, `notchExpanded` iguales en todas las tareas.
- **Riesgo conocido:** `swift build -c release` de GRDB puede tardar varios minutos la primera vez.
