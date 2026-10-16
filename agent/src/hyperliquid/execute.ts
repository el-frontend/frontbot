// Envío de la orden con su stop loss. Nunca deja una posición abierta sin stop.
import { formatPrice, type Bracket, type OrderWire } from "./format.js";

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

export async function executeBracket(ex: Exchange, bracket: Bracket, leverage: number): Promise<ExecuteResult> {
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
  const stopOk = stopAccepted(statuses[1]);

  if ("filled" in entry) {
    const { totalSz, avgPx, oid } = entry.filled;
    if (stopOk) return { status: "open", orderIds: [oid], filledSize: totalSz, avgPrice: avgPx };
    const why = errorOf(statuses[1]) ?? "sin respuesta";
    try {
      const closePx = bracket.refPrice * (bracket.isBuy ? 0.95 : 1.05);
      await ex.order({
        orders: [{ a: bracket.asset, b: !bracket.isBuy, p: formatPrice(closePx, bracket.szDecimals), s: totalSz, r: true, t: { limit: { tif: "Ioc" } } }],
        grouping: "na",
      });
      return { status: "failed", orderIds: [oid], filledSize: totalSz, avgPrice: avgPx, error: `El stop loss fue rechazado (${why}); la posición quedó cerrada a mercado.` };
    } catch (err) {
      return { status: "failed", orderIds: [oid], filledSize: totalSz, avgPrice: avgPx,
        error: `URGENTE: el stop loss fue rechazado (${why}) y no se pudo cerrar la posición (${(err as Error).message}). Ciérrala a mano en Hyperliquid.` };
    }
  }

  // Entrada límite en el libro.
  if (!("resting" in entry)) return { status: "failed", orderIds: [], error: "Respuesta inesperada del exchange." };
  const oid = entry.resting.oid;
  if (stopOk) return { status: "resting", orderIds: [oid] };
  try { await ex.cancel({ cancels: [{ a: bracket.asset, o: oid }] }); } catch { /* se informa abajo */ }
  return { status: "failed", orderIds: [oid], error: `El stop loss fue rechazado (${errorOf(statuses[1]) ?? "sin respuesta"}); la orden de entrada se canceló.` };
}
