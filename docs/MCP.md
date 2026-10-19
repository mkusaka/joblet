# Joblet MCP server

`joblet-mcp` is a Model Context Protocol server over stdio. An MCP client (Claude Code, Codex, Claude Desktop, ...) launches it as a child process and it operates your launchd LaunchAgents as the logged-in user through the same `JobRepository` the app uses. There is no network port, token or resident helper, and Joblet.app does not need to be running.

## Build and locate

```bash
scripts/build-app.sh                              # Joblet.app with the server at Contents/Helpers/joblet-mcp
swift build -c release --product joblet-mcp       # server only: .build/release/joblet-mcp
.build/release/joblet-mcp --help
```

Use the absolute path of the executable in your MCP configuration, for example `/Applications/Joblet.app/Contents/Helpers/joblet-mcp` after copying the app to Applications. Building in Xcode alone does not bundle the server. `build-app.sh` re-signs the app ad hoc after adding it (no notarization).

## Connect an agent

Start read-only; add flags only for what you need.

```bash
# Claude Code (read-only)
claude mcp add --scope user --transport stdio joblet -- /Applications/Joblet.app/Contents/Helpers/joblet-mcp
# Claude Code (create/edit/enable/disable and run)
claude mcp add --scope user --transport stdio joblet -- /Applications/Joblet.app/Contents/Helpers/joblet-mcp --allow-write --allow-run
```

Codex, `~/.codex/config.toml` (or `codex mcp add joblet -- <path> <flags>`):

```toml
[mcp_servers.joblet]
command = "/Applications/Joblet.app/Contents/Helpers/joblet-mcp"
args = ["--allow-write", "--allow-run"]
```

Claude Desktop and other JSON hosts:

```json
{ "mcpServers": { "joblet": { "command": "/Applications/Joblet.app/Contents/Helpers/joblet-mcp", "args": ["--allow-write", "--allow-run"] } } }
```

Joblet's Settings has an "Agent integration (MCP)" pane that copies this JSON with the right path.

## Permissions

Default: read-only, and only jobs created by Joblet (`local.joblet.<uuid>` labels). Tools that are not enabled are not listed and are rejected if called.

| Flag | Adds |
| --- | --- |
| *(none)* | `list_jobs`, `get_job`, `read_log` |
| `--allow-write` | `create_job`, `update_job`, `set_job_enabled`, `set_job_group` |
| `--allow-run` | `run_job` |
| `--allow-delete` | `delete_job` (plist is backed up first; logs are kept) |
| `--include-external` | Show, read and read logs of jobs created by other apps |
| `--allow-external-control` | With `--include-external` and the matching `--allow-write` / `--allow-run`: enable, disable, run and group external jobs |

External jobs can never be edited or deleted, with any flag. Every repository safety check still applies (running jobs are never modified, stale plists, duplicate labels, unsafe ownership and so on).

Write access is as powerful as shell access as you: `create_job` takes an arbitrary command, and `enabled` or `run_at_load` run it now or later. Pair it with per-call approval in your client and connect only agents you trust. Job commands, plists and logs are untrusted data and may contain prompt injection; logs may contain secrets.

## Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `list_jobs` | optional `group` (exact name) | jobs with label, name, schedule, `group` (or null), phase, enabled, pid, last exit code, `next_run_estimate`, `once_done`, `revision`; warnings only with `--include-external` |
| `get_job` | `label` | the above plus command, working directory, editable configuration, plist and log paths |
| `read_log` | `label`, `stream` (`stdout`/`stderr`), `max_bytes` (default 16384, max 65536) | tail of the log |
| `create_job` | `name`, `command`, optional `schedule`, `working_directory`, `run_at_load`, `enabled` | new label. Defaults: disabled, manual schedule, no run at load |
| `update_job` | `label`, `expected_revision`, `changes` | patch; omitted fields are kept, `schedule` is replaced whole |
| `set_job_enabled` | `label`, `expected_revision`, `enabled` | enable or disable |
| `set_job_group` | `label`, `group` (1 to 40 characters, or `null` to remove) | sets or clears the job's group in Joblet's `groups.json`; the plist and launchd are untouched |
| `run_job` | `label`, `expected_revision` | requests a run (`kickstart -p`) and does not wait for completion |
| `delete_job` | `label`, `expected_revision`, `confirm_label` (must equal `label`) | removes the job, keeps a backup and logs |

Mutations require `expected_revision`, the `revision` from a fresh `get_job` or `list_jobs`. It changes whenever the plist file changes; a stale value is rejected. It is a concurrency token, not a secret. `set_job_group` is the exception: it never changes the plist, so the token would not protect anything, and concurrent writes to `groups.json` are refused instead. Labels must match exactly, and a duplicated label is an error rather than a guess.

Schedules: `{"kind":"manual"}`, `{"kind":"interval","interval_minutes":10}`, `{"kind":"daily","hour":9,"minute":0}`, `{"kind":"weekly","weekday":1,"hour":9,"minute":0}` (0 = Sunday, local time), `{"kind":"once","date":"2026-10-20T09:00"}`. Unrelated fields and wrongly typed values are errors.

A `once` date is this Mac's local time, formatted exactly `YYYY-MM-DDTHH:MM`, and must be in the future when the job is created, updated or enabled. After it runs, the job disables and unregisters itself; `get_job` then reports `phase: "unloaded"` and `once_done: true`. If the Mac is asleep at that time it runs on wake; if the Mac is off, the run is missed. See the README for how the wrapper works.

`next_run_estimate` is an ISO 8601 time with the local offset, or `null`. It is an estimate, never a guarantee, and is `null` unless the job is enabled and loaded. Calendar and `once` jobs derive it from the rule. Interval jobs use the newest write to their stdout/stderr log plus the interval, so it is `null` until the job has written to its log, and it can be in the past when a run is overdue (for example after sleep).

## Protocol

- Newline-delimited JSON-RPC 2.0 on stdin/stdout; stdout carries protocol messages only. stderr gets one audit line per mutation (tool name and ok/failed, never arguments). Closing stdin shuts the server down.
- Supports MCP 2026-07-28 (stateless, per-request `_meta`, `server/discover`) and the earlier `initialize` handshake (2025-11-25, 2025-06-18, 2024-11-05, answering with the client's version when supported, otherwise 2025-11-25). Checked against https://modelcontextprotocol.io/specification/2026-07-28 and /2025-11-25.
- Unknown method: `-32601`. Malformed JSON: `-32700`. Invalid request (including batches): `-32600`. Bad params, missing required `_meta`, unknown or disabled tool: `-32602`. Unsupported 2026-07-28-era version: `-32022`. Tool failures are results with `isError: true`.
- Tool results carry `structuredContent` plus the same JSON as a text content block.
- Limits: 256 KiB per request, 64 KiB per log read, 20 mutations per minute per process.

## Limitations

- launchctl uses your `gui/<uid>` domain, so it needs a GUI login session (not SSH-only or logged out).
- Two MCP processes, or an MCP process and the app, editing the same job are protected by revision checks and the repository's file checks, not by a lock.
- Behavior against the real launchd is covered by manual checks, not automated tests: connect read-only first, then create a disabled `date` job with `--allow-write --allow-run --allow-delete`, enable it, run it, read its log and delete it.
