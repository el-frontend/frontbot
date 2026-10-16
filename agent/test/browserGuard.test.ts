import { describe, it, expect } from "vitest";
import { BrowserGuard, mentionsSocialHost, BROWSER_ALLOWED_TOOLS } from "../src/browserGuard.js";

const t = (name: string) => `mcp__claude-in-chrome__${name}`;
const click = { action: "left_click", coordinate: [10, 10], tabId: 1 };

/** Guard verificado sobre una pestaña segura, listo para interactuar. */
function verifiedGuard(tabsText = "Tab 1: Google (https://www.google.com/search?q=x)") {
  const g = new BrowserGuard();
  g.afterTool(t("tabs_context_mcp"), { content: [{ type: "text", text: tabsText }] });
  return g;
}

describe("mentionsSocialHost", () => {
  it("detects publishing hosts, including subdomains", () => {
    expect(mentionsSocialHost("https://www.instagram.com/p/abc")).toBe(true);
    expect(mentionsSocialHost("url: https://es.linkedin.com/feed/")).toBe(true);
    expect(mentionsSocialHost("https://x.com/home")).toBe(true);
  });
  it("does not confuse hosts that merely end in the same letters", () => {
    expect(mentionsSocialHost("https://www.fedex.com/track")).toBe(false);
    expect(mentionsSocialHost("https://www.google.com/search?q=linkedin")).toBe(false);
  });
});

describe("BrowserGuard", () => {
  it("always allows reading tools", () => {
    const g = new BrowserGuard();
    for (const name of ["get_page_text", "read_page", "find", "tabs_context_mcp", "navigate"]) {
      expect(g.beforeTool(t(name), { url: "https://www.linkedin.com/feed/" }).allow).toBe(true);
    }
  });

  it("blocks scripting, uploads and batches outright", () => {
    const g = verifiedGuard();
    for (const name of ["javascript_tool", "file_upload", "upload_image", "browser_batch", "shortcuts_execute"]) {
      expect(g.beforeTool(t(name), {}).allow).toBe(false);
    }
  });

  it("requires a fresh tabs_context_mcp before clicking", () => {
    const g = new BrowserGuard();
    const res = g.beforeTool(t("computer"), click);
    expect(res.allow).toBe(false);
    expect(res.reason).toContain("tabs_context_mcp");
  });

  it("allows clicks and form input on a verified non-social page", () => {
    expect(verifiedGuard().beforeTool(t("computer"), click).allow).toBe(true);
    expect(verifiedGuard().beforeTool(t("form_input"), { ref: "r1", value: "x" }).allow).toBe(true);
  });

  it("forbids clicking or typing while a social network is open", () => {
    const g = verifiedGuard("Tab 1: Feed | LinkedIn (https://www.linkedin.com/feed/)");
    const res = g.beforeTool(t("computer"), { action: "type", text: "hola" });
    expect(res.allow).toBe(false);
    expect(res.reason).toContain("publicar");
    expect(g.beforeTool(t("form_input"), { ref: "r1", value: "x" }).allow).toBe(false);
  });

  it("allows passive computer actions on social networks", () => {
    const g = verifiedGuard("https://www.instagram.com/");
    for (const action of ["screenshot", "scroll", "scroll_to", "zoom", "wait", "hover"]) {
      expect(g.beforeTool(t("computer"), { action }).allow).toBe(true);
    }
  });

  it("invalidates the verification after a click, a navigation or a new tab", () => {
    for (const [name, input] of [["computer", click], ["navigate", { url: "https://bit.ly/x" }], ["tabs_create_mcp", {}]] as const) {
      const g = verifiedGuard();
      expect(g.beforeTool(t(name), input).allow).toBe(true);
      expect(g.beforeTool(t("computer"), click).allow).toBe(false);
    }
  });

  it("treats unknown computer actions as interactive", () => {
    const g = verifiedGuard("https://www.instagram.com/");
    expect(g.beforeTool(t("computer"), { action: "something_new" }).allow).toBe(false);
  });

  it("rejects non-web navigation such as javascript: URLs", () => {
    const g = new BrowserGuard();
    expect(g.beforeTool(t("navigate"), { url: "javascript:alert(1)" }).allow).toBe(false);
    expect(g.beforeTool(t("navigate"), { url: "example.com" }).allow).toBe(true);
    expect(g.beforeTool(t("navigate"), { url: "back" }).allow).toBe(true);
  });

  it("ignores tools from other servers", () => {
    expect(new BrowserGuard().beforeTool("mcp__frontbot__posts_list", {}).allow).toBe(true);
  });

  it("only pre-approves tools the guard knows how to police", () => {
    expect(BROWSER_ALLOWED_TOOLS).toContain(t("computer"));
    expect(BROWSER_ALLOWED_TOOLS).not.toContain(t("javascript_tool"));
    expect(BROWSER_ALLOWED_TOOLS).not.toContain(t("browser_batch"));
  });
});
