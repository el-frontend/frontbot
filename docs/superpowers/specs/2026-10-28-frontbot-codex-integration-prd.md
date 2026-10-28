# PRD: Integración de Codex en Frontbot

**Fecha:** 2026-10-28  
**Estado:** Para revisión y aprobación del usuario  
**Producto:** Frontbot para macOS

## 1. Resumen

Frontbot permitirá asignar Claude o Codex como proveedor de IA por agente. Ajustes permitirá configurar las credenciales disponibles de cada proveedor. La integración de Codex usará Codex app-server y conservará el protocolo JSON-RPC existente entre la app Swift y el sidecar Node.

El usuario podrá autenticar Codex mediante la sesión local de Codex CLI o mediante una API key de OpenAI guardada en Keychain. La selección de proveedor en Ajustes solo permitirá administrar la configuración de cada cuenta; el proveedor que ejecuta un agente se elegirá en la página de ese agente.

## 2. Problema

Hoy Frontbot depende de Claude Agent SDK. La autenticación de Claude se configura en Ajustes como sesión de Claude Code o API key de Anthropic, y el modelo se configura por agente. El usuario quiere incorporar Codex y poder elegir qué proveedor usa cada agente, sin perder el chat, las herramientas propias ni los controles de Frontbot.

## 3. Usuarios y necesidades

- **Usuario de Frontbot:** quiere elegir el modelo/proveedor que mejor encaje con cada agente y usar su sesión de Codex o su API key.
- **Frontbot:** debe conservar la propiedad de sus datos, herramientas, aprobaciones, interfaz y ciclo de vida de ejecuciones.

## 4. Objetivos

1. Permitir Claude o Codex por agente y recordar la selección.
2. Configurar en Ajustes las credenciales disponibles de ambos proveedores.
3. Ejecutar agentes Codex con streaming, continuidad de conversación y cancelación desde Frontbot.
4. Mantener disponibles para Codex las herramientas de Frontbot que formen parte del alcance de esta versión.
5. Respetar los controles existentes de acceso a archivos, ejecución de comandos y aprobaciones.
6. Conservar el comportamiento actual de Claude y migrar agentes existentes a Claude sin cambios visibles.

## 5. Fuera de alcance

- Reemplazar Claude Agent SDK o eliminar el sidecar actual.
- Cambiar la UI principal del chat o el almacenamiento de conversaciones de Frontbot.
- Replicar en Codex la extensión Claude in Chrome. La opción «Usar mi Chrome» seguirá siendo exclusiva de Claude y se explicará cuando el agente use Codex.
- Incorporar la integración Codex a las sesiones experimentales del Laboratorio en esta primera entrega; estas seguirán usando el flujo Claude actual y no deberán cambiar de proveedor silenciosamente.
- Cambiar la autenticación, modelos o permisos de Claude.
- Añadir proveedores distintos de Claude y Codex.

## 6. Experiencia propuesta

### Ajustes

- Reemplazar la sección exclusiva de Claude por una sección **Proveedores de IA**.
- Usar un selector compartido Claude/Codex para elegir qué credenciales se muestran y editan. Este selector no cambia el proveedor de ningún agente.
- En Claude, conservar el estado de sesión de Claude Code y la opción de guardar una API key de Anthropic.
- En Codex, mostrar el estado de la sesión local de Codex CLI, instrucciones para iniciar sesión si no existe una sesión utilizable, y un campo opcional para guardar una API key de OpenAI.
- Guardar las API keys en Keychain. Mostrar estado de credencial presente/ausente sin volver a revelar el valor.
- Permitir reemplazar o eliminar la API key guardada.

### Configuración del agente

- Añadir **Proveedor** a Configuración en la página de cada agente, antes del selector de modelo.
- Filtrar la lista de modelos según el proveedor y validar la combinación al guardar.
- Al cambiar de proveedor, conservar el modelo seleccionado si pertenece a ese proveedor; si no, seleccionar su modelo predeterminado.
- Si falta autenticación para el proveedor elegido, indicar el problema en la configuración y ofrecer acceso a Ajustes. Los runs deben fallar con un mensaje claro si el problema se descubre al ejecutarlos.
- Agentes existentes y agentes nuevos usan Claude por defecto.
- En agentes Codex, desactivar o explicar la indisponibilidad de la función Claude in Chrome.

