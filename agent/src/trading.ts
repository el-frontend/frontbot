// Herramientas de trading (Hyperliquid) para agentes con trading activado.
// Leer el mercado va directo al exchange; proponer un trade va a la app, que valida el mandato.
import { tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import type { AppCall } from "./tools.js";
import * as hl from "./hyperliquid/client.js";

export type Network = "testnet" | "mainnet";
export type RunTrading = {
  network: Network;
  address?: string;
  mandate: { mode: string; max_risk_pct: number; max_leverage: number; coins: string[]; max_trades_per_day: number; paused?: boolean };
};

/** Lo que se usa del exchange (inyectable en los tests). */
export type Market = {
  marketPrice(n: Network, coin: string): Promise<number>;
  candles(n: Network, coin: string, interval: string, count: number): Promise<unknown[]>;
  funding(n: Network, coin: string): Promise<unknown>;
  book(n: Network, coin: string): Promise<unknown>;
  accountState(n: Network, user: string): Promise<{ account_value: number } & Record<string, unknown>>;
};

export const realMarket: Market = {
  marketPrice: hl.marketPrice, candles: hl.candles, funding: hl.funding, book: (n, c) => hl.book(n, c), accountState: hl.accountState,
};

export const TRADING_TOOL_NAMES = ["market_price", "market_candles", "market_funding", "market_book", "account_state", "trade_propose"] as const;

const ok = (value: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(value) }] });
const fail = (message: string) => ({ isError: true, content: [{ type: "text" as const, text: message }] });
const coin = z.string().describe("Símbolo en Hyperliquid, p. ej. BTC o ETH");

export function buildTradingTools(call: AppCall, ctx: { agentId?: string; trading: RunTrading }, market: Market = realMarket) {
  const n = ctx.trading.network;
  const guarded = <A>(fn: (args: A) => Promise<unknown>) => async (args: A) => {
    try { return ok(await fn(args)); } catch (err) { return fail((err as Error).message); }
  };
  const needAddress = () => {
    if (!ctx.trading.address) throw new Error("El usuario aún no conecta su cuenta de Hyperliquid: pídele que conecte su API wallet en la página del agente.");
    return ctx.trading.address;
  };

  return [
    tool("market_price", "Precio medio actual de una moneda en Hyperliquid.", { coin },
      guarded(async ({ coin: c }: { coin: string }) => ({ coin: c.toUpperCase(), price: await market.marketPrice(n, c), network: n }))),
    tool("market_candles", "Velas OHLCV recientes. interval: 1m, 5m, 15m, 1h, 4h, 1d, 1w… count: hasta 500.",
      { coin, interval: z.string(), count: z.number().int().min(1).max(500) },
      guarded(async ({ coin: c, interval, count }: { coin: string; interval: string; count: number }) => ({ coin: c.toUpperCase(), interval, candles: await market.candles(n, c, interval, count) }))),
    tool("market_funding", "Funding por hora, open interest, precio mark/oráculo, volumen diario y apalancamiento máximo.", { coin },
      guarded(async ({ coin: c }: { coin: string }) => market.funding(n, c))),
    tool("market_book", "Libro de órdenes (10 niveles por lado).", { coin },
      guarded(async ({ coin: c }: { coin: string }) => market.book(n, c))),
    tool("account_state", "Valor de la cuenta, margen disponible y posiciones abiertas del usuario.", {},
      guarded(async () => market.accountState(n, needAddress()))),
    tool("trade_propose",
      "Propone un trade. Es la ÚNICA forma de operar. La app valida el mandato (stop loss obligatorio, riesgo, apalancamiento, monedas, trades por día). En modo aprobación el usuario decide; en modo automático la app lo ejecuta si cumple. Si se rechaza, lee los motivos y corrige.",
      {
        coin, side: z.enum(["long", "short"]), size_usd: z.number().positive().describe("Tamaño nocional en USD (sale de la fórmula de riesgo). En órdenes a mercado el riesgo incluye un deslizamiento de hasta el 10 % de la distancia al stop (máx. 0,5 %): dimensiona con ese margen."),
        leverage: z.number().int().min(1), entry_type: z.enum(["market", "limit"]), entry_price: z.number().positive().optional(),
        stop_loss: z.number().positive(), take_profit: z.number().positive().optional(),
        rationale: z.string().describe("Tesis, invalidación, confluencias y cálculo del tamaño"),
      },
      guarded(async (args: Record<string, unknown>) => {
        const c = String(args.coin).toUpperCase();
        // La foto del mercado la toma el sidecar: el modelo no puede inventar precio ni valor de cuenta.
        const [price, account] = await Promise.all([market.marketPrice(n, c), ctx.trading.address ? market.accountState(n, ctx.trading.address) : null]);
        const { coin: _c, side, size_usd, leverage, entry_type, entry_price, stop_loss, take_profit, rationale } = args;
        return call("tool.trade_propose", {
          agent_id: ctx.agentId, coin: c, side, size_usd, leverage, entry_type, entry_price, stop_loss, take_profit, rationale,
          snapshot: { price, account_value: account?.account_value ?? null, network: n },
        });
      })),
  ];
}
