// Envío de la orden con su stop loss. Nunca deja una posición abierta sin stop.
import { formatPrice, formatSize, type Bracket, type OrderWire } from "./format.js";

export type OrderStatus = { resting: { oid: number } } | { filled: { totalSz: string; avgPx: string; oid: number } } | { error: string } | string;

/** Lo mínimo del ExchangeClient que se usa (para poder probarlo con uno falso). */
export interface Exchange {
  updateLeverage(args: { asset: number; isCross: boolean; leverage: number }): Promise<unknown>;
  order(args: { orders: OrderWire[]; grouping: "na" | "normalTpsl" }): Promise<{ statuses: OrderStatus[] }>;
  cancel(args: { cancels: { a: number; o: number }[] }): Promise<unknown>;
}

export type ExecuteResult = {
  status: "open" | "resting" | "failed";
  orderIds: number[];
  filledSize?: string;
  avgPrice?: string;
  error?: string;
};

const errorOf = (s: OrderStatus | undefined) => (typeof s === "object" && s && "error" in s ? s.error : undefined);
const stopAccepted = (s: OrderStatus | undefined) => s !== undefined && errorOf(s) === undefined;

/** Las respuestas de error del SDK traen los estados originales: hacen falta para saber si la entrada se llenó. */
function statusesFromError(err: unknown): OrderStatus[] | undefined {
  const r = (err as { response?: { response?: { data?: { statuses?: OrderStatus[] } } } })?.response;
  return r?.response?.data?.statuses;
}

/** `stopExists`: si el exchange no devolvió el estado del stop (sin error explícito), se comprueba en sus órdenes abiertas. */
export async function executeBracket(ex: Exchange, bracket: Bracket, leverage: number, stopExists?: () => Promise<boolean>): Promise<ExecuteResult> {
  try {
    await ex.updateLeverage({ asset: bracket.asset, isCross: false, leverage });
  } catch (err) {
    return { status: "failed", orderIds: [], error: `No se pudo fijar el apalancamiento: ${(err as Error).message}` };
  }

  let statuses: OrderStatus[];
  let orderError: string | undefined;
  try {
    statuses = (await ex.order({ orders: bracket.orders, grouping: bracket.grouping })).statuses;
  } catch (err) {
    const fromError = statusesFromError(err);
    if (!fromError) return { status: "failed", orderIds: [], error: (err as Error).message };
    statuses = fromError;
    orderError = (err as Error).message;
  }

  const entry = statuses[0];
  const entryError = errorOf(entry);
  if (entryError || !entry || typeof entry === "string") {
    return { status: "failed", orderIds: [], error: entryError ?? orderError ?? "La entrada no se aceptó." };
  }
  let stopOk = stopAccepted(statuses[1]);
  if (!stopOk && statuses[1] === undefined && stopExists) stopOk = await stopExists().catch(() => false);

  if ("filled" in entry) {
    const { totalSz, avgPx, oid } = entry.filled;
    if (stopOk) return { status: "open", orderIds: [oid], filledSize: totalSz, avgPrice: avgPx };
    const why = errorOf(statuses[1]) ?? "sin respuesta";
    // Cerrar a mercado lo llenado; un IOC puede llenarse en parte, así que se reintenta con lo que quede.
    let remaining = Number(totalSz);
    let lastError = "";
    const closePx = bracket.refPrice * (bracket.isBuy ? 0.95 : 1.05);
    for (let attempt = 0; attempt < 3 && remaining > 0; attempt++) {
      try {
        const r = await ex.order({
          orders: [{ a: bracket.asset, b: !bracket.isBuy, p: formatPrice(closePx, bracket.szDecimals), s: formatSize(remaining, bracket.szDecimals), r: true, t: { limit: { tif: "Ioc" } } }],
          grouping: "na",
        });
        const s = r.statuses[0];
        if (typeof s === "object" && s && "filled" in s) remaining = Math.max(0, Number((remaining - Number(s.filled.totalSz)).toFixed(10)));
        else lastError = errorOf(s) ?? "sin llenado";
      } catch (err) {
        lastError = (err as Error).message;
      }
    }
    if (remaining <= 0) {
      return { status: "failed", orderIds: [oid], filledSize: totalSz, avgPrice: avgPx, error: `El stop loss fue rechazado (${why}); la posición quedó cerrada a mercado.` };
    }
    return { status: "failed", orderIds: [oid], filledSize: totalSz, avgPrice: avgPx,
      error: `URGENTE: el stop loss fue rechazado (${why}) y quedan ${formatSize(remaining, bracket.szDecimals)} sin cerrar (${lastError}). Ciérrala a mano en Hyperliquid.` };
  }

  // Entrada límite en el libro.
  if (!("resting" in entry)) return { status: "failed", orderIds: [], error: "Respuesta inesperada del exchange." };
  const oid = entry.resting.oid;
  if (stopOk) return { status: "resting", orderIds: [oid] };
  try { await ex.cancel({ cancels: [{ a: bracket.asset, o: oid }] }); } catch { /* se informa abajo */ }
  return { status: "failed", orderIds: [oid], error: `El stop loss fue rechazado (${errorOf(statuses[1]) ?? "sin respuesta"}); la orden de entrada se canceló.` };
}

/** Cierra a mercado hasta quedar en cero; solo entonces cancela el stop y el take profit. */
export async function closeFully(deps: { position(): Promise<number>; closeIoc(size: number): Promise<void>; cancelOrders(): Promise<void> }) {
  let closes = 0;
  for (let attempt = 0; attempt < 4; attempt++) {
    const size = Math.abs(await deps.position());
    if (size === 0) {
      await deps.cancelOrders();
      return { closed: true, attempts: closes };
    }
    if (attempt === 3) break;
    await deps.closeIoc(size);
    closes++;
  }
  const left = Math.abs(await deps.position());
  throw new Error(`La posición sigue abierta (${left} sin cerrar); su stop loss sigue activo. Reintenta o ciérrala en Hyperliquid.`);
}

