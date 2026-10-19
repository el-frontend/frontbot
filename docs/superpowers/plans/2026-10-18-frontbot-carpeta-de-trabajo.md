# Carpeta de trabajo en el chat — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que en el chat se pueda elegir una carpeta de trabajo y que el agente trabaje ahí con las herramientas reales de Claude Code (Read, Write, Edit, Glob, Grep, Bash, TodoWrite), con carta blanca dentro y aprobación fuera.

**Architecture:**
- **Sidecar:**
  - recibe `workdir` en `agent.run`;
  - activa las herramientas integradas con `cwd` y la sandbox del SDK;
  - un hook `PreToolUse` decide con una función pura (`workdirDecision`) si permitir, denegar o preguntar a la app (`workdir.approve`).
- **App:**
  - guarda la carpeta y las carpetas de lectura en la conversación;
  - muestra un chip en el composer;
  - responde a las aprobaciones con una hoja y recuerda los "permitir en esta conversación" en memoria.

**Tech Stack:** Swift 6 / SwiftUI / GRDB 7 (app); Node + TypeScript + vitest + `@anthropic-ai/claude-agent-sdk` 0.3.296 (sidecar).

**Spec:** `docs/superpowers/specs/2026-10-18-frontbot-carpeta-de-trabajo-design.md`

## Global Constraints

