import type { Readable, Writable } from "node:stream";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { requestToolBridge, type BridgeTool, type ToolBridgeConfig } from "./tool-bridge.js";

export function createFrontbotMcpServer(config: ToolBridgeConfig) {
  const server = new Server({ name: "frontbot", version: "0.1.0" }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => {
    const response = await requestToolBridge<{ tools: BridgeTool[] }>(config, { op: "list" });
    return { tools: response.tools };
  });
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    return await requestToolBridge(config, {
      op: "call",
      name: request.params.name,
      arguments: request.params.arguments ?? {},
    });
  });
  return server;
}

/** Entry point for Codex's MCP stdio child. No Frontbot state is read in this process. */
export async function runFrontbotMcp(
  config: ToolBridgeConfig,
  input: Readable = process.stdin,
  output: Writable = process.stdout,
) {
  const server = createFrontbotMcpServer(config);
  const transport = new StdioServerTransport(input, output);
  await server.connect(transport);
  return { server, transport };
}

if (process.argv[1]?.endsWith("frontbot-mcp.js")) {
  const socketPath = process.env.FRONTBOT_MCP_SOCKET;
  const token = process.env.FRONTBOT_MCP_TOKEN;
  if (!socketPath || !token) {
    process.stderr.write("Falta la configuración privada del puente MCP de Frontbot.\n");
    process.exitCode = 1;
  } else {
    void runFrontbotMcp({ socketPath, token }).catch((error: Error) => {
      process.stderr.write(`No se pudo iniciar el puente MCP de Frontbot: ${error.message}\n`);
      process.exitCode = 1;
    });
  }
}
