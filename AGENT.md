# AGENT.md

Guidance for AI coding agents working in this repository.

## What this is

Neopi is a Neovim plugin written in Lua. It sends code selections and prompts from
Neovim to the [Pi coding agent](https://github.com/earendil-works/pi-coding-agent)
through [acpx](https://github.com/openclaw/acpx), and shows progress, session hints,
and a session transcript inside the editor.

It has two backends:

- `acpx` (default) — headless, agent-agnostic sessions with indicators, completion
  tracking, buffer refresh, and follow-ups.
- `tmux` (experimental) — opens interactive Pi panes in tmux.

## Repository layout

```
plugin/neopi.lua            Entry point. Calls require("neopi").setup() on load.
lua/neopi/init.lua          Config defaults, :Pi and :PiView, prompt building,
                            session<->region mapping, buffer refresh.
lua/neopi/backends/acpx.lua Headless backend: send, send_stream, cancel.
lua/neopi/backends/tmux.lua Experimental tmux pane backend.
lua/neopi/view.lua          :PiView transcript: replay + live streaming + keymaps.
lua/neopi/indicators.lua    Inline spinner/status virtual text, line highlights.
lua/neopi/notify.lua        Persistent notifications (mini.notify, vim.notify fallback).
README.md                   User-facing docs. Update when commands/config change.
```

## Commands

- `:Pi [prompt]` (range) — send the current selection/context and a prompt to Pi.
- `:PiView [session]` — open an acpx session transcript. No argument uses the
  session attached to the region under the cursor.

## Configuration

Defaults live in `defaults` near the top of `lua/neopi/init.lua`. `setup()` deep-merges
over them. Keep the README's "Configuration" block in sync when adding options.

Notable keys: `backend`, `pi_command`, `acpx.{command,agent,format,permissions,
refresh_buffers_on_done,resume_by_region}`, `view.{split,show_thinking}`,
`indicators.*`, `notifications.*`, `session_hints.*`.

## Conventions

- Lua, 2-space indent, double quotes, no trailing whitespace.
- Module style: `local M = {}` at the top, `return M` at the bottom. Private helpers
  are `local function`.
- Guard Neovim API calls that touch buffers/windows/jobs with `pcall` or validity
  checks (`nvim_buf_is_valid`), since callbacks can outlive them.
- From async contexts (job callbacks), notify via `vim.notify` and schedule UI work
  with `vim.schedule`.
- Prefer `vim.api.*` over `vim.cmd`. When you do use `vim.cmd`, remember Neovim's Lua
  is **not** LuaJIT: `||` is a LuaJIT extension and will fail in Neovim. Use `or`.
- Keep the public surface small and documented in the README.

## Verifying changes

There is no test suite. Verify manually, preferably with headless Neovim:

```bash
# Load the plugin from a working tree
nvim --headless -u NONE --cmd 'set rtp^=/path/to/neopi' \
  -c 'lua require("neopi").setup({})' -c 'qa!'
```

- Do **not** trust `luajit` alone as a syntax checker: LuaJIT accepts syntax (such as
  `||`) that Neovim's PUC Lua rejects. Load the module in Neovim to be sure.
- To test without a real agent, create a fake `acpx` executable that handles
  `sessions new` and writes to a file, then point `acpx.command` at it.
- Live testing needs a working `acpx` and `pi` (or another ACP agent).
- A quick end-to-end check is `:Pi` from headless Neovim plus a fake backend that
  edits the open file; confirm the buffer refreshes.

## Gotchas

- `:checktime` called from Lua only refreshes the **current** buffer. Refresh other
  buffers explicitly with `checktime <buf>` (see `refresh_changed_buffers`).
- `pi-acp` spawns `pi` from `PATH`. Neopi forwards its `pi_command` as
  `PI_ACP_PI_COMMAND` so acpx uses the intended Pi install (and its default model).
- Thinking is the ACP `agent_thought_chunk` event. It is adapter-dependent; `pi-acp`
  emits it only from **0.0.34** onward. Older versions stream answers without thinking.
- acpx scopes sessions by the resolved `agentCommand` string + `cwd` + name. Changing
  the adapter command creates a new session scope, so old sessions are not resumed.
- The region-to-session map is in-memory only; it is lost when Neovim restarts. The
  acpx sessions themselves persist under `~/.acpx/sessions/`.
- `:PiView` replay reads `~/.acpx/sessions/index.json` and the matching
  `<id>.stream.ndjson`. Live streaming uses `acpx --format json` with unbuffered
  stdout; parse partial lines carefully (the last element of an `on_stdout` chunk may
  be incomplete).

## Contributing workflow

1. Branch from `main` (e.g. `feat/...`, `fix/...`, `docs/...`).
2. Make focused commits; keep code and docs changes logically separated.
3. Update `README.md` for any user-visible command or config change.
4. Open a PR against `main` describing the change, how it was verified, and any
   environment assumptions.
