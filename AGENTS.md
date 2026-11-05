# Frontbot · guide for coding agents

Frontbot is a native macOS app (Swift 6, SwiftUI) that runs a team of AI agents for brands and social media. A Node sidecar runs the agents and talks to the app over JSON-RPC (stdio). Everything is stored locally: SQLite (GRDB) plus files under `~/Library/Application Support/Frontbot`.

## Layout

- `app/`: Swift package.
  - `FrontbotCore`: storage, rules, scheduling, the agent client and tool handlers. Testable.
  - `FrontbotApp`: the SwiftUI UI.
  - `FrontbotDemoSeed`: fills a data folder with demo data.
  - `Tests/FrontbotCoreTests`: XCTest.
- `agent/`: TypeScript sidecar.
  - `src/runner.ts`: Claude runner (Claude Agent SDK) and `ProviderRunner` routing.
  - `src/codex-runner.ts`: Codex with an API key (Responses API loop).
  - `src/codex-app-runner.ts` + `src/codex/*`: Codex with a ChatGPT session (`codex app-server`).
  - `src/tools.ts`: the Frontbot tool contract and the closed tool lists per mode.
  - `src/browserGuard.ts`: never interact with social networks, exchanges or wallets in the browser.
  - `src/workdir.ts`: the working-folder sandbox rules.
  - Tests live in `test/` (vitest). Fakes for external processes are in `test/fixtures/`.
- `app/Localization/en/*.strings`: English translations. **The Spanish strings in the code are the keys.**
- `docs/superpowers/specs/` and `docs/superpowers/plans/`: design specs and implementation plans, in Spanish. Read the spec of the feature you touch.
- `web/`: the marketing site (Next.js). It has its own `web/AGENTS.md`.
- `scripts/build-app.sh`: builds `build/Frontbot.app`.

## Commands

Run them from the repo root. All of them work offline once dependencies are installed.

```bash
cd agent && npm ci                     # first time (needs network)
cd agent && npm test                   # vitest, ~2 s
cd agent && npm run typecheck          # tsc --noEmit
cd agent && npm run build              # dist/: required BEFORE the Swift tests that spawn the sidecar
cd app && swift build                  # app + core
cd app && swift test < /dev/null       # XCTest, ~25 s
./scripts/build-app.sh                 # full app bundle (release, ad-hoc signed)
```

Gotchas:
- Always redirect stdin for `swift test` (`< /dev/null`), or a test that reads stdin can hang the run.
- The sidecar tests (`AgentClient*Tests`) run `agent/dist/main.js` with Node. They look for Node at `FRONTBOT_NODE`, with `/opt/homebrew/bin/node` as the default, and skip if it is missing. Run `npm run build` first, or they test stale code.
- Don't trust a piped exit status (`swift test | grep …` always "passes"). Check the test count and the failure count.

## Rules that must not break

These are product decisions. Don't relax them, even to make a test pass.

- **No agent tool publishes, approves or trades on its own.** The user makes the final click. Every write outside the working folder, script run, trade or paid image goes through a Swift-side approval.
- **Closed tool lists per run mode** (`specsFor` / `allowedToolsFor` in `agent/src/tools.ts`, and `codexCaps`/`codexArgs` in `agent/src/codex/launch.ts`): chat, scheduled, summarize, image, metrics, study. A mode gets only the tools it needs. Enforce this in the runtime, never only in the prompt.
- **BrowserGuard:**
  - On social, exchange or wallet hosts, the agent can only read, scroll and navigate by URL.
  - It must check `tabs_context_mcp` before any click or keystroke.
  - Codex reaches Chrome only through `ChromeBridge`, which applies the same guard on every call, one call at a time.
- **Codex with a session:**
  - It uses Frontbot's own `CODEX_HOME` (`<data>/codex-home`), never `~/.codex`.
  - The Codex process gets no API keys.
  - Without a working folder it has no shell: `environments: []` and `shell_tool` disabled.
  - Accepting an approval runs the command outside the sandbox, so accept only after `workdir.approve` returns true.
  - A failed session run never falls back to the API key.
- **Secrets** live only in the Keychain (`CredentialStore`). Never put them in SQLite, logs, run params or UI state.
- **Sidecar stdout is reserved for JSON-RPC.** Logs go to stderr.

## Conventions

- Swift 6 strict concurrency: actors for tool state (`ImageCreateTool`, `MetricsTool`, `AgentClient`). Database migrations are append-only in `AppDatabase.swift` (`vNN-name`).
- UI copy is written in Spanish in the code. Every new user-visible string needs its English line in `app/Localization/en/<area>.strings`, with no duplicate keys. Check the files with `plutil -lint`.
- Comments are short, in Spanish, and explain *why*. Match the density of the code around them.
- Use TDD: write the failing test first (vitest or XCTest), then the code. For bugs, write a test that reproduces it.
- Tests never use the network or real accounts. Use the fakes: `fake-codex.mjs` speaks the app-server protocol and `fake-chrome-mcp.mjs` the Claude in Chrome MCP. `FRONTBOT_FAKE_AGENT=1` gives a scripted sidecar.
- Run the full suites (`npm test` and `swift test`) before you call something done.
- Commit or push only when asked. Use conventional commits (`feat(scope): …`, `fix(scope): …`).

## Manual checks

`agent/scripts/codex-smoke.mjs` runs the Codex session runtime against the real Codex CLI. It spends a few tokens from the connected subscription. It needs a `FRONTBOT_CODEX_HOME` that already has a ChatGPT session.
