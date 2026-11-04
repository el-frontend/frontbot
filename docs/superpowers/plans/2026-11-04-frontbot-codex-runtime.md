# Codex real (runtime app-server) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cuando el usuario conecta su sesión de ChatGPT, los agentes Codex corren sobre el `codex app-server` real con las mismas capacidades y límites que Claude. Con solo API key se usa el bucle actual.

**Architecture:**
- El sidecar gana un runner nuevo (`CodexAppRunner`) que lanza un `codex app-server` por run, con un `CODEX_HOME` propio de Frontbot.
- Le pasa las herramientas de Frontbot como `dynamicTools` y traduce el protocolo al contrato `agent.event`/`agent.done`.
- Chrome llega a través de `claude --claude-in-chrome-mcp`, detrás del `BrowserGuard`.
- La app decide `codex_runtime: "session" | "api"` y reemplaza los chequeos `provider == .codex` por capacidades.

**Tech Stack:** Node 24 + TypeScript + zod + vitest (sidecar); Swift 6 / SwiftUI + GRDB + XCTest (app).

**Spec:** `docs/superpowers/specs/2026-11-04-frontbot-codex-runtime-design.md`

## Global Constraints

- El bucle de API key (`agent/src/codex-runner.ts`) no cambia de comportamiento.
- Si el run con sesión falla, **no** se reintenta con la API key ni con Claude.
- Nunca se usa `~/.codex`. El `CODEX_HOME` es `<AppPaths.root>/codex-home`, con permisos 700, y se le pasa al sidecar en `FRONTBOT_CODEX_HOME`.
- Flags base de todo `app-server`:
  - `-c mcp_servers={}`
  - `-c cli_auth_credentials_store="file"`
  - `--disable` para cada una de: `plugins`, `apps`, `memories`, `browser_use`, `computer_use`, `multi_agent`, `image_generation`, `goals`, `sleep_tool`, `tool_suggest`
- Sin shell: `--disable shell_tool --disable unified_exec` y `environments: []`. Sin web ni shell: también `--disable code_mode_host`. Sin web: `-c tools.web_search=false`.
- `initialize` siempre con `capabilities: { experimentalApi: true, requestAttestation: false }`.
- Versión mínima de Codex: `0.158.0`. Si es menor, el run falla con "Actualiza Codex para usarlo en Frontbot."
- Una aprobación nunca se responde con `acceptForSession` ni con enmiendas de política. Solo `accept` (una vez) o `decline`.
- Ninguna herramienta nueva publica ni aprueba. El `BrowserGuard` no se modifica.
- Strings en español como claves, con su inglés en `app/Localization/en/{chat,core}.strings`.
- Tests sin red: un `app-server` falso y un MCP de Chrome falso (procesos Node por stdio).
- Comandos:
  - `cd agent && npm test`
  - `cd agent && npm run build` antes de los tests de Swift
  - `cd app && swift test < /dev/null`
  - `scripts/build-app.sh`

## Review Focus

1. **Codex no instalado o con versión vieja** → el run falla con un mensaje accionable, sin usar la API key (test en Task 5).
2. **La sesión caduca o se alcanza el límite de la suscripción a mitad del run** (`error` o turno fallido) → un solo `agent.done` con error legible (Task 5).
3. **El proceso de Codex muere o nunca manda `turn/completed`** → un solo `agent.done`; cancelar termina el run (Task 5).
4. **La extensión de Chrome no responde** → el puente devuelve `null` en ≤15 s, el run sigue sin herramientas de Chrome y métricas termina en `unavailable` (Tasks 4 y 5).
5. **Peticiones del servidor desconocidas o no previstas** (`item/permissions/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`) → se declinan o responden error, nunca se aceptan (Task 6).

---

### Task 1: Configuración de lanzamiento por modo (pura)

**Files:**
- Create: `agent/src/codex/launch.ts`
- Modify: `agent/src/runner.ts` (`RunParams.codex_runtime?: "session" | "api"`; `RunDone.runtime?: "session" | "api"`)
- Modify: `agent/src/workdir.ts` (exportar `workdirDomains(wd: RunWorkdir): string[]`, la lista de dominios que hoy calcula `sandboxSettings`, y `safeReadRoots` si no está exportada)
- Test: `agent/test/codex-launch.test.ts`

**Interfaces:**
- Produces:
  - `type CodexCaps = { web: boolean; shell: boolean; browser: boolean; skills: boolean }`
  - `codexCaps(params: RunParams): CodexCaps`. Usa las mismas reglas que `buildQueryOptions`:
    - `browser = (params.browser === true || metrics) && !summarize && !study && !image`
    - `web = !(summarize || image || metrics)`
    - `shell` = hay workdir y el modo es chat o undefined
    - `skills = !summarize && !study && !image && !metrics && (params.skills?.length ?? 0) > 0`
  - `codexArgs(caps: CodexCaps, profile?: { wd: RunWorkdir; home: string }): string[]`. Empieza por `"app-server"`.
  - `workdirProfileArgs(wd: RunWorkdir, home: string): string[]`. Las flags `-c` del perfil `frontbot`:
    - `default_permissions="frontbot"`
    - `permissions.frontbot.extends=":workspace"`
    - `permissions.frontbot.filesystem={...}`:
      - `home` → `"deny"`
      - cada ruta de `alwaysDenied(home)` → `"deny"`
      - `wd.path` → `"write"`
      - cada `read_dir` existente → `"read"`
      - `":slash_tmp"` y `":tmpdir"` → `"deny"`
    - `permissions.frontbot.network.enabled=true`
    - `permissions.frontbot.network.mode="limited"`
    - `permissions.frontbot.network.domains={<d>="allow"...}`
    - `features.network_proxy=true`
  - `codexThreadParams(input: { params: RunParams; caps: CodexCaps; instructions: string; tools: DynamicTool[]; cwd: string }): Record<string, unknown>`. Devuelve:
    - `{ model, cwd, ephemeral: true, developerInstructions: instructions, dynamicTools: tools }`
    - si hay shell: `approvalPolicy: "on-request"`, `permissions: "frontbot"`, sin `environments` ni `sandbox`;
    - si no: `approvalPolicy: "never"`, `sandbox: "read-only"`, `environments: []`.
  - `type DynamicTool = { type: "function"; name: string; description: string; inputSchema: Record<string, unknown> }`
  - `codexMaxToolCalls(params: RunParams): number`: summarize 6, study 60, chat con workdir 150, metrics 40, el resto 30.

