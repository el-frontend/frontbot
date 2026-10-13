import { describe, it, expect } from "vitest";
import { buildTools, ALLOWED_TOOLS, TOOL_SPECS } from "../src/tools.js";

describe("tools", () => {
  it("allows only web tools plus frontbot tools, never publish/approve", () => {
    expect(ALLOWED_TOOLS).toContain("WebSearch");
    expect(ALLOWED_TOOLS).toContain("WebFetch");
    expect(ALLOWED_TOOLS).toContain("mcp__frontbot__posts_create_draft");
    expect(ALLOWED_TOOLS.some((t) => /publish|approve|Bash|Write|Edit/.test(t))).toBe(false);
    expect(TOOL_SPECS.map((t) => t.name).sort()).toEqual([
      "brands_get_guide", "brands_list", "brands_write_guide", "ideas_create",
      "posts_create_draft", "posts_list", "posts_update_draft",
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
});
