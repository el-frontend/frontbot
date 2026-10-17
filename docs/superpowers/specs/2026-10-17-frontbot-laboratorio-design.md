# Frontbot: laboratorio de aprendizaje de los agentes (diseño)

**Fecha:** 2026-10-17 · **Estado:** en revisión con el usuario.
**Base:** `2026-10-16-frontbot-agentes-design.md` y `2026-10-17-frontbot-tareas-programadas-design.md`. Sus reglas siguen vigentes salvo lo que cambia aquí. Este diseño retira "Backtesting" de la lista de fuera de alcance del diseño de agentes.

## 1. Por qué

Hoy un agente solo puede "pensar con código" dentro de un skill:

- los scripts solo corren desde skills **activos**;
- cada ejecución pide aprobación;
- la sandbox solo lee la carpeta del skill.

Al iterar un backtest con el Crypto Trader, **cada cambio acabó siendo un skill nuevo**: `backtest-donchian-1h-4h`, `walkforward-donchian-4h-v2`… Además, los CSV quedaron copiados en cada uno. El usuario lo describió así: *"cada vez que cambiaba algo teníamos que crear un nuevo skill, eso no debería ser así"*.

**La idea:** cada agente tiene un **laboratorio** propio donde investiga, prueba, se equivoca y vuelve a probar con su propio criterio, sin pedir permiso. Un skill es conocimiento **graduado**: solo nace, o cambia, cuando el agente comprobó que funciona y el usuario lo aprueba.

## 2. Metas, no-metas y anti-metas

**Metas**

- Vale para **cualquier agente**, no solo trading: el trader prueba estrategias con backtests; uno de contenido estudia qué posts, hooks o carruseles funcionan mejor.
- **Regla general: aprender con evidencia, no con opiniones.** El agente busca datos que respalden cada conclusión y anota qué tan fuerte es esa evidencia.
- El agente decide qué estudiar, cómo y cuándo un tema está resuelto.
- Iterar no crea skills ni pide aprobaciones.
- Graduar (crear un skill o mejorar uno existente) sí pasa siempre por el usuario, con la evidencia a la vista.
- Gasto acotado y visible.

**No-metas (esta versión)**

- Leer métricas reales de LinkedIn o Instagram: hoy no hay integración de analítica. Cuando exista, entrará como fuente de solo lectura del laboratorio.
- Probar estrategias en la testnet de Hyperliquid desde el laboratorio. El usuario no lo confirmó; queda para después.
- Elegir modelo automáticamente fuera del laboratorio. En el chat el modelo lo elige el usuario (decisión suya).

**Anti-metas (sería un fracaso aunque funcione)**

- Que el laboratorio toque cuentas reales: wallets, trades, publicaciones o el Chrome con las sesiones del usuario.
- Un proceso que corre de fondo sin parar y quema tokens "por si acaso".
- Volver a llenar la biblioteca de skills a medio probar, o de versiones con sufijo `v2`.
- Que el usuario apruebe una mejora sin poder ver qué cambia ni por qué.

## 3. Decisiones (con el usuario)

| Tema | Decisión |
|---|---|
| Qué se aprueba siempre | Todo lo que toque dinero o salga al mundo: usar wallets, operaciones reales y publicar. En el laboratorio **nunca** se actúa sobre cuentas reales. |
| Criterio de éxito | Lo pone el agente: tiene libertad en su laboratorio. |
| Alcance | Todos los agentes. |
| Cuándo se estudia | Por su cuenta y lo decide el agente, pero **solo cuando hay algo concreto que aprender** (un tema de estudio), no como proceso permanente. |
| Límite de gasto | 150 000 tokens por sesión, 500 000 por agente al día y 3 temas abiertos por agente. Configurable por agente. |
| Modelos | Dentro del laboratorio el agente elige según la dificultad: Haiku para lo mecánico, Sonnet para razonar. Además aprende cuál le basta para cada tipo de paso. |
| Dónde se ve | Pestaña **Laboratorio** en la página de cada agente (opción A de la maqueta). |
| Graduar | El usuario respondió "avanza" a esta propuesta: skill nuevo o mejora de uno existente, con antes y después más la evidencia; historial de versiones con vuelta atrás; rechazar con comentario; aviso de macOS. |

## 4. Conceptos

