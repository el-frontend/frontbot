# Frontbot · Codex real (runtime `app-server`)

Fecha: 2026-11-04. Reemplaza, para el proveedor Codex, la decisión "solo API key" de `2026-10-28-frontbot-api-key-only-design.md`. Ese bucle **no se borra**: queda como respaldo cuando no hay sesión de Codex.

## Por qué

Hoy un agente "Codex" en Frontbot es un bucle hecho a mano contra la API de Responses (`agent/src/codex-runner.ts`): solo texto y herramientas de Frontbot, 8 rondas, solo API key. Por eso, con Codex quedan desactivados "Desde links", Métricas, Chrome, carpeta de trabajo, skills y Laboratorio, y el uso se cobra aparte de la suscripción de ChatGPT del usuario.

El usuario quiere que Codex "pueda hacer lo mismo que hacemos con Claude Code": controlar el runtime real de Codex igual que controlamos el Agent SDK de Claude. También quiere usar su Chrome con sesión iniciada, "porque si no, no podrá ver mis sesiones".

Éxito:
- un agente Codex, con la sesión de ChatGPT conectada, hace en Frontbot lo mismo que un agente Claude: chat, tareas programadas, resumen, imagen, métricas, "Desde links", carpeta de trabajo, skills y Laboratorio;
- y lo hace con los mismos límites de seguridad.

## Objetivos

- Un proveedor **Codex** con dos formas de ejecutarse, elegidas por Frontbot (lo decidió el usuario):
  - **Sesión de Codex conectada** → runtime real (`codex app-server`). Si también hay API key, gana la sesión.
  - **Solo API key** → el bucle actual (`CodexRunner`), sin cambios de comportamiento. Las funciones que necesitan web, Chrome o carpeta siguen desactivadas y la app explica que se activan conectando Codex.
  - **Ninguna** → el aviso de siempre para conectar en Ajustes.
- La sesión de Codex se conecta con la cuenta de ChatGPT del usuario: el uso sale de su suscripción.
- En el runtime real, paridad de capacidades con Claude:
  - herramientas de Frontbot;
  - web;
  - Chrome con sesión del usuario;
  - carpeta de trabajo;
  - skills;
  - Laboratorio;
  - los modos `chat`, `scheduled`, `summarize`, `image`, `metrics` y `study`.
- El registro del run dice con qué se ejecutó: Codex (sesión) o API *(mi decisión)*.

## No objetivos

- Cambiar el proveedor Claude, su runtime o sus permisos.
- Borrar o reescribir el bucle de API key.
- Usar el Chrome propio de Codex (`browser_use`/`node_repl`). Ver "Chrome" abajo.
- Reusar la sesión ni la configuración de la app Codex del usuario (`~/.codex`).
- Computer use, generación de imágenes nativa de Codex, plugins, apps/conectores y memorias de Codex.
- Pasar de un proveedor a otro de forma automática.

## Anti-objetivos (fallaría aunque funcione)

- **Que Codex tenga más poder que Claude en el mismo modo.** Shell, disco, MCP o JavaScript que Frontbot no haya dado explícitamente para ese run son un fallo.
- **Que el navegador interactúe con una red social.** Las reglas del `BrowserGuard` actual se aplican igual, llamada por llamada, no como instrucción en el prompt.
- **Que la configuración personal del usuario se cuele**, por ejemplo sus servidores MCP de `~/.codex/config.toml`: `node_repl` ejecuta JavaScript sin sandbox.
- **Cobrar a la API key sin que se vea**: si el runtime real falla, no se reintenta con la API key *(mi decisión)*.
- Romper la sesión de la app Codex del usuario: Frontbot nunca toca `~/.codex/auth.json`.

## Lo que demostró la prueba (2026-11-04, Codex CLI `0.158.0-alpha.2.1`)

Probado con un `app-server` real y la sesión de ChatGPT del usuario (plan Pro). El script desechable está en el scratchpad de la sesión; no forma parte del repo.