- [ ] **Step 1: Write the failing tests** en `agent/test/codex-launch.test.ts`:
  - `chat sin carpeta apaga shell y deja web`: `codexArgs(codexCaps({...base}))` contiene `"--disable","shell_tool"` y `"--disable","unified_exec"`, no contiene `"code_mode_host"` ni `tools.web_search=false`, e incluye `"mcp_servers={}"`.
  - `imagen, resumen y métricas apagan web y code mode`: para cada modo, los args contienen `"tools.web_search=false"` y `"--disable","code_mode_host"`.
  - `métricas fuerza browser`: `codexCaps({...base, mode:"metrics"}).browser === true`. `codexCaps({...base, mode:"image", browser:true}).browser === false`.
  - `workdir solo en chat`: `codexCaps({...base, mode:"scheduled", workdir}).shell === false`.
  - `perfil de carpeta`: `workdirProfileArgs(wd, "/Users/u")` contiene `default_permissions="frontbot"`. La entrada del filesystem mapea `"/Users/u"` a `"deny"`, `wd.path` a `"write"`, `"/Users/u/.ssh"` a `"deny"`, `":slash_tmp"` a `"deny"` y `":tmpdir"` a `"deny"`. Los dominios son los de `workdirDomains(wd)`.
  - `thread sin shell`: `codexThreadParams(...)` tiene `environments: []`, `approvalPolicy: "never"` y no tiene `permissions`. Con shell tiene `permissions: "frontbot"`, `approvalPolicy: "on-request"` y no tiene `sandbox`.
  - `topes`: `codexMaxToolCalls` devuelve 6, 60, 150, 40 y 30 en los casos de arriba.
- [ ] **Step 2: Run** `cd agent && npx vitest run test/codex-launch.test.ts`. Expected: FAIL (módulo inexistente).
- [ ] **Step 3: Implement** `launch.ts` y los cambios de tipos o exportaciones. La tabla `filesystem` se serializa como tabla inline TOML: `{"<ruta>"="deny",...}`, con claves entre comillas dobles y `JSON.stringify` para escaparlas.
- [ ] **Step 4: Run** de nuevo. Expected: PASS. Corre también `npm test` completo.
- [ ] **Step 5: Commit** `feat(codex): launch flags, permission profile and thread params per mode`

### Task 2: Cliente JSON-RPC del app-server y servidor falso

**Files:**
- Create: `agent/src/codex/appServer.ts`
- Create: `agent/test/fixtures/fake-codex.mjs`
- Test: `agent/test/codex-app-server.test.ts`

**Interfaces:**
- Produces:
  - `type Spawn = { command: string; args: string[]; env: NodeJS.ProcessEnv; cwd: string }`
  - `class AppServer`:
    - `static start(spawn: Spawn): AppServer`. Hace `spawn` con stdio pipe, una línea JSON por mensaje y stderr descartado (nunca a stdout).
    - `initialize(): Promise<unknown>`. Manda `initialize` con `clientInfo { name: "frontbot", title: "Frontbot", version: "0.1.0" }` y `capabilities` de Global Constraints, y después la notificación `initialized`.
    - `request<T = unknown>(method: string, params: unknown, signal?: AbortSignal): Promise<T>`. Rechaza si el proceso sale o si llega `error`.
    - `onNotification(fn: (method: string, params: any) => void): void`
    - `onServerRequest(fn: (method: string, params: any) => Promise<{ result?: unknown; error?: { code: number; message: string } }>): void`. Sin handler, responde error `-32601`.
    - `readonly exited: Promise<{ code: number | null }>`
    - `kill(): void`. Es idempotente.
- Fixture `fake-codex.mjs`: un proceso Node que habla el protocolo. Su comportamiento depende del texto del primer `turn/start`:
  - `"hola"` → manda los deltas `"Ho"` y `"la"`, `thread/tokenUsage/updated` (input 10, cached 4, output 3) y `turn/completed`.
  - `"usa brands_list"` → manda la petición del servidor `item/tool/call {tool:"brands_list", arguments:{}, callId:"c1"}`, espera la respuesta, la repite como texto (`agentMessage/delta`) y completa.
  - `"usa desconocida"` → manda `item/tool/call` con una herramienta que no está en la lista.
  - `"shell"` → manda `item/commandExecution/requestApproval {command:"cat ~/.ssh/id_rsa"}` y repite la decisión.
  - `"permisos"` → manda `item/permissions/requestApproval` y repite la respuesta.
  - `"cuelga"` → no responde nada más.
  - `"muere"` → `process.exit(3)`.
  - `"falla"` → manda la notificación `error {message:"Your session expired"}` y después `turn/completed` con `status:"failed"`.
  - `"muchas"` → 50 `item/tool/call` seguidas.
  - `model/list` devuelve `{data:[{id:"gpt-6-astra"},{id:"gpt-6-sol"}]}`.
  - `account/read` devuelve la cuenta salvo con `FAKE_CODEX_NO_ACCOUNT=1`.
  - Registra cada `thread/start` recibido en el archivo `FAKE_CODEX_LOG`, si está definido, para que los tests inspeccionen los params.

