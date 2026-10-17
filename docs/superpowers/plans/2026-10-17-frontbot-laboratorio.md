# Laboratorio de aprendizaje: plan de implementación

> **Para agentes:** sub-skill obligatorio: superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans. Los pasos usan casillas (`- [ ]`).

**Objetivo:** cada agente tiene un laboratorio propio. Ahí estudia temas concretos en sesiones acotadas: anota con evidencia, ejecuta código sin aprobación en una sandbox sin red y usa datasets compartidos. Lo aprendido solo se convierte en un skill nuevo, o en una nueva versión de uno existente, cuando el usuario lo aprueba.

**Arquitectura:**

- **Core:** `FrontbotCore/Lab/` (modelos, store, scheduler puro, workspace, sandbox, datasets, herramientas `tool.lab_*`) y `FrontbotCore/Skills/SkillVersions.swift` (propuestas, instantáneas, revertir).
- **Cliente:** `AgentClient` lanza runs con `mode: "study"` y cierra la `labSession` al terminar.
- **Sidecar:** añade el modo `study`, con su lista cerrada de herramientas, subagentes Haiku/Sonnet y un medidor de tokens que corta la sesión.
- **App:** `LabController` (fuera de `AppModel`, que ya tiene 1000 líneas) se engancha al reloj de 60 s. La UI es una pestaña en la página del agente.

**Tecnología:** Swift 6 / SwiftUI / GRDB 7 (vendorizado), macOS 15; Node + `@anthropic-ai/claude-agent-sdk` 0.3.296, zod, vitest.

**Spec:** `docs/superpowers/specs/2026-10-17-frontbot-laboratorio-design.md`. Se lee junto con este plan; las secciones citadas como §N son de ahí.

## Restricciones globales

- **Dependencias:** ninguna nueva, ni Swift ni npm.
- **Copy de UI y errores de herramientas:** en español, con el tono de la app ("Quedó en borrador: …").
- **Límites por defecto** (`agentLabSettings`): `sessionTokenCap = 150000`, `dailyTokenCap = 500000`, `maxOpenTopics = 3`, `enabled = true`, `allowOpus = false`.
- **Métrica de tokens:** `input + cache_creation + output + 0.1 × cache_read`.
- **Sesión:**
  - aviso al 85 % del límite y corte al 100 %;
  - `maxTurns: 60` y 20 minutos de reloj;
  - 20 min entre sesiones `continue`;
  - backoff tras fallo: 20 min → 1 h → 4 h, y 3 fallos seguidos pasan el tema a `paused`;
  - no se lanza con menos de 20000 tokens restantes en el día;
  - límite de corte = mín(`sessionTokenCap`, lo que queda del día);
  - una sola sesión de laboratorio a la vez en toda la app.
