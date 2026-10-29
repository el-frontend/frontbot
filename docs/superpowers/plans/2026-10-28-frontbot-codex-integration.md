# Frontbot Codex Integration Implementation Plan

> **Superseded (2026-10-28):** This CLI/app-server implementation plan is retained as a historical record. Follow [the API-key-only integration plan](2026-10-28-frontbot-api-key-only-integration.md) and its approved design amendment instead.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Codex as a selectable provider per Frontbot agent, with Codex CLI account authentication or an OpenAI API key, while retaining Frontbot’s UI, tools, data ownership, streaming and approval controls.

**Architecture:** Extend the existing Agent model with a provider and keep the Swift app as the source of truth for settings, credentials, conversations and approvals. Keep the existing Node sidecar and JSON-RPC contract; route each run to the current Claude runner or a new Codex app-server runner. Expose Frontbot tools to app-server through a local MCP bridge that forwards calls to Swift over the existing app/sidecar boundary.

**Tech Stack:** Swift 6, SwiftUI, GRDB/SQLite, Keychain, Node 24, TypeScript, Vitest, Claude Agent SDK, Codex CLI app-server, MCP stdio, JSON-RPC.

---

## Repository map

| Area | Existing files | Planned responsibility |
|---|---|---|
| Agent data and schema | `app/Sources/FrontbotCore/Models/Records.swift`, `app/Sources/FrontbotCore/Store/AppDatabase.swift`, `app/Sources/FrontbotCore/Store/Repositories.swift` | Provider enum, per-provider model catalogs, database migration, validation and defaults. |
| Provider UI | `app/Sources/FrontbotApp/AgentDetailView.swift`, `app/Sources/FrontbotApp/SettingsView.swift`, `app/Sources/FrontbotApp/SchedulesView.swift`, `app/Sources/FrontbotApp/AppModel.swift` | Per-agent provider/model selection, provider credential panels, schedule model filtering and user-facing errors. |
| Secrets and executables | `app/Sources/FrontbotCore/Credentials/CredentialStore.swift`, `app/Sources/FrontbotCore/Agent/AgentLocator.swift`, `app/Sources/FrontbotCore/Agent/AgentClient.swift` | Keychain account for OpenAI, Codex CLI discovery/auth status, provider keys delivered only to the needed child process. |
| Sidecar | `agent/src/main.ts`, `agent/src/runner.ts`, `agent/src/tools.ts`, `agent/src/rpc.ts` | Provider routing, MCP bridge, Codex app-server process and event translation. |
| Tests | `app/Tests/FrontbotCoreTests/AgentStoreTests.swift`, `CredentialStoreTests.swift`, `AgentClientRobustnessTests.swift`; `agent/test/runner.test.ts`, `main.test.ts`, `rpc.test.ts`, plus new focused tests | Migration, validation, UI model catalogs, credentials, routing, RPC, cancellation, tools and errors. |
| Packaging and docs | `scripts/build-app.sh`, new `README.md` | Detect the local Codex CLI dependency and explain setup/troubleshooting. Do not bundle or install Codex CLI without a separate product decision. |

## Implementation decisions

1. Add a persisted `provider` field to `Agent`; migrate all existing agents to `claude`.
2. Keep model IDs provider-specific and validate the provider/model pair in one catalog. A provider switch selects that provider’s default model if the old model is incompatible.
3. Provider choice in Settings only selects which account credentials are being edited. It does not change agent assignments.
4. Credentials remain workspace-scoped in Keychain. The Codex API key is passed only to the Codex process environment. A Codex CLI session is detected through the local CLI; no silent fallback between auth methods or providers.
5. Frontbot remains the owner of conversation history. Codex receives the Frontbot history supplied for a run; Codex persistence behavior must be explicitly configured and checked so user messages are not silently duplicated into unrelated Codex history.
6. Chat, scheduled tasks and conversation summaries use the assigned provider. A scheduled task’s model must be valid for its agent’s provider; old model IDs resolve to the new provider’s default when needed. The experimental Lab remains Claude-only. Claude in Chrome is unavailable for Codex.
7. Treat the MCP bridge and permission mapping as a release blocker: Codex must not gain a broader filesystem or command permission than the existing Frontbot approval flow.

## Task 1: Provider model catalog and database migration