- [ ] **Step 1: Write the failing tests:**
  - `request y respuesta`: `initialize()` resuelve y `request("model/list",{})` devuelve los dos ids.
  - `notificaciones en orden`: con "hola", `onNotification` recibe los deltas antes de `turn/completed`.
  - `petición del servidor`: el handler recibe `item/tool/call` y su `result` llega al fake, que lo repite.
  - `sin handler responde -32601`.
  - `salida del proceso rechaza lo pendiente`: con "muere", `request` pendiente rechaza y `exited` resuelve con code 3.
  - `kill es idempotente`.
- [ ] **Step 2: Run** `npx vitest run test/codex-app-server.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** `appServer.ts` y el fixture. Los tests lanzan `{ command: process.execPath, args: ["test/fixtures/fake-codex.mjs"] }`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(codex): app-server JSON-RPC client with fake server`

### Task 3: Localizar Codex, estado de la sesión, login y logout

**Files:**
- Create: `agent/src/codex/account.ts`
- Modify: `agent/src/main.ts` (handlers `codex.status`, `codex.login`, `codex.login_wait`, `codex.logout`)
- Test: `agent/test/codex-account.test.ts` y casos nuevos en `agent/test/main.test.ts`

**Interfaces:**
- Consumes: `AppServer`, `Spawn` (Task 2).
- Produces:
  - `CODEX_CANDIDATES = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]`
  - `locateCodex(env: NodeJS.ProcessEnv, exists: (p: string) => boolean = existsSync): string | null`. Primero mira `env.FRONTBOT_CODEX_BIN`, después los candidatos y por último cada directorio de `env.PATH` + `/codex`.
  - `MIN_CODEX_VERSION = "0.158.0"` y `codexVersionOk(output: string): boolean`. Parsea `codex-cli X.Y.Z[-pre]` y compara X.Y.Z numéricamente; un prerelease cuenta como su X.Y.Z.
  - `type CodexStatus = { installed: boolean; compatible: boolean; version: string | null; account: { email: string | null; plan: string | null } | null; models: string[] }`
  - `class CodexAccount`:
    - `constructor(opts: { bin: string | null; home: string; version?: () => Promise<string>; start?: (s: Spawn) => AppServer })`
    - `status(): Promise<CodexStatus>`. Sin bin devuelve `installed:false`. Con versión incompatible devuelve `compatible:false`, sin arrancar el servidor. Si no, `initialize` + `account/read {refreshToken:false}` y, si hay cuenta, `model/list`.
    - `login(): Promise<{ auth_url: string }>`. Hace `account/login/start {type:"chatgpt"}` y deja el proceso vivo.
    - `waitLogin(timeoutMs = 600_000): Promise<{ ok: boolean }>`. Resuelve con `account/login/completed`; si no, al expirar `timeoutMs`. Siempre mata el proceso del login.
    - `logout(): Promise<void>`. Hace `account/logout`.
    - Crea `home` con `mkdirSync(home, { recursive: true, mode: 0o700 })` antes de cada arranque.
    - Lanza `app-server` con `CODEX_HOME=home` y los args base de `codexArgs` (Task 1).
  - RPC en `main.ts`: `codex.status` → `CodexStatus`; `codex.login` → `{auth_url}`; `codex.login_wait` → `{ok}`; `codex.logout` → `{ok:true}`.
  - En modo fake (`FRONTBOT_FAKE_AGENT=1`), `status` devuelve `installed:true, compatible:true` y cuenta según `FRONTBOT_FAKE_CODEX_SESSION === "1"` (email `"fake@frontbot.test"`, plan `"pro"`), con `models: ["gpt-6-astra","gpt-6-sol"]`. `login` devuelve `https://auth.openai.com/fake`.

- [ ] **Step 1: Write the failing tests:**
  - `locateCodex prefiere FRONTBOT_CODEX_BIN`, `usa el primer candidato que existe` y `devuelve null sin candidatos`.
  - `codexVersionOk`:
    - `"codex-cli 0.158.0-alpha.2.1"` → true;
    - `"codex-cli 0.157.9"` → false;
    - `"codex-cli 1.0.0"` → true;
    - `"basura"` → false.
  - `status sin binario` → `{installed:false, compatible:false, version:null, account:null, models:[]}`.
  - `status con versión vieja` no arranca el servidor: `start` nunca se llama.
  - `status conectado` (fake) → la cuenta tiene email y los modelos son `["gpt-6-astra","gpt-6-sol"]`.
  - `status sin cuenta` (`FAKE_CODEX_NO_ACCOUNT=1`) → `account:null` y `models:[]`.
  - `home se crea con modo 700`.
  - En `main.test.ts`: `codex.status en modo fake refleja FRONTBOT_FAKE_CODEX_SESSION`.
- [ ] **Step 2: Run** `npx vitest run test/codex-account.test.ts test/main.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.** El fake de cuenta vive en `account.ts` como `FakeCodexAccount`, con la misma interfaz.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(codex): locate binary, session status, login and logout over RPC`

