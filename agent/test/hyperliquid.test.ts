import { describe, it, expect } from "vitest";
import { formatPrice, formatSize, buildBracket, marketSlippage } from "../src/hyperliquid/format.js";
import { executeBracket, closeFully, type Exchange } from "../src/hyperliquid/execute.js";

describe("format", () => {
  it("prices: max 5 significant figures and 6 - szDecimals decimals; integers allowed", () => {
    expect(formatPrice(60123.456, 5)).toBe("60123");
    expect(formatPrice(123456.7, 5)).toBe("123457");
    expect(formatPrice(3456.789, 4)).toBe("3456.8");
    expect(formatPrice(1.234567, 2)).toBe("1.2346");
    expect(formatPrice(0.000123456, 0)).toBe("0.000123");
  });

  it("sizes round down to szDecimals", () => {
    expect(formatSize(0.0123456, 5)).toBe("0.01234");
    expect(formatSize(2.999, 0)).toBe("2");
  });
});

describe("buildBracket", () => {
  const base = { asset: 0, szDecimals: 5, refPrice: 60_000 };

  it("market long: IOC entry with slippage plus reduce-only SL and TP triggers", () => {
    const b = buildBracket({ ...base, side: "long", sizeUsd: 600, entryType: "market", stopLoss: 58_800, takeProfit: 63_000 });
    expect(b.size).toBe("0.01");
    const [entry, sl, tp] = b.orders;
    expect(entry).toMatchObject({ a: 0, b: true, p: "60120", s: "0.01", r: false, t: { limit: { tif: "Ioc" } } });
    expect(sl).toMatchObject({ b: false, r: true, s: "0.01", t: { trigger: { isMarket: true, triggerPx: "58800", tpsl: "sl" } } });
    expect(tp).toMatchObject({ b: false, r: true, t: { trigger: { isMarket: true, triggerPx: "63000", tpsl: "tp" } } });
    expect(b.grouping).toBe("normalTpsl");
  });

  it("limit short without take profit: GTC entry and only the stop", () => {
    const b = buildBracket({ ...base, side: "short", sizeUsd: 600, entryType: "limit", entryPrice: 61_000, stopLoss: 62_000 });
    expect(b.orders).toHaveLength(2);
    expect(b.orders[0]).toMatchObject({ b: false, p: "61000", t: { limit: { tif: "Gtc" } } });
    expect(b.orders[1]).toMatchObject({ b: true, r: true, t: { trigger: { tpsl: "sl", triggerPx: "62000" } } });
  });

  it("refuses orders below Hyperliquid's 10 USD minimum or without a stop", () => {
    expect(() => buildBracket({ ...base, side: "long", sizeUsd: 5, entryType: "market", stopLoss: 59_000 })).toThrow(/10 USD/);
    expect(() => buildBracket({ ...base, side: "long", sizeUsd: 600, entryType: "market", stopLoss: 0 })).toThrow(/stop loss/);
  });
});

function fakeExchange(statuses: unknown[], opts: { throwOnOrder?: boolean; closeFills?: string[] } = {}) {
  const fills = [...(opts.closeFills ?? ["0.01"])];
  const calls: { method: string; args: unknown }[] = [];
  const ex: Exchange = {
    async updateLeverage(args) { calls.push({ method: "updateLeverage", args }); },
    async order(args) {
      calls.push({ method: "order", args });
      if (args.grouping === "na") { // cierre de emergencia
        const sz = fills.shift() ?? "0";
        return { statuses: [sz === "0" ? { error: "no fill" } : { filled: { totalSz: sz, avgPx: "58000", oid: 99 } }] };
      }
      if (opts.throwOnOrder) { const e = new Error("order 1: Invalid TP/SL price") as Error & { response?: unknown }; e.response = { response: { data: { statuses } } }; throw e; }
      return { statuses };
    },
    async cancel(args) { calls.push({ method: "cancel", args }); },
  };
  return { ex, calls };
}

