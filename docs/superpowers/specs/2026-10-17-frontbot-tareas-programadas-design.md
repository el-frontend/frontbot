# Frontbot: tareas programadas (diseño)

**Fecha:** 2026-10-17 · **Estado:** aprobado en conversación ("empieza").
**Base:** `2026-10-16-frontbot-agentes-design.md`.

## Decisiones (con el usuario)

| Tema | Decisión |
|---|---|
| Dónde corren | Reloj dentro de la app. Frontbot arranca al iniciar sesión (`SMAppService`, interruptor en Ajustes) y sigue en el notch sin ventana. Lo que se perdió por sueño o app cerrada corre **una sola vez** al volver. |
| Resultados | Cada ejecución queda en el historial de la tarea. Solo si el agente llama a `notify_user` o propone un trade, llega un aviso de macOS y la ejecución se guarda como conversación (🕒 en Recientes). Al tocar el aviso se abre esa conversación. |
| Quién crea tareas | El usuario, desde la página del agente o la sección Programadas, y los agentes con `schedule_create_draft`. Lo que crea un agente queda en **borrador** y solo el usuario lo activa. |

## Modelo

```
scheduledTask (id, agentId→agent cascade, name, instruction, schedule JSON, model, status draft|active|paused,
               maxRunsPerDay, lastRunAt?, nextRunAt?, createdByAgentId?, createdAt, updatedAt)
taskRun       (id, taskId→scheduledTask cascade, agentRunId?, status running|done|failed|skipped, summary?,
               notified bool, conversationId?, costUsd, startedAt, finishedAt?)
```

**Frecuencia (`Schedule`)**
- `interval(minutes ≥ 15)`;
- `daily(hh:mm)`;
- `weekly(días, hh:mm)`;
- ventana opcional (desde, hasta) para los intervalos.

`next(after:)` es pura y se calcula en el calendario local.

## Reloj

Revisa cada 60 s, al arrancar la app y al despertar el Mac. Una tarea está pendiente si cumple todo esto:

- está `active` y su agente también;
- `nextRunAt ≤ ahora`;
- no tiene otra ejecución `running`;
- no superó `maxRunsPerDay` en el día local.

Al lanzarla, `nextRunAt = next(after: ahora)`. Así, lo que se perdió corre una sola vez.

## Ejecución

- El run es igual que uno del chat: herramientas, skills, memoria, navegador y trading del agente.
- Lleva el modo `scheduled`. El prompt le dice que nadie está mirando, que no pida aclaraciones y que use `notify_user` solo si hay algo importante.
- `notify_user(title, message)` solo existe en este modo. El sidecar inyecta el `run_id`.
- Los trades siguen el mandato: en modo aprobación quedan pendientes y avisan; en automático se ejecutan si cumplen.
- Los scripts muestran la hoja de aprobación y un aviso de macOS. Si no hay respuesta en 120 s, cuentan como denegados.

## Herramientas

- **Todos los agentes:** `schedule_list` (sus tareas), `schedule_create_draft` y `schedule_update_draft` (solo borradores propios).
- **Solo en runs programados:** `notify_user`.
- No hay herramienta para activar, pausar ni borrar tareas.

## UI

- **Página del agente:** sección "Tareas programadas" con estado, próxima ejecución, activar/pausar, ejecutar ahora, editar, borrar e historial.
- **Barra lateral:** "Programadas" con todas las tareas y un contador de borradores.
- **Notch:** "Próxima: <agente> · hh:mm".
- **Ajustes:** "Abrir Frontbot al iniciar sesión".
- **Plantilla Crypto Trader:** crea "Revisión de mercado cada 4 h" en borrador.

## Fuera de alcance

- Modo launchd.
- Disparadores por evento (precio o noticias).