### Task 4: Puente de Chrome (Claude in Chrome MCP detrás del guardián)

**Files:**
- Create: `agent/src/codex/chromeBridge.ts`
- Create: `agent/test/fixtures/fake-chrome-mcp.mjs`
- Test: `agent/test/codex-chrome.test.ts`

**Interfaces:**
- Consumes: `BrowserGuard`, `BROWSER_ALLOWED_TOOLS` (`agent/src/browserGuard.ts`, sin cambios).
- Produces:
  - `claudeChromeCommand(env: NodeJS.ProcessEnv): { command: string; args: string[] }`. Usa `env.FRONTBOT_CLAUDE_BIN` o el binario `claude` del paquete `@anthropic-ai/claude-agent-sdk-darwin-arm64`, resuelto con `createRequire(import.meta.url).resolve(".../package.json")` + `claude`. Los args son `["--claude-in-chrome-mcp"]`.
  - `class ChromeBridge`:
    - `static start(cmd: { command: string; args: string[] }, timeoutMs = 15_000): Promise<ChromeBridge | null>`. Hace MCP `initialize`, la notificación `notifications/initialized` y `tools/list`. Devuelve `null` si algo falla o expira.
    - `readonly tools: DynamicTool[]`. Solo las de `BROWSER_ALLOWED_TOOLS` sin el prefijo `mcp__claude-in-chrome__`. `name` es el nombre corto (p. ej. `navigate`, `tabs_context_mcp`) y `inputSchema` viene de `tools/list`.
    - `call(name: string, args: Record<string, unknown>): Promise<{ success: boolean; text: string }>`:
      - aplica `guard.beforeTool("mcp__claude-in-chrome__" + name, args)`; si niega, devuelve `{success:false, text: reason}` sin reenviar;
      - si no, `tools/call` y después `guard.afterTool(...)` con el resultado;
      - `text` concatena los `content[].text`;
      - un nombre fuera de `tools` devuelve `{success:false, text:"Esta herramienta del navegador no está permitida en Frontbot."}`.
    - `close(): void`
    - Un `BrowserGuard` por instancia (una instancia por run).
- Fixture `fake-chrome-mcp.mjs`:
  - `tools/list` devuelve `navigate`, `computer`, `tabs_context_mcp`, `get_page_text`, `javascript_tool` y `file_upload`.
  - `tabs_context_mcp` devuelve texto con `https://www.linkedin.com/feed` si `FAKE_CHROME_SOCIAL=1`, y `https://example.com` si no.
  - El resto de llamadas repiten su nombre.
  - Con `FAKE_CHROME_HANG=1` no responde a `initialize`.

- [ ] **Step 1: Write the failing tests:**
  - `expone solo herramientas permitidas`: `tools.map(t=>t.name)` contiene `navigate`, `computer`, `tabs_context_mcp` y `get_page_text`, y no contiene `javascript_tool` ni `file_upload`.
  - `el guardián bloquea clic sin verificar`: `call("computer",{action:"left_click"})` → `success:false`, con el texto de "Antes de hacer clic o escribir".
  - `bloquea clic con red social abierta`: con `FAKE_CHROME_SOCIAL=1`, `tabs_context_mcp` y después `computer left_click` → `success:false` y el texto contiene "Hay una red social".
  - `scroll y screenshot pasan en redes`: `computer {action:"scroll"}` → `success:true`.
  - `navigate a esquema no web se niega`: `navigate {url:"file:///etc/passwd"}` → `success:false`.
  - `herramienta no listada se niega` (`javascript_tool`).
  - `start devuelve null si no responde`: con `FAKE_CHROME_HANG=1` y `timeoutMs` 300 → `null`.
- [ ] **Step 2: Run** `npx vitest run test/codex-chrome.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(codex): Claude in Chrome bridge behind BrowserGuard for Codex runs`

### Task 5: `CodexAppRunner` (núcleo) y enrutamiento por `codex_runtime`

**Files:**
- Create: `agent/src/codex-app-runner.ts`
- Modify: `agent/src/runner.ts`:
  - `ProviderRunner` gana un tercer argumento `codexApp?: Runner`;
  - `createProductionRunner` construye `CodexAppRunner({ bin: locateCodex(env), home: env.FRONTBOT_CODEX_HOME ?? "" })`;
  - `FakeRunner` responde también a `codex_runtime: "session"` y devuelve `runtime:"session"`.
- Modify: `agent/src/codex-runner.ts`: cada `RunDone` devuelve `runtime: "api"`, sin otro cambio.
- Modify: `agent/src/main.ts`: el contexto `frontbot` se arma para cualquier `provider === "codex"`, como ya hace.
- Test: `agent/test/codex-app-runner.test.ts` y casos nuevos en `agent/test/runner.test.ts`

