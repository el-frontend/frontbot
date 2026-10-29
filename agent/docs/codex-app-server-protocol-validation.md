# Codex app-server protocol validation

Validated on 2026-10-28 with the installed binary:

```text
/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
codex-cli 0.158.0-alpha.2.1
```

The probe used an isolated `CODEX_HOME` under `/private/tmp`; it did not read or modify the user's Codex state. The app-server communicates as newline-delimited JSON-RPC on stdio. The app-server schema was generated with:

```sh
CODEX_BIN=/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
"$CODEX_BIN" app-server generate-ts --experimental --out /private/tmp/frontbot-codex-protocol
```

## Observed protocol behavior

| Check | Result | Evidence / limitation |
| --- | --- | --- |
| `initialize` then `initialized` | Passed | `initialize` returned a JSON-RPC response; `initialized` is a notification. |
| `thread/start` | Passed | Returned a thread object with an ID using `ephemeral: true`. |
| `turn/start` | Request accepted; full turn unverified | The request was accepted, but an isolated home had no Codex sign-in/API credential and the environment could not complete a model request. No successful text delta was confirmed. |
| Streaming and completion | Not confirmed against the live service | The protocol schema and implementation support `item/agentMessage/delta` and `turn/completed`; no authenticated live turn was available to prove them end-to-end. Fake app-server coverage was part of the original Task 6 implementation, but does not prove CLI tool confinement. |
| `turn/interrupt` | Passed in the auth-free probe after turn start | The RPC response was received. |
| Cleanup | Passed | `thread/unsubscribe` is supported. `thread/close` is not a method in this CLI build. Ending the one-run app-server process also ends its MCP child. |
| Frontbot MCP config | Recognized, successful connection unverified | A deliberately missing `required` Frontbot MCP process caused `thread/start` to fail with “required MCP servers failed to initialize”. A successful authenticated/local MCP handshake was not established in the protocol probe. |
| Native shell/read confinement | **Not proven** | `app-server --help` exposes repeatable `--disable FEATURE` flags, and `features list` reports `shell_tool`, `unified_exec`, `unified_exec_tty`, and `shell_snapshot` as separate features. The CLI surface did not provide a verified per-thread allowlist or proof that all native command and file-read paths are unavailable while Frontbot MCP remains enabled. Approval policy and prompt instructions do not enforce this boundary. |

Useful commands to repeat the non-secret inspection:

```sh
CODEX_BIN=/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
"$CODEX_BIN" --version
"$CODEX_BIN" app-server --help
"$CODEX_BIN" features list
```

Feature flags were parsed by the installed app-server with:

```sh
CODEX_BIN=/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
CODEX_HOME=/private/tmp/frontbot-codex-home "$CODEX_BIN" app-server \
  --disable shell_tool \
  --disable unified_exec \
  --disable unified_exec_tty \
  --disable shell_snapshot \
  --listen stdio://
```

Parsing those flags is not evidence that native shell/read execution is impossible. Until a repeatable native-tool denial test and successful Frontbot MCP test establish that exact security property, Frontbot's `CodexRunner` intentionally returns a clear unavailable error before launching the CLI. Do not remove that gate based only on feature names, sandbox labels, approval settings, or model instructions.
