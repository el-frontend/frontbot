# Frontbot OpenAI API Key Only Integration Design Amendment

> This amendment replaces the Codex CLI/app-server runtime and local-session authentication in the approved Frontbot Codex integration PRD. The provider remains selectable per agent, but authentication uses an OpenAI API key only.

## Context and decision

The approved app-server design was prototyped against the installed Codex CLI `0.158.0-alpha.2.1`. Its generated `SandboxPolicy.readOnly` schema does not expose restricted read roots. The isolated CLI probe could initialize a thread and connect to a local MCP server, but it could not validate a completed authenticated turn or demonstrate that native shell and file-read capabilities can be denied while MCP remains available. Read-only access therefore cannot meet Frontbot's security boundary, and the production Codex runtime is currently disabled.

The user approved an API-key-only route. Frontbot will call the OpenAI Responses API directly from its Node sidecar. It will expose only Frontbot-owned function tools for each run, and each function call will return to Swift through the existing `tool.*` RPC handling and approval flow. The Codex CLI, local Codex session, app-server process, native shell tools, and the per-run MCP socket are out of scope for this version.

The internal persisted provider identifier remains `codex` to preserve the v12 database migration and existing agent assignments. Settings will present this as a Codex/OpenAI API-key connection and will not imply that CLI sign-in is supported.

## Goals

- Run a Codex-selected agent using only a workspace-scoped OpenAI API key stored in Keychain.
- Keep Claude's existing provider and runtime behavior unchanged.
- Give the model only the Frontbot functions allowed by the agent's existing `ToolContext`; never offer shell, filesystem-native, browser, or other built-in tools.
- Preserve Frontbot as the source of conversation history and tool approval decisions.
- Keep streaming, cancellation, error reporting, and the existing `agent.event` / `agent.done` contract.
- Support provider-specific model selection using documented Responses API model IDs.

## Non-goals

- Codex CLI session authentication, app-server, or CLI discovery.
- Native Codex shell or filesystem tools.
- OpenAI-hosted MCP, browser, web search, file search, or other built-in tools.
- Changing the Claude provider, its credentials, models, or capabilities.
- Persisting conversation state in OpenAI Conversations or chaining stored `previous_response_id` state.

## Architecture and data flow

1. Swift loads the workspace's OpenAI API key from Keychain and provides it to the Node sidecar through its private process environment. It remains absent from JSON-RPC run parameters, process arguments, logs, SQLite, and UI state after save.
2. At sidecar initialization, Node removes inherited `OPENAI_API_KEY` values from `process.env` and retains only the workspace key in the OpenAI runner's private configuration. The runner uses the key only for the HTTPS `Authorization` header to `api.openai.com`.
3. For each Codex run, the sidecar constructs a Responses API input from the Frontbot-supplied conversation history and current prompt. The request uses `stream: true`, `store: false`, the selected model, and only the current run's Frontbot function definitions. No native or built-in tools are included.
4. The sidecar translates Responses SSE text deltas and status/error events into Frontbot events. It completes an assistant turn only after the response reaches a successful terminal state.
5. For each function call, the sidecar validates the function name and JSON arguments against the current run's allowlist, invokes the existing Frontbot tool handler via `AppCall` / `RpcPeer`, and supplies a correlated `function_call_output` in the next Responses request. Within the current run, it replays the complete prior `response.output` items along with tool outputs so stateless reasoning and function-call context remain intact. Approval-gated operations continue through the existing Swift approval path.
6. The tool loop is bounded by cancellation and configured limits. An `AbortSignal` aborts the active fetch; pending Swift tool calls retain their existing request correlation and timeout behavior. Each run emits one `agent.done` result.
7. On the next user turn, Frontbot provides its own persisted user/assistant history again. The OpenAI response object is not used as a remote conversation store.

