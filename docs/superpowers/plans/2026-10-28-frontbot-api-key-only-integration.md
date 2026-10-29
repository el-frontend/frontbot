# Frontbot API Key Only Codex Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (selected by the user) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run agents assigned to Codex through the OpenAI Responses API using only the workspace API key, with Frontbot tools, history, permissions, and approvals remaining authoritative.

**Architecture:** Keep the existing persisted `codex` provider and per-agent model selection. The Swift app supplies its Keychain API key privately to the Node sidecar; a direct Responses API runner streams results and executes only the Frontbot function tools allowed for that run through the existing `AppCall` RPC. No Codex CLI, app-server, native shell/filesystem tools, hosted MCP, or remote conversation state is used.

**Tech Stack:** Swift 6, SwiftUI, GRDB/SQLite, Keychain, Node 24, TypeScript, Vitest, native `fetch`/SSE, OpenAI Responses API.

**Spec path:** `docs/superpowers/specs/2026-10-28-frontbot-api-key-only-design.md` (user-approved). This plan supersedes the runtime, credential, and model-catalog sections of `docs/superpowers/plans/2026-10-28-frontbot-codex-integration.md`; already completed provider persistence, per-agent selection, scheduled-task routing, and credential storage work is the baseline.

## Global Constraints

- Preserve the existing `agent.event` and `agent.done` JSON-RPC contracts and Claude behavior.
- Keep the API key in Keychain and private runner configuration only. Never put it in request parameters, argv, SQLite, logs, or user-visible errors. Remove inherited `OPENAI_API_KEY` values from the sidecar environment.
- Send `store: false` on every Responses request. Do not use `previous_response_id`, Conversations API state, or imply that `store: false` is Zero Data Retention.
- Each request may expose only the current run's allowlisted Frontbot function tools. Never expose OpenAI native tools, shell, arbitrary code, browser, filesystem, hosted MCP, or web search.
- Validate complete function call names and JSON arguments before dispatch. Route every call through the existing Frontbot tool handler and Swift approval path; unknown or denied calls fail closed.
- Abort active HTTP requests and pending tool work on cancellation. Emit exactly one final `agent.done` per run.
- Do not silently fall back to Claude, a local CLI, another model, or a different authentication method.
- Preserve scheduled-task provider/model normalization, Lab's Claude-only boundary, and Claude in Chrome's Codex-disabled boundary.

## Review Focus

| Input class or failure mode | Required coverage | Owning task |
|---|---|---|
| Secret handling and API authentication | Keychain save/delete/presence, sidecar env stripping, safe errors for missing/invalid keys, no key in logs or emitted errors | 1, 5 |
| Untrusted model tool calls | Unknown function, malformed JSON, schema-invalid arguments, and tool not in the run allowlist are rejected before `AppCall` | 2, 4 |
| Stream/protocol ordering and incomplete data | SSE text/function events, malformed or unrelated events, missing terminal completion, multiple function calls, replay of full output items | 3, 4 |
| Cancellation, timeouts, and provider failures | Active fetch abort, pending `AppCall`, rate-limit/network/model/API errors, exactly-once completion | 3, 4 |
| Provider boundaries and user data ownership | Only Frontbot tools, `store:false`, no remote history IDs, Claude unchanged, schedules/Lab/Chrome boundaries preserved | 1, 4, 5 |

## Repository map

| Area | Existing files | Planned responsibility |
|---|---|---|
| Settings and model catalog | `app/Sources/FrontbotApp/SettingsView.swift`, `app/Sources/FrontbotCore/Agent/AgentProvider.swift`, `app/Sources/FrontbotCore/Credentials/CredentialStore.swift` | API-key-only UI, API models, secure key operations; remove CLI status/login/discovery UI. |
| Sidecar run and tools | `agent/src/main.ts`, `agent/src/runner.ts`, `agent/src/tools.ts`, `agent/src/rpc.ts` | Supply `AppCall` to the provider runner and preserve the shared Frontbot validation/approval handlers. |
| New API adapter | New `agent/src/openai-responses.ts` and focused tests | Build Requests API payloads, parse SSE, normalize API errors, support abort. |
| Codex runner | `agent/src/codex-runner.ts`, `agent/test/codex-runner.test.ts` | Stateless Responses tool loop, event translation, bounded function dispatch and completion. |
| Legacy CLI path | `app/Sources/FrontbotCore/Agent/CodexLocator.swift`, `agent/src/codex-app-server.ts`, `agent/src/codex-protocol.ts`, `agent/docs/codex-app-server-protocol-validation.md` and related tests | Remove code and copy that are no longer part of the API-key-only product path. |
| Validation | `agent/test/`, `app/Tests/FrontbotCoreTests/` | Fake HTTP streaming server, security and protocol tests, full existing regression suite. |

## Task 1: Make Codex settings and models API-key-only