describe("executeBracket", () => {
  const bracket = buildBracket({ asset: 0, szDecimals: 5, refPrice: 60_000, side: "long", sizeUsd: 600, entryType: "market", stopLoss: 58_800, takeProfit: 63_000 });

  it("sets isolated leverage, then sends entry + SL + TP", async () => {
    const { ex, calls } = fakeExchange([{ filled: { totalSz: "0.01", avgPx: "60010", oid: 1 } }, "waitingForTrigger", "waitingForTrigger"]);
    const r = await executeBracket(ex, bracket, 3);
    expect(calls[0]).toEqual({ method: "updateLeverage", args: { asset: 0, isCross: false, leverage: 3 } });
    expect(r).toMatchObject({ status: "open", filledSize: "0.01", avgPrice: "60010", orderIds: [1] });
  });

  it("if the entry fills but the stop is rejected, closes the position at market", async () => {
    const { ex, calls } = fakeExchange([{ filled: { totalSz: "0.01", avgPx: "60010", oid: 1 } }, { error: "Invalid TP/SL price" }, "waitingForTrigger"], { throwOnOrder: true });
    const r = await executeBracket(ex, bracket, 3);
    expect(r.status).toBe("failed");
    expect(r.error).toContain("cerrada a mercado");
    const close = calls.find((c) => c.method === "order" && (c.args as { grouping: string }).grouping === "na");
    expect(close?.args).toMatchObject({ orders: [{ b: false, r: true, s: "0.01", t: { limit: { tif: "Ioc" } } }] });
  });

  it("if a resting limit entry cannot get its stop, cancels the entry", async () => {
    const limit = buildBracket({ asset: 0, szDecimals: 5, refPrice: 60_000, side: "long", sizeUsd: 600, entryType: "limit", entryPrice: 59_500, stopLoss: 58_800 });
    const { ex, calls } = fakeExchange([{ resting: { oid: 7 } }, { error: "bad" }], { throwOnOrder: true });
    const r = await executeBracket(ex, limit, 3);
    expect(r.status).toBe("failed");
    expect(calls.find((c) => c.method === "cancel")?.args).toEqual({ cancels: [{ a: 0, o: 7 }] });
  });

  it("a rejected entry is a plain failure", async () => {
    const { ex } = fakeExchange([{ error: "Insufficient margin" }, "waitingForFill", "waitingForFill"], { throwOnOrder: true });
    const r = await executeBracket(ex, bracket, 3);
    expect(r).toMatchObject({ status: "failed" });
    expect(r.error).toContain("Insufficient margin");
  });

  it("a resting limit entry with its stop accepted is pending", async () => {
    const { ex } = fakeExchange([{ resting: { oid: 7 } }, "waitingForFill", "waitingForFill"]);
    expect((await executeBracket(ex, bracket, 3)).status).toBe("resting");
  });
});

describe("safety fixes", () => {
  it("market slippage is capped at 10% of the stop distance (max 0.5%), like the app", () => {
    expect(marketSlippage(60_000, 58_800)).toBeCloseTo(0.002, 9);
    expect(marketSlippage(60_000, 50_000)).toBeCloseTo(0.005, 9);
    const b = buildBracket({ asset: 0, szDecimals: 5, refPrice: 60_000, side: "long", sizeUsd: 600, entryType: "market", stopLoss: 58_800 });
    expect(b.orders[0].p).toBe("60120");
  });

  it("refuses a stop the price already crossed", () => {
    expect(() => buildBracket({ asset: 0, szDecimals: 5, refPrice: 58_700, side: "long", sizeUsd: 600, entryType: "market", stopLoss: 58_800 })).toThrow(/stop loss/);
    expect(() => buildBracket({ asset: 0, szDecimals: 5, refPrice: 60_000, side: "short", sizeUsd: 600, entryType: "limit", entryPrice: 61_000, stopLoss: 60_500 })).toThrow(/stop loss/);
  });

  it("emergency close retries partial fills and escalates if something stays open", async () => {
    const statuses = [{ filled: { totalSz: "0.01", avgPx: "60010", oid: 1 } }, { error: "bad" }];
    const bracket = buildBracket({ asset: 0, szDecimals: 5, refPrice: 60_000, side: "long", sizeUsd: 600, entryType: "market", stopLoss: 58_800 });
    const partialThenRest = fakeExchange(statuses, { throwOnOrder: true, closeFills: ["0.004", "0.006"] });
    const ok = await executeBracket(partialThenRest.ex, bracket, 3);
    expect(ok.error).toContain("cerrada a mercado");
    const stuck = fakeExchange(statuses, { throwOnOrder: true, closeFills: ["0.004", "0", "0"] });
    const urgent = await executeBracket(stuck.ex, bracket, 3);
    expect(urgent.error).toContain("URGENTE");
    expect(urgent.error).toContain("0.006");
  });

  it("closeFully only cancels the stop once the position is flat", async () => {
    let size = 0.01;
    const cancelled: number[] = [];
    const deps = {
      position: async () => size,
      closeIoc: async (sz: number) => { size = Math.max(0, +(size - Math.min(sz, 0.006)).toFixed(8)); },
      cancelOrders: async () => { cancelled.push(1); },
    };
    await expect(closeFully(deps)).resolves.toEqual({ closed: true, attempts: 2 });
    expect(cancelled).toEqual([1]);

    size = 0.01; cancelled.length = 0;
    await expect(closeFully({ ...deps, closeIoc: async () => {} })).rejects.toThrow(/sigue abierta/);
    expect(cancelled).toEqual([]);
  });
});

describe("missing stop status", () => {
  const bracket = buildBracket({ asset: 0, szDecimals: 5, refPrice: 60_000, side: "long", sizeUsd: 600, entryType: "market", stopLoss: 58_800 });
  it("checks the exchange for the stop before panic-closing", async () => {
    const { ex, calls } = fakeExchange([{ filled: { totalSz: "0.01", avgPx: "60010", oid: 1 } }]);
    const r = await executeBracket(ex, bracket, 3, async () => true);
    expect(r.status).toBe("open");
    expect(calls.some((c) => (c.args as { grouping?: string }).grouping === "na")).toBe(false);
  });
  it("closes if the stop really is not there", async () => {
    const { ex } = fakeExchange([{ filled: { totalSz: "0.01", avgPx: "60010", oid: 1 } }]);
    expect((await executeBracket(ex, bracket, 3, async () => false)).status).toBe("failed");
  });
});