**Files:**
- Modify: `app/Sources/FrontbotCore/Agent/AgentClient.swift` (or extract catalogs to `app/Sources/FrontbotCore/Agent/AgentProvider.swift`)
- Modify: `app/Sources/FrontbotCore/Models/Records.swift`
- Modify: `app/Sources/FrontbotCore/Store/AppDatabase.swift`
- Modify: `app/Sources/FrontbotCore/Store/Repositories.swift`
- Test: `app/Tests/FrontbotCoreTests/AgentStoreTests.swift`
- Test: new `app/Tests/FrontbotCoreTests/AgentProviderTests.swift`

- [ ] **Step 1: Add failing provider catalog and compatibility tests.** Cover `claude` and `codex` identifiers, each default model, resolving an unknown model, and resolving a Claude model for a Codex agent to the Codex default.
- [ ] **Step 2: Run the focused Swift tests.** Run `cd app && swift test --filter AgentProviderTests`; expected: compile/test failures because the provider type and provider-aware resolver do not exist.
- [ ] **Step 3: Add the provider and catalog types.** Define `AgentProvider: String, Codable, CaseIterable, Sendable` with `claude` and `codex`. Expose `defaultModel(for:)`, `models(for:)`, and `resolve(_:for:)`; retain existing `AgentModel.all` compatibility only where needed during migration.
- [ ] **Step 4: Add the database migration.** Register `v12-agent-provider` after `v11-workdir`; add non-null `agent.provider` with default `claude`. Add `provider` to `Agent` and `AgentDraft`, and pass it through `createAgent`, `updateAgent`, and `ensureDefaultAgent`.
- [ ] **Step 5: Validate provider/model pairs in the repository.** `Repositories.validated(_:)` must normalize `draft.model` against `draft.provider`; creation defaults to Claude and updates preserve the existing provider/model pair.
- [ ] **Step 6: Verify migration and persistence.** Add tests opening an older-schema database, checking existing agents migrate to Claude, and round-tripping both providers. Run `cd app && swift test --filter AgentProviderTests` and `cd app && swift test --filter AgentStoreTests`; expected: PASS.
- [ ] **Step 7: Commit.** `git add app/Sources/FrontbotCore app/Tests/FrontbotCoreTests && git commit -m "feat(agent): persist provider per agent"`.

## Task 2: Per-agent provider and model controls

**Files:**
- Modify: `app/Sources/FrontbotApp/AgentDetailView.swift`
- Modify: `app/Sources/FrontbotApp/AppModel.swift`
- Modify: `app/Sources/FrontbotApp/SchedulesView.swift`
- Modify: `app/Sources/FrontbotCore/Store/Repositories.swift` if provider-aware scheduled model validation belongs in the store
- Test: `app/Tests/FrontbotCoreTests/AgentStoreTests.swift`
- Test: `app/Tests/FrontbotCoreTests/ScheduledTaskTests.swift`

- [ ] **Step 1: Add failing repository tests for provider changes.** Verify a Claude agent can change to Codex, an incompatible stored model becomes the Codex default, a valid Codex model is preserved, and an unknown provider is rejected.
- [ ] **Step 2: Add failing scheduled-task compatibility tests.** Verify a Claude model on a Codex agent resolves to the Codex default when a task runs, and task model selection exposes only models for the assigned agent provider.
- [ ] **Step 3: Add the provider picker to agent settings.** Place `Proveedor` above `Modelo` in `AgentDetailView.settings`; persist changes through the existing `save` helper. Make the model picker use `AgentProvider.models(for: agent.provider)`.
- [ ] **Step 4: Explain provider-specific capabilities.** For Codex, show that Claude in Chrome is not available and disable its toggle without erasing the saved browser preference. Keep the Lab tab restricted to Claude agents and show an explanatory message on Codex agents.
- [ ] **Step 5: Make scheduled task models provider-aware.** In `TaskEditorSheet`, initialize the catalog from `agent.provider`; normalize an existing incompatible task model for display/save. In `AppModel.start(_:)`, resolve `task.model` against the assigned agent provider before calling `client.run`.
- [ ] **Step 6: Verify provider UI state and scheduled dispatch.** Run `cd app && swift test --filter 'AgentStoreTests|ScheduledTaskTests'`; expected: PASS. Build the app with `cd app && swift build` to catch SwiftUI type errors; expected: build succeeds.
- [ ] **Step 7: Commit.** `git add app/Sources/FrontbotApp app/Sources/FrontbotCore/Store/Repositories.swift app/Tests/FrontbotCoreTests && git commit -m "feat(settings): choose provider per agent"`.

