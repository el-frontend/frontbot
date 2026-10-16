// Acceso real a Hyperliquid: lectura de mercado/cuenta (pública) y envío de órdenes firmadas con la API wallet.
import { HttpTransport, InfoClient, ExchangeClient } from "@nktkas/hyperliquid";
import { privateKeyToAccount } from "viem/accounts";
import { buildBracket, formatPrice, formatSize } from "./format.js";
import { executeBracket, type Exchange, type ExecuteResult, type OrderStatus } from "./execute.js";

export type Network = "testnet" | "mainnet";
const INTERVALS = ["1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "8h", "12h", "1d", "3d", "1w", "1M"] as const;
export type Interval = (typeof INTERVALS)[number];
const INTERVAL_MS: Record<string, number> = { m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000, M: 2_592_000_000 };

const transport = (network: Network) => new HttpTransport({ isTestnet: network === "testnet", timeout: 15_000 });
const info = (network: Network) => new InfoClient({ transport: transport(network) });

const num = (s: string | null | undefined) => (s == null ? null : Number(s));

export async function assetOf(network: Network, coin: string) {
  const meta = await info(network).meta();
  const asset = meta.universe.findIndex((u) => u.name === coin.toUpperCase());
  if (asset < 0) throw new Error(`${coin} no existe en Hyperliquid (${network}).`);
  return { asset, szDecimals: meta.universe[asset].szDecimals, maxLeverage: meta.universe[asset].maxLeverage };
}

export async function marketPrice(network: Network, coin: string): Promise<number> {
  const mids = await info(network).allMids();
  const px = Number(mids[coin.toUpperCase()]);
  if (!(px > 0)) throw new Error(`No hay precio para ${coin} en Hyperliquid (${network}).`);
  return px;
}

export async function candles(network: Network, coin: string, interval: string, count: number) {
  if (!INTERVALS.includes(interval as Interval)) throw new Error(`Intervalo inválido: ${interval}. Usa ${INTERVALS.join(", ")}.`);
  const n = Math.min(Math.max(Math.floor(count), 1), 500);
  const unit = INTERVAL_MS[interval.slice(-1)] * Number(interval.slice(0, -1) || 1);
  const endTime = Date.now();
  const data = await info(network).candleSnapshot({ coin: coin.toUpperCase(), interval: interval as Interval, startTime: endTime - unit * n, endTime });
  return data.slice(-n).map((c) => ({ t: new Date(c.t).toISOString(), o: num(c.o), h: num(c.h), l: num(c.l), c: num(c.c), v: num(c.v) }));
}

export async function funding(network: Network, coin: string) {
  const [meta, ctxs] = await info(network).metaAndAssetCtxs();
  const i = meta.universe.findIndex((u) => u.name === coin.toUpperCase());
  if (i < 0) throw new Error(`${coin} no existe en Hyperliquid.`);
  const c = ctxs[i];
  return { coin: coin.toUpperCase(), funding_hourly: num(c.funding), open_interest: num(c.openInterest), mark_price: num(c.markPx),
    oracle_price: num(c.oraclePx), premium: num(c.premium), day_volume_usd: num(c.dayNtlVlm), max_leverage: meta.universe[i].maxLeverage };
}

export async function book(network: Network, coin: string, depth = 10) {
  const b = await info(network).l2Book({ coin: coin.toUpperCase() });
  if (!b) throw new Error(`No hay libro de órdenes para ${coin}.`);
  const side = (levels: { px: string; sz: string; n: number }[]) => levels.slice(0, depth).map((l) => ({ px: Number(l.px), sz: Number(l.sz), orders: l.n }));
  return { bids: side(b.levels[0]), asks: side(b.levels[1]) };
}

export async function accountState(network: Network, user: string) {
  const s = await info(network).clearinghouseState({ user: user as `0x${string}` });
  return {
    account_value: Number(s.marginSummary.accountValue),
    withdrawable: Number(s.withdrawable),
    positions: s.assetPositions.map(({ position: p }) => ({
      coin: p.coin, size: Number(p.szi), entry_price: num(p.entryPx), unrealized_pnl: Number(p.unrealizedPnl),
      leverage: p.leverage.value, liquidation_price: num(p.liquidationPx), position_value: Number(p.positionValue),
    })),
  };
}

export async function openOrders(network: Network, user: string) {
  const orders = await info(network).frontendOpenOrders({ user: user as `0x${string}` });
  return orders.map((o) => ({ coin: o.coin, oid: o.oid, side: o.side === "B" ? "buy" : "sell", size: Number(o.sz), limit_price: Number(o.limitPx),
    trigger_price: o.isTrigger ? Number(o.triggerPx) : null, type: o.orderType, reduce_only: o.reduceOnly }));
}

function exchangeFor(network: Network, privateKey: string): Exchange {
  const key = (privateKey.startsWith("0x") ? privateKey : `0x${privateKey}`) as `0x${string}`;
  const client = new ExchangeClient({ transport: transport(network), wallet: privateKeyToAccount(key) });
  return {
    updateLeverage: (args) => client.updateLeverage(args),
    order: async (args) => ({ statuses: (await client.order(args)).response.data.statuses as OrderStatus[] }),
    cancel: (args) => client.cancel(args),
  };
}

export type ExecuteParams = {
  network: Network; private_key: string; coin: string; side: "long" | "short"; size_usd: number; leverage: number;
  entry_type: "market" | "limit"; entry_price?: number; stop_loss: number; take_profit?: number;
};

/** Entrada + stop loss (+ take profit) en una sola acción `normalTpsl`. */
export async function executeTrade(p: ExecuteParams): Promise<ExecuteResult & { size: string; reference_price: number }> {
  const [{ asset, szDecimals, maxLeverage }, refPrice] = await Promise.all([assetOf(p.network, p.coin), marketPrice(p.network, p.coin)]);
  if (p.leverage > maxLeverage) throw new Error(`${p.coin} admite como máximo ${maxLeverage}x en Hyperliquid.`);
  const bracket = buildBracket({ asset, szDecimals, refPrice, slippage: 0.03, side: p.side, sizeUsd: p.size_usd, entryType: p.entry_type,
    entryPrice: p.entry_price, stopLoss: p.stop_loss, takeProfit: p.take_profit });
  const result = await executeBracket(exchangeFor(p.network, p.private_key), bracket, p.leverage);
  return { ...result, size: bracket.size, reference_price: refPrice };
}

/** Cierra la posición de `coin` a mercado (solo reducir) y cancela sus órdenes pendientes (stop / take profit). */
export async function closePosition(p: { network: Network; private_key: string; address: string; coin: string }) {
  const coin = p.coin.toUpperCase();
  const [{ asset, szDecimals }, state, refPrice, orders] = await Promise.all([
    assetOf(p.network, coin), accountState(p.network, p.address), marketPrice(p.network, coin), openOrders(p.network, p.address),
  ]);
  const ex = exchangeFor(p.network, p.private_key);
  const position = state.positions.find((x) => x.coin === coin && x.size !== 0);
  let closed = false;
  if (position) {
    const isBuy = position.size < 0; // un short se cierra comprando
    await ex.order({
      orders: [{ a: asset, b: isBuy, p: formatPrice(refPrice * (isBuy ? 1.05 : 0.95), szDecimals), s: formatSize(Math.abs(position.size), szDecimals), r: true, t: { limit: { tif: "Ioc" } } }],
      grouping: "na",
    });
    closed = true;
  }
  const mine = orders.filter((o) => o.coin === coin);
  if (mine.length) await ex.cancel({ cancels: mine.map((o) => ({ a: asset, o: o.oid })) });
  return { closed, cancelled_orders: mine.length };
}
