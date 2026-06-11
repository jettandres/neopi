# Neopi

Neopi is a small Neovim plugin that sends code and prompts from your editor to the [Pi coding agent](https://github.com/earendil-works/pi-coding-agent) running in tmux panes.

The goal is to keep Neovim as your main coding surface while Pi works asynchronously in adjacent tmux panes.

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

## Requirements

Neopi assumes the following environment:

- Neovim
- tmux
- Pi coding agent installed and available as `pi`
- you are already inside a tmux session for the default tmux backend

Optional for headless sessions:

- `acpx` installed and available as `acpx`

Neopi defaults to the tmux backend. The optional acpx backend is for headless, programmatic Pi sessions.

## Example workflow

Start inside Neovim, already running within tmux.

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
3. create or reuse a tmux layout for Pi panes
4. start an interactive Pi session in a tmux pane
5. send the generated prompt/context into that Pi session
6. return focus to Neovim

Pi then runs asynchronously while you continue editing. The pane remains visible and interactive, so you can jump into it later to read progress, answer questions, interrupt, or send follow-up prompts.

## tmux layout behavior

On the first `:Pi` invocation, Neopi creates a vertical split on the right side of the current tmux window:

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

### tmux backend

Neopi's default backend is interactive tmux.

The plugin launches normal Pi sessions inside tmux panes instead of running Pi as a hidden/headless command. This keeps the agent visible and gives you a place to continue the conversation after the initial prompt.

```lua
require("neopi").setup({
  backend = "tmux",
})
```

### acpx backend

Neopi also has an experimental acpx backend for headless Pi sessions.

Instead of opening an interactive tmux pane, Neopi creates an acpx session and sends the generated prompt to Pi through acpx. This is better for future progress indicators, completion tracking, cancellation, and structured output, but follow-up happens through Neopi/acpx rather than by typing directly into a visible Pi pane.

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

The acpx backend is experimental and not the default.

## Editor feedback

Neopi can show lightweight inline status using Neovim virtual text.

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

## Configuration

Potential setup:

```lua
require("neopi").setup({
  backend = "tmux",
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
  indicators = {
    enabled = true,
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    interval_ms = 120,
    success_ttl_ms = 5000,
    error_ttl_ms = 8000,
  },
})
```

## Initial implementation scope

The first version should focus on:

- defining `:Pi {prompt}`
- supporting visual selections
- requiring an active tmux session for the default tmux backend
- creating the right-side Pi pane on first use
- creating additional right-side horizontal panes on later uses
- launching visible, interactive Pi sessions
- sending selected code plus minimal file/project context to Pi
- returning focus to Neovim immediately

Out of scope for the first version:

- applying edits back into Neovim automatically
- parsing Pi output
- managing Pi sessions from Neovim
- non-tmux terminal support
- full headless result rendering in Neovim
- acpx session management commands such as history, status, cancel, and follow-up

## Project status

Neopi is currently being designed. The README is the source of truth for the intended UX before implementation begins.