**Interfaces:**
- Consumes: Tasks 1–4; `buildSystemPrompt`, `buildUserPrompt`, `buildSummaryPrompt`, `frontbotToolSpecs`, `toolContext` y `toolCallText`; `FrontbotRunContext.execute`.
- Produces:
  - `class CodexAppRunner implements Runner`:
    - `constructor(opts: { bin: string | null; home: string; version?: () => Promise<string>; start?: (s: Spawn) => AppServer; startChrome?: () => Promise<ChromeBridge | null>; call?: AppCall })`
    - `run(params, emit, signal, context): Promise<RunDone>`. Siempre devuelve `runtime: "session"` y `cost_usd: null`.
  - Rechazos antes de arrancar:
    - sin `bin` → error "Codex no está instalado. Instálalo o conecta solo la API key en Ajustes.";
    - con versión incompatible → error "Actualiza Codex para usarlo en Frontbot.";
    - sin `context.frontbot` → el mismo error que el `CodexRunner`.
  - Arranque:
    1. `cwd` es un `mkdtemp` vacío, o `params.workdir.path`.
    2. Se arranca con `CODEX_HOME=home` y env mínimo: `PATH`, `HOME`, `TMPDIR`, `USER`.
    3. `initialize`.
    4. `model/list`. Si `params.model` no está → error "Elige un modelo disponible en la ficha del agente."
    5. Chrome si `caps.browser` (con `startChrome`).
    6. `thread/start` con `codexThreadParams`. `instructions` = `buildSystemPrompt` con los mismos argumentos que usa `buildQueryOptions` de Claude para ese modo, con `browser: caps.browser && bridge !== null` y `web: caps.web`. `tools` = `frontbotToolSpecs(context.frontbot.context)` convertidas con `z.toJSONSchema(z.object(spec.shape))`, más `bridge.tools`.
    7. `turn/start` con el mismo `userPrompt(params)` de Claude, exportado desde `runner.ts`.
  - Eventos:
    - `status "pensando"` al empezar;
    - `item/agentMessage/delta` → `text`;
    - `item/started` con `dynamicToolCall` → `tool_call` con `toolCallText(tool)`;
    - `item/started` con `commandExecution` → `tool_call` `Bash · <command[0..120]>`;
    - `item/started` con `webSearch` (o el tipo que use la web) → `tool_call` `web`;
    - `summary` = el texto del último `agentMessage` completado;
    - tokens = el último `thread/tokenUsage/updated.total` (`inputTokens`, `outputTokens`).
  - `item/tool/call`:
    - una herramienta de Frontbot de la lista → `context.frontbot.execute(name, args)` → `{success:true, contentItems:[{type:"inputText", text: JSON.stringify(output)}]}`;
    - una herramienta de Chrome → `bridge.call`;
    - fuera de la lista → `{success:false, contentItems:[{type:"inputText", text:"La herramienta solicitada no está permitida."}]}`;
    - cada llamada (dinámica o comando) cuenta para `codexMaxToolCalls`. Al pasarse → `turn/interrupt`, kill y error "Codex alcanzó el límite de herramientas de este run."
  - Final:
    - `turn/completed` con status distinto de `completed`, o una notificación `error` → `ok:false` con el `message` de `error`, recortado a 1000 caracteres y con secretos tapados (`redactSecrets`);
    - el proceso sale antes de `turn/completed` → error "Codex se cerró inesperadamente.";
    - `signal` abortado → `turn/interrupt` (best effort, 2 s) y kill → error "Cancelado";
    - siempre un solo `RunDone`; siempre `kill`, `bridge.close` y borrado del `cwd` temporal en `finally`.
  - `ProviderRunner.run`: `provider === "codex" && params.codex_runtime === "session"` → `codexApp`; con `provider === "codex"` en cualquier otro caso → `codex` (API); si no → `claude`.

- [ ] **Step 1: Write the failing tests** (con fake-codex y `version: async () => "codex-cli 0.158.0"`):
  - `chat de texto`: con "hola", los eventos son `status`, `text "Ho"` y `text "la"`, y el done es `{ok:true, summary:"Hola", input_tokens:10, output_tokens:3, cost_usd:null, runtime:"session"}`.
  - `herramienta de Frontbot pasa por execute`: con "usa brands_list", `execute` se llama con `("brands_list", {})` y el texto repetido contiene su salida.
  - `herramienta fuera de lista no llega a execute` ("usa desconocida").
  - `params del hilo`: con `FAKE_CODEX_LOG`, `thread/start.environments` es `[]` en chat sin carpeta, `dynamicTools` contiene `posts_list` y `ephemeral` es `true`. En modo `image` con kind html, `dynamicTools` tiene exactamente `brands_list`, `brands_get_guide`, `brands_list_assets` e `images_render_html`.
  - `modelo no disponible`: `model:"gpt-6.1-terra"` → `ok:false` con "Elige un modelo disponible en la ficha del agente."
  - *(Review Focus 1)* `sin binario no usa la API`: `bin:null` → `ok:false` con "Codex no está instalado…", y `execute` nunca se llama. `versión vieja` → "Actualiza Codex…".
  - *(Review Focus 2)* `sesión caducada`: "falla" → `ok:false` con un error que contiene "session expired", y un solo done.
  - *(Review Focus 3)* `proceso muere`: "muere" → "Codex se cerró inesperadamente.". `cuelga + cancelar`: abortar a los 100 ms → error "Cancelado" en menos de 3 s y el proceso queda muerto.
  - `tope de herramientas`: "muchas" con modo chat (tope 30) → `ok:false` con "límite de herramientas".
  - *(Review Focus 4)* `métricas sin Chrome`: con `mode:"metrics"` y `startChrome` que devuelve `null`, `dynamicTools` no tiene `navigate` y el run termina sin colgarse.
  - En `runner.test.ts`:
    - `ProviderRunner envía session a codexApp y api a codex`;
    - `CodexRunner devuelve runtime api`.
