# Frontbot: la mascota (diseño)

**Fecha:** 2026-10-16 · **Estado:** aprobado en conversación, sección a sección.
**Fuentes de diseño (fuera del repo):** `~/Downloads/frontbot.jpeg` (dibujo 2D, 1408×768, fondo blanco) y `~/Downloads/frontbot-meshy.glb` (modelo 3D de Meshy).

## Decisiones (con el usuario)

| Tema | Decisión |
|---|---|
| Dónde aparece | Icono de la app y logo; mascota 3D en el notch; mascota 3D en el chat. La bienvenida (onboarding) va en una spec aparte y reutiliza `MascotView`. |
| Expresividad | Solo movimientos del cuerpo entero, hechos en código (flotar, girar, inclinarse, rebotar, estirarse y aplastarse, brillo). Separar piezas (orejas, ojos) queda para después, sin rehacer la arquitectura. |
| Render | Convertir el modelo antes de compilar a USDZ y renderizarlo con RealityKit (`RealityView`). El mínimo de la app sube de macOS 14 a **macOS 15**. |

## El modelo de partida

El GLB tiene una sola malla rígida: 162.035 vértices, sin esqueleto, sin blend shapes y sin animaciones. Tiene un material con tres texturas WebP y usa `KHR_mesh_quantization`, `KHR_texture_transform` y `EXT_texture_webp`, que los frameworks de Apple no cargan. Por eso hay que convertirlo.

## Conversión (`scripts/mascot/`)

`convert.mjs <glb>` se ejecuta a mano cuando cambia el modelo, nunca durante la compilación. Usa `@gltf-transform` y sus dependencias, instaladas en `scripts/mascot/` (no en el sidecar).

1. Quita la cuantización y aplica `KHR_texture_transform` a las UV.
2. Pasa las texturas de WebP a 1024 px como máximo: color y metal/rugosidad en JPEG, relieve en PNG.
3. Simplifica la malla a unos 30.000 vértices, conservando las costuras de UV.
4. Centra el modelo en el origen y lo escala para que su caja mida 1. La cara mira a +Z.
5. Escribe USDA con material `UsdPreviewSurface` (color base, metal/rugosidad y relieve), lo convierte a `.usdc` con `usdcat` y lo empaqueta en `.usdz` con un empaquetador propio (`usdz.mjs`), porque ni `realitytool` ni `usdcat` generan USDZ desde glTF.
6. Genera `preview.png` (un render del resultado) para revisarlo a ojo.

**Salida:** `app/Sources/FrontbotApp/Resources/Mascot/frontbot.usdz`, que va en el repo. El GLB no se versiona.

**Si un paso falla**, el script se detiene con un mensaje claro y no sobrescribe el USDZ anterior.

**Límites del resultado:** menos de 3 MB y menos de 40.000 vértices.

## Logo e icono (`scripts/mascot/cutout.swift`)

Vision (`VNGenerateForegroundInstanceMaskRequest`) separa la mascota del fondo blanco de `frontbot.jpeg` y produce:

- `Resources/Mascot/logo.png`: la mascota recortada al contenido, con transparencia, a 512 px;
- `build/AppIcon.icns`: la mascota sobre un cuadrado redondeado con el fondo oscuro de la app, en todos los tamaños de `iconutil`. `scripts/build-app.sh` lo copia al bundle y declara `CFBundleIconFile`.

El logo sustituye al símbolo `rectangle.roundedtop`:

- en la cabecera de la barra lateral;
- en el notch;
- en el avatar del agente Frontbot (`isDefault`). Los demás agentes conservan su SF Symbol.

## Estados (FrontbotCore)

**`MascotState`:** `idle`, `listening`, `thinking`, `talking`, `happy`, `sad`.

**`MascotMood`** decide el estado a partir de eventos con hora, sin depender de la UI.

| Evento | Estado |
|---|---|
| Notch abierto o escribiendo en el composer | `listening` |
| Run iniciado | `thinking` |
| Llega texto del agente | `talking` (vuelve a `thinking` tras 1,5 s sin texto nuevo) |
| Run terminado bien | `happy` durante 2 s, luego `idle` |
| Run terminado con error o cancelado | `sad` durante 2 s, luego `idle` |
| Notch cerrado y sin run | `idle` |