**Files:**
- Modify: `app/Sources/FrontbotApp/SettingsView.swift`
- Modify: `app/Sources/FrontbotApp/AppModel.swift`, `app/Sources/FrontbotCore/Agent/AgentClient.swift`
- Modify: `app/Sources/FrontbotCore/Agent/AgentProvider.swift`
- Modify: `app/Sources/FrontbotCore/Credentials/CredentialStore.swift` only if credential labeling or presence API needs adjustment
- Modify/test: corresponding `app/Tests/FrontbotCoreTests/` settings, provider, and credential tests
- Remove: `app/Sources/FrontbotCore/Agent/CodexLocator.swift` and its tests if no remaining references exist

- [ ] **Step 1: Add tests for the API-only model catalog and credential state.** Expect the selector to expose `gpt-6-astra` by default and `gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-luna` as alternatives; credential UI state reveals saved/not-saved only.
- [ ] **Step 2: Run focused Swift tests.** Use `cd app && swift test --filter AgentProviderTests` and the credential/settings test filters; confirm the new expectations fail before implementation.
- [ ] **Step 3: Update the catalog and Settings copy.** Remove executable discovery, CLI login/auth status, and local-session claims. Retain per-agent provider selection and secure save/delete. Explain API project billing separately from ChatGPT/Codex subscriptions and never reveal the saved value.
- [ ] **Step 4: Remove obsolete CLI locator UI/state.** Delete `CodexLocator` only after references are removed; do not change unrelated Claude account setup.
- [ ] **Step 5: Verify and commit.** Run the focused Swift tests and commit as `feat(settings): make Codex API key only`.

## Task 2: Connect direct Frontbot tool execution to provider runs

**Files:**
- Modify: `agent/src/main.ts`, `agent/src/runner.ts`, `agent/src/tools.ts`
- Modify: `agent/test/main.test.ts`, `agent/test/runner.test.ts`, `agent/test/tools.test.ts`

- [ ] **Step 1: Add a runner test for direct `AppCall` injection.** Verify Codex uses the same provider-neutral tool specifications and handlers, and Claude still receives its existing SDK tools.
- [ ] **Step 2: Extract the run-scoped `AppCall` construction.** Keep RPC correlation, timeout behavior, sensitive-operation approval, and trusted trading context enrichment intact; pass the callback into the Codex runner without exposing RPC internals to the HTTP adapter.
- [ ] **Step 3: Export/reuse the Frontbot tool schemas and execution handler.** Derive function definitions from each run's `ToolContext`, validate completed arguments with existing Zod schemas, and route approved calls through `call("tool.<name>", ...)`.
- [ ] **Step 4: Remove the per-run Codex MCP socket bridge.** Retain unrelated MCP code only if another current provider path uses it; the Codex API path must not start an MCP subprocess or listener.
- [ ] **Step 5: Verify and commit.** Run focused sidecar tests and commit as `refactor(agent): dispatch Codex tools through Frontbot RPC`.

## Task 3: Implement the Responses API transport and SSE parser

**Files:**
- Create: `agent/src/openai-responses.ts`
- Create: `agent/test/openai-responses.test.ts`
- Modify: `agent/package.json` only if native fetch is insufficient (default to no new dependency)

- [ ] **Step 1: Write request and SSE parser tests.** Cover `stream:true`, `store:false`, selected model, function tool payload, authorization header, text delta, function call completion, response completion, API error, malformed JSON/SSE, unknown events, and abort.
- [ ] **Step 2: Run the focused Vitest file and confirm expected failures.** `cd agent && npx vitest run test/openai-responses.test.ts`.
- [ ] **Step 3: Implement a small native-fetch transport.** POST to the Responses endpoint, parse `text/event-stream` incrementally, forward typed events, and accept an `AbortSignal`. Never include the key in thrown error text.
- [ ] **Step 4: Normalize HTTP/provider errors safely.** Map authentication, rate limits, unavailable models, request-size errors, network failures, and generic provider errors to actionable redacted messages.
- [ ] **Step 5: Verify and commit.** Re-run the focused tests and commit as `feat(agent): add Responses API streaming transport`.

## Task 4: Implement the stateless Codex tool loop

**Files:**
- Modify: `agent/src/codex-runner.ts`, `agent/src/runner.ts`, `agent/src/main.ts`
- Modify: `app/Sources/FrontbotCore/Agent/AgentClient.swift`, run result persistence/display only if needed to represent unavailable cost separately from `$0`
- Modify: `agent/test/codex-runner.test.ts`, `agent/test/runner.test.ts`, `agent/test/main.test.ts`