## Task 3: Codex credential settings and executable discovery

**Files:**
- Modify: `app/Sources/FrontbotCore/Credentials/CredentialStore.swift`
- Modify: `app/Sources/FrontbotCore/Agent/AgentLocator.swift` (or create `CodexLocator.swift`)
- Modify: `app/Sources/FrontbotApp/AppModel.swift`
- Modify: `app/Sources/FrontbotApp/SettingsView.swift`
- Test: `app/Tests/FrontbotCoreTests/CredentialStoreTests.swift`
- Test: new `app/Tests/FrontbotCoreTests/CodexLocatorTests.swift`

- [ ] **Step 1: Add failing Keychain tests for the OpenAI key account.** Confirm workspace-scoped set/get/delete and whitespace normalization without changing Anthropic key behavior.
- [ ] **Step 2: Add failing executable/auth status tests.** Inject environment, candidate paths and an `exists` closure; verify discovery uses a valid `codex` executable and reports missing CLI cleanly without depending on the developer’s machine.
- [ ] **Step 3: Implement credential operations.** Add `CredentialStore.openAIKey`; add `AppModel` state and save/delete methods for that key. Only expose presence, never the saved value. Reconfigure the sidecar when credentials change.
- [ ] **Step 4: Implement Codex CLI discovery/status.** Resolve `codex` from the app environment and supported standard install paths. Query login status without a shell, with a short timeout; return a typed status such as `available`, `notInstalled`, `notSignedIn`, or `unavailable`.
- [ ] **Step 5: Implement the shared provider credential card.** Replace “Cuenta de Claude” with “Proveedores de IA”; add a Claude/Codex selector that changes only the displayed credential panel. Preserve Claude’s current copy and flow. The Codex panel shows CLI session status, setup guidance, an optional secure API-key field, save/delete controls, and safe error text.
- [ ] **Step 6: Verify keychain and status behavior.** Run `cd app && swift test --filter CredentialStoreTests` and `cd app && swift test --filter CodexLocatorTests`; expected: PASS. Run `cd app && swift build`; expected: build succeeds.
- [ ] **Step 7: Commit.** `git add app/Sources/FrontbotCore/Credentials app/Sources/FrontbotCore/Agent app/Sources/FrontbotApp app/Tests/FrontbotCoreTests && git commit -m "feat(settings): configure Codex credentials"`.

## Task 4: Provider-aware sidecar configuration and dispatch contract

**Files:**
- Modify: `app/Sources/FrontbotCore/Agent/AgentClient.swift`
- Modify: `app/Sources/FrontbotApp/AppModel.swift`
- Modify: `agent/src/runner.ts`
- Modify: `agent/src/main.ts`
- Test: `app/Tests/FrontbotCoreTests/AgentClientRobustnessTests.swift`
- Test: `agent/test/runner.test.ts`
- Test: `agent/test/main.test.ts`

