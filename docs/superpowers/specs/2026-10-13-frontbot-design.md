# Frontbot — Diseño v1

**Fecha:** 2026-10-13
**Estado:** borrador para revisión
**Nombre:** "Frontbot" es nombre de trabajo.

## 1. Objetivo

App de escritorio nativa para macOS: un agente con IA enfocado en **gestión de marcas y redes sociales** (subir marcas, generar contenido, calendario, preparar publicaciones), que además ayuda con **tareas diarias** y **búsqueda de oportunidades de negocio**.

- **Usuario v1:** el autor, para sus propias marcas.
- **Horizonte:** la arquitectura debe permitir convertirla en producto para otros (agencias, community managers) sin reescribir. No se construye nada de producto en v1 (sin login, backend ni facturación).
- **Éxito v1:** el autor la usa a diario para generar y preparar el contenido de sus marcas en Instagram y LinkedIn, llevar sus tareas del día y guardar investigaciones de negocio.

## 2. Relación con coucou

[coucou](https://github.com/Louis-CFM/coucou) (MIT) es un *monitor* de agentes en el notch, no un agente. No se hace fork. Frontbot es un proyecto nuevo que **toma piezas puntuales** del código de coucou con la atribución MIT (copyright y licencia en `THIRD_PARTY_NOTICES.md`):

- Controlador de la ventana del notch y su geometría (`IslandWindowController`, `IslandScreenGeometry`).
- Renderizado de chat en markdown (`ChatMarkdown`, `ChatMarkdownView`).
- Atajo global (`HotKeyCenter`).

**Prohibido reutilizar** (no cubierto por MIT, ver `LICENSE-ASSETS.md` de coucou): los nombres "Coucou" y "Mochi", el personaje Mochi, los íconos, los sonidos y los medios. Frontbot usa su propio bundle ID.

## 3. Arquitectura

```
Frontbot.app (Swift 6, SwiftUI + AppKit)
├── Notch: prompt rápido, tareas de hoy, avisos de "post listo para aprobar"
├── Ventana principal: Marcas · Calendario · Tareas · Ideas · Chat · Ajustes
├── AgentClient ── JSON-RPC 2.0 por stdio ──► frontbot-agent (sidecar Node/TS)
├── Store: SQLite + carpeta de archivos                ├── Claude Agent SDK (TypeScript)
└── CredentialStore (Keychain)                         ├── Herramientas propias (llaman a la app)
                                                       ├── WebSearch / WebFetch del SDK
                                                       └── PublishingService (abre el navegador del usuario)
```

### 3.1 Componentes

| Componente | Responsabilidad | Depende de |
|---|---|---|
| **App Swift** | Toda la UI; **única dueña de los datos** (SQLite y archivos). Arranca, vigila y reinicia el sidecar. | Store, AgentClient, CredentialStore |
| **Store** | SQLite en `~/Library/Application Support/Frontbot/frontbot.sqlite`; archivos de marca en `brands/<brand_id>/`. | — |
| **AgentClient** | Cliente JSON-RPC hacia el sidecar: manda prompts, recibe eventos en streaming y atiende las llamadas a herramientas que vienen del sidecar. | Store |
| **frontbot-agent** | Proceso Node empaquetado en el `.app` (runtime de Node incluido). Corre el Agent SDK y expone las herramientas propias, que se resuelven con llamadas JSON-RPC de vuelta a la app. | Agent SDK |
| **PublishingProvider** | Interfaz para publicar. v1: `BrowserAssistProvider`. v2: proveedores con API oficial por red. | — |
| **CredentialStore** | Guarda en el Keychain la API key de Anthropic, por workspace. Nunca secretos en disco ni en git. | Keychain |

### 3.2 Preparado para producto

- Todo cuelga de un `workspace_id`; en v1 hay un único workspace.
- Las credenciales son por workspace.
- Autenticación del agente: **uso personal** → sin API key, el Agent SDK usa la sesión de Claude Code del usuario en su Mac (decisión del 2026-10-15). **Producto distribuido** → cada usuario necesitará su API key de Anthropic; la app ya admite una key opcional en Ajustes (Keychain).
- La publicación pasa siempre por `PublishingProvider`; ningún código depende de una red o proveedor concreto.

## 4. Modelo de datos (SQLite)

| Entidad | Campos | Notas |
|---|---|---|
| `workspace` | id, name, created_at | Uno solo en v1. |
| `brand` | id, workspace_id, name, industry, networks (JSON: `instagram`, `linkedin`), created_at | |
| *guía de marca* | `brands/<id>/guide.md` | Tono, público, pilares, palabras sí/no, ejemplos. Se inyecta como contexto en toda tarea de esa marca. |
| `brand_asset` | id, brand_id, kind (`logo`, `guide_source`, `image`), path, created_at | Los archivos se guardan en `brands/<id>/assets/`. |
| `post` | id, brand_id, network, body, media (JSON de ids de `brand_asset`), status, scheduled_for, published_url, created_at, updated_at | Ver máquina de estados. |
| `task` | id, workspace_id, title, due_date, done, brand_id (nullable), created_at | |
| `business_idea` | id, workspace_id, title, summary, sources (JSON de URLs), score (1–5), report_path, created_at | El reporte va en `ideas/<id>.md`. |
| `agent_run` | id, workspace_id, brand_id (nullable), prompt, status (`running`, `done`, `failed`), result_summary, input_tokens, output_tokens, cost_usd, log_path, created_at | Auditoría y control de gasto. |

### 4.1 Máquina de estados de `post`

```
borrador ──(usuario aprueba)──► aprobado ──(usuario: "Preparar publicación")──► preparando
preparando ──(usuario confirma publicado/programado)──► publicado | programado
preparando ──(cancelar)──► aprobado
programado ──(usuario confirma)──► publicado
cualquier estado ──(usuario)──► archivado
```

Solo el usuario mueve un post de `borrador` en adelante. El agente solo crea y edita borradores.

## 5. Funciones v1

1. **Subir marca.** Formulario con nombre, rubro y redes, más archivos: PDF o imágenes de la guía, y logos. Opción **"Entrevístame"**: el agente hace preguntas y escribe `guide.md`. Si se sube un PDF de guía, el agente genera `guide.md` a partir de él. `guide.md` siempre se puede editar a mano.
2. **Generar contenido.** El usuario pide algo como "5 posts de Instagram para esta semana sobre X". El agente investiga en la web con la guía como contexto y crea **borradores** con fecha sugerida en el calendario.
3. **Imágenes.** El usuario sube imágenes a la biblioteca de la marca y las adjunta a los posts. El agente puede sugerir qué imagen usar entre las existentes. **La generación de imágenes con IA no entra en v1.**
4. **Calendario.** Vista semanal y mensual, filtrable por marca y red. Desde ahí se edita, se aprueba y se prepara la publicación.
5. **Publicación asistida** (Instagram y LinkedIn). Ver sección 7.
6. **Tareas del día.** Lista simple. El agente crea, lista y completa tareas ("recuérdame grabar el reel el jueves").
7. **Ideas de negocio.** El usuario pide algo como "busca oportunidades en X". El agente investiga y guarda `business_idea` con fuentes, puntaje y reporte.
8. **Chat.** Conversación libre con el agente en la ventana principal, con la marca activa como contexto opcional.
9. **Notch.** Atajo global para abrir el prompt rápido; muestra las tareas de hoy y la cantidad de posts aprobados pendientes de publicar.

### Fuera de v1

Generación de imágenes y video · analíticas · voz/wake word · iPhone · redes distintas de IG y LinkedIn · APIs oficiales de publicación · varios workspaces, login y facturación · tareas recurrentes o programadas del agente.

## 6. Agente

### 6.1 Flujo

1. El usuario envía un prompt. La app crea un `agent_run` y manda al sidecar `agent.run { run_id, prompt, brand_id? }`.
2. El sidecar arma el system prompt con las instrucciones base de Frontbot, más el `guide.md` de la marca si hay una activa, más la fecha de hoy.
3. Durante la ejecución, el sidecar emite notificaciones `agent.event { run_id, type: text|tool_call|tool_result|status }`, que la UI muestra en streaming.
4. Cada herramienta propia que use el agente se convierte en una llamada `tool.<nombre>` del sidecar a la app. La app valida, persiste y responde con el resultado o un error legible.
5. Al terminar, el sidecar envía `agent.done { run_id, summary, usage }` y la app cierra el `agent_run`.
6. La app puede enviar `agent.cancel { run_id }`.

### 6.2 Herramientas propias

| Grupo | Herramientas |
|---|---|
| Marcas | `brands_list`, `brands_get_guide`, `brands_write_guide`, `brands_list_assets` |
| Posts | `posts_list`, `posts_create_draft`, `posts_update_draft` |
| Tareas | `tasks_list`, `tasks_create`, `tasks_complete` |
| Ideas | `ideas_create` |

- Las herramientas del SDK permitidas son solo `WebSearch` y `WebFetch`. Bash, edición de archivos y cualquier otra quedan deshabilitadas.
- **No hay herramienta para aprobar ni publicar.** `posts_update_draft` falla si el post no está en `borrador`.

### 6.3 Modelo

Por defecto `claude-sonnet-5-5` (equilibrio costo/calidad para uso diario), configurable en Ajustes (p. ej. `claude-opus-5-5` para investigaciones de negocio). El costo de cada `agent_run` se muestra en su historial.

## 7. Publicación asistida

> **Cambio (2026-10-16):** se retiró el Chrome dedicado con Playwright y los scripts de compositor. Frontbot ahora usa el navegador del usuario, donde ya tiene sus sesiones.

- **Flujo.** El usuario pulsa "Abrir en <red> para publicar" en un post `aprobado` y el post pasa a `preparando`. La app abre la red en el navegador por defecto, copia el texto al portapapeles y selecciona las imágenes en el Finder.
  - **LinkedIn** abre el compositor con el texto ya escrito (`/feed/?shareActive=true&text=…`). Es un parámetro no documentado, así que el texto también va al portapapeles.
  - **Instagram** no admite nada parecido en la web: abre el inicio, y el usuario pulsa Crear, sube las imágenes y pega el texto.
- **Clic final.** El usuario publica o programa dentro de la red. Después lo confirma en Frontbot ("Publicado" o "Programado") y, si quiere, pega la URL.
- **Nunca se pulsa Publicar de forma automática.** El agente puede usar el Chrome del usuario para investigar (Claude in Chrome, opcional en Ajustes), pero detrás de un guardián (`agent/src/browserGuard.ts`):
  - bloquea JavaScript, subidas de archivos y lotes;
  - exige verificar las pestañas con `tabs_context_mcp` antes de cada clic o tecla;
  - rechaza cualquier clic o escritura mientras haya abierta una red social o un programador de posts.

## 8. Errores

| Caso | Comportamiento |
|---|---|
| El sidecar se cae | La app lo reinicia (máximo 3 veces por minuto); el `agent_run` en curso queda `failed` con log. |
| Error de la API de Claude (rate limit, sin crédito, key inválida) | Mensaje claro en la UI y enlace a Ajustes si es la key. Sin reintentos infinitos: el SDK reintenta según su política y luego falla. |
| La herramienta recibe datos inválidos (marca inexistente, texto sobre el límite de la red, media inexistente) | La app responde con un error descriptivo para que el agente corrija. |
| Imagen inválida al subirla (formato o tamaño) | Se rechaza en la UI antes de guardarla. |
| No se puede abrir el navegador | El post sigue `aprobado` y se muestra el error. |

Límites de texto validados: Instagram 2.200 caracteres de caption y 30 hashtags; LinkedIn 3.000 caracteres.

## 9. Pruebas

- **Swift (XCTest):** Store (CRUD y migraciones), máquina de estados de `post`, validaciones por red, codificación y decodificación del protocolo JSON-RPC.
- **Sidecar (Vitest):** cada herramienta contra una app simulada, y la construcción del system prompt. Hay un **modo agente falso** con respuestas guionadas, para probar la UI de punta a punta sin gastar tokens.
- **Compositores:** checklist manual por red antes de cada release (las redes no permiten pruebas automáticas estables contra producción).

## 10. Stack y estructura del repo

```
frontbot/
├── app/                 # Proyecto Xcode (XcodeGen: project.yml), Swift 6
│   ├── Sources/App/     # UI, Store, AgentClient, CredentialStore
│   └── Tests/
├── agent/               # Sidecar TypeScript (Node LTS)
│   ├── src/             # rpc, tools, composers/
│   └── test/
├── docs/
└── THIRD_PARTY_NOTICES.md
```

- SQLite mediante GRDB.swift (excepción justificada a "cero dependencias": migraciones y observación de cambios para la UI en vivo).
- Sidecar: `@anthropic-ai/claude-agent-sdk`. Opcionalmente usa Claude in Chrome (la extensión de Claude) en el Chrome del usuario.
- Requisito mínimo: macOS 14+. El notch es opcional: en Macs sin notch se muestra como panel bajo la barra de menú.