1. **Login aislado.**
   - Con `CODEX_HOME` apuntando a una carpeta propia y `cli_auth_credentials_store="file"`, `account/read` empieza vacío.
   - `account/login/start {type:"chatgpt"}` devuelve una `authUrl`. Tras el login en el navegador, `account/read` devuelve la cuenta (`chatgpt`, plan).
   - La sesión de `~/.codex` no se toca.
   - También existe `{type:"apiKey"}`, que no usaremos.
2. **Herramientas de Frontbot sin MCP.**
   - `thread/start` acepta `dynamicTools` (requiere `initialize.capabilities.experimentalApi: true`).
   - Codex las pide con la petición del servidor `item/tool/call {callId, tool, arguments}`.
   - El cliente responde `{success, contentItems:[{type:"inputText", text}]}`.
3. **Lista cerrada.**
   - Con `CODEX_HOME` aislado, `environments: []`, `--disable shell_tool --disable unified_exec --disable code_mode_host --disable goals --disable sleep_tool --disable tool_suggest --disable plugins --disable apps --disable memories --disable browser_use --disable computer_use --disable multi_agent --disable image_generation`, el modelo solo tiene: las herramientas dinámicas, `web__run` (búsqueda web) y `clock__curr_time`.
   - Con `-c tools.web_search=false` desaparece la web.
   - **Ojo:** en `CODEX_HOME=~/.codex` se colaban los MCP del usuario (Pencil, `node_repl`) aunque se pasara `-c mcp_servers={}`. El aislamiento por carpeta es obligatorio.
4. **Carpeta de trabajo (shell activo).**
   - Funciona con un perfil `[permissions.<id>]` en el `config.toml` del `CODEX_HOME` de Frontbot, `extends = ":workspace"`, con entradas `"<ruta>" = "deny"`.
   - El perfil se elige en `thread/start` con `permissions: "<id>"`. Si además se pasa `sandbox`, el perfil se ignora.
   - Resultado con `approvalPolicy: "on-request"`:
     - escribir dentro de la carpeta: bien;
     - leer `~/.zshrc` o un archivo denegado: `Operation not permitted`;
     - escribir fuera: bloqueado, **salvo en `/tmp`**, que `:workspace` permite.
   - El shell necesita `code_mode_host` activo (sin él: "code-mode host is disabled").
5. **Aprobaciones.**
   - Con `approvalPolicy: "untrusted"`, cada comando llega como `item/commandExecution/requestApproval`.
   - **"accept" ejecuta el comando fuera de la sandbox**: leyó el archivo denegado y escribió fuera.
   - Por eso aceptar equivale a "sin sandbox", como el Bash `dangerouslyDisableSandbox` de Claude.
   - Con `"on-request"`, lo que cabe en la sandbox corre sin preguntar y lo que necesita salir llega como petición de aprobación.
6. **Chrome.**
   - El Chrome de Codex se maneja con JavaScript escrito por el modelo, dentro de `node_repl` (servicio interno de OpenAI, fuera de sandbox). No se puede poner un guardián herramienta por herramienta.
   - En cambio, el binario de Claude que Frontbot ya incluye (`@anthropic-ai/claude-agent-sdk-darwin-arm64/claude`) arranca **Claude in Chrome como servidor MCP stdio independiente** (`claude --claude-in-chrome-mcp`).
   - Respondió a `initialize`, `tools/list` (las herramientas de siempre: `navigate`, `read_page`, `get_page_text`, `find`, `computer`, `tabs_*`, …) y a `tabs_context_mcp` contra el Chrome real del usuario.