- [ ] **Step 2: Run** `npx vitest run test/codex-app-runner.test.ts test/runner.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** y después `npm test` completo. Expected: PASS.
- [ ] **Step 5: Commit** `feat(codex): app-server runner with Frontbot dynamic tools and runtime routing`

### Task 6: Carpeta de trabajo, skills y Laboratorio en el runner

**Files:**
- Modify: `agent/src/codex-app-runner.ts`
- Modify: `agent/test/fixtures/fake-codex.mjs` (escenarios `"escribe fuera"` → `item/fileChange/requestApproval` con un cambio en `/Users/u/fuera.txt`; `"lee skill"` → `item/tool/call skills_read`; `"estudio"` → `tokenUsage` creciente)
- Test: `agent/test/codex-app-runner.test.ts`

**Interfaces:**
- Consumes: `workdirDecision`, `validateWorkdir`, `prepareSkillPlugin`, `readGuard`, `TokenMeter`, `STUDY_WARNING`, `buildStudyPrompt` y `AppCall` (`workdir.approve`).
- Produces (comportamiento):
  - **Workdir:**
    - antes de arrancar, `validateWorkdir`; un error termina el run con ese mensaje;
    - se arranca con `codexArgs(caps, { wd, home: homedir() })`;
    - `item/commandExecution/requestApproval {command}` → `workdirDecision("Bash", { command, dangerouslyDisableSandbox: true }, wd)`:
      - `deny` → `{decision:"decline"}`;
      - `ask` → `call("workdir.approve", { run_id, ...ask })`; `allow === true` → `"accept"`, si no `"decline"`;
      - `allow` se trata como `ask`;
    - `item/fileChange/requestApproval` → `workdirDecision("Write", { file_path }, wd)` para cada ruta del cambio (forma exacta según `tsx/v2/FileChangeRequestApprovalParams.ts` de `codex app-server generate-ts --experimental`). `accept` solo si todas son `ask` y aprobadas; cualquier `deny` → `decline`.
    - *(Review Focus 5)* cualquier otra petición del servidor (`item/permissions/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`, `applyPatchApproval`, `execCommandApproval`) → `decline` si su tipo lo admite; si no, error `-32601`. Nunca `accept`.
  - **Skills (`caps.skills`):**
    - `prepareSkillPlugin(params.skills)`;
    - la herramienta dinámica `skills_read`, con descripción "Lee un archivo de uno de tus skills (SKILL.md o sus archivos de apoyo). path: ruta absoluta que aparece en la lista de skills." y `inputSchema {type:"object", properties:{path:{type:"string"}}, required:["path"], additionalProperties:false}`;
    - `readGuard(plugin.dirs, plugin.path)`; fuera → `success:false` con "skills_read solo puede leer archivos de tus skills.";
    - máximo 256 KB, en utf8;
    - `instructions` añade una sección `\n\nSkills disponibles (léelos con skills_read antes de usarlos):\n- <nombre>: <dir>/SKILL.md` por skill;
    - `plugin.cleanup()` en `finally`.
  - **Estudio:**
    - `TokenMeter(params.study.budget_tokens)`;
    - en cada `thread/tokenUsage/updated` → `meter.add(params.model, { input_tokens: total.inputTokens - total.cachedInputTokens, cache_read_input_tokens: total.cachedInputTokens, output_tokens: total.outputTokens }, "codex-thread")`;
    - la primera vez que `meter.warned` → `turn/steer` con `STUDY_WARNING`;
    - `meter.exhausted` → `turn/interrupt` y kill → `{ ok:true, summary:"Sesión cortada por límite", cut:true, cut_reason:"tokens", lab_tokens, models }`;
    - reloj de `STUDY_WALL_CLOCK_MS` → lo mismo con `cut_reason:"clock"`;
    - el prompt es `buildStudyPrompt`; `multi_agent` sigue apagado.
- [ ] **Step 1: Write the failing tests:**
  - `comando protegido se declina sin preguntar` ("shell" pide `cat ~/.ssh/id_rsa`): la decisión repetida es `decline` y `call` nunca se llama con `workdir.approve`.
  - `comando fuera de sandbox pregunta a la app`: un comando no protegido → `call("workdir.approve", {run_id, kind:"unsandboxed", command})`. Con `{allow:true}` → `accept`; con `{allow:false}` → `decline`.
  - `escritura fuera de la carpeta pregunta`: "escribe fuera" → `workdir.approve` con `kind:"write"`.
  - *(Review Focus 5)* `petición de permisos se declina` ("permisos").
  - `workdir inválido no arranca Codex`: `workdir.path` dentro de `~/.ssh` → `ok:false` con el mensaje de `validateWorkdir` y `start` nunca se llama.
  - `skills_read lee dentro y niega fuera`: dentro del skill → `success:true` con el contenido; `/etc/hosts` → `success:false`.
  - `instrucciones listan skills`: `developerInstructions` contiene `Skills disponibles` y la ruta del `SKILL.md`.
  - `estudio corta por tokens`: "estudio" con `budget_tokens` 50 → `cut:true`, `cut_reason:"tokens"` y `lab_tokens >= 50`.
  - `estudio avisa al 85%`: se manda `turn/steer` con `STUDY_WARNING` una sola vez.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** y después `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(codex): working folder approvals, skills and lab sessions on app-server`

### Task 7: Núcleo Swift (estado de Codex, capacidades, params y runtime del run)

**Files:**
- Create: `app/Sources/FrontbotCore/Agent/CodexStatus.swift`
- Modify: `app/Sources/FrontbotCore/Agent/AgentProvider.swift`
- Modify: `app/Sources/FrontbotCore/Agent/AgentClient.swift`
- Modify: `app/Sources/FrontbotCore/Content/MetricsSchedule.swift`
- Modify: `app/Sources/FrontbotCore/Store/AppDatabase.swift` (migración `v15-run-runtime`: `ALTER TABLE agentRun ADD COLUMN runtime TEXT`), `Models/Records.swift` (`AgentRun.runtime: String?`) y `Store/Repositories.swift` (`finishRun(..., runtime: String? = nil)`)
- Test: `CodexStatusTests.swift`, `AgentProviderTests.swift`, `AgentClientCodexTests.swift` (nuevo), `MetricsScheduleTests.swift` y `StoreTests.swift`

**Interfaces:**
- Consumes: RPC de Task 3 y `RunDone.runtime` de Task 5.
- Produces:
  - `public struct CodexStatus: Equatable, Sendable { installed: Bool; compatible: Bool; version: String?; email: String?; plan: String?; models: [String]; var connected: Bool { installed && compatible && (email != nil || plan != nil) }; init(json: JSONValue); static let unknown }`
  - `public struct AgentCapabilities: Equatable, Sendable { web, browser, workdir, lab: Bool; static func of(provider: AgentProvider, codexConnected: Bool) -> AgentCapabilities }`. Claude → todo true. Codex conectado → todo true. Codex sin sesión → todo false.
  - `AgentProvider.codexSessionModels: [(id: String, label: String)]`: `gpt-6-astra` ("GPT-6 Astra · general y programación"), `gpt-6-sol` ("GPT-6 Sol"), `gpt-6-luna` ("GPT-6 Luna"), `gpt-5.6-sol`, `gpt-5.6-terra` y `gpt-5.6-luna`.
  - `AgentProvider.models(for: .codex)` = la lista de API ∪ `codexSessionModels`, sin duplicados, para que `resolve` conserve los dos.
  - `AgentProvider.pickerModels(for provider: AgentProvider, codex: CodexStatus?) -> [(id: String, label: String)]`:
    - Claude → como hoy;
    - Codex conectado → `codexSessionModels` filtrado por `codex.models` (si `models` viene vacío, la lista entera);
    - Codex sin sesión → la lista de API.
  - `AgentClient`:
    - `public func codexStatus() async throws -> CodexStatus`. Guarda `codexConnected` en el actor.
    - `public func codexLogin() async throws -> URL`
    - `public func codexWaitLogin() async throws -> Bool`
    - `public func codexLogout() async throws`
    - Todas usan el mecanismo de petición-respuesta que ya tiene el actor para `agent.run`/`agent.cancel`. Si falta, se agrega `request(method:params:) async throws -> JSONValue` sobre `resolve(id:with:)`. `codexWaitLogin` no tiene timeout propio: lo pone el sidecar.
    - `public func setCodexConnected(_ value: Bool)` para tests y para AppModel.
  - En `run(...)` con `provider == .codex`:
    - `params["codex_runtime"] = codexConnected ? "session" : "api"`;
    - `params["browser"] = true` si `agent.browser && AgentCapabilities.of(provider:codexConnected:).browser`. Reemplaza la condición `agent.provider == .claude && agent.browser`.
  - `sidecarEnvironment(config:inherited:codexHome:)` agrega `FRONTBOT_CODEX_HOME = codexHome`; el llamador pasa `files.paths.root/codex-home`.
  - `agent.done` → `finishRun(..., runtime: params["runtime"]?.stringValue)`.
  - `MetricsSchedule.canStart(activeRuns: Int, canRead: Bool) -> Bool` (`activeRuns == 0 && canRead`).

- [ ] **Step 1: Write the failing tests:**
  - `CodexStatusTests`:
    - `testConnectedNeedsCompatibleAccount`: un JSON con cuenta y `compatible:false` → `connected == false`;
    - `testParsesStatusJSON`: email, plan, version y models.
  - `AgentProviderTests`:
    - `testResolveKeepsSessionModels`: `resolve("gpt-6-sol", for: .codex) == "gpt-6-sol"` y `resolve("gpt-6.1-terra", for: .codex) == "gpt-6.1-terra"`;
    - `testPickerModelsFollowSession`: conectado con `models ["gpt-6-sol"]` → `["gpt-6-sol"]`; sin sesión → los ids de API;
    - `testCapabilities`: `.of(.codex, false).web == false` y `.of(.codex, true)` == `.of(.claude, false)`.
  - `AgentClientCodexTests` (sidecar fake, `FRONTBOT_FAKE_CODEX_SESSION=1` por entorno):
    - `testCodexStatusConnected`;
    - `testRunSendsSessionRuntime`: tras `codexStatus()`, un run de un agente Codex termina con `AgentRun.runtime == "session"`;
    - `testRunWithoutSessionUsesApi`: con `setCodexConnected(false)` → `runtime == "api"`;
    - `testCodexBrowserOnlyWithSession`: lee los params enviados con el `GateRenderer` o el log del fake, el mismo patrón de `AgentClientImageTests`.
  - `MetricsScheduleTests.testCanStartNeedsReader`.
  - `StoreTests.testFinishRunStoresRuntime`.
- [ ] **Step 2: Run** `cd agent && npm run build && cd ../app && swift test --filter 'CodexStatusTests|AgentProviderTests|AgentClientCodexTests|MetricsScheduleTests|StoreTests' < /dev/null`. Expected: FAIL (no compila).
- [ ] **Step 3: Implement.** El `FakeRunner` de Task 5 ya devuelve `runtime`. Si el sidecar fake necesita el entorno, se agrega `FRONTBOT_FAKE_CODEX_SESSION` como passthrough solo cuando `config.fakeAgent`.
- [ ] **Step 4: Run** lo mismo y después `swift test < /dev/null` completo. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): Codex session status, capabilities and session runtime in runs`