- [ ] **Step 1: Add failing RPC contract tests.** Assert `agent.run` includes `provider`, `model`, `run_id`, and the existing agent/task context; assert the sidecar chooses the correct runner and keeps the same `agent.event`/`agent.done` notifications.
- [ ] **Step 2: Add a typed sidecar provider config.** Extend Swift `AgentConfig` with optional `openAIAPIKey` and Codex executable information; extend `RunParams` with `provider: "claude" | "codex"`. Keep Anthropic and OpenAI secrets out of JSON-RPC messages and logs.
- [ ] **Step 3: Pass provider in every relevant run.** `AgentClient.run` sends `agent.provider`; summarize calls use the agent provider and its default summarization model; scheduled tasks use the provider/model normalization from Task 2. Runs without an agent retain Claude defaults.
- [ ] **Step 4: Add a runner router without changing Claude behavior.** Preserve `RealRunner` as the Claude implementation; add a `ProviderRunner` dispatcher selected by `params.provider`. Keep `FakeRunner` able to cover both provider paths without starting external processes.
- [ ] **Step 5: Harden environment construction.** Add unit tests proving `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are only present for the matching provider child process and are never inherited from the app’s shell. Do not put keys in command-line arguments.
- [ ] **Step 6: Verify the contract.** Run `cd agent && npm test -- test/runner.test.ts test/main.test.ts` and `cd agent && npm run typecheck`; run `cd app && swift test --filter AgentClientRobustnessTests`. Expected: PASS.
- [ ] **Step 7: Commit.** `git add app/Sources/FrontbotCore/Agent/AgentClient.swift app/Sources/FrontbotApp/AppModel.swift app/Tests/FrontbotCoreTests/AgentClientRobustnessTests.swift agent/src agent/test && git commit -m "refactor(agent): route runs by provider"`.

## Task 5: Local MCP bridge for Codex tools

**Files:**
- Modify: `agent/src/tools.ts`
- Create: `agent/src/frontbot-mcp.ts`
- Create: `agent/src/tool-bridge.ts`
- Modify: `agent/src/main.ts`
- Modify: `agent/package.json` only if the existing MCP SDK lacks the server transport needed
- Test: new `agent/test/frontbot-mcp.test.ts`
- Test: new `agent/test/tool-bridge.test.ts`

- [ ] **Step 1: Extract provider-independent Frontbot tool definitions.** Refactor `tools.ts` so tool names, schemas, descriptions and `AppCall` handlers can be registered both with the current Claude SDK server and the MCP server used by Codex. Keep current names and allowlists unchanged.
- [ ] **Step 2: Define the private local bridge contract.** Add a per-run Unix-domain socket with a random one-run token. The sidecar owns the listener and forwards MCP tool calls through `AppCall` over its existing `RpcPeer` to Swift; the bridge must reject unknown tools, malformed requests and invalid tokens.
- [ ] **Step 3: Add bridge tests with an in-memory RPC peer.** Verify an MCP tool request reaches the registered Swift handler, returns its result/error, and cannot call a tool excluded by that run’s `ToolContext`.
- [ ] **Step 4: Register the MCP transport.** `frontbot-mcp.ts` starts an MCP stdio server for Codex and relays requests through the authenticated local socket. No business data is read directly from SQLite or files by the bridge process.
- [ ] **Step 5: Verify permissions remain app-owned.** Cover file writes, scripts, trading proposals, memory, and scheduled-task `notify_user`: each operation must still go through the existing Swift `tool.*` request handler and its existing approval rules.
- [ ] **Step 6: Run sidecar tests.** Run `cd agent && npm test -- test/tools.test.ts test/frontbot-mcp.test.ts test/tool-bridge.test.ts`; expected: PASS. Run `cd agent && npm run typecheck`; expected: PASS.
- [ ] **Step 7: Commit.** `git add agent/src/tools.ts agent/src/frontbot-mcp.ts agent/src/tool-bridge.ts agent/src/main.ts agent/test agent/package.json agent/package-lock.json && git commit -m "feat(agent): expose Frontbot tools to Codex"`.

## Task 6: Codex app-server runtime

**Files:**
- Create: `agent/src/codex-runner.ts`
- Create: `agent/src/codex-app-server.ts`
- Create: `agent/src/codex-protocol.ts`
- Modify: `agent/src/runner.ts`
- Modify: `agent/src/main.ts`
- Test: new `agent/test/codex-protocol.test.ts`
- Test: new `agent/test/codex-runner.test.ts`
- Test: `agent/test/main.test.ts`

- [ ] **Step 1: Validate the exact app-server handshake before coding.** Use the installed Codex CLI, when available, to verify `codex app-server --listen stdio://`, `initialize`/`initialized`, `thread/start`, `turn/start`, text delta events, `turn/completed`, cancellation and MCP server configuration. Record protocol/version assumptions in code comments and docs. If local CLI is unavailable, drive this step with official protocol fixtures and mark the live smoke check for Task 9.
- [ ] **Step 2: Add protocol parser tests.** Parse newline-delimited JSON-RPC replies and notifications; ignore unrelated notifications; reject malformed response envelopes; map text deltas, tool events, turn completion/failure and approval requests to typed events.
- [ ] **Step 3: Add a process wrapper with injected spawn.** `CodexAppServer` starts the discovered executable with `app-server --listen stdio://`, uses separate stdin/stdout streams, sends `initialize` then `initialized`, and owns graceful shutdown. Inject the spawn function so tests use a fake process.
- [ ] **Step 4: Implement Codex turn lifecycle.** `CodexRunner` starts a thread/turn for each run using Frontbot-supplied history and prompt, applies provider model and per-run MCP configuration, emits Frontbot status/text/tool-call events, and returns `RunDone` with usage when available. Set persistence/configuration explicitly so Codex does not retain duplicate conversation history outside Frontbot.
- [ ] **Step 5: Implement cancellation and process cleanup.** On `AbortSignal`, send the app-server interrupt/cancel request, wait the configured grace period, then terminate the child; always close the MCP bridge and release sockets. Ensure each run resolves once, even when cancellation races turn completion.
- [ ] **Step 6: Apply Frontbot sandbox and approval policy.** Map the no-workdir mode to deny-by-default/no arbitrary shell access. Map workdir mode to the same allowed directories and command/write approval requests as current Claude behavior. If app-server cannot express an equivalent restriction, keep the Codex workdir feature disabled with a clear message; do not relax the current security policy.
- [ ] **Step 7: Test success and failure paths with a fake app-server.** Cover startup failure, invalid auth, unsupported model, MCP failure, stream ordering, user cancel, turn failure, process exit, usage unavailable and secret redaction. Run `cd agent && npm test -- test/codex-protocol.test.ts test/codex-runner.test.ts test/main.test.ts`; expected: PASS.
- [ ] **Step 8: Run full sidecar checks and commit.** Run `cd agent && npm run typecheck && npm test`; expected: PASS. Commit with `git add agent/src agent/test && git commit -m "feat(agent): run Codex app-server turns"`.

