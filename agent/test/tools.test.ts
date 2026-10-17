import { describe, it, expect } from "vitest";
import { buildTools, ALLOWED_TOOLS, TOOL_SPECS, allowedToolsFor } from "../src/tools.js";

describe("tools", () => {
  it("allows only web tools plus frontbot tools, never publish/approve", () => {
    expect(ALLOWED_TOOLS).toContain("WebSearch");
    expect(ALLOWED_TOOLS).toContain("WebFetch");
    expect(ALLOWED_TOOLS).toContain("mcp__frontbot__posts_create_draft");
    expect(ALLOWED_TOOLS.some((t) => /publish|approve|Bash|Write|Edit/.test(t))).toBe(false);
    expect(TOOL_SPECS.map((t) => t.name).sort()).toEqual([
      "brands_get_guide", "brands_list", "brands_list_assets", "brands_write_guide", "ideas_create",
      "posts_create_draft", "posts_list", "posts_update_draft",
      "schedule_create_draft", "schedule_list", "schedule_update_draft",
      "skills_create_draft", "skills_list", "skills_run_script", "skills_update_draft",
      "tasks_complete", "tasks_create", "tasks_list",
    ]);
  });

  it("handler forwards to app with tool. prefix and returns JSON text", async () => {
    const calls: [string, unknown][] = [];
    const tools = buildTools(async (m, p) => { calls.push([m, p]); return { post_id: "p1" }; });
    const create = tools.find((t) => t.name === "posts_create_draft")!;
    const res = await create.handler({ brand_id: "b", network: "instagram", body: "hola" }, {});
    expect(calls).toEqual([["tool.posts_create_draft", { brand_id: "b", network: "instagram", body: "hola" }]]);
    expect(res.content[0]).toEqual({ type: "text", text: '{"post_id":"p1"}' });
  });

  it("app errors become isError results the model can read", async () => {
    const tools = buildTools(async () => { throw new Error("Solo se pueden editar posts en borrador; este está en approved."); });
    const update = tools.find((t) => t.name === "posts_update_draft")!;
    const res = await update.handler({ post_id: "p1", body: "v2" }, {});
    expect(res.isError).toBe(true);
    expect(res.content[0]).toEqual({ type: "text", text: "Solo se pueden editar posts en borrador; este está en approved." });
  });
  it("draft tools accept optional media ids", () => {
    const create = TOOL_SPECS.find((t) => t.name === "posts_create_draft")!;
    const update = TOOL_SPECS.find((t) => t.name === "posts_update_draft")!;
    expect(Object.keys(create.shape)).toContain("media");
    expect(Object.keys(update.shape)).toContain("media");
  });
});

describe("tools per agent", () => {
  it("injects the run's agent_id so the model cannot choose it", async () => {
    const calls: [string, unknown][] = [];
    const tools = buildTools(async (m, p) => { calls.push([m, p]); return {}; }, { agentId: "a1", isDefault: false });
    await tools.find((t) => t.name === "tasks_list")!.handler({ agent_id: "otro" } as never, {});
    expect(calls[0]).toEqual(["tool.tasks_list", { agent_id: "a1" }]);
  });

  it("only the default agent can create agents", () => {
    const names = (isDefault: boolean) => buildTools(async () => ({}), { agentId: "a", isDefault }).map((t) => t.name);
    expect(names(true)).toContain("agents_create_draft");
    expect(names(false)).not.toContain("agents_create_draft");
    expect(allowedToolsFor({ agentId: "a", isDefault: false })).not.toContain("mcp__frontbot__agents_create_draft");
    expect(allowedToolsFor({ agentId: "a", isDefault: true })).toContain("mcp__frontbot__agents_create_draft");
  });
});

describe("file tools", () => {
  const names = (ctx: Parameters<typeof allowedToolsFor>[0]) => allowedToolsFor(ctx).map((t) => t.replace("mcp__frontbot__", ""));

  it("only exist when the agent has authorized folders", () => {
    expect(names({ isDefault: false, agentId: "a" }).filter((n) => n.startsWith("files_"))).toEqual([]);
    expect(names({ isDefault: false, agentId: "a", files: true }).filter((n) => n.startsWith("files_")).sort())
      .toEqual(["files_folders", "files_list", "files_read", "files_write"]);
  });

  it("scheduled runs can read but never write (nobody can approve)", () => {
    const scheduled = names({ isDefault: false, agentId: "a", files: true, scheduled: true });
    expect(scheduled).toContain("files_read");
    expect(scheduled).not.toContain("files_write");
  });

  it("summaries never touch files", () => {
    expect(names({ isDefault: false, agentId: "a", files: true, memoryOnly: true }).some((n) => n.startsWith("files_"))).toBe(false);
  });

  it("files_write carries the run id set by the sidecar, not the model", async () => {
    const calls: [string, unknown][] = [];
    const tools = buildTools(async (m, p) => { calls.push([m, p]); return { written: "/x" }; }, { isDefault: false, agentId: "a", files: true, runId: "r1" });
    await tools.find((t) => t.name === "files_write")!.handler({ path: "/x", content: "hola", run_id: "otro" } as never, {});
    expect(calls).toEqual([["tool.files_write", { path: "/x", content: "hola", run_id: "r1", agent_id: "a" }]]);
  });
});
