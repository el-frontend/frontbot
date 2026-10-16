// Reglas de formato de Hyperliquid para perpetuos y armado de la orden entrada + stop loss (+ take profit).

const strip = (s: string) => (s.includes(".") ? s.replace(/0+$/, "").replace(/\.$/, "") : s);

/** Máximo 5 cifras significativas y (6 − szDecimals) decimales; los enteros siempre valen. */
export function formatPrice(px: number, szDecimals: number): string {
  if (!(px > 0)) throw new Error("Precio inválido.");
  if (px >= 100_000) return String(Math.round(px));
  const maxDecimals = Math.max(0, 6 - szDecimals);
  const sig = Number(px.toPrecision(5));
  return strip(sig.toFixed(maxDecimals));
}

/** Redondea hacia abajo a szDecimals (nunca más tamaño del calculado). */
export function formatSize(sz: number, szDecimals: number): string {
  const f = 10 ** szDecimals;
  return strip((Math.floor(sz * f + 1e-9) / f).toFixed(szDecimals));
}

export type OrderWire = {
  a: number; b: boolean; p: string; s: string; r: boolean;
  t: { limit: { tif: "Gtc" | "Ioc" } } | { trigger: { isMarket: boolean; triggerPx: string; tpsl: "tp" | "sl" } };
};

/** Deslizamiento máximo de una entrada a mercado: 10 % de la distancia al stop, tope 0,5 % (igual que la app). */
export function marketSlippage(entry: number, stop: number): number {
  return entry > 0 ? Math.min(0.005, (0.1 * Math.abs(entry - stop)) / entry) : 0;
}

export type BracketInput = {
  asset: number; szDecimals: number; refPrice: number;
  side: "long" | "short"; sizeUsd: number; entryType: "market" | "limit"; entryPrice?: number;
  stopLoss: number; takeProfit?: number;
};

export type Bracket = { asset: number; isBuy: boolean; refPrice: number; szDecimals: number; size: string; orders: OrderWire[]; grouping: "normalTpsl" };

/** Hyperliquid rechaza órdenes de menos de 10 USD de valor. */
export const MIN_ORDER_USD = 10;
/** Holgura del precio límite de las órdenes trigger a mercado. */
const TRIGGER_SLIPPAGE = 0.1;

export function buildBracket(i: BracketInput): Bracket {
  if (!(i.stopLoss > 0)) throw new Error("Una orden sin stop loss no se envía.");
  const isBuy = i.side === "long";
  const entryPx = i.entryType === "market" ? i.refPrice : i.entryPrice;
  if (!entryPx || entryPx <= 0) throw new Error("Falta el precio de entrada.");
  // Con el precio de ahora, el stop debe seguir del lado correcto (si no, se dispararía al instante).
  if (isBuy ? i.stopLoss >= entryPx : i.stopLoss <= entryPx) {
    throw new Error(`El stop loss (${i.stopLoss}) ya no está del lado correcto de la entrada (${entryPx}): vuelve a analizar.`);
  }
  const slippage = marketSlippage(entryPx, i.stopLoss);
  const size = formatSize(i.sizeUsd / entryPx, i.szDecimals);
  if (Number(size) * entryPx < MIN_ORDER_USD) throw new Error(`El tamaño queda por debajo del mínimo de Hyperliquid (${MIN_ORDER_USD} USD).`);

  const px = (p: number) => formatPrice(p, i.szDecimals);
  const entry: OrderWire = i.entryType === "market"
    ? { a: i.asset, b: isBuy, p: px(i.refPrice * (isBuy ? 1 + slippage : 1 - slippage)), s: size, r: false, t: { limit: { tif: "Ioc" } } }
    : { a: i.asset, b: isBuy, p: px(entryPx), s: size, r: false, t: { limit: { tif: "Gtc" } } };
  const exit = (trigger: number, tpsl: "tp" | "sl"): OrderWire => ({
    a: i.asset, b: !isBuy, s: size, r: true,
    p: px(trigger * (isBuy ? 1 - TRIGGER_SLIPPAGE : 1 + TRIGGER_SLIPPAGE)),
    t: { trigger: { isMarket: true, triggerPx: px(trigger), tpsl } },
  });
  const orders = [entry, exit(i.stopLoss, "sl")];
  if (i.takeProfit && i.takeProfit > 0) orders.push(exit(i.takeProfit, "tp"));
  return { asset: i.asset, isBuy, refPrice: i.refPrice, szDecimals: i.szDecimals, size, orders, grouping: "normalTpsl" };
}
