// MCP de Claude in Chrome falso (stdio, JSON-RPC por líneas).
const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const schema = { type: "object", properties: {}, additionalProperties: true };
const tools = ["navigate", "computer", "tabs_context_mcp", "get_page_text", "javascript_tool", "file_upload"]
  .map((name) => ({ name, description: `fake ${name}`, inputSchema: schema }));

let buf = "";
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    if (msg.id === undefined) continue;
    if (process.env.FAKE_CHROME_HANG === "1") continue;
    if (msg.method === "initialize") send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "Claude in Chrome", version: "1.0.0" } } });
    else if (msg.method === "tools/list") send({ jsonrpc: "2.0", id: msg.id, result: { tools } });
    else if (msg.method === "tools/call") {
      const name = msg.params?.name;
      const text = name === "tabs_context_mcp"
        ? `Tab 1: ${process.env.FAKE_CHROME_SOCIAL === "1" ? "https://www.linkedin.com/feed" : "https://example.com"}`
        : `called:${name}`;
      send({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text }], isError: false } });
    } else send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "no" } });
  }
});
process.stdin.on("end", () => process.exit(0));