- **Tema de estudio** (`labTopic`): una pregunta concreta, como "¿por qué pierde en mercados laterales?" o "¿qué portada de carrusel rinde mejor?".
  - Lo abre el agente cuando detecta un hueco, en cualquier run (chat, programado o estudio), o lo abre el usuario desde la UI.
  - Estados: `studying` → `paused` | `resolved` | `abandoned`; `resolved` → `graduated` al aprobarse una propuesta.
  - "Abiertos" son `studying` y `paused`, con un máximo de 3 por agente.
- **Sesión de estudio** (`labSession`): un run acotado del agente sobre un tema.
  - Al terminar, el agente decide el siguiente paso: seguir (otra sesión), pausar, resolver o abandonar.
- **Cuaderno** (`labEntry`): lo que el agente anota durante las sesiones.
  - Cada entrada tiene un tipo: `hypothesis`, `test`, `result`, `conclusion`, `model_note`, `feedback` (comentario del usuario al rechazar) o `note`.
  - Las conclusiones llevan evidencia (`weak` | `medium` | `strong`) y sus fuentes: URL, archivo del laboratorio o id de entrada.
- **Espacio de trabajo**: carpeta del agente donde escribe scripts y resultados libremente.
- **Datos compartidos**: almacén de datasets de solo lectura que pueden usar todos los labs. Así ningún CSV se copia por tema.
- **Propuesta de graduación** (`skillProposal`): skill nuevo o cambio a uno existente, con resumen de la evidencia. Solo el usuario la aprueba.

## 5. Arquitectura

No hay procesos nuevos. Cada lado tiene piezas nuevas:

```
App (Swift, FrontbotCore)                        Sidecar (Node)
├─ Lab/LabStore (SQLite: labTopic, labSession,    ├─ runner: modo "study" (prompt, herramientas,
│   labEntry, skillProposal, skillVersion)        │   subagentes por modelo, corte por tokens)
├─ Lab/LabScheduler (elige qué sesión toca;       ├─ lab.ts: herramientas lab_* → tool.lab.* en la app
│   usa el reloj de 60 s de las tareas)           └─ (sin cambios en hyperliquid/ ni browserGuard)
├─ Lab/LabSandbox (perfil sandbox-exec del lab)
├─ Lab/Datasets (descarga https a datasets/)
├─ Skills/SkillVersions (instantáneas + revertir)
└─ UI: pestaña Laboratorio, cuaderno, revisión
```

**Rutas** (en `AppPaths`, bajo `~/Library/Application Support/Frontbot/`):

- `labs/<agentId>/topics/<topicId>/`: espacio de trabajo del tema (scripts, resultados).
- `labs/<agentId>/shared/`: utilidades del agente reutilizables entre temas.
- `datasets/<nombre>/`: datos compartidos y su `meta.json` (origen, fecha, tamaño).
- `skills/.versions/<skill>/<n>/`: instantánea completa de cada versión aprobada.

## 6. Modelo de datos

```
labTopic      (id, agentId→agent cascade, question, why, origin agent|user, status, conclusion?,
               sessions int, tokensUsed int, nextSessionAfter?, createdAt, updatedAt)
labSession    (id, topicId→labTopic cascade, agentRunId?, status running|done|failed|cut,
               tokens int, models JSON [{model, tokens}], outcome continue|pause|resolve|abandon?,
               summary?, startedAt, finishedAt?)
labEntry      (id, topicId→labTopic cascade, sessionId?, kind, text, evidence weak|medium|strong?,
               sources JSON [string], model?, createdAt)
skillProposal (id, agentId, topicId?, kind new|update, skillName, description, body, files JSON,
               evidenceSummary, baseVersion int?, status pending|approved|rejected, comment?,
               createdAt, decidedAt?)
skillVersion  (id, skillId→skill cascade, number int, proposalId?, snapshotPath, createdAt)
agentLabSettings (agentId PK, sessionTokenCap=150000, dailyTokenCap=500000, maxOpenTopics=3,
               enabled bool=true, allowOpus bool=false)
```

- Los límites de texto (`question` 300, `text` de entrada 4000) los fija el builder y se validan en el repositorio.
- `skill` gana `version int`. **Cualquier cambio** sube la versión y guarda una instantánea: un `update` aprobado, una vuelta atrás o una edición del usuario desde la app (`saveManifest`, decisión del diseño). Así el historial muestra también las ediciones del usuario, que también se pueden revertir. El conflicto de la sección 11 se detecta comparando `baseVersion` con `version`. Los cambios hechos a mano en el disco, fuera de la app, no se detectan.

## 7. Cuándo corre una sesión

`LabScheduler` revisa en el mismo reloj de 60 s que las tareas programadas, solo con la app abierta. Lanza una sesión para el tema `studying` más antiguo que cumpla todo esto:

- el agente está `active` y su laboratorio `enabled`;
- `nextSessionAfter ≤ ahora`;
- el agente no superó `dailyTokenCap` en el día local, sumando sesiones `done`, `cut` y `failed`;
- no hay otra sesión de laboratorio corriendo **en toda la app** (una a la vez);
- no hay un run de chat activo del mismo agente.

Más reglas:

- Tras cada sesión con `continue`, `nextSessionAfter = ahora + 20 min`, para dar aire y no encadenar sin pausa.
- Al abrir un tema queda `nextSessionAfter = ahora`, así que se estudia en el siguiente tic si hay presupuesto.
- **Fallos** (decisión del diseño): tras una sesión `failed`, o `cut` por los 20 minutos o los 60 turnos, la espera crece: 20 min → 1 h → 4 h. Con 3 fallos seguidos, el tema pasa a `paused` y la pestaña muestra el motivo. Una sesión `done` reinicia el contador. El corte por tokens no cuenta como fallo.
- **Presupuesto restante:** el límite de corte de una sesión es el menor entre `sessionTokenCap` y lo que le queda al agente del día. No se lanza una sesión si quedan menos de 20 000 tokens.
- **Runs simultáneos del mismo agente** (decisión del diseño): una sesión no empieza si hay un chat activo de ese agente. Si el usuario abre un chat o vence una tarea programada durante una sesión, corren en paralelo, como hoy corren tareas y chat. SQLite serializa las escrituras de memoria y cuaderno. `lab_note` solo existe en `study`, así que el chat no escribe en el cuaderno del tema en curso.
- **Botones del usuario:** "Estudiar ahora" pone `nextSessionAfter = ahora`; "Pausar" lo pasa a `paused`. Desde la UI, un tema pausado puede reanudarse, y también el agente puede reanudarlo.

## 8. La sesión de estudio (modo `study` del sidecar)

**Prompt.** Lleva:

- la pregunta y el porqué;
- el cuaderno del tema, con las últimas N entradas completas y un resumen de las anteriores;
- las `model_note` del agente (de todos sus temas);
- la lista de datasets y los archivos del espacio de trabajo.

**Reglas del prompt:**

- nadie está mirando;
- no pidas aclaraciones;
- anota en el cuaderno **mientras** trabajas, no al final;
- cada conclusión lleva evidencia;
- termina llamando a `lab_end_session(outcome, summary)`.

**Herramientas disponibles:**

- Las `lab_*` (sección 9).
- WebSearch y WebFetch.
- Lectura: `skills_list`, `memory_list`, `memory_remember`; lectura de marcas y posts (listar y leer, nunca crear, editar ni publicar).
- Mercado de Hyperliquid (`market_price`, `market_candles`, `market_funding`, `market_book`), solo para agentes con trading activo. Son datos públicos y en el laboratorio se leen **siempre de mainnet**, aunque el agente opere en testnet (decisión del diseño: las velas de testnet no sirven como evidencia). Para esto se separan las herramientas de mercado del contexto de trading del run.

**Herramientas que no existen en este modo:** `trade_propose`, `account_state`, Chrome, escrituras en carpetas del usuario (`AgentFiles`), `skills_run_script`, `skills_create_draft` o `skills_update_draft` (se gradúa con `lab_propose_skill`), `schedule_*`, `agents_create_draft` y `notify_user`. El guardián de herramientas del sidecar las bloquea aunque el modelo las nombre.

**Modelos.** El hilo principal corre en **Sonnet**. Con la opción `agents` del Agent SDK se definen dos subagentes:

- `ayudante` (Haiku): descargar y ordenar datos, ejecutar y resumir pruebas, formatear notas, clasificar ejemplos;
- `analista` (Sonnet): un segundo razonamiento acotado.

El prompt explica cuándo delegar y pide registrar en una `model_note` cuando un modelo se quedó corto o sobró. Si `allowOpus` está activo (por defecto, no), el hilo principal puede pedir una sola consulta a Opus por sesión. El builder decide cómo exponerla: un subagente `experto` o un parámetro.

**Corte por tokens.**

- El sidecar suma el uso de cada mensaje del asistente, incluidos los subagentes, con esta métrica: `input + cache_creation + output + 0,1 × cache_read`. Es decisión del diseño: contar las lecturas de caché completas agotaría 150 000 en pocos turnos.
- Al llegar al 85 % del límite de sesión, inyecta un aviso para que el agente anote y cierre.
- Al 100 % interrumpe el run. La sesión queda `cut` con outcome `continue`.
- Otros límites: `maxTurns` 60 y 20 minutos de reloj.
- Como el agente anota sobre la marcha, cortar no pierde trabajo.

