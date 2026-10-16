// Operaciones que pide la APP (nunca el agente): enviar una orden aprobada, cerrar una posición, consultar la cuenta.
import * as hl from "./hyperliquid/client.js";

export interface Trader {
  execute(p: hl.ExecuteParams): Promise<unknown>;
  close(p: { network: hl.Network; private_key: string; address: string; coin: string }): Promise<unknown>;
  snapshot(p: { network: hl.Network; coin: string; address?: string }): Promise<{ price: number; account_value: number | null }>;
  overview(p: { network: hl.Network; address: string }): Promise<unknown>;
}

export class HyperliquidTrader implements Trader {
  execute(p: hl.ExecuteParams) { return hl.executeTrade(p); }
  close(p: { network: hl.Network; private_key: string; address: string; coin: string }) { return hl.closePosition(p); }
  async snapshot(p: { network: hl.Network; coin: string; address?: string }) {
    const [price, account] = await Promise.all([hl.marketPrice(p.network, p.coin), p.address ? hl.accountState(p.network, p.address) : null]);
    return { price, account_value: account?.account_value ?? null };
  }
  async overview(p: { network: hl.Network; address: string }) {
    const [state, orders] = await Promise.all([hl.accountState(p.network, p.address), hl.openOrders(p.network, p.address)]);
    return { ...state, orders };
  }
}

/** Sin red: para los tests y FRONTBOT_FAKE_AGENT. El coin "FALLA" simula un error del exchange. */
export class FakeTrader implements Trader {
  async execute(p: hl.ExecuteParams) {
    if (p.coin === "FALLA") throw new Error("Hyperliquid no responde");
    const size = (Math.floor((p.size_usd / 60_000) * 1e5) / 1e5).toString();
    return { status: "open", orderIds: [1], filledSize: size, avgPrice: "60000", size, reference_price: 60_000 };
  }
  async close() { return { closed: true, cancelled_orders: 2 }; }
  async snapshot(p: { coin: string; address?: string }) {
    if (p.coin === "FALLA") throw new Error("Hyperliquid no responde");
    return { price: 60_000, account_value: p.address ? 1_000 : null };
  }
  async overview() {
    return { account_value: 1_000, withdrawable: 900, positions: [{ coin: "BTC", size: 0.0083, entry_price: 60_000, unrealized_pnl: 1.5, leverage: 3, liquidation_price: 41_000, position_value: 500 }], orders: [] };
  }
}
