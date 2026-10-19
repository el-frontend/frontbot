# Frontbot: carpeta de trabajo en el chat (diseño)

**Fecha:** 2026-10-18 · **Estado:** borrador para revisión del usuario; incluye sus respuestas sobre lectura y red.
**Base:** `2026-10-13-frontbot-design.md`, `2026-10-16-frontbot-agentes-design.md`.

## Por qué

El usuario quiere que un agente haga tareas reales en su Mac como Claude Code: por ejemplo, generar un vídeo con HTML + HyperFrames (escribir archivos, `npx hyperframes …`, renderizar).

Hoy no puede:
- los agentes solo tienen `files_*` (texto, en carpetas autorizadas, cada escritura con aprobación);
- no tienen terminal: las herramientas de Claude Code (`Bash`, `Write`, `Edit`, `Glob`, `Grep`) están apagadas para todos.

## Decisiones (con el usuario)

| Tema | Decisión |
|---|---|
| Dónde se activa | En el chat, eligiendo una carpeta. Ahí se abre una sesión de Claude Code (herramientas reales del SDK) con esa carpeta como directorio de trabajo. |
| Permisos dentro de la carpeta | **Carta blanca**: leer, buscar, crear, editar, borrar y ejecutar comandos dentro de la carpeta sin preguntar. |
| Lectura fuera de la carpeta | **Solo** la carpeta de trabajo, `~/Downloads` y las carpetas de lectura que el usuario añada explícitamente. Nada más del usuario, tampoco desde comandos. |
| Red de los comandos | **Lista de sitios** (cambiado por el usuario el 2026-10-19 tras ver que la sandbox bloquea todo sin lista): npm, GitHub, jsDelivr, unpkg, Google Fonts y lo estrictamente necesario para el render de HyperFrames. Un sitio fuera de la lista falla y el agente lo dice. |
| Permisos fuera de la carpeta | Se piden al usuario (ver §Permisos). |

## Decisiones mías (el usuario puede corregirlas)

Van marcadas *(mía)*.

## Qué ve el usuario

- **Botón "Carpeta"** en la barra del composer, junto a agente, marca y modelo *(mía)*.
  - Sin carpeta muestra `📁 Carpeta`; con carpeta, el nombre de la carpeta (ruta completa en el tooltip).
  - Al pulsarlo se abre un `NSOpenPanel` para elegir una carpeta, y aparece "Quitar carpeta" si ya hay una.
- **La carpeta es de la conversación** *(mía)*:
  - se guarda con ella y se restaura al volver a abrirla;
  - una conversación nueva empieza sin carpeta;
  - mientras el agente responde no se puede cambiar.
- **Sin carpeta, el chat funciona exactamente como hoy.**
- **Con carpeta**, en el hilo:
  - las llamadas a herramientas se ven como hoy (`✓ Bash · npm install`, `✓ Write · index.html`), mostrando el comando o el archivo *(mía)*;
  - "Detener" corta la sesión y mata los procesos que haya lanzado.
- **Dónde funciona** *(mía)*:
  - solo en conversaciones con alguien mirando: chat principal y notch;
  - nunca en tareas programadas, laboratorio ni resúmenes, porque nadie podría aprobar lo de fuera.
- **Botón para abrir la carpeta en Finder** junto al chip *(mía)*, para ver el vídeo resultante.
- **Carpetas de lectura extra:**
  - el menú del chip tiene "Añadir carpeta de lectura…" (`NSOpenPanel`);
  - son de la conversación, como la carpeta de trabajo, y se pueden quitar desde el mismo menú;
  - `~/Downloads` está siempre incluida y no se quita *(mía)*.

## Herramientas

Con carpeta, el run del sidecar añade las herramientas integradas de Claude Code:
- `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Bash`;
- `TodoWrite`, para tareas largas *(mía)*.

Configuración del run:
- `cwd` = la carpeta;
- `maxTurns` sube de 30 a 150 *(mía: un render con iteraciones necesita muchas vueltas)*;
- el system prompt añade una sección: "Trabajas en la carpeta X. Dentro tienes carta blanca. Puedes leer también ~/Downloads y [carpetas extra]. Fuera de eso no tienes acceso; si necesitas un archivo de otro sitio, pídele al usuario que lo añada como carpeta de lectura o que lo copie a la carpeta."