**`MascotMotion`** es una función pura `pose(state, t, reduceMotion) -> MascotPose`. `MascotPose` contiene desplazamiento, rotación (yaw, pitch, roll), escala (x, y, z) e intensidad de brillo (0…1).

- `idle`: flota ±0,03 con un periodo de 4 s y un leve balanceo.
- `listening`: gira hacia la cámara e inclina la cabeza.
- `thinking`: oscila de un lado a otro y el brillo pulsa.
- `talking`: rebotes cortos.
- `happy`: salto con aplastado y estirado, y media vuelta.
- `sad`: se encoge y baja la mirada.

Cada animación cíclica empieza y acaba en la misma pose, para que no haya saltos. Con "Reducir movimiento" (`accessibilityReduceMotion`), la pose es fija y solo cambia el brillo.

## `MascotView` (FrontbotApp)

**Parámetros:** `state`, `size` y `animated`.

**Carga.** Carga `frontbot.usdz` una sola vez y comparte el recurso entre instancias. Si falla, muestra `logo.png` y lo registra en el log.

**Animación.** Aplica `MascotMotion` en cada fotograma solo mientras la vista es visible y el estado lo pide. En `idle` con "Reducir movimiento" o con `animated: false`, renderiza un fotograma y se detiene.

**Escena.** Luz fija suave y fondo transparente. El brillo de la pose regula una luz puntual cian delante del modelo (el material no tiene máscara de emisión: modular su emisión teñiría todo el cuerpo). La escena usa una luz ambiental basada en imagen generada en código; sin ella el blanco se ve gris.

## Dónde aparece

**Notch cerrado**
- Logo 2D de unos 20 pt a la izquierda.
- Mientras hay un run, `MascotView` pequeña en `thinking`, que pasa a `happy` o `sad` al terminar.

**Notch abierto**
- `MascotView` de 56 pt junto a la última respuesta, siguiendo los estados de `MascotMood`.

**Chat**
- **Conversación nueva con Frontbot:** `MascotView` de 140 pt sobre el texto de bienvenida, en `idle`, y `listening` mientras escribes.
- **Mientras responde:** la fila "pensando…" lleva una `MascotView` de 28 pt en `thinking` en lugar del `ProgressView`.
- Con los demás agentes no cambia nada.

**Límite.** Como mucho dos `MascotView` animadas a la vez: el notch abierto y una del chat.

## Pruebas

**`MascotMotion`**
- Los límites de cada estado.
- Que las animaciones cíclicas cierren el ciclo: la pose en `t` es la misma que en `t + periodo`.
- Que con "Reducir movimiento" la pose sea fija.
- Que la pose sea continua al pasar de un estado a otro.

**`MascotMood`**
- Las secuencias de eventos de la tabla, incluido el retorno a `idle` y la vuelta de `talking` a `thinking`.

**El recurso**
- Que `frontbot.usdz` exista en el bundle, cargue y cumpla los límites de tamaño y vértices.

**Los scripts**
- Se ejecutan con los archivos de `~/Downloads`. El usuario revisa a ojo `preview.png`, `logo.png` y el icono antes de seguir.

**Manual (usuario)**
- El icono en el Dock.
- El logo en la barra lateral.
- Los estados en el notch y en el chat.
- "Reducir movimiento".
- El consumo de CPU y GPU en reposo, en el Monitor de Actividad.

## Orden de construcción

1. Conversión del modelo y su vista previa (el mayor riesgo).
2. `MascotState`, `MascotMood`, `MascotMotion` y `MascotView`. Subir el mínimo a macOS 15.
3. Recorte, logo e icono.
4. Notch.
5. Chat.

## Fuera de alcance

- La bienvenida (spec propia).
- Piezas separadas, parpadeo, orejas móviles y rig.
- Sonidos.
- Mascotas para los demás agentes.
- Generar la mascota con IA.