`store: false` disables the normal stored response object behavior; it is not a claim of Zero Data Retention or of no processing. Users remain subject to the data controls applicable to their OpenAI API project. See [Responses conversation state and `store: false`](https://developers.openai.com/api/docs/guides/conversation-state) and [OpenAI API data controls](https://developers.openai.com/api/docs/guides/your-data).

## Tools and permissions

- Reuse provider-neutral Frontbot tool schemas and handler definitions created for the bridge work; call them directly inside the sidecar instead of launching an MCP stdio child.
- Preserve per-agent allowlists, existing tool schemas, approval prompts, write restrictions, script approval, trading approvals, and scheduled `notify_user` handling.
- Do not include an OpenAI `shell`, custom-code, hosted MCP, web, or file-search tool in a request.
- Never interpret model output or a tool name as an approval. Swift remains the authority for all sensitive operations.
- If a function name is unknown, the arguments are invalid, the API returns an unsupported tool call, or the API key/model is unavailable, fail the run with a safe error. Never fall back to Claude or to a local CLI.

## Model catalog

Use current documented Responses API model IDs in the Codex selector: `gpt-6-astra`, `gpt-6.1-sol`, `gpt-6.1-terra`, and `gpt-6-luna`. Default to `gpt-6-astra`. OpenAI documents GPT-6 Astra as its flagship for complex reasoning and coding and documents GPT-6.1 Sol and GPT-6 Luna as alternatives; see [OpenAI Models](https://developers.openai.com/api/docs/models) and [Function calling](https://developers.openai.com/api/docs/guides/function-calling).

Model access depends on the API project. Unsupported or unavailable models produce a specific actionable error; Frontbot does not silently choose another model. The account selector is not a CLI session selector.

## Settings and billing

- Keep the existing provider selection per agent and workspace-scoped Keychain credential operations.
- Remove Codex CLI status, login instructions, executable discovery, and the suggestion that an existing local Codex session can authenticate Frontbot.
- Show only the OpenAI API key state (saved/not saved), secure save/delete actions, and safe error copy. Never display the saved key value.
- Explain that Codex runs use the selected OpenAI API key and are billed under the corresponding OpenAI API project, independently of a ChatGPT/Codex subscription.
- Keep the Lab and Claude in Chrome boundaries unchanged.

## Error, streaming, and usage handling

- Parse the Responses SSE event stream, including text deltas, completed function calls, terminal completion, and API errors. Ignore unrelated event types safely.
- Do not execute a partial function call; wait for the complete call item and validate its JSON before dispatch.
- Redact API keys and authorization data from request errors, logs, and emitted user-facing messages.
- Map authentication, rate limit, unsupported model, request-size, network, cancellation, and provider failures to safe actionable messages.
- Record token counts only when the response reports them. Report cost only when a valid comparable cost is available; otherwise treat it as unavailable rather than `$0`.

## Validation and acceptance

- Unit tests cover SSE parsing/order, multi-step function-call output handling, tool allowlist rejection, API error redaction, key isolation, `store: false`, cancellation, malformed events, and exactly-once completion.
- Tests prove the API request contains only allowed Frontbot function tools and never a shell/native tool.
- Tests prove all Frontbot function calls go through the existing `AppCall` handler and approval path.
- Swift tests cover API-key save/delete presence state and model-catalog migration/normalization.
- A fake OpenAI HTTP server exercises streaming without using a production API key. A manual smoke test with a developer-owned API key verifies a successful text turn, Frontbot tool call, cancellation, missing key, invalid key, and unsupported model.
- Existing Claude tests and capability flows remain green.

## OpenAPI references

- [Responses API function calling](https://developers.openai.com/api/docs/guides/function-calling): the application receives function calls, executes its own code, and returns correlated function outputs.
- [Responses API streaming](https://developers.openai.com/api/docs/guides/streaming-responses): streaming uses typed server-sent events.
- [Conversation state](https://developers.openai.com/api/docs/guides/conversation-state): history can be managed manually and `store: false` disables normal response-object persistence.
- [Models](https://developers.openai.com/api/docs/models): current model IDs and selection guidance.