7. **Web y `code_mode_host`.**
   - La herramienta web de Codex (`web__run`) busca **y abre URLs** (leyó el primer párrafo de `example.com`). Equivale a `WebSearch` + `WebFetch`.
   - Necesita `code_mode_host` activo, igual que el shell.
   - `code_mode_host` agrega `exec`/`wait`: un JavaScript aislado para orquestar herramientas, sin `require`, `process`, `fetch` ni `Deno`. Intentar leer el archivo denegado devolvió `undefined`.
   - Por eso `code_mode_host` queda **encendido** en todos los modos con web o shell. No da acceso al disco ni a la red. El guardián sigue en cada herramienta dinámica, aunque la llame `exec`.
   - En los modos sin web ni shell (imagen, resumen, métricas) se apaga.
8. **Modelos de la suscripción.** `model/list` con la sesión Pro devolvió `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra` y `gpt-5.6-luna`. No es la misma lista que la de la API (`gpt-6.1-sol`, `gpt-6.1-terra`).
9. **Streaming y uso.**
   - Llegan `item/agentMessage/delta` (texto), `item/started`/`item/completed` (herramientas, comandos), `thread/tokenUsage/updated` (tokens de entrada y salida, y caché) y `turn/completed`.
   - No llega costo en dinero.

## Cómo funciona (decidido con el usuario)

### Sesión y Ajustes

- Frontbot tiene su propia carpeta de Codex dentro de su carpeta de datos (p. ej. `<datos>/codex-home`, permisos 700) *(ruta: mi decisión)*:
  - con su `config.toml` (perfiles de permisos de Frontbot, `cli_auth_credentials_store="file"`);
  - y con la sesión de ChatGPT que el usuario conecte desde Frontbot.
- Ajustes → Codex muestra:
  - **Sesión de Codex**: conectada (cuenta y plan) o no. Tiene un botón **Conectar con ChatGPT**, que abre el login en el navegador, y otro **Desconectar** (`account/logout`).
  - **API key de OpenAI** (opcional): igual que hoy, en el llavero.
  - Una nota: con la sesión conectada se usa Codex con tu suscripción. Con solo la API key se usa el modo básico, sin web, Chrome ni carpeta, y se factura a la API.
- **Codex no instalado:** se busca el binario de Codex (el de la app ChatGPT/Codex o `codex` en el PATH). Si no está, la sesión aparece como "Codex no está instalado", con el enlace de instalación, y se usa el modo API si hay key.

### Elección del runtime en cada run

- La app decide antes de lanzar el run y lo manda al sidecar: `provider: "codex"` y `codex_runtime: "session" | "api"`.
- Con `session`, el sidecar usa el runner nuevo. Con `api`, usa el `CodexRunner` actual.
- Si la sesión está conectada pero el run falla (sesión caducada, límite de la suscripción, Codex se cae), el run falla con un mensaje claro. **No se reintenta con la API key.**
- Las comprobaciones de capacidad de la app pasan de "¿es Codex?" a "¿este agente puede X?":
  - `canReadLinks`, `canReadMetrics`, Chrome en la ficha del agente, carpeta de trabajo y Laboratorio.
  - Codex con sesión puede todo lo que puede Claude.
  - Codex con solo API key queda como hoy.

### Runner nuevo (`codex-app-runner`, nombre al builder)

- Un proceso `codex app-server` por run *(mi decisión: aislamiento simple y cancelación limpia)*:
  - con `CODEX_HOME` de Frontbot;
  - con un `cwd` temporal vacío, o la carpeta de trabajo;
  - con las flags de la sección 3 de la prueba.
- Se usa `thread/start` con `ephemeral: true`, el modelo del agente, `baseInstructions`/`developerInstructions` construidas con `buildSystemPrompt` y `dynamicTools` = las especificaciones de `frontbotToolSpecs(toolContext(params))`, con su JSON Schema.
  - **El historial lo pone Frontbot en el prompt**, como hoy (`buildUserPrompt`). Codex no guarda conversaciones.
- Cada `item/tool/call` se valida contra la lista del run. Lo que no está en la lista responde con error. Lo que sí está va por `frontbot.execute`, igual que el `CodexRunner` actual.
- Los eventos se traducen al contrato actual:
  - `agentMessage/delta` → `text`;
  - el inicio de una herramienta o un comando → `tool_call`, con el mismo texto que `toolCallText`;
  - `turn/completed` → `agent.done` con tokens y `cost_usd: null`.
