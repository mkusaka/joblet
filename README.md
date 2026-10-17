# Joblet

A small SwiftUI app for managing scheduled jobs on your Mac. Joblet is a front end for `launchd`: it creates, edits, enables, disables and runs the LaunchAgents in `~/Library/LaunchAgents`, and ships an MCP server so AI agents can do the same under explicit, opt-in permissions.

Joblet has no third-party dependencies and no timers of its own. Quit the app and your jobs keep running, because macOS runs them.

## Features

- List, search and filter jobs (all / created by Joblet / existing), with running / waiting / not loaded / unknown state.
- Create jobs with an interval, daily, weekly or manual-only schedule; edit and delete jobs created by Joblet.
- Enable, disable and run now. Read the tail of stdout/stderr and the plist (show or copy).
- Menu bar extra with job status and next run.
- `joblet-mcp`: a stdio MCP server (see below).

Jobs from other apps can be viewed, and enabled, disabled or run when they can be identified safely. They are never edited or deleted.

## Requirements

macOS 14 or later, Xcode 26 / Swift 6 toolchain (the package uses Swift language mode 5).

## Build and run

Open `Joblet.xcodeproj` in Xcode, choose the **Joblet** scheme and **My Mac**, then press Run. Or from a terminal:

```bash
scripts/build-app.sh
open build/Build/Products/Release/Joblet.app
```

The build is for your own Mac (ad-hoc signed, App Sandbox off, no notarization). Opening the app changes nothing by itself.

## How scheduling maps to launchd

| Schedule | Plist value |
| --- | --- |
| Every N minutes | `StartInterval = N * 60` |
| Daily at HH:mm | `StartCalendarInterval` with `Hour`, `Minute` |
| Weekly | the above plus `Weekday` (0 = Sunday) |
| Manual only | no time trigger |
| Also run when loaded | `RunAtLoad = true` |

The command runs through `/bin/zsh -c` with an explicit `PATH` (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`); your interactive `.zshrc` is not read. Use absolute paths for tools installed elsewhere, and do not put secrets in the command: it is stored in the plist.

- Enable is `launchctl enable` plus `bootstrap` when needed. Disable is `disable` plus `bootout`.
- Run now is `kickstart -p`; Joblet never force-kills a job (`-k`).
- Calendar jobs missed during sleep run on wake; nothing runs while the Mac is off. Interval jobs are not guaranteed to run during sleep.
- The next-run time shown is derived from the calendar rule and is an estimate. Interval jobs show none.

Created jobs get the label `local.joblet.<UUID>` (not editable). Logs live under `~/Library/Application Support/Joblet/Logs/<label>/`, and a backup of the previous plist is kept there on every edit or delete.

## Safety rules and limitations

- Current user's LaunchAgents only: no LaunchDaemons, other users, or crontab.
- A running job cannot be edited, disabled or deleted. Edits and deletes are refused when the plist changed since it was read, when labels are duplicated, when the plist is a symlink or has unsafe owner/permissions/hard links, when the loaded plist path differs, or when launchctl state cannot be determined. A failed change is rolled back where possible.
- Plists with keys the editor cannot preserve are view/run-only.
- Logs show only the last 64 KiB. There is no run history, rotation or failure notification.
- The exit code is launchd's last reported value, not a run history.
- macOS Background Items approval is separate from launchctl registration; check System Settings if a job is blocked.
- Enabling a job with `RunAtLoad` may run it immediately.

## MCP server

`joblet-mcp` lets AI agents operate jobs over stdio, read-only by default. Build it with `swift build -c release --product joblet-mcp` (or use `scripts/build-app.sh`, which bundles it at `Joblet.app/Contents/Helpers/joblet-mcp`), then register it with an absolute path:

```bash
claude mcp add joblet -- /path/to/joblet-mcp --allow-write --allow-run
```

```toml
# ~/.codex/config.toml
[mcp_servers.joblet]
command = "/path/to/joblet-mcp"
args = ["--allow-write", "--allow-run"]
```

| Flag | Enables |
| --- | --- |
| *(none)* | `list_jobs`, `get_job`, `read_log` (jobs created by Joblet only) |
| `--allow-write` | `create_job`, `update_job`, `set_job_enabled` |
| `--allow-run` | `run_job` |
| `--allow-delete` | `delete_job` |
| `--include-external` | show jobs created by other apps |
| `--allow-external-control` | enable/disable/run external jobs (needs `--include-external`) |

Mutations need the current `expected_revision`, and deletes need `confirm_label`. External jobs can never be edited or deleted. Details, tools and protocol notes: [docs/MCP.md](docs/MCP.md).

## Development

```bash
mise install          # swiftformat, swiftlint, lefthook
lefthook install      # pre-commit format and lint
swift test            # JobletCore and MCP tests (including a spawned joblet-mcp); never touch real launchd
mise exec -- swiftformat --lint .
mise exec -- swiftlint lint --quiet
xcodebuild -project Joblet.xcodeproj -scheme Joblet -destination 'platform=macOS' CODE_SIGN_IDENTITY=- test
```

Unit tests use a temporary home and an in-memory launchctl. The UI tests (`JobletUITests`) drive the app with UI automation and need Accessibility / automation permission on a local Mac; they run against a temporary home as well.

## CI

GitHub Actions (`.github/workflows`): `test.yml` runs SwiftFormat/SwiftLint, `swift test`, and the Xcode UI tests on `macos-26` and `macos-15`; `workflow-lint.yml` checks the workflows (actionlint, ghalint, zizmor, CodeQL, pinact). Renovate keeps actions and mise tools current.