## 7. Requisitos funcionales

### RF-1: Proveedor persistente por agente

Cada registro de agente guardará el identificador del proveedor (`claude` o `codex`). La base de datos se migrará asignando `claude` a los registros existentes. La selección se conserva al reiniciar Frontbot.

### RF-2: Configuración de credenciales

Las credenciales pertenecen al workspace actual, siguiendo el patrón de `CredentialStore`. Las API keys se normalizan y almacenan en Keychain; no se guardan en SQLite, preferencias, logs ni archivos del sidecar. El usuario puede actualizar o borrar cada key.

Para Codex, Frontbot debe reconocer la sesión local de Codex CLI cuando esté disponible y aceptar una API key de OpenAI configurada desde Ajustes. Si la sesión CLI no está disponible y no hay API key, la UI mostrará el paso necesario para conectar la cuenta.

### RF-3: Enrutamiento de ejecución

El sidecar elegirá el runtime según el proveedor del agente y mantendrá el contrato actual `agent.run`, `agent.event`, `agent.done` y `agent.cancel` con la app Swift. Los chats interactivos y las tareas programadas asociadas a un agente respetarán su proveedor.

### RF-4: Codex app-server

El runtime Codex usará Codex app-server como proceso local controlado por el sidecar. Debe inicializar una conversación, iniciar turnos, traducir eventos de texto/actividad a los eventos actuales de Frontbot y soportar interrupción. No debe depender de la UI interactiva de Codex CLI.

### RF-5: Herramientas y permisos

El agente Codex debe poder invocar las herramientas Frontbot incluidas en el alcance mediante una integración MCP local. Las llamadas a herramientas conservarán el flujo de validación y respuesta a través de la app Swift. El runtime Codex no debe ampliar los permisos existentes ni omitir las aprobaciones para comandos y escrituras fuera de la carpeta de trabajo.

### RF-6: Modelos y uso

El selector de modelos presentará únicamente modelos compatibles con el proveedor. El registro de uso mostrará los tokens y costos cuando el runtime los proporcione. Frontbot no inventará un costo cuando Codex no exponga un valor comparable.

### RF-7: Compatibilidad de funciones

- Las herramientas propias de Frontbot que se usan en chat y tareas programadas se mantienen disponibles con ambos proveedores.
- Trading seguirá sujeto a las reglas y aprobaciones de Frontbot; la integración no ejecutará operaciones directamente desde Codex.
- El navegador Claude in Chrome es exclusivo de Claude. Al seleccionar Codex, la UI lo hará explícito y el sidecar no expondrá esa herramienta.
- El Laboratorio experimental queda en Claude en esta entrega.

### RF-8: Errores

La app distinguirá, como mínimo, falta de CLI/app-server, falta de sesión o API key, credencial inválida, error de arranque, fallo del turno, cancelación y desconexión del proceso. Los mensajes no expondrán secretos. Un fallo de Codex no debe dejar un run activo o una conversación bloqueada.

## 8. Requisitos no funcionales

- **Seguridad:** API keys solo en Keychain y en memoria del proceso durante su uso; no heredarlas de la shell salvo que el flujo existente de Frontbot lo requiera expresamente y esté documentado.
- **Aislamiento:** `AgentClient` seguirá siendo dueño del proceso del sidecar y de la comunicación con Swift. El sidecar aislará los detalles de proveedor mediante runtimes separados.
- **Compatibilidad:** los agentes guardados y conversaciones existentes no requieren configuración manual ni migración externa.
- **Confiabilidad:** cancelar un run debe detener el turno Codex y liberar el estado de Frontbot; fallos del proceso deben cerrar los runs asociados.
- **Privacidad:** los mensajes y el historial se enviarán al proveedor del agente de esa ejecución, no a otro proveedor por fallback automático.