- Cancelar → `turn/interrupt` y después matar el proceso. Si el proceso muere, el run termina con error. Siempre un solo `agent.done`.
- Topes de turnos: equivalentes a los `maxTurns` de Claude por modo (30, 150, 40, 60, 6). Se cuentan por llamadas a herramientas o por ítems *(forma: al builder)*.

### Capacidades por modo (paridad con `buildQueryOptions` de Claude)

| Modo | Herramientas de Frontbot | Web | Chrome | Shell / disco | Skills | Sub-agentes |
|---|---|---|---|---|---|---|
| chat | `specsFor` | sí | si el agente lo tiene | solo con carpeta de trabajo | si el agente tiene | no |
| scheduled | `specsFor` (scheduled) | sí | si el agente lo tiene | no | si el agente tiene | no |
| summarize | memoria | no | no | no | no | no |
| image | lista cerrada de imagen | no | no | no | no | no |
| metrics | `metrics_post`, `posts_record_metrics` | no | **siempre** | no | no | no |
| study | lista de estudio | sí | no | no | no | no en esta versión (ver respuestas a la revisión) |

- "No" significa que la herramienta no existe en el run: flag apagada, `environments: []` o fuera de `dynamicTools`. No basta con pedirlo en el prompt.
- **Trading:** las herramientas de trading van como dinámicas (ya están en `specsFor`) y siguen pasando por `trade_propose` y la aprobación de Swift.
- **Skills:** se preparan en una carpeta temporal como hoy (`prepareSkillPlugin`) y se leen sin shell (ver "Respuestas a la revisión"). Los scripts siguen yendo **solo** por `skills_run_script` con aprobación.
- **Laboratorio:** ver "Respuestas a la revisión": un solo hilo, sin sub-agentes en esta versión.

### Chrome (decidido con el usuario: su Chrome con sesión)

- Cuando el run tiene navegador, el sidecar arranca `claude --claude-in-chrome-mcp` (el binario de Claude que ya trae Frontbot) como cliente MCP.
- Codex ve como herramientas dinámicas **solo** las de `BROWSER_ALLOWED_TOOLS`, con el nombre y el esquema del servidor.
- Cada llamada pasa por `BrowserGuard.beforeTool` antes de reenviarse y por `afterTool` después, igual que en los hooks de Claude. Si el guardián niega, Codex recibe `success:false` con el motivo.
- Requisito: la extensión Claude in Chrome instalada y conectada.
  - Si no responde, el agente lo trata como "sin Chrome": en métricas, `unavailable:true`; en chat, un mensaje.
  - La ficha del agente lo explica *(mi decisión)*.

### Carpeta de trabajo

- El perfil de permisos de Frontbot en el `config.toml` aislado se genera por run, o con un id por run *(al builder)*:
  - `extends = ":workspace"`;
  - escritura en la carpeta;
  - `deny` en el home del usuario (salvo la carpeta), en las rutas protegidas de `workdir.ts` y en `/tmp`/`$TMPDIR` fuera de la carpeta.
- Se aplica la misma lógica que `workdirDecision`/`isProtectedPath`.
- `approvalPolicy: "on-request"`. Cada `item/commandExecution/requestApproval` o `item/fileChange/requestApproval` se resuelve así:
  - si es protegido → `decline`;
  - si no → `workdir.approve` a Swift, que pregunta al usuario. Aprobado → `accept`, para esa llamada sola. Nunca `acceptForSession` ni enmiendas de política.
- La red del shell sigue las mismas reglas que la sandbox de Claude (`sandboxSettings`).

### Respuestas a la revisión del builder (mis decisiones)