- [ ] **Step 1: Add failing runner tests using a fake Responses transport.** Cover text-only success, sequential and parallel function calls, invalid/unknown tools, multiple tool-loop rounds, usage counts, cancellation, API errors, and exactly-once completion.
- [ ] **Step 2: Implement request construction.** Use Frontbot's `history` and prompt, selected model, system instructions, current run's Frontbot function tools, `stream:true`, and `store:false`. Do not use `previous_response_id` or remote conversation state.
- [ ] **Step 3: Implement function-call execution.** Wait for complete call items, validate and invoke each through `AppCall`, then send correlated `function_call_output` items with every item from the preceding `response.output` in the next request. Bound loop work and reject calls outside the current allowlist.
- [ ] **Step 4: Implement event, cancellation, and accounting behavior.** Emit Frontbot text/status/tool events, abort in-flight fetch on cancellation, propagate pending RPC cancellation where supported, and count only provider-reported tokens. Extend the run-result contract and stored usage state only as needed so unavailable cost is distinct from `$0` in run and scheduled-run history.
- [ ] **Step 5: Wire production configuration and routing.** Construct the runner with the API key captured from the private app-provided environment. Keep the key out of `RunParams`; no fallback path is allowed.
- [ ] **Step 6: Verify and commit.** Run focused runner/RPC tests and commit as `feat(agent): run Codex through Responses API`.

## Task 5: Remove unreachable CLI/app-server runtime and update product boundaries

**Files:**
- Remove: `agent/src/codex-app-server.ts`, `agent/src/codex-protocol.ts`, associated tests, and `agent/docs/codex-app-server-protocol-validation.md` once no references remain
- Modify: `agent/src/runner.ts`, `agent/src/main.ts`, `agent/test/runner.test.ts`, `agent/test/main.test.ts`
- Modify: the relevant setup documentation; remove outdated CLI setup instructions
- Modify: provider/schedule/Lab/Chrome tests only where needed to codify existing behavior

- [ ] **Step 1: Search for CLI/app-server remnants and identify references.** Confirm credential environment plumbing, UI status, tests, docs, and protocol code are either deleted or deliberately retained for a non-production test fixture.
- [ ] **Step 2: Delete unreachable production code and obsolete documentation.** Remove `CodexRunner` configuration fields such as `executable`, `consumeCodexRuntimeConfig`, CLI process spawning, and old app-server protocol modules. Keep the simple provider selector and key handling.
- [ ] **Step 3: Add regression assertions for capability boundaries.** Confirm no shell/filesystem-native tool definitions are sent, Lab remains Claude-only, Claude in Chrome remains disabled for Codex, and scheduled runs preserve Codex model/provider normalization.
- [ ] **Step 4: Document setup and data behavior.** Explain API key setup, API project billing, Frontbot-owned history, `store:false` scope, and that data handling follows the selected OpenAI API project's controls. Do not promise ZDR.
- [ ] **Step 5: Verify and commit.** Run typecheck and relevant Swift/sidecar tests; commit as `chore(agent): remove Codex CLI runtime`.

## Task 6: Full feature acceptance and integration verification

**Files:**
- Modify only files needed to resolve integration defects discovered during verification
- Test: entire existing agent and Swift test suites

- [ ] **Step 1: Run sidecar verification.** `cd agent && npm test && npm run typecheck && npm run build`.
- [ ] **Step 2: Run Swift verification.** `cd app && swift test`.
- [ ] **Step 3: Exercise the HTTP adapter against a local fake OpenAI server.** Verify successful text, one Frontbot function call, multiple loop rounds, abort, missing/invalid key responses, and unsupported model errors without a production API key.
- [ ] **Step 4: Review generated requests and emitted events.** Confirm `store:false`, no remote conversation ID, only Frontbot functions, no credentials outside the authorization header, one final completion, and only reported usage/cost values.
- [ ] **Step 5: Complete a manual smoke test with a developer-owned API key.** Verify settings save/delete, successful run, tool approval flow, cancellation, missing key, invalid key, and unsupported model. Confirm the credential is absent from SQLite, logs, argv, and UI after saving.
- [ ] **Step 6: Commit any final fixes separately.** Keep security, runtime, and UI corrections in focused commits.

## PRD and approved design coverage

| Requirement | Plan task |
|---|---|
| Per-agent provider and existing-agent migration | Completed baseline; regression in 5 and 6 |
| Provider-specific Responses API model catalog | 1 |
| OpenAI API key in Keychain, API-only Settings | 1, 5 |
| Direct streaming Responses API runtime | 3, 4 |
| Frontbot-only function calls and approval path | 2, 4 |
| Frontbot-owned history; `store:false`; no stored response IDs | 4, 5 |
| Cancellation, safe errors, token/cost handling | 3, 4, 6 |
| Scheduled runs and summaries use assigned provider | 5, 6 |
| Lab and Claude in Chrome provider restrictions | 5, 6 |
| Remove unsupported CLI/app-server behavior | 1, 5 |
| Regression and acceptance | 6 |

## Self-review

- No placeholders or unresolved decisions remain; API-only architecture and its security limits are defined in the approved design addendum.
- All design requirements map to a task above. Previously delivered provider persistence, per-agent selection, scheduling, and Keychain support remain the baseline and receive regression coverage.
- Request state is consistent: each tool-loop request replays complete prior `response.output` items plus correlated outputs, with `store:false` and no response IDs.
- The five review focus categories map to concrete owning tasks and validation cases.
- The manual API-key smoke test is separate from the automated suite and uses a developer-owned key; automated protocol tests use a local fake server.
