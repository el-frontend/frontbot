// Guardián del navegador del usuario (Claude in Chrome): el agente puede leer, hacer clic y
// rellenar formularios, pero nunca interactuar con una red social, para que no pueda publicar.
// No conoce el formato de las respuestas de la extensión: solo busca hosts de redes en su texto.

const PREFIX = "mcp__claude-in-chrome__";

/** Sitios donde un clic o una tecla pueden publicar contenido en nombre del usuario. */
const SOCIAL_HOSTS = [
  "instagram.com", "linkedin.com", "facebook.com", "fb.com", "x.com", "twitter.com", "tiktok.com",
  "threads.net", "threads.com", "youtube.com", "pinterest.com", "reddit.com", "bsky.app",
  "metricool.com", "buffer.com", "hootsuite.com", "later.com",
  // Exchanges y wallets: los trades solo van por la API, con aprobación o mandato.
  "hyperliquid.xyz", "hyperliquid-testnet.xyz", "binance.com", "bybit.com", "coinbase.com", "okx.com", "kraken.com", "bitget.com",
  "kucoin.com", "gate.io", "gate.com", "mexc.com", "htx.com", "bitfinex.com", "deribit.com", "dydx.trade", "gmx.io", "jup.ag",
  "uniswap.org", "phantom.app", "phantom.com", "metamask.io", "rabby.io",
];
const SOCIAL_RE = new RegExp(
  `(?<![a-z0-9-])(?:[a-z0-9-]+\\.)*(?:${SOCIAL_HOSTS.map((h) => h.replace(/\./g, "\\.")).join("|")})(?![a-z0-9-])`, "i");

/** Redes, exchanges y wallets (incluidas las ventanas de extensiones, como la de Phantom). */
export const mentionsSocialHost = (text: string) => SOCIAL_RE.test(text) || /chrome-extension:\/\//i.test(text);

const READ_TOOLS = ["tabs_context_mcp", "get_page_text", "read_page", "find", "read_console_messages", "read_network_requests", "list_connected_browsers"];
/** Cambian la página o la pestaña: después hay que volver a verificar dónde está el navegador. */
const NAV_TOOLS = ["navigate", "tabs_create_mcp", "tabs_close_mcp", "select_browser", "switch_browser", "resize_window"];
const INTERACTIVE_TOOLS = ["computer", "form_input"];
const PASSIVE_ACTIONS = new Set(["screenshot", "scroll", "scroll_to", "zoom", "wait", "hover"]);

/** Herramientas del navegador que se pre-aprueban; el resto (javascript, subidas, lotes…) queda fuera. */
export const BROWSER_ALLOWED_TOOLS = [...READ_TOOLS, ...NAV_TOOLS, ...INTERACTIVE_TOOLS].map((n) => PREFIX + n);

export type GuardDecision = { allow: boolean; reason?: string };

const responseText = (response: unknown) => JSON.stringify(response ?? "");

export class BrowserGuard {
  /** true tras un tabs_context_mcp que no ha quedado obsoleto por una navegación o un clic. */
  private verified = false;
  private socialOpen = false;

  beforeTool(toolName: string, input: unknown): GuardDecision {
    if (!toolName.startsWith(PREFIX)) return { allow: true };
    const name = toolName.slice(PREFIX.length);
    const args = (input ?? {}) as Record<string, unknown>;

    if (READ_TOOLS.includes(name)) return { allow: true };

    if (NAV_TOOLS.includes(name)) {
      if (name === "navigate") {
        const url = String(args.url ?? "").trim();
        if (/^[a-z][a-z0-9+.-]*:/i.test(url) && !/^https?:/i.test(url)) {
          return { allow: false, reason: "Solo se puede navegar a páginas web (http/https)." };
        }
      }
      this.verified = false;
      return { allow: true };
    }

    if (INTERACTIVE_TOOLS.includes(name)) {
      if (name === "computer" && PASSIVE_ACTIONS.has(String(args.action))) return { allow: true };
      if (!this.verified) {
        return { allow: false, reason: "Antes de hacer clic o escribir, llama a tabs_context_mcp para confirmar en qué página está cada pestaña." };
      }
      if (this.socialOpen) {
        return { allow: false, reason: "Hay una red social, un exchange o una wallet abierta: Frontbot no puede publicar, operar ni firmar desde el navegador. Solo puedes leerla; cierra esa pestaña para hacer clic en otras páginas." };
      }
      this.verified = false; // el clic puede haber cambiado de página
      return { allow: true };
    }

    return { allow: false, reason: "Esta herramienta del navegador no está permitida en Frontbot." };
  }

  afterTool(toolName: string, response: unknown) {
    if (toolName !== PREFIX + "tabs_context_mcp") return;
    this.verified = true;
    this.socialOpen = mentionsSocialHost(responseText(response));
  }
}