## Task 7: Provider-specific capability and lifecycle integration

**Files:**
- Modify: `agent/src/prompt.ts`, `agent/src/runner.ts`, `agent/src/codex-runner.ts`
- Modify: `app/Sources/FrontbotApp/AppModel.swift`, `app/Sources/FrontbotApp/Lab/NotebookView.swift` or `LabTabView.swift`, `app/Sources/FrontbotApp/AgentDetailView.swift`
- Test: `agent/test/runner.test.ts`, new `agent/test/codex-capabilities.test.ts`
- Test: `app/Tests/FrontbotCoreTests/AgentClientRobustnessTests.swift`, `LabSchedulerTests.swift`

- [ ] **Step 1: Add capability matrix tests.** Codex receives app-owned tools and eligible workdir tools; it never receives Claude in Chrome or Lab-only tools. Claude’s existing browser and Lab paths remain unchanged.
- [ ] **Step 2: Route background conversation summaries.** Use the conversation agent’s provider and its provider-specific summary model. Keep summaries limited to the existing memory tool allowlist and never fall back to Claude automatically.
- [ ] **Step 3: Enforce Lab provider behavior.** Prevent selecting a Codex agent for a new Lab session and show the already specified Claude-only explanation. Existing Claude Lab sessions remain unaffected by the migration.
- [ ] **Step 4: Preserve run accounting.** Record tokens when Codex returns them and record cost only when a valid comparable cost is supplied; represent unavailable cost as unavailable in display logic rather than fabricated zero cost.
- [ ] **Step 5: Verify lifecycle.** Run `cd agent && npm test -- test/runner.test.ts test/codex-capabilities.test.ts test/lab.test.ts test/scheduled.test.ts`; run `cd app && swift test --filter AgentClientRobustnessTests` and `cd app && swift test --filter LabSchedulerTests`. Expected: PASS.
- [ ] **Step 6: Commit.** `git add app/Sources/FrontbotApp app/Tests/FrontbotCoreTests agent/src agent/test && git commit -m "feat(agent): preserve provider capabilities and lifecycle"`.

## Task 8: Settings help, packaging and documentation

**Files:**
- Create: `README.md`
- Modify: `scripts/build-app.sh` only if build-time validation or packaging metadata needs an update
- Modify: `app/Sources/FrontbotApp/SettingsView.swift` for final setup/error copy
- Test: `app/Tests/FrontbotCoreTests/CodexLocatorTests.swift`
- Test: manual app build and signed package inspection