- **Archivos del laboratorio:** 1 MB por archivo y 200 MB por agente.
- **Datasets:** 500 MB cada uno y 2 GB en total, solo https GET, inmutables.
- **Sandbox del laboratorio:** 5 min, sin red, salida de 20 KB.
- **Propuestas:** las mismas validaciones que `skills_create_draft` (20 archivos, 200 KB cada uno, nombre kebab-case).
- **Texto:** `question` hasta 300 caracteres, `why` hasta 1000 y el texto de `labEntry` hasta 4000.
- **El modo `study` nunca expone:** `trade_propose`, `account_state`, Chrome, `files_*`, `skills_run_script`, `skills_create_draft`, `skills_update_draft`, `schedule_*`, `agents_create_draft`, `notify_user`, `posts_create_draft`, `posts_update_draft`, `brands_write_guide`, `tasks_create`, `tasks_complete` ni `ideas_create`.
- **Commits:** convencionales, uno por tarea, terminados en `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Comandos:** tests de Swift con `swift test --package-path app --filter <Suite>`; sidecar con `cd agent && npx vitest run <archivo>` y `npm run typecheck`.

## Foco de revisión

1. **La app se cierra o se cuelga con una sesión `running`.** Al arrancar, esa sesión pasa a `cut` (no cuenta como fallo) y el tema se puede volver a estudiar. Lo prueba la Tarea 1, con `failRunningLabSessions`.
2. **Rutas que escapan:** `../`, rutas absolutas, enlaces simbólicos dentro del workspace que apuntan fuera, o el prefijo `skill:` con un skill no asignado. Se rechazan con un mensaje claro. Lo prueba la Tarea 3.
3. **Descargas que fallan a medias:** una redirección a http, superar los 500 MB mientras se descarga, o un 404. Se aborta, se borra lo parcial y el dataset no queda registrado. Lo prueba la Tarea 4.
4. **El skill cambió entre que se propuso y se aprobó** (se borró, se desasignó del agente, o subió de versión por una edición del usuario). Aprobar falla con un mensaje y la propuesta sigue `pending`, para poder rechazarla. Lo prueba la Tarea 5.
5. **El cambio de día local** para el presupuesto. Una sesión de las 23:50 cuenta en el día en que empezó, y el presupuesto se libera a medianoche local. Lo prueba la Tarea 2.

---

### Tarea 1: Modelos, migración y `LabStore`

**Archivos:**
- Crear: `app/Sources/FrontbotCore/Lab/LabModels.swift`, `app/Sources/FrontbotCore/Lab/LabStore.swift`
- Modificar: `app/Sources/FrontbotCore/Store/AppDatabase.swift` (migración `v9-lab` al final del migrador), `app/Sources/FrontbotCore/Models/Records.swift` (`Skill.version`)
- Test: `app/Tests/FrontbotCoreTests/LabStoreTests.swift`

**Interfaces:**
- **Produce (en `LabModels.swift`):**
  - `enum LabTopicStatus: String, Codable, Sendable { case studying, paused, resolved, abandoned, graduated }`, con `var isOpen: Bool` (verdadero para studying y paused).
  - `enum LabOrigin: String { case agent, user }`.
  - `enum LabSessionStatus: String { case running, done, failed, cut }`.
  - `enum LabOutcome: String { case `continue`, pause, resolve, abandon }`.
  - `enum LabEntryKind: String { case hypothesis, test, result, conclusion, model_note, feedback, note }`.
  - `enum Evidence: String { case weak, medium, strong }`.
- **Registros GRDB** (`Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable`) con los campos de §6:
  - `LabTopic`, que añade `consecutiveFailures: Int` y `pausedReason: String?`;
  - `LabSession`, con `models: [LabModelUsage]` y `struct LabModelUsage: Codable { model: String; tokens: Int }`;
  - `LabEntry` (`id: Int64?`, `MutablePersistableRecord`), con `sources: [String]`;
  - `SkillProposal`, con `files: [String: String]`;
  - `SkillVersion`;
  - `AgentLabSettings`, con `static func defaults(agentId:)`.
- `Skill` gana `public var version: Int`. La migración le pone `defaults(to: 1)`.
- **Produce (en `LabStore.swift`, `extension AppDatabase`):**
  - `openTopic(agentId:question:why:origin:now:) throws -> LabTopic` valida longitudes y `maxOpenTopics`. Error: "Ya tienes 3 temas abiertos: pausa o abandona uno antes de abrir otro." Deja `nextSessionAfter = now`.
  - `topics(agentId:) -> [LabTopic]` (los abiertos primero y después por `updatedAt` desc) y `topic(id:)`.
  - `setTopicStatus(id:_:reason:now:) throws -> LabTopic`. Al pasar a `studying` reinicia `consecutiveFailures`, deja `pausedReason = nil` y `nextSessionAfter = now`. Abrir por encima del límite falla con el mismo error.
  - `studyNow(topicId:now:)`.
  - `addEntry(topicId:sessionId:kind:text:evidence:sources:model:) throws -> LabEntry` y `entries(topicId:) -> [LabEntry]` (orden ascendente).
  - `startLabSession(topicId:now:) throws -> LabSession` y `attachAgentRun(labSessionId:agentRunId:)`.
  - `finishLabSession(id:status:outcome:summary:conclusion:tokens:models:now:) throws -> LabTopic`. Aplica las reglas de la Tarea 2 con `LabScheduler.apply`.
  - `failRunningLabSessions() throws -> Int`: las sesiones `running` pasan a `cut`, que no cuenta como fallo.
  - `labTokensUsed(agentId:from:to:) -> Int`: suma `tokens` de las sesiones con `startedAt` en [from, to).
  - `labTokensUsed(agentId:day:calendar:) -> Int`: lo mismo para ese día local. El uso del mes de la Tarea 10 llama a la primera con el mes local.
  - `labSettings(agentId:) -> AgentLabSettings` (defaults si no hay fila) y `saveLabSettings(_:)`.
  - `runningLabSession() -> LabSession?`.

- [ ] **Paso 1: tests que fallan**, en `LabStoreTests` con `AppDatabase.inMemory()` y un agente creado con `createAgent`:
  - `testOpenTopicRespectsMaxOpen`: tres `openTopic` OK; el cuarto lanza `ValidationError` con el mensaje de arriba; tras `setTopicStatus(.abandoned)` de uno, el cuarto entra.
  - `testQuestionLengthValidated`: una `question` de 301 caracteres lanza error; la de 300 entra.
  - `testEntriesInOrderWithEvidence`: `addEntry(kind: .conclusion, evidence: .medium, sources: ["https://x"])` se lee igual con `entries(topicId:)`.
  - `testFailRunningSessionsCutsWithoutFailure`: con una sesión `running`, `failRunningLabSessions() == 1`, la sesión queda `.cut` y `topic.consecutiveFailures == 0`.
  - `testTokensUsedByLocalDay`: sesiones con `startedAt` hoy 23:50 (40000) y mañana 00:10 (10000). `labTokensUsed(day: hoy) == 40000` y `labTokensUsed(day: mañana) == 10000`.
  - `testSkillVersionDefaultsToOne`: un skill creado con `SkillLibrary.createUserSkill` tiene `version == 1`.
  - `testDeletingAgentCascades`: `deleteAgent` borra sus temas, sesiones y entradas.
- [ ] **Paso 2:** `swift test --package-path app --filter LabStoreTests` falla porque no compila (faltan los tipos).
- [ ] **Paso 3: implementación.**
  - Migración `v9-lab`: las tablas de §6 más las columnas `consecutiveFailures`/`pausedReason` de `labTopic`.
  - Claves foráneas: `agentId → agent` con cascade; `topicId → labTopic` con cascade; `skillVersion.skillId → skill` con cascade.
  - Índices en `labTopic.agentId` y `labSession.topicId`.
  - `skill.version integer not null default 1`.
  - Los JSON (`models`, `sources`, `files`) se guardan como texto, igual que `Post.media`.
- [ ] **Paso 4:** `swift test --package-path app --filter LabStoreTests` pasa, y `swift test --package-path app` no rompe nada más.
- [ ] **Paso 5:** commit `feat(lab): lab data model and store`.

### Tarea 2: `LabScheduler` puro (qué sesión toca, presupuesto y backoff)

**Archivos:**
- Crear: `app/Sources/FrontbotCore/Lab/LabScheduler.swift`
- Test: `app/Tests/FrontbotCoreTests/LabSchedulerTests.swift`

**Interfaces:**
- **Consume:** los tipos de la Tarea 1.
- **Produce:**
  - `struct LabCandidate { topic: LabTopic; agent: Agent; settings: AgentLabSettings; usedToday: Int }`.
  - `enum LabScheduler`, con:
    - `static func next(candidates: [LabCandidate], sessionRunning: Bool, agentsInChat: Set<String>, now: Date) -> LabCandidate?`. Devuelve nil si `sessionRunning`. Si no, el `studying` más antiguo (`createdAt` asc) cuyo agente está `.active`, con `settings.enabled`, sin chat activo, `nextSessionAfter ≤ now` y `budget(...) != nil`.
    - `static func budget(settings: AgentLabSettings, usedToday: Int) -> Int?` = `min(sessionTokenCap, dailyTokenCap − usedToday)`, o nil si es menor que 20000.
    - `static func apply(finished status: LabSessionStatus, outcome: LabOutcome?, to topic: inout LabTopic, now: Date)`:
      - `done` + `continue` → espera 20 min y fallos a 0;
      - `done` + `pause` → `paused`;
      - `done` + `resolve` → `resolved`;
      - `done` + `abandon` → `abandoned`;
      - `cut` → espera 20 min, sin tocar fallos;
      - `failed` → fallos +1 y espera `[20 min, 1 h, 4 h][min(fallos−1, 2)]`; con 3 fallos, `paused` y `pausedReason = "Falló 3 veces seguidas"`.
    - `static let minimumBudget = 20_000` y `static let continueDelay: TimeInterval = 20 * 60`.

- [ ] **Paso 1: tests que fallan.**
  - `testPicksOldestStudyingWithBudget`: dos temas `studying` del mismo agente; devuelve el de `createdAt` menor.
  - `testSkipsWhenSessionRunning`: `next(..., sessionRunning: true)` devuelve nil.
  - `testSkipsAgentInChatOrInactiveOrDisabled`: tres casos, todos dan nil.
  - `testBudgetIsMinOfSessionAndDailyRemaining`: `budget(defaults, usedToday: 0) == 150000`, `budget(defaults, usedToday: 400000) == 100000`, `budget(defaults, usedToday: 485000) == nil`.
  - `testContinueWaitsTwentyMinutes`: `apply(.done, .continue)` deja `nextSessionAfter == now + 1200`.
  - `testFailureBackoffAndAutoPause`: tres `apply(.failed, nil)` seguidos dan esperas de 1200, 3600 y luego `status == .paused` con `pausedReason`.
  - `testDoneResetsFailures`: tras un fallo, `apply(.done, .continue)` deja `consecutiveFailures == 0`.
  - `testCutDoesNotCountAsFailure`.
- [ ] **Paso 2:** `swift test --package-path app --filter LabSchedulerTests` falla.
- [ ] **Paso 3:** implementar como arriba. `LabStore.finishLabSession` (Tarea 1) llama a `apply`.
- [ ] **Paso 4:** pasa `LabSchedulerTests` y también `LabStoreTests`.
- [ ] **Paso 5:** commit `feat(lab): pure scheduler with budget and backoff`.

### Tarea 3: espacio de trabajo y `LabSandbox`

**Archivos:**
- Crear: `app/Sources/FrontbotCore/Lab/LabWorkspace.swift`, `app/Sources/FrontbotCore/Lab/LabSandbox.swift`
- Modificar:
  - `app/Sources/FrontbotCore/Store/AppPaths.swift`: añadir `labsDir`, `labDir(agentId)`, `labTopicDir(agentId, topicId)`, `labSharedDir(agentId)`, `datasetsDir`, `datasetDir(name)`, `skillVersionsDir(name)` (= `skills/.versions/<name>`) y `labVenvPython` (= `labs/.venv/bin/python3`).
  - `app/Sources/FrontbotCore/Skills/ScriptSandbox.swift`: generalizar `profile` y `run`.
- Test: `app/Tests/FrontbotCoreTests/LabWorkspaceTests.swift`, `app/Tests/FrontbotCoreTests/LabSandboxTests.swift` (copiar el estilo de `ScriptSandboxTests`)

**Interfaces:**
- **`ScriptSandbox`:**
  - `static func profile(readDirs: [String], writeDirs: [String], tmpDir: String, home: String, interpreterDir: String) -> String`. La versión actual de un solo `skillDir` pasa a ser un caso particular, sin cambio de comportamiento.
  - `func run(script: String, args: [String], in workDir: URL, readDirs: [URL], writeDirs: [URL], interpreter: String? = nil) throws -> Result`.
  - `run(script:args:in:)` sigue existiendo y delega en la nueva.
- **`LabWorkspace(paths: AppPaths, db: AppDatabase, agentId: String, topicId: String?)`:**
  - `func write(_ path: String, content: String) throws`. Solo en `topics/<topicId>/…`, o en `shared/…` con el prefijo `shared/`. Valida 1 MB por archivo y 200 MB por agente.
  - `func read(_ path: String) throws -> (text: String, truncated: Bool)`. Lee el tema, `shared/`, `skill:<nombre>/…` (solo skills asignados al agente) y `dataset:<nombre>/…`. El tope es 512 KB, igual que `AgentFiles`.
  - `func list(_ dir: String?) throws -> [String]`.
  - `func resolve(_ path: String, forWriting: Bool) throws -> URL`. Rechaza rutas absolutas, `..`, `\` y enlaces cuya ruta real salga de su raíz. Error: "Ruta fuera de tu laboratorio: <path>."
- **`LabSandbox(paths:db:nodePath:timeout: 300)`:**
  - `func run(agentId: String, topicId: String, script: String, args: [String]) throws -> ScriptSandbox.Result`.
  - El script se resuelve con `LabWorkspace.resolve`, así que puede vivir en el tema, en `shared/` o en `skill:`.
  - Ejecuta con `workDir` = el tema y `readDirs` = [`labDir(agentId)`, `datasetsDir`, carpetas de los skills asignados].
  - `writeDirs` = [el tema, `shared/`].
  - Intérprete de `.py`: `paths.labVenvPython` si existe y es ejecutable; si no, `ScriptSandbox.pythonPath`.

- [ ] **Paso 1: tests que fallan.**
  - `LabWorkspaceTests`:
    - `testWriteAndReadInsideTopic`;
    - `testRejectsDotDotAbsoluteAndBackslash`: tres casos;
    - `testRejectsSymlinkEscaping`: un enlace `topics/t/out → /tmp`; tanto `read("out/x")` como `write` fallan;
    - `testSkillPrefixOnlyForAssignedSkills`: asignado se lee; no asignado da error;
    - `testPerFileAndPerAgentLimits`: el límite de agente se prueba con un `maxAgentBytes` inyectable, por ejemplo 1000.
  - `LabSandboxTests`:
    - `testScriptReadsDatasetAndWritesTopic`: un `.py` lee `../../../../datasets/d/a.csv` por ruta real y escribe `out.txt` en el tema;
    - `testCannotWriteOutsideTopicOrShared`: escribir en `datasets/` da exit ≠ 0;
    - `testNoNetwork`: un `.py` que abre un socket a 1.1.1.1:80 falla;
    - `testCannotReadOtherAgentsLab`.
  - `ScriptSandboxTests` existentes: siguen pasando sin cambios.
- [ ] **Paso 2:** `swift test --package-path app --filter "LabWorkspaceTests|LabSandboxTests|ScriptSandboxTests"` falla.
- [ ] **Paso 3:** implementar. En el perfil, el `deny file-read* home` va antes de los `allow` de `readDirs`, igual que hoy con `skillDir`.
- [ ] **Paso 4:** pasan las tres suites.
- [ ] **Paso 5:** commit `feat(lab): agent workspace and lab sandbox`.

### Tarea 4: datasets compartidos

**Archivos:**
- Crear: `app/Sources/FrontbotCore/Lab/Datasets.swift`
- Test: `app/Tests/FrontbotCoreTests/DatasetsTests.swift`

**Interfaces:**
- `protocol DatasetDownloader: Sendable { func download(_ url: URL, to file: URL, maxBytes: Int) async throws }`.
  - `URLSessionDatasetDownloader` es la implementación real: `URLSessionConfiguration.ephemeral`, sin cookies ni credenciales (`httpShouldSetCookies = false`, `urlCredentialStorage = nil`).
  - Un delegado rechaza redirecciones que no sean https.
  - Aborta si `Content-Length` o el acumulado superan `maxBytes`.
  - Exige HTTP 200.
- `struct DatasetMeta: Codable { name, description, files: [String], bytes: Int, sources: [String], fetchedByAgentId: String?, createdAt: Date }`.
- `struct Datasets(paths: AppPaths, downloader: DatasetDownloader)`:
  - `func list() throws -> [DatasetMeta]`.
  - `func fetch(name: String, urls: [String], description: String, agentId: String) async throws -> DatasetMeta`:
    - `name` en kebab-case de hasta 64 caracteres; error si ya existe: "Ya existe el dataset <name>: los datasets no se reescriben, usa otro nombre.";
    - solo https; de 1 a 50 URLs;
    - nombre de archivo = último componente de la URL, deduplicado;
    - descarga a `datasets/.tmp-<uuid>/` y renombra al final;
    - si algo falla, borra el temporal.
  - Límites: `maxDatasetBytes = 500_000_000` y `maxTotalBytes = 2_000_000_000`, el total contado antes y durante la descarga.
  - `func importFolder(_ source: URL, name: String, description: String) throws -> DatasetMeta`: copia y rechaza enlaces simbólicos. Lo usa el usuario, no el agente.
  - `func delete(name: String) throws`: lo usa solo el usuario.

- [ ] **Paso 1: tests que fallan**, con un `FakeDownloader` que escribe bytes o lanza error.
  - `testFetchWritesFilesAndMeta`.
  - `testRejectsExistingName`.
  - `testRejectsHttpUrl`.
  - `testFailedDownloadLeavesNothing`: la segunda URL falla, no existe `datasets/<name>` y no queda `.tmp-*`.
  - `testDatasetSizeLimit` y `testTotalSizeLimit`, con límites inyectables más pequeños.
  - `testImportFolderRejectsSymlinks`.
- [ ] **Paso 2:** `swift test --package-path app --filter DatasetsTests` falla.
- [ ] **Paso 3:** implementar. Los límites se pasan por `init` con los defaults de arriba.
- [ ] **Paso 4:** pasa.
- [ ] **Paso 5:** commit `feat(lab): shared immutable datasets`.

### Tarea 5: propuestas de graduación, versiones de skills y diff

**Archivos:**
- Crear: `app/Sources/FrontbotCore/Skills/SkillVersions.swift`, `app/Sources/FrontbotCore/Content/LineDiff.swift`
- Modificar: `app/Sources/FrontbotCore/Skills/SkillLibrary.swift` (`saveManifest` guarda una instantánea y sube `version`)
- Test: `app/Tests/FrontbotCoreTests/SkillVersionsTests.swift`, `app/Tests/FrontbotCoreTests/LineDiffTests.swift`

**Interfaces:**
- **`LineDiff`:**
  - `enum DiffLine: Equatable { case same(String), added(String), removed(String) }`;
  - `enum LineDiff { static func diff(old: String, new: String) -> [DiffLine] }`, por LCS de líneas.
- **`SkillVersions(library: SkillLibrary)`:**
  - `func snapshot(_ skill: Skill, proposalId: String?) throws -> SkillVersion`: copia la carpeta a `skillVersionsDir(name)/<version>/` e inserta la fila.
  - `func versions(skillId:) -> [SkillVersion]`.
  - `func propose(agentId:topicId:kind:skillName:description:body:files:evidenceSummary:) throws -> SkillProposal`:
    - valida como `write`, con `SkillManifest` y `validateFiles`;
    - `new`: falla si el nombre existe;
    - `update`: el skill debe existir y estar asignado al agente, y guarda `baseVersion = skill.version`;
    - pone el tema `resolved`.
  - `func proposalFiles(_ p: SkillProposal) -> [(path: String, old: String?, new: String)]`: compara con los archivos actuales, incluido `SKILL.md` renderizado.
  - `func approve(proposalId:) throws -> Skill`:
    - `new` crea el skill `active`, `source = .agent`, `createdByAgentId`, asignado al agente, con `version 1`;
    - `update` exige que el skill exista, esté asignado y `skill.version == baseVersion`. Si no: "El skill cambió desde que se propuso: recházala para que el agente vuelva a proponer." La propuesta sigue `pending`;
    - en `update`: `snapshot(actual)`, escribe la nueva versión (reemplaza `SKILL.md` y los `files`; los demás archivos no cambian) y hace `version += 1`;
    - en los dos casos, propuesta `approved` y tema `graduated`.
  - `func reject(proposalId:comment:) throws`: propuesta `rejected`; si hay comentario, entrada `feedback` (o `note` con "Rechazada sin comentario"); tema → `studying` vía `setTopicStatus`. Si el tema ya superó el límite de abiertos, queda `paused`.
  - `func revert(skillId:to number: Int) throws -> Skill`: guarda una instantánea de la versión actual, restaura la carpeta elegida y hace `version += 1`.
  - `func pendingProposals(agentId: String?) -> [SkillProposal]`.
- **`SkillLibrary.saveManifest`:** antes de escribir, llama a `SkillVersions(library: self).snapshot(skill, proposalId: nil)` y después sube `version`.

- [ ] **Paso 1: tests que fallan.**
  - `LineDiffTests`: `testDiffMarksAddedRemovedSame` (`"a\nb\nc"` → `"a\nx\nc"` da `[.same("a"), .removed("b"), .added("x"), .same("c")]`) y `testEmptyOld`.
  - `SkillVersionsTests`:
    - `testApproveNewCreatesActiveAssignedSkill`;
    - `testApproveUpdateSnapshotsAndBumpsVersion`: tras aprobar, `version == 2`, existe `.versions/<name>/1/SKILL.md` con el texto viejo y el tema está `graduated`;
    - `testUserEditBumpsVersionAndBlocksStaleProposal`: con una propuesta pendiente, `saveManifest` y luego `approve` lanza el error de "cambió" y la propuesta sigue `pending`;
    - `testApproveFailsIfSkillUnassignedOrDeleted`;
    - `testRejectAddsFeedbackAndReopens`;
    - `testRevertRestoresAndBumps`;
    - `testUpdateRequiresAssignedSkill`.
- [ ] **Paso 2:** `swift test --package-path app --filter "SkillVersionsTests|LineDiffTests"` falla.
- [ ] **Paso 3:** implementar.
- [ ] **Paso 4:** pasan, y también la suite completa (los tests existentes de `SkillLibrary`).
- [ ] **Paso 5:** commit `feat(skills): graduation proposals, versions and revert`.

### Tarea 6: herramientas `tool.lab_*` y runs de estudio en `AgentClient`

**Archivos:**
- Crear: `app/Sources/FrontbotCore/Lab/LabToolHandler.swift`, `app/Sources/FrontbotCore/Lab/StudyPrompt.swift`
- Modificar:
  - `app/Sources/FrontbotCore/Agent/ToolHandler.swift`: delega en `LabToolHandler` los métodos `tool.lab_*` síncronos.
  - `app/Sources/FrontbotCore/Agent/AgentClient.swift`.
- Test: `app/Tests/FrontbotCoreTests/LabToolHandlerTests.swift`, `app/Tests/FrontbotCoreTests/AgentClientStudyTests.swift` (estilo de `AgentClientTests` con `FRONTBOT_FAKE_AGENT`)

**Interfaces:**
- **Consume:** las Tareas 1, 3, 4 y 5.
- **`LabToolHandler(db:paths:)`** y su `func handle(method: String, params: JSONValue) throws -> JSONValue`, para:
  - `lab_open_topic`, `lab_list_topics`, `lab_resume_topic`, `lab_note`, `lab_read_notebook`;
  - `lab_write_file`, `lab_read_file`, `lab_list_files`, `lab_list_datasets`;
  - `lab_end_session`, `lab_propose_skill`.
- **Contexto:** todas reciben `agent_id`. Las de estudio reciben además `topic_id` y `session_id`, y validan que esa sesión esté `running`, sea del tema y que el tema sea del agente. Error: "Esta herramienta solo funciona dentro de una sesión de estudio."
- **`lab_end_session`** solo guarda `pendingOutcome`/`summary`/`conclusion` en la sesión (columnas `outcome`, `summary`; conclusión en `labTopic.conclusion`). El cierre real ocurre en `agent.done`. Con `resolve` sin `conclusion` da error.
- **`lab_read_notebook`** devuelve las entradas como JSON: `kind`, `text`, `evidence`, `sources`, `date`.
- **`StudyPrompt.payload(topic:entries:modelNotes:datasets:files:) -> JSONValue`:** últimas 30 entradas completas; de las anteriores, solo `conclusion` y `result`, recortadas a 300 caracteres; `model_notes` = las últimas 20 `model_note` del agente en todos sus temas.
- **`AgentClient`:**
  - `public struct StudyContext: Sendable { topic: LabTopic; session: LabSession; budgetTokens: Int; allowOpus: Bool }`.
  - `run(...)` gana `study: StudyContext? = nil`. Si está, el run lleva:
    - `params["mode"] = "study"`;
    - `params["study"] = { topic_id, session_id, question, why, budget_tokens, allow_opus, notebook: StudyPrompt.payload(...) }`;
    - el run cuenta como desatendido;
    - `trading` se envía igual, porque el sidecar decide qué usar.
  - `studyRuns: [String: String]` (runId → sessionId).
  - En `agent.done` de un run de estudio, antes de `broadcast(.finished)`:
    - llama a `db.finishLabSession(...)` con `status` = `cut` si `params["cut"] == true`, `done` si `ok` y `failed` si no;
    - el `outcome` es el guardado por `lab_end_session`; si no hay ninguno y fue `done`, se usa `continue`;
    - `tokens` = `params["lab_tokens"]` y `models` = `params["models"]`.
  - `fail(runId:)` hace lo mismo con `failed`.
  - `case .request(id, "tool.lab_run", …)` y `"tool.lab_fetch_dataset"` se atienden en un `Task`, como `skills_run_script`, pero sin aprobación. Se rechazan si el `run_id` no está en `studyRuns`.
  - `lab_run` devuelve `exit_code`, `stdout`, `stderr` y `timed_out`.
  - `lab_fetch_dataset` devuelve el `DatasetMeta` en JSON.

- [ ] **Paso 1: tests que fallan.**
  - `LabToolHandlerTests`:
    - `testOpenTopicFromChatNeedsNoSession`;
    - `testStudyToolsRequireRunningSession`: `lab_note` sin sesión, o con una sesión `done`, falla con el mensaje;
    - `testNoteAndReadNotebook`;
    - `testEndSessionResolveRequiresConclusion`;
    - `testProposeSkillMarksTopicResolved`;
    - `testWriteFileUsesTopicWorkspace`.
  - `AgentClientStudyTests` (FakeRunner, Tarea 8): `testStudyRunFinishesSessionWithTokensAndOutcome`. Un run con `StudyContext` cuyo fake llama a `lab_note` y `lab_end_session("pause")` deja la sesión `done`, los tokens que reporta el fake (1234) y el tema `paused`.
  - `testCrashDuringStudyMarksFailed`.
- [ ] **Paso 2:** `swift test --package-path app --filter "LabToolHandlerTests|AgentClientStudyTests"` falla.
- [ ] **Paso 3:** implementar. El `default` de `ToolHandler.handle` comprueba `method.hasPrefix("tool.lab_")` antes de "Herramienta desconocida".
- [ ] **Paso 4:** pasan. Esta tarea va después de la 8 (ver Orden), así que el FakeRunner de estudio ya existe.
- [ ] **Paso 5:** commit `feat(lab): lab tools and study runs in the agent client`.

### Tarea 7: sidecar, herramientas del laboratorio y lista cerrada del modo `study`

**Archivos:**
- Crear: `agent/src/lab.ts`
- Modificar:
  - `agent/src/tools.ts`: `ToolContext` gana `study?: { topicId: string; sessionId: string }`; `specsFor` añade el modo estudio y la inyección de ids.
  - `agent/src/trading.ts`: separar `buildMarketTools`.
  - `agent/src/runner.ts`: `RunParams.mode` admite `"study"` y añade `study?: RunStudy`; `toolContext` y `buildQueryOptions` (tools/allowedTools del modo).
- Test: `agent/test/lab.test.ts`

**Interfaces:**
- **`lab.ts`:**
  - `LAB_TOOL_SPECS` con las 13 herramientas de §9 y sus shapes zod:
    - `kind: z.enum([...7])`, `evidence: z.enum(["weak","medium","strong"]).optional()`, `sources: z.array(z.string()).optional()`;
    - `outcome: z.enum(["continue","pause","resolve","abandon"])`;
    - `kind` de la propuesta `z.enum(["new","update"])`;
    - `files: z.record(z.string(), z.string()).optional()`, `urls: z.array(z.string()).min(1).max(50)`.
  - Las descripciones explican el uso, por ejemplo que `lab_run` corre sin red desde el tema y que los datasets están en `dataset:<nombre>/…`.
  - `LAB_ANYWHERE = ["lab_open_topic","lab_list_topics","lab_resume_topic","lab_read_notebook","lab_list_datasets"]`.
  - `export type RunStudy = { topic_id; session_id; question; why; budget_tokens: number; allow_opus: boolean; notebook: unknown }`.
- **`tools.ts`:**
  - `specsFor(ctx)` con `ctx.study`: solo `brands_list`, `brands_get_guide`, `brands_list_assets`, `posts_list`, `tasks_list`, `skills_list`, `memory_list`, `memory_remember` y todas las `LAB_TOOL_SPECS`.
  - Fuera de estudio, las demás listas añaden `LAB_ANYWHERE`; con `memoryOnly`, no.
  - `buildTools` inyecta `topic_id` y `session_id` desde `ctx.study`.
  - `export const STUDY_TOOL_NAMES`: la lista exacta resultante, para el test.
- **`trading.ts`:**
  - `buildMarketTools(market: Market, network: Network)` devuelve `market_price`, `market_candles`, `market_funding` y `market_book`;
  - `buildTradingTools` la reutiliza más `account_state` y `trade_propose`;
  - en `study` con `params.trading`, el runner usa `buildMarketTools(market, "mainnet")`.
- **`buildQueryOptions` en `study`:**
  - `tools: ["WebSearch","WebFetch","Agent"]`; si el SDK 0.3.296 llama `Task` a la herramienta de subagentes, se verifica en `sdk-tools.d.ts`;
  - sin Chrome, sin plugin de skills y sin `Read`;
  - `allowedTools` = `STUDY_TOOL_NAMES` con prefijo `mcp__frontbot__`, más los de mercado si hay trading, más WebSearch, WebFetch y Agent.

- [ ] **Paso 1: tests que fallan** en `agent/test/lab.test.ts`.
  - `study mode exposes exactly the study tools`: `allowedToolsFor(toolContext({mode:"study", study:{…}, agent}))` es igual (ordenado) a la lista esperada escrita literal en el test.
  - `study mode never exposes money or publishing tools`: ninguno de los nombres de la sección Restricciones globales aparece en `allowedTools` ni en `buildQueryOptions(...).allowedTools`, ni siquiera con `browser: true`, `trading` y `folders`.
  - `study market tools read mainnet`: `buildMarketTools` con un `Market` falso registra `n === "mainnet"` aunque `trading.network` sea `"testnet"`.
  - `lab tools inject topic and session ids`: llamar a `lab_note` hace `call("tool.lab_note", {…, agent_id, topic_id, session_id})`.
  - `chat mode gets lab_open_topic but not lab_run`.
- [ ] **Paso 2:** `cd agent && npx vitest run test/lab.test.ts` falla.
- [ ] **Paso 3:** implementar.
- [ ] **Paso 4:** `npx vitest run` (todo el sidecar) y `npm run typecheck` pasan.
- [ ] **Paso 5:** commit `feat(agent): lab tools and closed tool list for study mode`.

### Tarea 8: sidecar, sesión de estudio (prompt, subagentes y medidor de tokens)

**Archivos:**
- Crear: `agent/src/study.ts`
- Modificar:
  - `agent/src/runner.ts`: `RealRunner.run` en modo study y `RunDone` gana `cut?: boolean; lab_tokens?: number; models?: { model: string; tokens: number }[]`; `FakeRunner` en modo study.
  - `agent/src/main.ts`, si serializa `RunDone` campo a campo: añadir los nuevos.
- Test: `agent/test/study.test.ts`

**Interfaces:**
- `countTokens(u: { input_tokens?; output_tokens?; cache_creation_input_tokens?; cache_read_input_tokens? }): number`, con la métrica de las restricciones globales, redondeada hacia abajo.
- `class TokenMeter`:
  - `constructor(budget: number)`;
  - `add(model: string, usage)`;
  - `get total`, `get warned` (≥ 85 %), `get exhausted` (≥ 100 %) y `byModel(): {model,tokens}[]`.
  - Solo cuenta mensajes `assistant` con `message.stop_reason !== null`, incluidos los de subagentes (`parent_tool_use_id` no nulo), porque los parciales no traen el uso final.
- `buildStudyPrompt(study: RunStudy, agent): string`:
  - la pregunta, el porqué, el cuaderno y las `model_note`;
  - las reglas de §8: nadie mira, anota mientras trabajas, evidencia en cada conclusión, termina con `lab_end_session`;
  - cuándo delegar en `ayudante` y `analista`;
  - "Nunca actúas sobre cuentas reales".
- `studyAgents(allowOpus: boolean)`: `ayudante` con `model: "haiku"`, `analista` con `model: "sonnet"` y, si `allowOpus`, `experto` con `model: "opus"`, descrito como "solo una consulta por sesión y solo si Sonnet ya falló".
  - Los subagentes tienen `tools` = WebSearch, WebFetch y `mcp__frontbot__lab_read_file`, `lab_list_files`, `lab_run`, `lab_note`, `lab_list_datasets`.
- **Opciones del run en `study`:**
  - `model: "claude-sonnet-5-5"` (el hilo principal siempre en Sonnet, §8), `agents: studyAgents(...)`, `forwardSubagentText: true`, `maxTurns: 60`;
  - hook `PostToolUse`: si `meter.warned` y aún no avisó, devuelve `hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: "Te queda poco presupuesto de tokens en esta sesión: anota lo que tengas y llama a lab_end_session." }`;
  - si `meter.exhausted`, o pasan 20 min (`setTimeout`), `abortController.abort()` y se devuelve `{ ok: true, cut: true, summary: "Sesión cortada por límite" }` con `lab_tokens` y `models`. No pasa por `cancelled()`.
- **`FakeRunner` en `study`:**
  - llama `tool.lab_note` (kind `note`, texto "nota de prueba");
  - si `params.prompt` contiene "pausar", `tool.lab_end_session` con `pause`; si no, con `continue`;
  - devuelve `lab_tokens: 1234` y `models: [{model:"claude-haiku-4-5-20251001", tokens: 1234}]`.

- [ ] **Paso 1: tests que fallan.**
  - `countTokens weighs cache reads at 10%`: `{input:1000, output:500, cache_creation:200, cache_read:10000}` da `2700`.
  - `meter ignores partial messages and counts subagents`.
  - `meter warns at 85% and exhausts at 100%`, con presupuesto 1000.
  - `study prompt includes question, notebook and end-session rule`.
  - `study options use sonnet main thread and haiku/sonnet subagents`: `buildQueryOptions` en study da `model === "claude-sonnet-5-5"`, `agents.ayudante.model === "haiku"` y ningún `experto` sin `allow_opus`.
  - `runner cuts the session when budget is exhausted`: con `query` inyectable (exponer `RealRunner` con una fábrica de query para tests) que emite mensajes de 600 + 600 tokens y presupuesto 1000, el resultado tiene `cut === true` y `lab_tokens === 1200`.
- [ ] **Paso 2:** `cd agent && npx vitest run test/study.test.ts` falla.
- [ ] **Paso 3:** implementar.
- [ ] **Paso 4:** `npx vitest run` y `npm run typecheck` pasan. Después, `swift test --package-path app --filter AgentClientStudyTests` pasa (necesita `cd agent && npm run build` si los tests de Swift usan `dist/`; comprobarlo en `AgentClientTests`).
- [ ] **Paso 5:** commit `feat(agent): study sessions with model routing and token budget`.

### Tarea 9: prompts y plantilla

**Archivos:**
- Modificar: `agent/src/prompt.ts` (reglas comunes), `app/Sources/FrontbotCore/Agent/AgentTemplate.swift` (instrucciones de `crypto-trader`)
- Test: `agent/test/prompt.test.ts`, `app/Tests/FrontbotCoreTests/` (el test de la plantilla, si existe; si no, una aserción en `AgentStoreTests`)

**Interfaces:** ninguna nueva.

**Copy fijado:**
- Regla común nueva:
  `"- Tienes un laboratorio propio. Cuando detectes algo concreto que te convenga aprender o mejorar (algo que te salió mal, una duda que se repite, una forma mejor de hacer tu trabajo), ábrelo con lab_open_topic: lo estudiarás en sesiones aparte. Aprende con evidencia, no con opiniones."`
- La regla de `skills_create_draft` pasa a:
  `"- Si el usuario te pide guardar un procedimiento como skill, usa skills_create_draft (queda en borrador). Lo que aprendas por tu cuenta se gradúa desde el laboratorio, no con skills_create_draft."`
- En la plantilla Crypto Trader, la frase "Cuando una estrategia funcione… guárdala como skill" se reemplaza por:
  `"Investiga y prueba tus estrategias en tu laboratorio (backtests con lab_run sobre datasets). Cuando tengas evidencia sólida, propón graduarla como skill con lab_propose_skill."`

- [ ] **Paso 1: tests que fallan.**
  - `system prompt mentions the lab`: `buildSystemPrompt({today})` contiene `"lab_open_topic"`.
  - El test de Swift: las instrucciones de la plantilla contienen `"lab_propose_skill"` y no contienen `"guárdala como skill"`.
- [ ] **Paso 2:** ejecutarlos; fallan.
- [ ] **Paso 3:** cambiar el copy.
- [ ] **Paso 4:** `npx vitest run test/prompt.test.ts` y el filtro de Swift pasan. Ajustar las aserciones existentes de prompt que citen el texto viejo.
- [ ] **Paso 5:** commit `feat(lab): agents learn about their lab in the prompt`.

### Tarea 10: `LabController` en la app (reloj, avisos y notch)

**Archivos:**
- Crear: `app/Sources/FrontbotApp/LabController.swift`
- Modificar:
  - `app/Sources/FrontbotApp/AppModel.swift`:
    - propiedad `let lab: LabController`;
    - en `init`, `try db.failRunningLabSessions()`;
    - en `tickScheduler()`, `lab.tick()`;
    - en `listen()`, `if lab.handle(update) { continue }` después de `handleScheduled`;
    - `var agentsInChat: Set<String>`, a partir de `activeRun?.agentId`.
  - `app/Sources/FrontbotApp/Notch/NotchView.swift`: la línea de "estudiando".

**Interfaces:**
- **Consume:** `LabScheduler.next`, `LabStore`, `AgentClient.run(study:)`, `SkillVersions`, `Datasets`.
- **Produce** (`@MainActor @Observable final class LabController`):
  - `init(db:paths:client:workspaceId:model: AppModel)`, con referencia débil a model para avisos y agentes;
  - `var runningSession: (session: LabSession, topic: LabTopic, agent: Agent)?`;
  - `func tick()`;
  - `func handle(_ update: AgentUpdate) -> Bool`: true si es un run de estudio; al terminar, recarga y lanza el aviso de propuesta nueva;
  - `func topics(agentId:) -> [LabTopic]`, `func entries(topicId:) -> [LabEntry]`, `func sessions(topicId:) -> [LabSession]`;
  - `func openTopic(agentId:question:why:)`, `func studyNow(_:)`, `func pause(_:)`, `func resume(_:)`, `func abandon(_:)`;
  - `func pendingProposals(agentId:) -> [SkillProposal]`, `func approve(_:)`, `func reject(_:comment:)`;
  - `func usage(agentId:) -> (today: Int, month: Int)`;
  - `func settings(agentId:)` y `func save(_ settings:)`;
  - `func cancelRunning()`;
  - `var datasets: [DatasetMeta]`, `func importDataset(folder:name:description:)`, `func deleteDataset(_:)`.
- **Reglas:**
  - `tick()` arma `LabCandidate`s para los temas `studying` de agentes activos y llama a `LabScheduler.next`. Si hay candidato:
    1. `startLabSession`;
    2. `client.run(prompt: topic.question, agent:, brand: nil, model: "claude-sonnet-5-5", study: …)`;
    3. `attachAgentRun`.
  - Si el run no llega a lanzarse, se cierra la sesión como `failed`.
  - Corte de reloj de 25 min como red de seguridad: `client.cancel`.
  - **Aviso de propuesta:** `"<agente> quiere graduar «<skill>»"`, con el `evidenceSummary` recortado a 200 caracteres. Al tocarlo se abre la página del agente en la pestaña Laboratorio, con `userInfo["agentLab"] = agentId` manejado en `NotificationRouter`.
  - **Notch:** si hay `runningSession`, muestra `"<agente> estudiando: <question>"` recortado a 60 caracteres.

- [ ] **Paso 1:** la lógica que se puede probar ya está en Core (Tareas 1, 2 y 6). Aquí no hay test unitario nuevo. Escribir la clase y conectarla.
- [ ] **Paso 2:** `swift build --package-path app` sin errores ni warnings nuevos en los archivos tocados.
- [ ] **Paso 3:** prueba manual con `FRONTBOT_FAKE_AGENT=1`:
  - lanzar la app compilada (`swift run --package-path app FrontbotApp` o `scripts/build-app.sh`);
  - abrir un tema desde la UI (Tarea 11) o temporalmente con un `lab.openTopic` en un botón de depuración;
  - comprobar que en ≤ 60 s la sesión corre, el cuaderno recibe "nota de prueba" y el tema vuelve a `studying` con `nextSessionAfter` +20 min.
- [ ] **Paso 4:** commit `feat(lab): lab controller wired to the app clock`.

### Tarea 11: UI, pestaña Laboratorio y cuaderno

**Archivos:**
- Crear: `app/Sources/FrontbotApp/Lab/LabTabView.swift`, `app/Sources/FrontbotApp/Lab/NotebookView.swift`
- Modificar: `app/Sources/FrontbotApp/AgentDetailView.swift`: `Picker` segmentado bajo el header, con `General | Laboratorio`. "General" es el contenido actual. El estado de la pestaña va en `AppModel.agentTab: [String: AgentTab]`, para que el aviso pueda abrir directamente Laboratorio.

**Interfaces:** consume `LabController` (Tarea 10).

**Contenido (maqueta A, §12):**
- **Cabecera:** `"hoy 212k / 500k tokens"` con una barra de `Theme.accent` y `"este mes 1,2M"`. Formato con `k`/`M` y una decimal.
- **"Listo para graduar":** una tarjeta por propuesta pendiente, con borde `Theme.accent`, nombre del skill, `new` ("skill nueva") o `update` ("mejora de <skill>"), las primeras 2 líneas de `evidenceSummary` y los botones "Revisar y aprobar" (abre la hoja de la Tarea 12) y "Ver cuaderno".
- **"Temas de estudio · N/3":** pregunta, píldora de estado (`estudiando` `Theme.inFlight`, `pausado` `Theme.muted`, con `pausedReason` si existe), "sesión N · X tokens" y la última `conclusion` o `result`.
  - Menú de acciones: Estudiar ahora, Pausar/Reanudar y Abandonar, este último con `confirmationDialog`.
  - Si el tema es el `runningSession`, píldora "estudiando ahora" y botón "Detener".
- **"Nuevo tema":** hoja con pregunta (≤ 300) y por qué. Se deshabilita con N = máximo y explica el motivo.
- **"Aprendido":** temas `resolved`/`graduated`, con su conclusión.
- **Ajustes plegables:** interruptor "Laboratorio activo", campos numéricos de los tres límites y "Permitir Opus".
- **`NotebookView`:**
  - entradas agrupadas por sesión: cabecera "Sesión N · fecha · modelos (haiku 40k, sonnet 90k) · estado";
  - cada entrada con la píldora de tipo, la de evidencia y el texto con `MarkdownView`;
  - `sources` como enlaces si son http(s); si no, en texto mono;
  - abajo, "Archivos del tema": lista con `LabWorkspace.list` y vista de solo lectura al tocar uno, con `CodeBlockView` para `.py`/`.js`/`.sh`/`.csv` recortado.

- [ ] **Paso 1:** construir las vistas. Pruebas del layout: `swift build --package-path app`.
- [ ] **Paso 2:** prueba manual con `FRONTBOT_FAKE_AGENT=1`:
  - crear un tema desde "Nuevo tema", ver cómo pasa a "estudiando ahora", abrir el cuaderno con la entrada de prueba;
  - pausar, reanudar y abandonar;
  - comprobar que con 3 temas "Nuevo tema" queda deshabilitado.
- [ ] **Paso 3:** commit `feat(lab): lab tab and notebook`.

### Tarea 12: UI, revisión de propuestas, historial de skills y Ajustes del laboratorio

**Archivos:**
- Crear: `app/Sources/FrontbotApp/Lab/ProposalReviewSheet.swift`, `app/Sources/FrontbotApp/Lab/LabSettingsSection.swift`
- Modificar: `app/Sources/FrontbotApp/SkillsView.swift` (sección "Historial"), `app/Sources/FrontbotApp/SettingsView.swift` (incluye `LabSettingsSection`)

**Interfaces:** consume `SkillVersions.proposalFiles`, `LineDiff.diff`, `SkillVersions.versions`/`revert` y `LabController.datasets`.

**Contenido:**
- **`ProposalReviewSheet`:**
  - título "Graduar «<skill>»";
  - `evidenceSummary` con `MarkdownView` y un enlace "Ver cuaderno";
  - por archivo, un desplegable con el diff de `LineDiff`: líneas `added` sobre `Theme.approved.opacity(0.12)` con prefijo `+`, `removed` sobre `Theme.danger.opacity(0.12)` con `-`, en mono 12;
  - para `new`, el contenido completo;
  - botones "Aprobar" (`AccentButtonStyle`), y "Rechazar" con un campo de comentario opcional;
  - si `approve` lanza el error de "cambió", lo muestra y deja solo "Rechazar".
- **Historial en `SkillsView`:** lista de versiones ("v3 · 17 oct · desde propuesta de Crypto Trader" o "edición tuya") con "Volver a esta versión" (`confirmationDialog`).
- **`LabSettingsSection`** (en Ajustes, título "Laboratorio"):
  - lista de datasets: nombre, tamaño, quién lo trajo, "Borrar" con confirmación;
  - "Añadir carpeta como dataset…", con `NSOpenPanel` y una hoja de nombre y descripción;
  - "Preparar entorno de Python":
    - ejecuta, fuera de la sandbox y a pedido del usuario, `ScriptSandbox.pythonPath -m venv <labs/.venv>` y después `<venv>/bin/pip install numpy pandas`;
    - muestra el progreso y el resultado;
    - si ya existe, "Entorno listo (numpy, pandas)" con un botón "Reinstalar".
    - La ejecución vive en un `LabPythonEnv` pequeño dentro del mismo archivo, con un `Process` y el log en texto.

- [ ] **Paso 1:** construir las vistas; `swift build --package-path app` sin errores.
- [ ] **Paso 2:** prueba manual:
  - con `FRONTBOT_FAKE_AGENT=1`, crear desde un test de depuración o desde la consola de la app (`lab_propose_skill` vía `LabToolHandler` con una sesión falsa) una propuesta `update` sobre un skill asignado;
  - revisar el diff, aprobar y ver la v2 en el historial;
  - "Volver a esta versión" restaura;
  - rechazar otra propuesta con un comentario: aparece como `feedback` en el cuaderno.
- [ ] **Paso 3:** prueba manual de datasets:
  - importar `data/data/4h` como `btc-4h-binance`;
  - aparece en la lista con su tamaño;
  - en una sesión real (sin `FAKE`) el agente lo ve en `lab_list_datasets`.
- [ ] **Paso 4:** `swift test --package-path app`, `cd agent && npx vitest run && npm run typecheck`, y `scripts/build-app.sh`. Todo en verde y la app se empaqueta.
- [ ] **Paso 5:** commit `feat(lab): proposal review, skill history and lab settings`.

---

## Orden y dependencias

1 → 2 → 3 → 4 → 5 → 7 → 8 → 6 → 9 → 10 → 11 → 12.

La Tarea 6 va después de la 8 porque su test de punta a punta usa el `FakeRunner` de estudio. Las Tareas 3, 4 y 5 son independientes entre sí, una vez hecha la 1.
