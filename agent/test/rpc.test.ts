import { describe, it, expect } from "vitest";
import { PassThrough } from "node:stream";
import { RpcPeer, RpcError } from "../src/rpc.js";

function pair() {
  const aToB = new PassThrough();
  const bToA = new PassThrough();
  return { a: new RpcPeer(bToA, aToB), b: new RpcPeer(aToB, bToA) };
}

describe("RpcPeer", () => {
  it("request/response round trip with unicode", async () => {
    const { a, b } = pair();
    b.onRequest("echo", async (p) => ({ got: p.text }));
    await expect(a.request("echo", { text: "café ☕️" })).resolves.toEqual({ got: "café ☕️" });
  });

  it("propagates handler errors as RpcError", async () => {
    const { a, b } = pair();
    b.onRequest("boom", async () => { throw new Error("se rompió"); });
    await expect(a.request("boom", {})).rejects.toMatchObject({ message: "se rompió", code: -32000 });
  });

  it("unknown method returns -32601", async () => {
    const { a } = pair();
    const err = await a.request("nope", {}).catch((e) => e);
    expect(err).toBeInstanceOf(RpcError);
    expect(err.code).toBe(-32601);
  });

  it("delivers notifications", async () => {
    const { a, b } = pair();
    const got = new Promise((resolve) => b.onNotification("ping", resolve));
    a.notify("ping", { n: 1 });
    await expect(got).resolves.toEqual({ n: 1 });
  });

  it("handles messages split across chunks and several per chunk", async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const peer = new RpcPeer(input, output);
    const seen: unknown[] = [];
    peer.onNotification("n", (p) => seen.push(p));
    input.write('{"jsonrpc":"2.0","method":"n","par');
    input.write('ams":{"i":1}}\n{"jsonrpc":"2.0","method":"n","params":{"i":2}}\n');
    await new Promise((r) => setImmediate(r));
    expect(seen).toEqual([{ i: 1 }, { i: 2 }]);
  });
});