## 9. Herramientas `lab_*`

Las resuelve la app vía `tool.lab.*`. El sidecar inyecta `agent_id` y, en modo `study`, `topic_id` y `session_id`.

| Herramienta | Modos | Qué hace |
|---|---|---|
| `lab_open_topic(question, why)` | chat, scheduled, study | Abre un tema. Falla si ya hay 3 abiertos: el agente debe pausar o abandonar alguno. |
| `lab_list_topics()` | todos | Temas del agente con estado y conclusión. |
| `lab_resume_topic(id)` | todos | `paused` → `studying`. |
| `lab_note(kind, text, evidence?, sources?)` | study | Añade una entrada al cuaderno del tema en curso. |
| `lab_read_notebook(topicId?)` | todos | Lee el cuaderno; sin id, el del tema en curso. Sirve para reutilizar lo aprendido en otros temas. |
| `lab_write_file(path, content)` / `lab_read_file(path)` / `lab_list_files(dir?)` | study | Escritura dentro del espacio del tema o de `shared/`. Lectura también en `skills/<nombre>/` de los skills asignados al agente, con el prefijo `skill:<nombre>/…`. Rutas relativas, sin `..` ni enlaces que salgan. 1 MB por archivo y 200 MB por agente. |
| `lab_run(script, args[])` | study | Ejecuta en `LabSandbox` **sin aprobación**. Devuelve stdout, stderr y exit, recortados a 20 KB. Los archivos que escribe quedan en el espacio del tema. |
| `lab_list_datasets()` | todos | Nombre, descripción, archivos y tamaño. |
| `lab_fetch_dataset(name, urls[], description)` | study | La **app** descarga por https a `datasets/<name>/`. Solo GET, sin credenciales ni cookies; 500 MB por dataset y 2 GB en total. No ejecuta nada. Los datasets son **inmutables**: si el nombre ya existe, falla y el agente elige otro (por ejemplo, `btc-4h-2026-10`). `meta.json` guarda qué agente lo trajo. Solo el usuario los borra (decisión del diseño: así una conclusión nunca apunta a datos que cambiaron). |
| `lab_end_session(outcome, summary, conclusion?)` | study | Cierra la sesión. Con `resolve` exige `conclusion`. |
| `lab_propose_skill(kind, skillName, description, body, files?, evidenceSummary)` | study | Crea una `skillProposal` del tema en curso. Con `update`, el skill debe estar asignado al agente y se guarda `baseVersion`. Mismas validaciones que `skills_create_draft`: 20 archivos, 200 KB. |

**No existen** herramientas para aprobar propuestas, cambiar límites ni activar el laboratorio.

## 10. Sandbox del laboratorio (`LabSandbox`)

Es la misma base que `ScriptSandbox` (`sandbox-exec`, mismos intérpretes y la misma resolución segura de rutas), con otro perfil:

- **lee:** el sistema, `labs/<agentId>/` completo, `datasets/` y las carpetas de los skills asignados al agente (decisión del diseño: así reutiliza scripts de skills existentes);
- **escribe:** solo `labs/<agentId>/topics/<topicId>/`, `labs/<agentId>/shared/` y un temporal del run;
- **sin red**, como hoy: los datos entran solo con `lab_fetch_dataset`, que hace la app;
- **tiempo máximo:** 5 minutos, frente a los 60 s de los skills;
- **directorio de trabajo:** el espacio del tema.

**Librerías de Python.** El python3 del sistema puede no tener numpy ni pandas, y el builder debe comprobarlo. Si faltan, el laboratorio funciona con la biblioteca estándar. Opcionalmente, un botón **"Preparar entorno de Python"** en Ajustes crea, a pedido del usuario, un venv en `labs/.venv` con numpy y pandas, que `LabSandbox` usa si existe. La instalación la lanza el usuario, nunca el agente.

**Datos que ya existen.** En Ajustes → Laboratorio, el botón "Añadir carpeta como dataset" copia una carpeta del usuario a `datasets/`. Así se migran, por ejemplo, los CSV de BTC de `data/`.

## 11. Graduar un skill

**El agente propone** con `lab_propose_skill`. La app:

- guarda la propuesta `pending`;
- marca el tema `resolved`;
- lanza un aviso de macOS: "<agente> quiere graduar <skill>".

**El usuario revisa** en una hoja de revisión que muestra:

- el resumen de la evidencia y un enlace al cuaderno;
- para `new`, el `SKILL.md` y los archivos;
- para `update`, un antes y después por archivo, con diff por líneas, entre `baseVersion` y la propuesta.

**Si el skill cambió** después de `baseVersion` (por otra aprobación o una edición del usuario), la hoja lo indica y solo permite rechazar con el comentario "el skill cambió, vuelve a proponer".

**Aprobar:**

- `new` crea el skill `active`, `source = agent`, versión 1, asignado al agente.
- `update` toma una instantánea de la versión actual, escribe la nueva y sube `version`.
- El tema pasa a `graduated`.

**Rechazar** pide un comentario opcional. Se guarda como `labEntry` de tipo `feedback` y el tema vuelve a `studying`.

**Historial** en la página del skill: lista de versiones con fecha y propuesta de origen. "Volver a esta versión" restaura la instantánea, que se guarda a su vez como versión nueva.

Los borradores y `skills_create_draft` siguen existiendo para el chat. El laboratorio no los usa.

## 12. UI

**Pestaña Laboratorio** en la página del agente (maqueta A):

- Cabecera con los tokens de hoy frente al límite diario (barra) y los del mes.
- **Listo para graduar:** propuestas `pending`, con "Revisar y aprobar" y "Ver cuaderno".
- **Temas de estudio** (N/3): pregunta, estado, sesiones, tokens y la última conclusión parcial.
  - Acciones: "Estudiar ahora", "Pausar", "Reanudar" y "Abandonar".
  - Botón "Nuevo tema" para que el usuario plantee una pregunta.
- **Aprendido:** temas `resolved` o `graduated`, con su conclusión.
- Interruptor "Laboratorio activo" y los límites editables.

**Cuaderno** (al abrir un tema):

- entradas en orden, agrupadas por sesión;
- tipo y evidencia como etiqueta;
- fuentes como enlaces;
- por sesión: modelos usados y tokens;
- los archivos del espacio del tema, solo para ver.

**Otros sitios:**

- **Hoja de revisión** de propuestas (sección 11).
- **Página del skill:** historial de versiones.
- **Ajustes → Laboratorio:** datasets (lista, tamaño, borrar, añadir carpeta) y "Preparar entorno de Python".
- **Notch:** si hay una sesión en curso, "<agente> estudiando: <pregunta>".

## 13. Cambios en lo existente

- **Instrucciones de la plantilla Crypto Trader:** "cuando una estrategia funcione, guárdala como skill" pasa a "investiga y prueba en tu laboratorio; cuando tengas evidencia sólida, propón graduarla".
- **Prompt base de todos los agentes:** una línea sobre el laboratorio, `lab_open_topic` cuando detecten algo concreto que aprender y la regla de evidencia.
- **Skills de backtest que el agente ya creó:** no se migran. Siguen siendo skills activos. El agente puede reutilizarlos como punto de partida copiando su script al espacio de trabajo con `lab_write_file`.

## 14. Seguridad

- **Dinero y publicaciones:** el modo `study` no tiene ninguna herramienta que mueva dinero o publique. Las comprueba un test del sidecar que verifica la lista exacta de herramientas del modo.
- **Red:** solo la app la usa (`lab_fetch_dataset` y la búsqueda web del SDK). Los scripts del laboratorio no tienen red, así que no pueden exfiltrar nada.
- **Contenido de la web:** se trata como dato, no como instrucción. Se mantiene la regla del prompt actual.
- **Sin escalada:** ninguna herramienta permite al agente cambiar sus límites, aprobar propuestas ni activar nada.

## 15. Pruebas

Tests en `FrontbotCoreTests`:

- estados del tema;
- elección de `LabScheduler` (presupuesto, una sesión a la vez, `nextSessionAfter`);
- métrica de tokens;
- validación de rutas y tamaños del laboratorio;
- perfil de `LabSandbox` (escribir fuera, leer fuera del home, red);
- propuestas `new` y `update`, conflicto de `baseVersion`, instantáneas y vuelta atrás;
- límite de temas abiertos.

En el sidecar:

- la lista exacta de herramientas del modo `study`;
- el corte por tokens con mensajes de uso simulados.

## 16. Lo que se deja al builder

- División en fases y orden.
- Límites de texto y número de entradas del cuaderno en el prompt.
- Cómo exponer Opus cuando `allowOpus` está activo.
- Formato del diff y diseño visual fino, dentro del tema actual de la app.
- Si el venv opcional de Python entra en la primera fase o después.