- **Leer páginas web:** lo hace `web__run`, que abre URLs (prueba, punto 7). No hace falta una herramienta de Frontbot nueva. "Desde links" usa la web de Codex.
- **Red del shell en la carpeta de trabajo:**
  - Los dominios de `sandboxSettings` se pasan al perfil, en `[permissions.<id>.network.domains]` con `features.network_proxy = true`.
  - Si esta versión de Codex no aplica los dominios, el shell va **sin red**: se falla hacia lo cerrado.
  - Las `read_dirs` extra se agregan como `"read"` después del `deny` del home. El builder lo comprueba con un test real. Si un `read` no puede abrir un hueco dentro de un `deny`, esas carpetas extra no se ofrecen con Codex y la ficha lo explica.
- **Skills sin shell:**
  - Codex lee los skills con una herramienta dinámica de **solo lectura** limitada a los archivos de los skills del run, con el mismo `readGuard` que el `Read` de Claude.
  - No publica, no aprueba y no da más poder que el `Read` de Claude. Nunca se enciende el shell para leer skills.
  - Si los skills nativos de Codex (`skills/extraRoots/set`) leen sin shell y sin salirse de esa carpeta, el builder puede usarlos en su lugar.
- **Chrome y cuenta de Claude:**
  - El Chrome de Codex depende de la extensión Claude in Chrome, igual que el de Claude. Si la extensión pide cuenta de Claude conectada, ese requisito aplica también a Codex.
  - Ajustes y la ficha del agente lo explican. Sin Chrome, métricas da `unavailable` y el editor lo muestra.
  - Es aceptable para esta versión: el usuario quiere su Chrome con sesión, y esta es la única vía con un guardián exacto.
- **Laboratorio con Codex:**
  - Primera versión **sin sub-agentes**: un solo hilo con la lista de estudio, web y el mismo `TokenMeter`.
  - Cuenta tokens de entrada + salida, con el razonamiento dentro de la salida y las lecturas de caché a 0,1, como hoy.
  - El presupuesto y el reloj de 20 minutos se mantienen sin cambios.
  - `allow_opus` y los tres niveles de modelo no aplican a Codex. El hilo usa el modelo del agente.
  - Los sub-agentes de Codex quedan para después, cuando se pueda limitar su lista de herramientas.
- **Modelos de Codex:**
  - Con la sesión conectada, la ficha del agente muestra la lista de `model/list` de la sesión.
  - Con solo API key, la lista de la API, como hoy.
  - Si el modelo guardado no está disponible en la forma de ejecución elegida, el run falla con "Elige un modelo disponible en la ficha del agente". No se cambia de modelo en silencio, igual que la regla actual de la API.

## Restricciones

- Swift 6 / SwiftUI, Node + zod, XCTest + vitest; la suite completa en verde.
- Strings en español como claves, con el inglés en `app/Localization/en/*.strings`.
- No se agrega ninguna herramienta que publique o apruebe. El `BrowserGuard` no se debilita.
- El protocolo de `app-server` es experimental (los campos `dynamicTools` y `permissions` necesitan `experimentalApi`).
  - El runner valida la versión de Codex al iniciar. Si no es compatible, el run falla con "Actualiza Codex" y no se usa la API key a escondidas.
  - Los tipos se toman de `codex app-server generate-ts --experimental` de la versión probada.
- Sin red en los tests. Se prueba con un `app-server` falso (un proceso que habla el mismo JSON-RPC por stdio) y un servidor MCP de Chrome falso.

## Lo que queda al builder

- Nombre del runner y de los campos nuevos de `RunParams`.
- Cómo se detecta el binario de Codex y cuál es la versión mínima.
- Cómo se muestra en Swift el login de ChatGPT: proceso `app-server` corto que hace `account/login/start` y espera a `account/login/completed`.
- Cómo se cuentan los turnos.
- Si el perfil de permisos se escribe por run o es fijo con rutas pasadas por config.
- Cómo se migran las comprobaciones `provider == .codex` de la app a comprobaciones de capacidad.
