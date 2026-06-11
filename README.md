# Neopi

Neopi is a small Neovim plugin that sends code and prompts from your editor to the [Pi coding agent](https://github.com/earendil-works/pi-coding-agent).

The goal is to keep Neovim as your main coding surface while Pi works asynchronously in the background through acpx.

> Status: planning / early prototype

## Why Neopi?

When coding in Neovim, you often want to ask an agent to inspect, edit, explain, or refactor a specific piece of code without leaving your editor.

Neopi lets you:

- visually select code in Neovim
- run a command like `:Pi refactor this function`
- open an interactive Pi session in a tmux pane with the selected code and useful context
- keep editing while Pi runs independently
- switch to the Pi pane whenever you want visibility or follow-up conversation
- launch multiple Pi tasks in parallel tmux panes

## Installation

### lazy.nvim

After pushing this repository to GitHub, users can install it with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jettandres/neopi",
  config = function()
    require("neopi").setup()
  end,
}
```

For local development, you can point lazy.nvim at a local checkout:

```lua
{
  dir = "/path/to/neopi",
  config = function()
    require("neopi").setup()
  end,
}
```

The plugin also defines `:Pi` automatically when loaded, so calling `setup()` is optional unless you want to override defaults.

If you use `mini.notify`, load it before Neopi and set it up normally:

```lua
{
  "nvim-mini/mini.notify",
  version = false,
  config = function()
    require("mini.notify").setup()
  end,
}
```

Neopi will use `MiniNotify.add/update/remove` for persistent acpx running notifications when available, and will fall back to `vim.notify` otherwise.

## Requirements

Neopi assumes the following environment:

- Neovim
- Pi coding agent installed and available as `pi`
- `acpx` installed and available as [acpx](https://github.com/openclaw/acpx)

Optional for interactive tmux sessions:

- tmux
- you are already inside a tmux session

Optional for richer notifications:

- [`mini.notify`](https://github.com/nvim-mini/mini.notify)

Neopi defaults to the acpx backend for headless, programmatic Pi sessions. The tmux backend is still available for visible interactive Pi panes.

## Example workflow

Start inside Neovim.

Highlight some code using visual mode:

```lua
local function greet(name)
  print("hello " .. name)
end
```

Then run:

```vim
:'<,'>Pi make this safer and add input validation
```

Neopi will:

1. capture the selected lines
2. collect editor context, such as:
   - file path
   - filetype
   - selected line range
   - current working directory
   - git root, when available
3. create or reuse an acpx session
4. send the generated prompt/context to Pi through acpx
5. show inline status while Pi is running
6. refresh buffers after Pi finishes

Pi then runs asynchronously while you continue editing.

## tmux backend layout behavior

When using `backend = "tmux"`, the first `:Pi` invocation creates a vertical split on the right side of the current tmux window:

```text
+-----------------------------+---------------------+
|                             |                     |
|           Neovim            |      Pi task 1      |
|                             |                     |
+-----------------------------+---------------------+
```

The left pane remains dedicated to Neovim.

Future `:Pi` invocations create additional horizontal splits inside the right-hand Pi area:

```text
+-----------------------------+---------------------+
|                             |      Pi task 1      |
|                             +---------------------+
|           Neovim            |      Pi task 2      |
|                             +---------------------+
|                             |      Pi task 3      |
+-----------------------------+---------------------+
```

This allows multiple Pi prompts to run independently.

Each tmux pane is a persistent interactive Pi session, not a hidden one-off process. After Neopi sends the initial prompt, the pane remains available for follow-up conversation.

## Commands

### `:Pi {prompt}`

Send the current visual selection and prompt to Pi.

Example:

```vim
:'<,'>Pi explain this block and suggest simplifications
```

If no visual range is provided, Neopi may send the current file or cursor context depending on configuration.

## Prompt sent to Pi

Neopi builds a structured prompt before starting Pi.

Example generated prompt:

````text
User request:
make this safer and add input validation

Context:
- File: lua/example.lua
- Filetype: lua
- Selection: lines 12-18
- Working directory: /path/to/project
- Git root: /path/to/project

Selected code:
```lua
local function greet(name)
  print("hello " .. name)
end
```
````

This keeps the user's prompt short while still giving Pi enough context to act usefully.

## Backends

### acpx backend

Neopi's default backend uses acpx for headless Pi sessions.

Instead of opening an interactive tmux pane, Neopi creates an acpx session and sends the generated prompt to Pi through acpx. This is better for progress indicators, completion tracking, cancellation, structured output, and refreshing buffers after edits. Follow-up happens through Neopi/acpx rather than by typing directly into a visible Pi pane.

```lua
require("neopi").setup({
  backend = "acpx",
  acpx = {
    command = "acpx",
    agent = "pi",
    format = "text",
    permissions = "approve-all",
    refresh_buffers_on_done = true,
  },
})
```

### tmux backend

The tmux backend launches normal interactive Pi sessions inside tmux panes. This keeps the agent visible and gives you a place to continue the conversation after the initial prompt.

```lua
require("neopi").setup({
  backend = "tmux",
})
```

## Editor feedback

Neopi can show lightweight inline status using Neovim virtual text and line-number highlighting.

While a task is active, the selected range's line numbers are highlighted so it is clear which block Pi is working on.

For the tmux backend, the indicator tracks prompt delivery:

```text
local function greet(name)        ⠋ Sending to Pi...
local function greet(name)        ✓ Sent to Pi pane %12
```

For the acpx backend, the indicator can track the headless job lifecycle:

```text
local function greet(name)        ⠋ Pi running via acpx...
local function greet(name)        ✓ Pi done neopi-123
```

This distinction matters because interactive Pi panes remain open for follow-up conversation, so Neopi cannot reliably know when the agent is truly "done" in tmux mode.

When `mini.notify` is available, acpx sessions also get a persistent notification while running. This is useful when jumping between files because the running session remains visible outside the original buffer.

## Configuration

Potential setup:

```lua
require("neopi").setup({
  backend = "acpx",
  pi_command = "pi",
  tmux = {
    right_pane_width = 40,
    focus_back_to_neovim = true,
    prompt_delay_ms = 1000,
  },
  prompt = {
    include_file_path = true,
    include_filetype = true,
    include_line_range = true,
    include_cwd = true,
    include_git_root = true,
  },
  acpx = {
    command = "acpx",
    agent = "pi",
    format = "text",
    permissions = "approve-all",
    session = nil,
    refresh_buffers_on_done = true,
  },
  notifications = {
    enabled = true,
    acpx_running = true,
    done_ttl_ms = 5000,
    error_ttl_ms = 8000,
  },
  indicators = {
    enabled = true,
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    interval_ms = 120,
    success_ttl_ms = 5000,
    error_ttl_ms = 8000,
    number_highlight = true,
    highlights = {
      running = "NeopiRunning",
      success = "NeopiSuccess",
      error = "NeopiError",
    },
  },
})
```

## Initial implementation scope

The first version should focus on:

- defining `:Pi {prompt}`
- using acpx as the default backend
- supporting visual selections
- sending selected code plus minimal file/project context to Pi
- showing inline status and refreshing buffers after acpx completion
- preserving the tmux backend for interactive Pi panes

Out of scope for the first version:

- applying edits back into Neovim automatically
- parsing Pi output
- managing Pi sessions from Neovim
- non-tmux terminal support
- full headless result rendering in Neovim
- acpx session management commands such as history, status, cancel, and follow-up

## Project status

Neopi is currently being designed. The README is the source of truth for the intended UX before implementation begins.