## 9. Arquitectura de referencia

```text
Frontbot Swift
  ├─ SettingsView / AgentDetailView
  ├─ SQLite: provider en Agent
  ├─ CredentialStore (Keychain)
  └─ AgentClient ── JSON-RPC stdio ──► frontbot-agent (Node)
                                         ├─ ClaudeRunner (actual)
                                         └─ CodexRunner ── stdio RPC ──► Codex app-server
                                         └─ herramientas Frontbot vía MCP local
```

La app Swift seguirá siendo dueña de SQLite, archivos, aprobaciones y herramientas. El sidecar enrutará la ejecución. Codex app-server gestionará el turno de Codex; una capa adaptadora convertirá su protocolo a los eventos de Frontbot. La conexión de herramientas debe permitir que el runtime llame a las herramientas Frontbot manteniendo el puente de aprobación actual.

La selección de proveedor se persistirá en el agente. Las credenciales se mantendrán por workspace y proveedor. La interfaz de Ajustes permitirá administrarlas de forma independiente.

## 10. Criterios de aceptación

1. Un agente existente continúa usando Claude tras actualizar la app.
2. El usuario puede asignar Claude o Codex a cada agente y la selección persiste tras reiniciar Frontbot.
3. Cambiar la selección de proveedor en Ajustes no modifica la configuración de los agentes.
4. Con sesión Codex CLI o API key válida, un agente Codex puede completar un chat con texto en streaming y herramientas Frontbot.
5. El usuario puede cancelar un turno Codex desde Frontbot, y el estado del chat/run queda cerrado correctamente.
6. Las tareas programadas ejecutadas por un agente Codex usan Codex; las del agente Claude siguen usando Claude.
7. Las acciones de archivos/comandos mantienen las mismas aprobaciones y límites efectivos de Frontbot.
8. La API key de OpenAI se guarda y elimina desde Keychain, y nunca aparece en UI después de guardarse ni en logs/SQLite.
9. Sin una credencial Codex válida, Frontbot muestra cómo resolverlo y no cambia automáticamente a Claude.
10. La interfaz informa que Claude in Chrome y el Laboratorio no están disponibles para agentes Codex en esta entrega.
11. Fallos de inicio, autenticación o turno Codex no bloquean la ejecución posterior de Claude ni dejan runs colgados.

## 11. Riesgos y validaciones técnicas

- Codex app-server tiene un protocolo distinto del Agent SDK de Claude; es necesario validar el ciclo de vida, eventos de streaming, cancelación y recuperación ante cierre del proceso.
- Frontbot expone hoy herramientas MCP dentro del proceso Claude SDK. Para Codex será necesaria una integración MCP local compatible con app-server, manteniendo el puente de llamadas a Swift y las aprobaciones.
- La experiencia de autenticación mediante la sesión Codex CLI y la API key debe validarse con la versión de Codex CLI que se empaquete o detecte.
- Los datos de costos/uso pueden tener semántica distinta entre proveedores; la UI debe evitar comparar valores no equivalentes.
- Los modelos y capacidades cambian con el tiempo; el catálogo debe centralizarse por proveedor para facilitar su actualización.

## 12. Referencias

- [Codex como plataforma: `codex exec`, SDK y app-server](https://developers.openai.com/blog/codex-as-a-platform)
- [Codex CLI: inicio de sesión con plan de ChatGPT o API key](https://github.com/openai/codex#using-codex-with-your-chatgpt-plan)
- [App-server: protocolo, threads, turnos y eventos](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)
- [API de OpenAI: autenticación con API key](https://developers.openai.com/api/reference/overview)

## 13. Revisión requerida

Este PRD refleja las decisiones conversadas: proveedor por agente, credenciales en Ajustes, diseño de selector compartido para administrar credenciales y Codex app-server como runtime. Revisar especialmente el alcance de herramientas y funciones no compatibles (Claude in Chrome y Laboratorio) antes de aprobar. El plan de implementación se redactará después de la aprobación de este PRD.
