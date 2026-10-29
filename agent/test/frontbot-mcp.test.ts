import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createFrontbotMcpServer } from "../src/frontbot-mcp.js";
import { createToolBridge } from "../src/tool-bridge.js";

describe("Frontbot stdio MCP server adapter", () => {
  it("lists run-allowed schemas and relays MCP calls through the authenticated bridge", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const bridge = await createToolBridge(async (method, params) => {
      calls.push([method, params]);
      return { tasks: [{ id: "t1" }] };
    }, { agentId: "a1", isDefault: false });
    const server = createFrontbotMcpServer(bridge);
    const client = new Client({ name: "codex-test", version: "0.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    try {
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      const listed = await client.listTools();
      expect(listed.tools.map((tool) => tool.name)).toContain("tasks_list");
      expect(listed.tools.find((tool) => tool.name === "tasks_list")?.inputSchema).toMatchObject({ type: "object" });
      expect(listed.tools.map((tool) => tool.name)).not.toContain("agents_create_draft");
      const result = await client.callTool({ name: "tasks_list", arguments: {} });
      expect(result.content).toEqual([{ type: "text", text: '{"tasks":[{"id":"t1"}]}' }]);
      expect(calls).toEqual([["tool.tasks_list", { agent_id: "a1" }]]);
    } finally {
      await client.close();
      await server.close();
      await bridge.close();
    }
  });

  it("surfaces app approval errors to the model as MCP tool errors", async () => {
    const bridge = await createToolBridge(async () => { throw new Error("El usuario denegó la escritura."); }, {
      agentId: "a1", isDefault: false, files: true,
    });
    const server = createFrontbotMcpServer(bridge);
    const client = new Client({ name: "codex-test", version: "0.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    try {
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      const result = await client.callTool({ name: "files_write", arguments: { path: "/tmp/example.txt", content: "x" } });
      expect(result.isError).toBe(true);
      expect(result.content).toEqual([{ type: "text", text: "El usuario denegó la escritura." }]);
    } finally {
      await client.close();
      await server.close();
      await bridge.close();
    }
  });
});
