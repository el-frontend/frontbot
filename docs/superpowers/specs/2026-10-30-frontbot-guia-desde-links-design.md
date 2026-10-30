# Guía de marca desde links — diseño

Fecha: 2026-10-30. Primera de tres features de la "primera tanda" (después: imágenes generadas, métricas de posts).

## Intención

Crear la primera marca es el punto de más fricción para un usuario nuevo. Hoy el agente ya sabe leer una web y escribir la guía, pero solo como un prompt sugerido en el onboarding (`OnboardingView.swift`, `suggestions`). Queremos un camino propio, con botón, igual que "Entrevístame" y "Desde un PDF", que reciba **cualquier link** (web, Instagram, LinkedIn, Linktree, artículos…) y **recopile todo lo que pueda**: texto para la guía y también logo, colores y algunas fotos para los assets de la marca.

Éxito: un usuario pega su web y su Instagram, y en un par de minutos tiene una guía con ejemplos reales y su logo y fotos en la marca, sin haber escrito nada más.

## Objetivos

- Botón **"Desde links"** en la ficha de marca, junto a "Entrevístame" y "Desde un PDF".
- Acepta uno o varios links de cualquier tipo.
- El agente escribe la guía con las secciones de siempre más una de identidad visual, sin inventar.
- El agente importa logo y algunas fotos como assets de la marca.
- La marca recuerda sus links.
- El onboarding usa el mismo flujo.

## No objetivos

- Generar imágenes (es la feature siguiente).
- Leer métricas de los perfiles (feature 3).
- Volver a leer los links periódicamente o sincronizar la marca.
- Soportar SVG, video o PDFs enlazados como assets.

## Anti-objetivos (sería un fracaso aunque funcione)

- Una guía con tono, público o ejemplos inventados que el sitio no respalda.
- Reemplazar en silencio una guía que el usuario ya tenía.
- Llenar la marca de decenas de imágenes irrelevantes (iconos, banners de cookies, fotos de stock).
- Que la descarga de imágenes sirva para leer cosas de la red local o del Mac.

## Comportamiento

### Botón y hoja de links

- En `BrandDetailView.guideSection`, un tercer botón `OutlineButtonStyle` **"Desde links"**, deshabilitado mientras `model.isRunning` (igual que los otros dos).
- Abre una hoja pequeña con un campo de texto multilínea: "Pega uno o más links, uno por línea". Viene prellenado con los links guardados de la marca.
- Validación en la app: cada línea no vacía se normaliza (sin esquema → se antepone `https://`), y solo se aceptan `http`/`https` con host. Las líneas inválidas se marcan y no dejan continuar. Máximo 10 links.
- Al confirmar: se guardan los links en la marca y se llama a `model.guideFromLinks(_:)`, que hace lo mismo que `guideFromPDF`: vacía `messages`, pasa a `.chat` y envía `GuideSources.linksPrompt(brandName:links:hasGuide:)`.
- **Agentes que no pueden leer la web** *(llamada del diseño)*: los runs de Codex no tienen WebFetch ni navegador (`codex-runner.ts`), y los agentes `memoryOnly` no tienen WebFetch ni las herramientas `brands_*`. Si el agente seleccionado es de alguno de esos dos tipos, el botón queda deshabilitado con la ayuda "Este agente no puede leer la web; elige un agente de Claude". No se cambia de agente en silencio. En el onboarding, la sugerencia de crear la guía desde los links solo aparece si el agente por defecto puede leer la web; si no, se guardan los links igual.

### Prompt (`GuideSources.linksPrompt`)

Pide al agente, en este orden:

1. Leer cada link. Usar WebFetch para lo público. Si un link es un perfil de red o pide sesión y el navegador está disponible, usarlo. Si un link no se puede leer, decirlo y seguir con el resto.
2. Escribir la guía en markdown con las secciones de `GuideSources.sections` **más `## Identidad visual`** (colores en hex, tipografías si se ven, estilo de las fotos). En "Ejemplos" usar textos reales publicados, citados tal cual. Lo que no salga de los links queda como "(por definir)". No inventar.
3. Si `hasGuide` es verdadero, **antes de guardar** mostrar un resumen de lo nuevo y preguntar si reemplaza la guía actual; solo guardar si el usuario dice que sí.
4. Importar con `brands_import_image` el logo (`kind: logo`, como máximo 1) y hasta 8 fotos representativas (`kind: image`). Evitar iconos, banners, capturas de interfaz y fotos de stock.
5. Terminar con: qué salió de cada link, qué secciones quedaron "(por definir)" y qué imágenes se importaron.

La sección `## Identidad visual` también se añade a `GuideSources.sections`, para que la entrevista y el PDF la produzcan (con "(por definir)" si no hay datos).

### Herramienta nueva: `brands_import_image`