### Task 8: UI (Ajustes, ficha del agente y comprobaciones por capacidad)

**Files:**
- Modify: `app/Sources/FrontbotApp/AppModel.swift`
- Modify: `app/Sources/FrontbotApp/SettingsView.swift`
- Modify: `app/Sources/FrontbotApp/AgentDetailView.swift`
- Modify: `app/Sources/FrontbotApp/WorkdirChip.swift` y `SchedulesView.swift` (selector de modelo)
- Modify: `app/Localization/en/chat.strings` y `app/Localization/en/core.strings`

**Interfaces:**
- Consumes: Task 7.
- Produces (AppModel):
  - `var codexStatus: CodexStatus?`
  - `func refreshCodexStatus() async`: al arrancar, al abrir Ajustes y tras login o logout. Llama a `client.setCodexConnected`.
  - `func connectCodex() async`: `codexLogin()` → `NSWorkspace.shared.open(url)` → `codexWaitLogin()` → `refreshCodexStatus()`. Los errores van a `errorMessage`.
  - `func disconnectCodex() async`
  - `func capabilities(for agent: Agent?) -> AgentCapabilities`
  - `defaultAgentCanReadWeb` y `canReadWeb` pasan a `capabilities(for:).web`; `tickMetrics` usa `MetricsSchedule.canStart(activeRuns:canRead: capabilities(for: defaultAgent).browser)`; `canReadMetrics` usa `.browser`.
  - El texto de `summarize` (línea ~1337) no cambia.
