import Foundation

/// Skills iniciales que instala una plantilla de agente (activos y revisables por el usuario).
enum TemplateSkills {
    struct Seed { let name: String; let description: String; let body: String }

    static func skills(for templateId: String?) -> [Seed] {
        templateId == AgentTemplate.cryptoTrader.id ? [analisisTecnico, gestionDeRiesgo, tradingView] : []
    }

    static let analisisTecnico = Seed(
        name: "analisis-tecnico",
        description: "Método de análisis técnico para cripto: estructura, niveles, patrones y confluencia. Úsalo siempre que analices un gráfico o busques una entrada.",
        body: """
        # Análisis técnico

        Sigue estos pasos en orden y anota la conclusión de cada uno.

        ## 1. Contexto de temporalidades
        - Empieza en la temporalidad mayor (1D o 4H) para definir la tendencia, y baja a la de ejecución (1H o 15m) para el timing.
        - Opera a favor de la tendencia mayor salvo que haya una ruptura de estructura confirmada.

        ## 2. Estructura de mercado
        - Alcista: máximos y mínimos crecientes (HH/HL). Bajista: LH/LL. Lateral: rango con techo y piso claros.
        - Ruptura de estructura (BOS): el precio cierra más allá del último swing en la dirección de la tendencia.
        - Cambio de carácter (CHoCH): primer cierre contra la estructura; avisa, no confirma.

        ## 3. Niveles
        - Soportes y resistencias: zonas con varios toques o donde el precio reaccionó con volumen; trázalas como zonas, no líneas.
        - Niveles redondos, máximos y mínimos del día, de la semana y del mes anterior.
        - Rupturas: espera el cierre y, mejor, el retesteo del nivel roto.

        ## 4. Patrones
        - Continuación: banderas, triángulos, cuñas a favor de la tendencia.
        - Reversión: doble techo y doble suelo, hombro-cabeza-hombro, divergencias en el RSI en extremos.
        - Velas: envolventes, pin bars y martillos solo cuentan **en un nivel**, nunca en medio de la nada.

        ## 5. Indicadores (confirmación, no señal)
        - EMA 20/50/200: tendencia y soporte dinámico.
        - RSI 14: sobrecompra/sobreventa y divergencias.
        - Volumen: las rupturas válidas vienen con volumen creciente.
        - Funding y open interest (datos de Hyperliquid): un funding muy positivo con OI subiendo indica longs apalancados en riesgo.

        ## 6. Confluencia y decisión
        - Exige al menos 3 factores alineados (p. ej. tendencia + nivel + patrón de vela + volumen).
        - Define primero la **invalidación**: el precio que demuestra que la idea es incorrecta. El stop va ahí.
        - Si no hay confluencia o la relación riesgo/beneficio es menor a 1:2, la conclusión es "no hay trade".

        ## Formato de salida
        Tendencia mayor · estructura · niveles clave · patrón · confluencias (lista) · invalidación · escenario alcista y bajista con probabilidades aproximadas · conclusión.
        """)

    static let gestionDeRiesgo = Seed(
        name: "gestion-de-riesgo",
        description: "Reglas de gestión de riesgo y fórmula de tamaño de posición para perpetuos. Úsalo antes de proponer cualquier trade.",
        body: """
        # Gestión de riesgo

        ## Reglas
        - **Siempre stop loss.** Sin stop no hay trade.
        - Riesgo por trade: el `maxRiskPct` del mandato (por defecto 1 % de la cuenta). Nunca más.
        - Relación riesgo/beneficio mínima 1:2. Calcula el take profit desde los niveles, no al revés.
        - Apalancamiento: el mínimo que permita el tamaño; nunca más del máximo del mandato. El apalancamiento no cambia el riesgo si el tamaño sale de la fórmula, pero acerca el precio de liquidación.
        - Comprueba que el precio de liquidación quede claramente más allá del stop.
        - Tras dos pérdidas seguidas en el día, propone parar.

        ## Fórmula de tamaño
        ```
        riesgo_usd   = valor_cuenta × riesgo_pct
        distancia    = |entrada − stop| / entrada
        tamaño_usd   = riesgo_usd / distancia          (nocional de la posición)
        margen_usd   = tamaño_usd / apalancamiento
        ```
        Ejemplo: cuenta 1.000 USD, riesgo 1 % → 10 USD. Entrada 60.000, stop 58.800 → distancia 2 %. Tamaño = 10 / 0,02 = 500 USD nocional. Con 3x, margen ≈ 167 USD.

        **Órdenes a mercado:** la app suma un deslizamiento de hasta el 10 % de la distancia al stop (máx. 0,5 %). Usa `distancia × 1,1` (o `distancia + 0,005` si la distancia supera el 5 %) en la fórmula. En el ejemplo: 10 / 0,022 ≈ 454 USD.

        ## Antes de llamar a trade_propose
        1. Lee el valor de la cuenta con account_state.
        2. Calcula el tamaño con la fórmula y redondea hacia abajo.
        3. Verifica: stop del lado correcto (long: stop < entrada; short: stop > entrada), R:R ≥ 2, apalancamiento ≤ mandato.
        4. En `rationale` explica la tesis, la invalidación y la cuenta del tamaño.
        """)

    static let tradingView = Seed(
        name: "tradingview",
        description: "Cómo leer y manejar TradingView en el Chrome del usuario: cambiar símbolo y temporalidad, añadir indicadores y leer el gráfico. Úsalo cuando el usuario mencione un gráfico abierto o TradingView.",
        body: """
        # TradingView en el Chrome del usuario

        ## Leer lo que el usuario ve
        1. `tabs_context_mcp` para encontrar la pestaña de TradingView (tradingview.com/chart).
        2. `computer` con la acción `screenshot` para ver el gráfico. Describe símbolo, temporalidad, indicadores visibles y dibujos del usuario.
        3. `get_page_text` o `read_page` para datos de la leyenda (OHLC, valores de indicadores) si no se leen bien en la captura.

        ## Manejar el gráfico
        - Cambiar símbolo: clic en el nombre del símbolo arriba a la izquierda, escribe el ticker (p. ej. `BTCUSDT` o `BINANCE:ETHUSDT`) y Enter.
        - Cambiar temporalidad: escribe el número directamente sobre el gráfico (`4` + Enter → 4 minutos; `240` → 4h; `1D` → diario) o usa el selector de la barra superior.
        - Añadir indicador: botón "Indicadores" (o `/`), busca por nombre (RSI, EMA, Volume) y elígelo.
        - Desplazar y hacer zoom: scroll sobre el gráfico.
        - Antes de cada clic o tecla, vuelve a llamar a `tabs_context_mcp` (lo exige el sistema).

        ## Reglas
        - No borres ni muevas los dibujos del usuario; si necesitas los tuyos, avisa.
        - No cambies la configuración de la cuenta de TradingView ni sus alertas sin pedirlo.
        - TradingView es para analizar: **nunca** operes desde el navegador. Los trades solo se proponen con trade_propose.
        - Contrasta lo que ves en la captura con los datos de market_candles: la captura puede ser de otro exchange o temporalidad.
        """)
}