Todo lo demás sigue igual:
- las herramientas `mcp__frontbot__*`;
- el navegador con su guardián;
- los skills;
- trading con sus aprobaciones.

Publicar, operar con wallets y trades reales siguen **sin** ninguna vía nueva: carta blanca en la carpeta no autoriza nada de eso.

## Permisos

**Dentro de la carpeta** (ruta real resuelta, sin `..` ni enlaces simbólicos que salgan):
- `Read`/`Write`/`Edit`/`Glob`/`Grep`: permitido sin preguntar.
- `Bash`: permitido sin preguntar, siempre ejecutado en la **sandbox del SDK** (`sandbox.enabled`, `autoAllowBashIfSandboxed: true`). `allowUnsandboxedCommands: true` solo para que exista la vía de excepción de abajo: todo comando pedido sin sandbox (`dangerouslyDisableSandbox`) pasa siempre por la hoja de aprobación, nunca se autoriza solo.
  - **Escritura** de los comandos: solo la carpeta de trabajo, más los temporales y cachés que necesitan npm/npx (`~/.npm`, `TMPDIR`) *(mía)*.
  - **Lectura** de los comandos (decisión del usuario):
    - la carpeta de trabajo, `~/Downloads` y las carpetas de lectura extra;
    - más lo imprescindible para que corran las herramientas, no datos del usuario: sistema (`/usr`, `/bin`, `/System`, `/Library`, `/opt/homebrew`, `/private/etc`…), las apps que use el render (p. ej. `/Applications/Google Chrome.app`), el Node de la app, `~/.nvm`, `~/.npm`, `~/.cache` y temporales.
    - El resto de `~` (Documents, Desktop, Pictures, otras carpetas) queda bloqueado para lectura desde comandos.
    - La lista exacta la ajusta el constructor hasta que el render funcione, sin añadir carpetas de datos del usuario.
  - Así "dentro de la carpeta" se cumple también para comandos, no solo para las herramientas de archivos.

**Red de los comandos** (decisión del usuario, 2026-10-19): **lista de sitios** en `sandbox.network.allowedDomains`: `registry.npmjs.org`, `*.npmjs.org`, `github.com`, `*.github.com`, `*.githubusercontent.com`, `cdn.jsdelivr.net`, `unpkg.com`, `fonts.googleapis.com`, `fonts.gstatic.com`, más los dominios que el render de HyperFrames necesite de verdad (anotados). Fuera de la lista, la petición falla.
- **La lista es de cada agente** (decisión del usuario, 2026-10-19):
  - se edita en la página del agente, en una sección "Sitios de red" junto a sus carpetas;
  - un agente nuevo o sin cambios usa la lista base de arriba;
  - "Restaurar" vuelve a ella.
  - Cada entrada es un dominio (`ejemplo.com`) o un comodín de subdominio (`*.ejemplo.com`); nunca `*` solo.

**Fuera de la carpeta**:
- **Lectura** con `Read`/`Glob`/`Grep`:
  - permitida sin preguntar en `~/Downloads` y en las carpetas de lectura extra;
  - en cualquier otra ruta, denegada con el mensaje "Fuera de tus carpetas: pide al usuario que la añada como carpeta de lectura".
  - No hay hoja de aprobación para lecturas sueltas: el usuario las autoriza añadiendo la carpeta *(mía, para que lectura con herramientas y con comandos tengan la misma regla)*.
- **Escritura** con `Write`/`Edit` fuera de la carpeta de trabajo (también en Downloads y en las de lectura) abre una hoja de aprobación con la ruta y el contenido o diff.
  - Opciones *(mía)*:
    - **Permitir una vez**;
    - **Permitir en esta conversación** (esa ruta exacta);
    - **Denegar**.
  - Denegar devuelve al modelo "El usuario lo denegó; no insistas".