- [ ] **Step 1: Document Codex setup.** Explain that Codex CLI must be installed and signed in, or an OpenAI API key must be saved in Ajustes. State that Codex chat/scheduled runs use the selected agent provider, Lab and Claude in Chrome remain Claude-only, and billing follows the chosen authentication path.
- [ ] **Step 2: Add actionable unavailable/error guidance.** Ensure missing CLI, missing login/API key, invalid key and app-server startup errors tell the user exactly what to fix and do not include secret values.
- [ ] **Step 3: Validate packaged-app CLI discovery.** Confirm a GUI-launched app can locate Codex through supported paths despite the reduced macOS GUI `PATH`. Do not use shell profile sourcing or shell interpolation.
- [ ] **Step 4: Build release app.** Run `scripts/build-app.sh`; expected: release `.app` assembles successfully and still includes the existing Claude sidecar resources. Codex CLI remains an external prerequisite unless a separate distribution decision changes the PRD.
- [ ] **Step 5: Commit.** `git add README.md scripts/build-app.sh app/Sources/FrontbotApp/SettingsView.swift app/Tests/FrontbotCoreTests/CodexLocatorTests.swift && git commit -m "docs: explain Codex provider setup"`.

## Task 9: End-to-end acceptance

**Files:**
- Test: existing and new tests from Tasks 1–8
- Modify: only files needed to fix verified failures

- [ ] **Step 1: Run all Swift tests.** Run `cd app && swift test`; expected: PASS, including old Claude credential, agent, task, Lab and approval behavior.
- [ ] **Step 2: Run all Node tests and typecheck.** Run `cd agent && npm test && npm run typecheck`; expected: PASS.
- [ ] **Step 3: Verify Claude regression manually.** Start Frontbot with an existing Claude agent, test chat streaming, a Frontbot tool call, scheduled run, cancellation, and existing Claude in Chrome behavior.
- [ ] **Step 4: Verify Codex account-session path manually.** Select Codex for one agent while keeping another on Claude; run a streamed chat, a tool call, a follow-up turn with Frontbot history, cancellation, and a scheduled task. Confirm Settings provider selection did not change either agent.
- [ ] **Step 5: Verify API-key and error paths manually.** Save a valid OpenAI API key, run Codex, delete the key, then test missing auth and missing CLI messaging. Confirm the key is absent from SQLite, logs, process arguments and rendered UI after save.
- [ ] **Step 6: Verify permissions manually.** With a Codex agent, test denied shell/file actions, an in-workdir read, a write requiring approval, an outside-workdir write requiring approval, and a trading proposal requiring the existing user approval. Any permission mismatch blocks release.
- [ ] **Step 7: Verify migration and feature boundaries.** Launch against an existing database, confirm all agents use Claude until changed, confirm Lab and Claude in Chrome show provider limits for Codex, and check unavailable cost is not displayed as a real `$0` cost.
- [ ] **Step 8: Commit any final fixes separately.** Use focused conventional commits; do not combine security-policy changes with UI polish.

## PRD coverage check

| PRD requirement | Plan task |
|---|---|
| Per-agent provider and existing-agent migration | 1, 2 |
| Provider-specific model catalog | 1, 2, 7 |
| Claude/OpenAI Keychain credentials and CLI status | 3 |
| Shared account selector in Settings | 3 |
| Codex app-server routing, streaming and cancellation | 4, 6 |
| Frontbot MCP tools and Swift-owned data | 5, 6 |
| File/command/trading approvals | 5, 6, 9 |
| Scheduled tasks and summaries use assigned provider | 2, 4, 7 |
| Claude in Chrome and Lab boundaries | 2, 7 |
| Usage/cost reporting and safe errors | 6, 7, 8 |
| Compatibility, regression, packaging and acceptance | 1–9 |

## Self-review

- No unresolved placeholders remain. The live app-server protocol validation is explicitly Task 6 Step 1 and is a prerequisite for implementing the adapter.
- Provider/model selection is consistently stored on `Agent`; scheduled task model overrides are normalized against that agent’s provider before execution.
- The security requirement is repeated at the MCP bridge, app-server sandbox mapping and final acceptance levels; Codex workdir stays disabled if equivalent permission enforcement cannot be demonstrated.
- No PRD requirement is omitted. The plan does not add Codex support to the experimental Lab or Claude in Chrome, matching the approved PRD.
