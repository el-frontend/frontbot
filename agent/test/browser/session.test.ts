import { describe, it, expect, afterAll } from "vitest";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ChromePublisher } from "../../src/browser/session.js";

const hasChrome = existsSync("/Applications/Google Chrome.app");
const pids: number[] = [];

describe.skipIf(!hasChrome)("ChromePublisher", () => {
  afterAll(() => { for (const pid of pids) { try { process.kill(pid); } catch {} } });

  it("launches Chrome once for concurrent callers and the window outlives the publisher", async () => {
    const profile = mkdtempSync(join(tmpdir(), "fb-profile-"));
    const first = new ChromePublisher({ headless: true });
    const [a, b] = await Promise.all([first.browser(profile), first.browser(profile)]);
    expect(a).toBe(b);
    const port = readFileSync(join(profile, "DevToolsActivePort"), "utf8").split("\n")[0];
    pids.push(first.launchedPid!);
    await first.disconnect(); // como cuando el sidecar se reinicia

    const second = new ChromePublisher({ headless: true });
    await second.browser(profile);
    expect(second.launchedPid).toBeUndefined(); // se reconectó al Chrome existente, no lanzó otro
    expect(readFileSync(join(profile, "DevToolsActivePort"), "utf8").split("\n")[0]).toBe(port);
    await second.disconnect();
  });
});