**Siempre denegado, aunque esté dentro de la carpeta elegida** *(mía)*:
- `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/Library/Keychains`;
- la carpeta de datos de Frontbot (`~/Library/Application Support/Frontbot`: base de datos, claves);
- los perfiles de Chrome.

Se aplica a las herramientas de archivos (hook) y a `Bash` (lectura denegada en la sandbox). Las rutas siempre denegadas ganan también a `~/Downloads` y a las carpetas de lectura extra. Si el usuario elige como carpeta (de trabajo o de lectura) su `~` entero o `/`, la app lo rechaza y pide una carpeta concreta *(mía)*.

**Comprobado (Tarea 3):** el render de HyperFrames no puede correr en la sandbox (macOS bloquea `setpriority`/`uptime`), así que cada render pide esta aprobación.

**Si un comando no puede correr en la sandbox** (p. ej. el Chrome headless del render de HyperFrames lo bloquea) *(mía)*:
- no se desactiva la sandbox en general;
- el agente puede pedir ejecutar **ese comando** sin sandbox, y eso abre la hoja de aprobación con el comando exacto (una vez / denegar, sin "siempre").

## Detalles resueltos *(mías, tras la revisión)*

- **`files_*` y la carpeta son independientes.**
  - Las carpetas autorizadas del agente siguen dando `files_*` como hoy.
  - La carpeta de trabajo no las amplía ni las quita.
  - El botón "Carpeta" está disponible para cualquier agente, tenga o no carpetas autorizadas.
- **Notch:**
  - no tiene selector;
  - una conversación con carpeta que se continúa desde el notch la hereda;
  - las aprobaciones se muestran donde hoy salen las de scripts y escrituras.
- **Aprobaciones:**
  - de una en una, en cola;
  - sin tiempo límite: el run espera;
  - "Detener" deniega lo pendiente y corta.
- **Hook de `Read`:** el guardián de skills y el de la carpeta se combinan. Un `Read` se permite si lo permite cualquiera de los dos; las rutas siempre denegadas ganan a ambos.
- **Carpetas amplias:**
  - se rechazan `/`, `~` y ancestros de las rutas siempre denegadas;
  - `~/Documents`, `~/Desktop` y similares se aceptan, con un aviso en la hoja de selección recomendando una subcarpeta del proyecto.

## Implementación (orientación, no plan)

- **Sidecar** (`agent/src/runner.ts`), al construir las opciones con `params.workdir`:
  - `cwd`, `tools` + `allowedTools` con las integradas;
  - `sandbox`;
  - un hook `PreToolUse` decide dentro/fuera/denegado. Con carpeta, `permissionMode` pasa a `default` con un `canUseTool` que niega todo salvo el comando sin sandbox recién aprobado (verificado en Tarea 3: bajo `dontAsk` el SDK lo negaba igual);
  - las preguntas viajan a la app por el mismo canal JSON-RPC que hoy usan `askScriptApproval`/`askFileWriteApproval`.
- **App**:
  - columna `workdir` en `conversation` (migración);
  - el chip en `ChatView`;
  - `AppModel` pasa `workdir` en el run y muestra la hoja de aprobación nueva (reutiliza el estilo de las hojas de script/escritura);
  - "permitir en esta conversación" vive en memoria del run, no en la base de datos.
- **Info.plist**: nada nuevo; la app no está en App Sandbox.
- **Validación** de la carpeta en la app y otra vez en el sidecar:
  - existe;
  - es directorio;
  - no es `~` ni `/` ni ancestro de las rutas siempre denegadas.

## Fuera de alcance

- Varias carpetas a la vez.
- Que las tareas programadas o el laboratorio usen carpetas.
- Terminal interactiva visible para el usuario.
- Ver el vídeo dentro de Frontbot (se abre en Finder/QuickTime).

## Para el constructor

- Comprobar en el SDK 0.3.296 cómo se configuran la red y la escritura de la sandbox y si `canUseTool` llega para lecturas fuera de `cwd`. Si algo de §Permisos no se puede expresar tal cual, elegir lo más cercano que **no** dé más permiso, y anotarlo.
- Probar de punta a punta un render real de HyperFrames dentro de la sandbox antes de dar la función por terminada.