- Spec en `agent/src/tools.ts`: `{ brand_id: string, url: string, kind: "image" | "logo" }`. Descripción: descarga una imagen pública a los assets de la marca; devuelve el id del asset.
- Disponible en chat y en tareas programadas, igual que `brands_write_guide`. **No** está en el modo estudio (`STUDY_BASE`).
- La ejecuta la app (`ToolHandler`, `case "tool.brands_import_image"`) con un método nuevo `AssetImporter.importImage(fromRemote:brandId:kind:)`:
  - Solo `https` (y `http` se mejora a `https`). Se rechazan `localhost` y los nombres `.local`. *(Llamada del diseño:)* el host se resuelve y se rechaza si **cualquiera** de sus direcciones es privada, loopback, link-local, CGNAT (100.64/10), IPv6 ULA/link-local o IPv4 mapeada en IPv6. La comprobación se repite en cada redirección (delegado de `URLSession`). El riesgo que queda es el DNS rebinding entre la comprobación y la conexión: se acepta y no se fija la IP, porque es una app de escritorio local y la descarga solo puede guardar una imagen JPEG, PNG, WebP o GIF válida.
  - `URLSession` efímera, sin cookies, timeout de 20 s, máximo 8 MB (`maxImageBytes`), cortando la descarga si se pasa.
  - El tipo se detecta por los bytes, como hoy: JPEG y PNG se guardan tal cual; WebP y GIF se convierten a PNG con ImageIO (primer cuadro). Lo demás (SVG, HTML…) da un error claro al agente.
  - Se guarda con `store(_:ext:kind:brandId:)`. `kind: logo` usa `AssetKind.logo`, que ya existe.
  - Límite por marca y corrida: más de 1 logo o más de 8 imágenes en el mismo run devuelven error. *(Llamada del diseño: se cuenta por `run_id` en el `ToolHandler`.)*
- La descarga la hace la app y no el sandbox del agente, así que no pasa por la lista de dominios de la carpeta de trabajo. Esto es aceptable porque solo trae imágenes a la carpeta de la marca y aplica las protecciones de arriba.

### Dónde se ve el logo *(llamada del diseño)*

Hoy `AssetKind.logo` existe pero nada lo usa: la UI solo carga `kind: .image` y los posts solo aceptan imágenes como media.

- El logo más reciente de la marca reemplaza las iniciales en `BrandAvatar`, en todos los lugares donde aparece.
- En la sección de imágenes de la marca, el logo se muestra primero, con una etiqueta "Logo", y se puede borrar como cualquier imagen.
- Importar un logo nuevo no borra el anterior; se muestra siempre el más reciente.
- Los posts **no** aceptan el logo como media en esta versión (`Repositories.swift` no cambia).

### Respaldo de la guía *(llamada del diseño)*

La confirmación del prompt no basta para cumplir el anti-objetivo de no reemplazar una guía en silencio, porque cualquier run puede llamar a `brands_write_guide`. Por eso `BrandFiles.writeGuide` guarda la guía anterior en `guide.prev.md` antes de sobrescribirla, y la sección de la guía muestra **"Restaurar anterior"** cuando ese archivo existe. Así es como se aplica para cualquier escritura, no solo para "Desde links". La confirmación en el chat se mantiene como primera barrera.

### La marca guarda sus links

- Migración `v14-brand-links`: columna `links` (texto JSON, `[]` por defecto) en `brand`; `Brand.links: [String]`.
- Se escriben desde la hoja de links y desde el onboarding. No hay otro editor por ahora; la hoja hace de editor.
- `tool.brands_list` incluye `links`, para que el agente los conozca en otros pedidos.

### Onboarding

- El campo "Web (opcional)" pasa a ser **"Links (opcional)"** (web, Instagram, LinkedIn…), separados por espacios, comas o saltos de línea, con la misma validación.
- Al crear la marca se guardan en `Brand.links`.
- En el paso "¿Por dónde empezamos?", la primera sugerencia pasa a ser "Crear la guía de {marca} desde sus links". Al elegirla se ejecuta `guideFromLinks` (no un prompt de texto libre). El subtítulo del paso de marca se ajusta.

## Restricciones

- Se mantiene la regla de v1: ninguna herramienta publica nada. Esta solo escribe en la marca.
- Todo es local; las imágenes viven en `paths.assetsDir(brandId)`.
- Los textos nuevos de la UI se escriben en español (que son las claves) y se traducen en `app/Localization/en/`.
- El navegador es opcional: sin él, los perfiles que piden sesión se reportan como no leídos.

## Pruebas

- `AssetImporter`: rechaza esquemas que no sean http(s), hosts privados o locales, más de 8 MB y SVG; convierte WebP a PNG; guarda los logos como `logo`. Para no depender de la red, usar un `URLProtocol` falso.
- `ToolHandler`: límite por run de logo e imágenes; `brands_list` devuelve `links`.
- Migración v14 sobre una base v13 existente.
- `GuideSources.linksPrompt`: incluye todos los links y la instrucción de confirmar cuando `hasGuide`.
- Validación y normalización de links (sin esquema, inválidos, más de 10).
- Agente: `brands_import_image` está en chat y no en estudio.

## Queda a criterio del implementador

- El diseño exacto de la hoja de links (debe seguir los estilos de `Theme`).
- Los mensajes de error en español.
- Si la normalización de links vive en `FrontbotCore` (recomendado, para poder probarla) o en la vista.