- **Copia y comentarios:** la copia de UI va en español. Los comentarios siguen el estilo del código: en español, cortos, explican el porqué.
- **Plataforma:** macOS 15+, Swift 6 con concurrencia estricta. Los callbacks que lleguen de otros hilos van `@Sendable` (lección de `Dictation.swift`).
- **SDK:** `@anthropic-ai/claude-agent-sdk` 0.3.296 sin actualizar. `permissionMode: "dontAsk"`, `settingSources: []` y `persistSession: false` no cambian.
- **Dónde existe la carpeta de trabajo:** solo en runs de chat, con `mode` ausente o `"chat"`. En `scheduled`, `study` y `summarize` el sidecar ignora `workdir` aunque llegue.
- **Rutas siempre denegadas,** aunque caigan en una carpeta elegida: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/Library/Keychains`, `~/Library/Application Support/Frontbot`, `~/Library/Application Support/Google/Chrome`, y el perfil de Frontbot Chrome (ruta que ya usa el código del navegador).
- **Lectura permitida:** solo la carpeta de trabajo, `~/Downloads` (siempre, no se quita) y las carpetas de lectura extra de la conversación.
- **Escritura sin preguntar:** solo dentro de la carpeta de trabajo.
- **Red de los comandos:** lista de sitios (decisión del usuario 2026-10-19): `registry.npmjs.org`, `*.npmjs.org`, `github.com`, `*.github.com`, `*.githubusercontent.com`, `cdn.jsdelivr.net`, `unpkg.com`, `fonts.googleapis.com`, `fonts.gstatic.com` + los que el render de HyperFrames necesite (Tarea 3 los anota).
- **Sandbox de `Bash`:**
  - siempre activa: `enabled: true`, `failIfUnavailable: true`, `autoAllowBashIfSandboxed: true`, `allowUnsandboxedCommands: true`;
  - todo `Bash` con `dangerouslyDisableSandbox: true` pasa por aprobación (una vez / denegar, sin "en esta conversación").
- **`maxTurns`:** 150 con carpeta de trabajo; sin carpeta no cambia (30).
- **Publicar, wallets y trades:** sin vías nuevas.
- **Tests:** `cd agent && npm test`; `FRONTBOT_NODE=$(which node) swift test --package-path app`.

## Review Focus

1. **Enlace simbólico dentro de la carpeta que apunta fuera** (`work/docs → ~/Documents`): leer o escribir a través de él se trata como fuera → test en Tarea 1.
2. **`Glob` con patrón absoluto fuera** (`pattern: "/Users/x/Documents/**"`) o `Grep` con `path` fuera: se deniegan igual que `Read` → test en Tarea 1.
3. **Archivo nuevo en subcarpeta que aún no existe** dentro de la carpeta de trabajo (`work/out/a/b.html`): se permite sin preguntar → test en Tarea 1.
4. **"Detener" con la hoja de aprobación abierta:** la hoja se cierra, la respuesta es denegar y el chat no queda colgado → test en Tarea 4 (cliente) y paso manual en Tarea 6.
5. **La carpeta de la conversación ya no existe en disco** al enviar un mensaje: no se lanza el run y el chat muestra "La carpeta … ya no existe: elige otra o quítala." → test en Tarea 4.

---

### Tarea 1: Guardián de la carpeta (sidecar, función pura)

**Files:**
- Create: `agent/src/workdir.ts`
- Test: `agent/test/workdir.test.ts`

**Interfaces:**
- Produces:
  - `export type RunWorkdir = { path: string; read_dirs: string[] }`: rutas reales. `read_dirs` incluye `~/Downloads` resuelto; la app lo pone.
  - `export type WorkdirAsk = { kind: "write"; tool: "Write" | "Edit"; path: string; content?: string; old_string?: string; new_string?: string } | { kind: "unsandboxed"; command: string }`
  - `export type WorkdirDecision = { kind: "allow" } | { kind: "deny"; reason: string } | { kind: "ask"; ask: WorkdirAsk }`
  - `export function workdirDecision(tool: string, input: Record<string, unknown>, wd: RunWorkdir, home?: string): WorkdirDecision`
  - `export function alwaysDenied(home: string): string[]`: las rutas de Global Constraints, expandidas.
  - `export function sandboxSettings(wd: RunWorkdir, home: string, toolPaths: string[]): SandboxSettings`: `SandboxSettings` importado del SDK.
  - `export function validateWorkdir(wd: RunWorkdir, home?: string): string | null`: devuelve el mensaje de error, o `null` si es válida.
  - `export const WORKDIR_TOOLS = ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "TodoWrite"]`

- [ ] **Paso 1: tests que fallan.** Crea `agent/test/workdir.test.ts`.
  - Usa una carpeta temporal real (`mkdtempSync`) como `home` falso, con `work/`, `Downloads/`, `Documents/secret.txt`, `.ssh/id` y el enlace `work/docs → ../Documents`. Así `realpath` funciona de verdad.
  - Casos (todos con `wd = { path: <home>/work, read_dirs: [<home>/Downloads] }`):
    - `Read {file_path: <work>/a.txt}` → `allow`.
    - `Read {file_path: <home>/Downloads/x.mp4}` → `allow`.
    - `Read {file_path: <home>/Documents/secret.txt}` → `deny`, y `reason` contiene "carpeta de lectura".
    - `Read {file_path: <work>/docs/secret.txt}` (vía enlace) → `deny`.
    - `Read {file_path: <home>/.ssh/id}` con `read_dirs` que incluya `<home>` → `deny` (siempre denegado gana).
    - `Glob {pattern: "**/*.html"}` sin `path` → `allow`.
    - `Glob {pattern: "<home>/Documents/**"}` → `deny`.
    - `Grep {pattern: "x", path: <home>/Documents}` → `deny`.
    - `Write {file_path: <work>/out/a/b.html, content: "x"}` (subcarpetas inexistentes) → `allow`.
    - `Write {file_path: <home>/Downloads/a.txt, content: "hola"}` → `ask` con `{kind:"write", tool:"Write", path:<home>/Downloads/a.txt, content:"hola"}`.
    - `Edit {file_path: <home>/Documents/secret.txt, old_string:"a", new_string:"b"}` → `ask` con `old_string`/`new_string`.
    - `Write {file_path: <home>/.ssh/x}` → `deny` (nunca `ask`).
    - `Bash {command:"npm i"}` → `allow`.
    - `Bash {command:"npx hyperframes render", dangerouslyDisableSandbox:true}` → `ask` con `{kind:"unsandboxed", command:"npx hyperframes render"}`.
    - `Read {file_path: "relativo.txt"}` se resuelve contra `wd.path` → `allow`.
    - `mcp__frontbot__posts_list` → `allow` (no es asunto del guardián).
  - `validateWorkdir`:
    - `{path: home}` → mensaje (no `null`);
    - `{path: "/"}` → mensaje;
    - `{path: <home>/Library}` → mensaje, porque es ancestro de rutas denegadas;
    - ruta inexistente → mensaje;
    - `<home>/work` → `null`.
  - `sandboxSettings(wd, home, ["/opt/x"])`:
    - `filesystem.allowWrite` contiene `wd.path`;
    - `filesystem.denyRead` contiene `home`;
    - `filesystem.allowRead` contiene `wd.path`, cada `read_dirs` y `"/opt/x"`, y no contiene `home`;
    - `network` no tiene `allowedDomains`;
    - las cuatro banderas de Global Constraints.
- [ ] **Paso 2:** `cd agent && npx vitest run test/workdir.test.ts` → falla (el módulo no existe).
- [ ] **Paso 3: implementa `agent/src/workdir.ts`.**
  - **Resolución de rutas:** `~` → `home`; relativa → contra `wd.path`. Después, `realpath` del tramo existente más los componentes que faltan, como `AgentFiles.resolve`. El patrón de `Glob` se trata como ruta si es absoluto o empieza por `~`, cortándolo en el primer componente con comodín.
  - **"Dentro de":** igualdad, o prefijo + `sep`.
  - **`allowWrite`:** `wd.path`, `~/.npm`, `~/.cache`, `os.tmpdir()` real y `/private/tmp`.
  - **`allowRead`:** `wd.path`, `read_dirs`, `toolPaths`, `~/.npm`, `~/.npm-global`, `~/.nvm`, `~/.cache`, temporales.
  - **`denyRead`:** `[home, ...alwaysDenied(home)]`.
  - Comentario en el archivo: `allowRead` re-permite dentro de `denyRead`, y la Tarea 3 lo verifica de verdad.
- [ ] **Paso 4:** `npx vitest run test/workdir.test.ts` → pasa; `npm test` → todo verde.
- [ ] **Paso 5: commit.** `feat(agent): working-folder guard and sandbox settings`.

### Tarea 2: Runner con carpeta de trabajo (sidecar)

**Files:**
- Modify: `agent/src/runner.ts` (`RunParams`, `buildQueryOptions`, `RealRunner.run` y el `emit` de `tool_call`)
- Modify: `agent/src/prompt.ts` (`buildSystemPrompt`)
- Test: `agent/test/runner.test.ts`, `agent/test/prompt.test.ts`

**Interfaces:**
- Consumes: todo lo que produce la Tarea 1.
- Produces:
  - **`RunParams.workdir?: RunWorkdir`.**
  - **Llamada a la app:** `call("workdir.approve", { run_id, ...ask })`, que responde `{ allow: boolean }`.
  - **`tool_call` con contexto:** para las integradas, el texto del evento es `"<Tool> · <detalle>"`.
    - El detalle es `command` en `Bash`; `file_path` relativo a la carpeta en `Read`/`Write`/`Edit`; `pattern` en `Glob`/`Grep`; nada en `TodoWrite`.
    - Se corta a 120 caracteres.
  - **System prompt:** `buildSystemPrompt` acepta `workdir?: RunWorkdir`.

- [ ] **Paso 1: tests que fallan en `runner.test.ts`, sobre `buildQueryOptions`.**
  - **Chat con `workdir` válido:**
    - `options.cwd === wd.path`;
    - `tools` incluye `WORKDIR_TOOLS` más `WebSearch`/`WebFetch`;
    - `allowedTools` incluye `WORKDIR_TOOLS`;
    - `options.sandbox` es igual a `sandboxSettings(...)`;
    - `maxTurns === 150`;
    - hay un hook `PreToolUse` sin `matcher`, que cubre todas las herramientas.
  - **Mismo `workdir` con `mode: "scheduled"`, `"study"` y `"summarize"`:** sin `cwd`, sin `sandbox`, sin herramientas integradas y `maxTurns` como antes.
  - **`workdir` inválido** (`validateWorkdir` ≠ null): `RealRunner.run` devuelve `ok:false` con ese error sin llamar a `query`. Se prueba con `queryFn` falso.
  - **El hook:**
    - con `Read` fuera → `permissionDecision: "deny"` y el `reason` del guardián;
    - con `Write` en Downloads → llama a `call("workdir.approve", {run_id, kind:"write", tool:"Write", path, content})`;
    - si la app responde `{allow:false}` → `deny` con `"El usuario lo denegó; no insistas."`;
    - con `{allow:true}` → `{}`, se deja pasar;
    - si `call` lanza → `deny`.
  - **Con skills y `workdir`:**
    - `Read` de un archivo de skill fuera de la carpeta → permitido;
    - `Read` de `~/.ssh/x` → denegado aunque algún guardián lo permitiera.
- [ ] **Paso 2: test que falla en `prompt.test.ts`.** Con `workdir`, el prompt contiene la ruta de la carpeta, cada `read_dirs` y la frase "pídele al usuario que la añada como carpeta de lectura".
- [ ] **Paso 3: implementa.**
  - Sección del prompt, copia exacta:
    > `Carpeta de trabajo: ${path}. Dentro tienes carta blanca: lee, crea, edita, borra y ejecuta comandos sin pedir permiso. También puedes leer: ${read_dirs.join(", ")}. Fuera de eso no tienes acceso; si necesitas un archivo de otro sitio, pídele al usuario que la añada como carpeta de lectura o que lo copie a la carpeta. Escribir fuera de la carpeta de trabajo pide aprobación al usuario. Si un comando no funciona dentro de la sandbox, puedes pedir ejecutarlo sin ella (dangerouslyDisableSandbox) explicando por qué; el usuario lo aprueba o lo deniega.`
  - Los hooks de skills y de carpeta se combinan en un solo hook `PreToolUse` para `Read`: permite si lo permite cualquiera de los dos, salvo `alwaysDenied`, que gana siempre.
  - `toolPaths` para `sandboxSettings`:
    - el directorio de `process.execPath` (el Node de la app);
    - `/Applications/Google Chrome.app`;
    - `/Applications/Chromium.app`;
    - `/opt/homebrew`;
    - `/usr/local`.
- [ ] **Paso 4:** `npm test` → verde.
- [ ] **Paso 5: commit.** `feat(agent): chat runs with a working folder get Claude Code tools in the sandbox`.

### Tarea 3: Verificación real de la sandbox y del render de HyperFrames

Tarea de verificación, la hace el controlador o un subagente capaz. Gasta tokens reales en Haiku.

**Files:**
- Create: `agent/scripts/workdir-probe.ts`. Lanza `RealRunner` con `call` falso que aprueba todo y registra, modelo `claude-haiku-4-5-20251001`, y `workdir` sobre una carpeta temporal bajo `~/frontbot-probe-<fecha>` con `read_dirs: [~/Downloads]`.
- Modify, solo si la prueba lo exige: `agent/src/workdir.ts` (listas de `allowRead`/`allowWrite`/`toolPaths`).

- [ ] **Paso 1: comprobaciones con `Bash`.** Ejecuta el probe pidiéndole al agente que corra exactamente estos comandos y que informe la salida de cada uno:
  1. `echo ok > dentro.txt` → funciona.
  2. `echo x > ~/fuera-probe.txt` → falla.
  3. `cat ~/Documents/*` o `ls ~/Desktop` → falla.
  4. `ls ~/Downloads` → funciona.
  5. `curl -sI https://example.com | head -1` → `HTTP/... 200`.
  6. `npx -y hyperframes --version` → imprime una versión.
- [ ] **Paso 2: render de punta a punta.** Pide al agente un vídeo de 3 s con HyperFrames ("Hola Frontbot" sobre fondo negro), hecho y renderizado en la carpeta. Debe existir un `.mp4` > 0 bytes dentro de la carpeta.
  - Si el render falla por la sandbox:
    - ajusta `toolPaths`/`allowRead`/`allowWrite`, solo con rutas de herramientas o cachés y nunca con datos del usuario;
    - repite;
    - si aún falla, comprueba que el agente pide `dangerouslyDisableSandbox` y que el probe registra la petición `kind:"unsandboxed"`.
- [ ] **Paso 3: anotar.** Apunta en el ledger qué funcionó, qué rutas añadiste y por qué. Si `allowRead` no re-permite dentro de `denyRead`, elige lo más cercano que no dé más permiso, anótalo y actualiza los tests de la Tarea 1.
- [ ] **Paso 4:** borra la carpeta del probe; `npm test` → verde.
- [ ] **Paso 5: commit.** `chore(agent): workdir probe script and sandbox path fixes` (incluye el script).

### Tarea 4: Núcleo de la app — carpeta en la conversación, validación y aprobación

**Files:**
- Create: `app/Sources/FrontbotCore/Files/Workdir.swift`
- Modify:
  - `app/Sources/FrontbotCore/Models/Records.swift` (`Conversation`);
  - `app/Sources/FrontbotCore/Store/AppDatabase.swift` (migración `v11-workdir` y funciones);
  - `app/Sources/FrontbotCore/Agent/AgentClient.swift` (`run`, `workdir.approve`).
- Test: `app/Tests/FrontbotCoreTests/WorkdirTests.swift`

**Interfaces:**
- Produces:
  - **Modelo:** `Conversation.workdir: String?`, `Conversation.readDirs: [String]` (columna JSON `readDirs`, por defecto `[]`).
  - **`public enum Workdir`:**
    - `static func alwaysDenied(home: String) -> [String]`, con la misma lista que la Tarea 1;
    - `static func validated(_ path: String, home: String = NSHomeDirectory(), protected: [URL]) throws -> String`, que devuelve la ruta real;
    - `static func isBroad(_ path: String, home: String = NSHomeDirectory()) -> Bool`.
  - **`validated` lanza `ValidationError`** si la ruta:
    - no existe o no es carpeta: "… no es una carpeta.";
    - es `/` o `home`: "Elige una carpeta concreta, no toda tu carpeta personal.";
    - es ancestro o está dentro de una ruta siempre denegada o de `protected`: "Esa carpeta contiene datos protegidos (claves, llaveros o datos de Frontbot).".
  - **`isBroad`:** true para `~/Documents`, `~/Desktop`, `~/Downloads` y `~/Pictures` exactos.
  - **Base de datos:**
    - `AppDatabase.setWorkdir(conversationId: String, path: String?) throws`;
    - `AppDatabase.setReadDirs(conversationId: String, _ dirs: [String]) throws`.
  - **`AgentClient.run(..., workdir: Conversation? = nil)`:** si `workdir` es no nil, añade `params["workdir"] = {path, read_dirs: [realpath(~/Downloads)] + readDirs}`, sin duplicados.
    - Revalida con `Workdir.validated`; si falla, lanza `ValidationError("La carpeta \(path) ya no existe: elige otra o quítala.")` para "no existe", o el mensaje de `validated` para los demás.
    - No se envía si el run es `task`, `study` o `summarize`.
  - **`WorkdirApproval`:** `public struct WorkdirApproval: Equatable, Sendable { runId; kind: Kind (.write, .unsandboxed); tool: String?; path: String?; content: String?; oldString: String?; newString: String?; command: String? }`.
  - **Aprobador:** `AgentClient.setWorkdirApprover(_: @escaping @Sendable (WorkdirApproval) async -> Bool)`.
  - **Petición `workdir.approve`** (método RPC exacto, sin prefijo `tool.`): Si `run_id` no es un run activo y atendido → `{allow:false}`. Si lo es, llama al aprobador **sin plazo** y responde `{allow: Bool}`.
  - **`AgentClient.cancel(runId:)`:** además de lo que ya hace, emite `AgentUpdate.workdirApprovalCancelled(runId:)`, un caso nuevo, para que la app cierre la hoja.

- [ ] **Paso 1: tests que fallan en `WorkdirTests.swift`.** Usa una carpeta temporal como `home`.
  - `validated(home)` lanza.
  - `validated("/")` lanza.
  - `validated(home + "/Library")` lanza.
  - `validated(home + "/.ssh")` lanza.
  - `validated(<inexistente>)` lanza.
  - `validated(home + "/work")` devuelve la ruta real (sin enlaces).
  - `isBroad(home + "/Documents")` es true; `isBroad(home + "/Documents/proyecto")` es false.
  - Migración: una conversación nueva tiene `workdir == nil` y `readDirs == []`; después de `setWorkdir`/`setReadDirs` se releen iguales.
  - `AgentClient.run` con una conversación cuya carpeta se borró lanza el mensaje exacto "La carpeta … ya no existe: elige otra o quítala." y no deja el run en `running`. Sigue el patrón de tests existentes de `AgentClient` con sidecar falso.
  - `workdir.approve` de un run inexistente → `{allow:false}`, sin llamar al aprobador.
- [ ] **Paso 2:** `FRONTBOT_NODE=$(which node) swift test --package-path app --filter WorkdirTests` → falla.
- [ ] **Paso 3: implementa.** La migración `v11-workdir` añade `workdir TEXT` y `readDirs TEXT NOT NULL DEFAULT '[]'` a `conversation`.
- [ ] **Paso 4:** suite Swift completa → verde.
- [ ] **Paso 5: commit.** `feat(core): conversations keep a working folder; client sends it and relays approvals`.

### Tarea 5: UI — chip de carpeta, hoja de aprobación y envío

**Files:**
- Create: `app/Sources/FrontbotApp/WorkdirChip.swift`, `app/Sources/FrontbotApp/WorkdirApprovalSheet.swift`
- Modify:
  - `app/Sources/FrontbotApp/ChatView.swift` (barra del composer);
  - `app/Sources/FrontbotApp/AppModel.swift` (estado, envío, aprobación, cancelar);
  - `app/Sources/FrontbotApp/RootView.swift` (presentar la hoja).

**Interfaces:**
- Consumes: Tarea 4 (`Workdir`, `setWorkdir`, `setReadDirs`, `run(workdir:)`, `setWorkdirApprover`, `.workdirApprovalCancelled`).
- Produces:
  - **Estado de la conversación:** `AppModel.workdir: String?` y `AppModel.readDirs: [String]`, los de la conversación actual o los pendientes si aún no existe.
  - **Acciones:** `chooseWorkdir(_ url: URL)`, `clearWorkdir()`, `addReadDir(_ url: URL)`, `removeReadDir(_ path: String)`.
  - **Aprobaciones:** `pendingWorkdirApproval: WorkdirApproval?` y `answerWorkdir(_ choice: WorkdirChoice)`, con `enum WorkdirChoice { case once, conversation, deny }`.

- [ ] **Paso 1: estado en `AppModel`.**
  - Sin conversación, la carpeta elegida queda pendiente y `send` la guarda al crear la conversación.
  - Al abrir una conversación se cargan su `workdir`/`readDirs`; `newConversation` los vacía.
  - `chooseWorkdir`:
    - valida con `Workdir.validated(url.path, protected: [paths.root])` y muestra el error en `errorMessage` si falla;
    - si `Workdir.isBroad`, muestra este aviso, sin bloquear: "Vas a darle carta blanca sobre toda la carpeta X. Mejor una subcarpeta del proyecto.".
  - `addReadDir` valida igual y no permite `~/Downloads`, que ya está incluida.
- [ ] **Paso 2: enviar con carpeta.** `send` pasa la conversación con carpeta a `client.run(..., workdir:)`. El error de "ya no existe" se muestra en el chat como `.error` y no lanza el run. El notch usa el mismo `send` y hereda la carpeta, sin selector propio.
- [ ] **Paso 3: aprobación.**
  - Se conecta en el arranque junto a `setFileWriteApprover`.
  - Si la petición es `.write` y su `path` está en `workdirGrants[conversationId]` (memoria, `[String: Set<String>]`), responde `true` sin hoja.
  - Si no, encola. Se muestra una a la vez; si llega otra mientras hay una, espera su turno en la cola, no se deniega.
  - `.conversation` añade el `path` a los permisos de la conversación.
  - `.unsandboxed` nunca ofrece `.conversation`.
  - Al recibir `.workdirApprovalCancelled` o al pulsar "Detener", todas las pendientes de ese run se responden `false` y la hoja se cierra.
- [ ] **Paso 4: `WorkdirChip` en la barra del composer**, detrás del menú de modelo, con el estilo del chip de modelo.
  - Etiqueta: `folder` + "Carpeta", o el nombre de la carpeta, con la ruta completa en `.help`.
  - Menú:
    - "Elegir carpeta de trabajo…" (`NSOpenPanel`, solo directorios);
    - "Añadir carpeta de lectura…";
    - una sección "Lectura" con `~/Downloads` (sin quitar) y cada extra con "Quitar";
    - "Mostrar en Finder";
    - "Quitar carpeta".
  - Deshabilitado mientras `model.isRunningHere`.
- [ ] **Paso 5: `WorkdirApprovalSheet`**, con el estilo de la hoja de escritura de archivos existente.
  - **`.write`:** título "¿Escribir fuera de la carpeta?", la ruta, y el contenido. Para `Edit`, quitado/añadido con `LineDiff`, que ya existe.
    - Botones: "Denegar" (Esc), "Permitir en esta conversación", "Permitir una vez" (Return).
  - **`.unsandboxed`:** título "¿Ejecutar sin la protección de la carpeta?", el comando en monoespaciada y el aviso "Este comando podrá leer y escribir en todo tu Mac."
    - Botones: "Denegar" (Esc), "Permitir una vez".
- [ ] **Paso 6: verificar.** `swift build --package-path app`; suite Swift completa → verde.
- [ ] **Paso 7: commit.** `feat(chat): pick a working folder and approve actions outside it`.

### Tarea 6: Empaquetado y prueba manual

**Files:** ninguno nuevo (solo `scripts/build-app.sh` si hiciera falta).

- [ ] **Paso 1:** `scripts/build-app.sh` → `✓ …/Frontbot.app`.
- [ ] **Paso 2: lista de comprobación manual**, que hará el usuario y se le entrega en el resumen:
  1. Elegir carpeta en un chat nuevo: el chip muestra el nombre.
  2. Pedir "crea un vídeo de 5 s con HyperFrames que diga Hola" → aparece un `.mp4` en la carpeta.
  3. Pedir "lee ~/Documents/…" → se niega y pide añadirla como carpeta de lectura.
  4. Pedir "escribe una nota en ~/Downloads" → sale la hoja; "Permitir en esta conversación" → la segunda vez no pregunta.
  5. "Detener" con la hoja abierta → se cierra y el chat se libera.
  6. Reabrir la conversación → la carpeta sigue ahí.
- [ ] **Paso 3:** suites completas (`npm test`, `swift test`) → verde; commit si hubo cambios.