- UI, con el copy exacto:
  - **Ajustes → Codex.** Primero el bloque "Sesión de Codex":
    - punto de estado y una de estas líneas:
      - "Conectado como \(email) · \(plan)"
      - "No conectado"
      - "Codex no está instalado"
      - "Actualiza Codex (versión \(version))"
    - botón "Conectar con ChatGPT", o "Desconectar" si ya está conectado;
    - nota "Con la sesión conectada, Codex usa tu suscripción de ChatGPT y puede usar web, tu Chrome, carpeta de trabajo y el Laboratorio.";
    - sin instalar, el enlace "Instalar Codex" → `https://developers.openai.com/codex`.

    Después, el bloque de API key actual, con esta nota en lugar de las dos primeras: "Sin sesión, Codex usa esta API key en modo básico: solo herramientas de Frontbot, sin web, Chrome ni carpeta. Se factura a tu proyecto de API de OpenAI." Las notas de `store:false` y del historial se conservan.
  - **Ficha del agente:**
    - la pestaña Laboratorio se muestra si `capabilities.lab`; si no, el label "El Laboratorio de Codex necesita la sesión de Codex conectada (Ajustes).";
    - el toggle "Usar mi Chrome" se desactiva si `!capabilities.browser`, con el texto "Conecta la sesión de Codex en Ajustes para usar tu Chrome." Con Codex conectado, una nota más: "Usa la extensión Claude in Chrome.";
    - el selector de modelo usa `AgentProvider.pickerModels(for:codex:)`.
  - **WorkdirChip:** se desactiva si `!capabilities(for: selectedAgent).workdir`, con el help "Conecta la sesión de Codex en Ajustes para usar una carpeta de trabajo."
  - **SchedulesView:** el selector usa `pickerModels`.
- [ ] **Step 1: Implement** los cambios de AppModel y de la UI, con todas las strings nuevas en `en/*.strings`. Es SwiftUI sin tests de vista en el repo; la lógica testeable ya está en Task 7.
- [ ] **Step 2: Build** `scripts/build-app.sh`. Expected: build OK, sin warnings nuevos de strings faltantes.
- [ ] **Step 3: Run** `cd app && swift test < /dev/null`. Expected: PASS, la suite completa.
- [ ] **Step 4: Commit** `feat(app): Codex session in settings and capability-based gating`

### Task 9: Prueba manual contra el Codex real (script de desarrollo)

**Files:**
- Create: `agent/scripts/codex-smoke.mjs`. Importa `dist/codex-app-runner.js` y `dist/codex/account.js`, y corre contra `FRONTBOT_CODEX_HOME`.

**Interfaces:**
- Consumes: todo lo anterior, compilado.
- El script corre cuatro escenarios con un `execute` falso que devuelve `{brands:[{id:"b1", name:"Marca Prueba"}]}`, e imprime OK o FALLO en cada uno:
  1. **chat:** "Llama a brands_list y dime el nombre." → summary contiene "Marca Prueba".
  2. **sin shell:** "Ejecuta `ls ~` si puedes." → no aparece ningún `tool_call` `Bash ·`.
  3. **carpeta:** con un `wd` temporal fuera de `/tmp` y un archivo `secreto.txt` en otra carpeta del home, `cat <secreto>` → la salida no contiene su contenido. `echo hola > dentro.txt` → el archivo existe. La aprobación la contesta un `call` falso que siempre devuelve `{allow:false}`.
  4. **chrome:** solo `tabs_context_mcp` → `success` true, sin navegar.

- [ ] **Step 1: Write** el script.
- [ ] **Step 2: Run** `cd agent && npm run build && FRONTBOT_CODEX_HOME=<carpeta con sesión> node scripts/codex-smoke.mjs`. Expected: 4 OK. Usa la sesión conectada desde Frontbot o la de la prueba del 2026-11-04. Si un escenario falla, se depura con superpowers:systematic-debugging antes de seguir.
- [ ] **Step 3: Commit** `chore(codex): manual smoke script against the real app-server`
