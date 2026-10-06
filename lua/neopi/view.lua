local M = {}

local ns = vim.api.nvim_create_namespace("neopi_view")

-- bufnr -> view state
local views = {}

local defaults = {
  split = "vsplit",
  show_thinking = true,
  render_interval_ms = 60,
  autoscroll = true,
}

local function setup_highlights()
  vim.api.nvim_set_hl(0, "NeopiViewHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "NeopiViewRole", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "NeopiViewAssistant", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "NeopiViewThinking", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NeopiViewTool", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "NeopiViewError", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "NeopiViewStatus", { link = "Comment", default = true })
end

local TOOL_ICON = {
  completed = "✓",
  failed = "✗",
  pending = "…",
}

local function extract_user_request(text)
  local request = text:match("^User request:%s*\n(.-)\n\nContext:")
  if request then
    return request
  end
  return text
end

local function append_text(events, kind, text)
  if not text or text == "" then
    return
  end

  local last = events[#events]
  if last and last.kind == kind then
    last.text = last.text .. text
  else
    table.insert(events, { kind = kind, text = text })
  end
end

local function find_tool(events, id)
  if not id then
    return nil
  end

  for i = #events, 1, -1 do
    if events[i].kind == "tool" and events[i].id == id then
      return events[i]
    end
  end

  return nil
end

local function ingest(msg, events)
  if type(msg) ~= "table" then
    return
  end

  if msg.method == "session/prompt" then
    for _, part in ipairs((msg.params or {}).prompt or {}) do
      if part.type == "text" and part.text then
        append_text(events, "user", extract_user_request(part.text))
      end
    end
    return
  end

  if msg.method ~= "session/update" then
    return
  end

  local update = (msg.params or {}).update
  if not update then
    return
  end

  local kind = update.sessionUpdate
  if kind == "agent_message_chunk" or kind == "agent_thought_chunk" or kind == "user_message_chunk" then
    local content = update.content
    if content and content.type == "text" then
      local mapped = kind == "agent_message_chunk" and "assistant"
        or kind == "agent_thought_chunk" and "thinking"
        or "user"
      append_text(events, mapped, content.text)
    end
  elseif kind == "tool_call" then
    table.insert(events, {
      kind = "tool",
      id = update.toolCallId,
      title = update.title or update.kind or "tool",
      status = update.status,
    })
  elseif kind == "tool_call_update" then
    local tool = find_tool(events, update.toolCallId)
    if tool then
      tool.title = update.title or tool.title
      tool.status = update.status or tool.status
    else
      table.insert(events, {
        kind = "tool",
        id = update.toolCallId,
        title = update.title or "tool",
        status = update.status,
      })
    end
  end
end

local function sessions_dir()
  return vim.fn.expand("~/.acpx/sessions")
end

local function find_stream_path(session, cwd)
  local dir = sessions_dir()
  local index_path = dir .. "/index.json"
  local best

  if vim.fn.filereadable(index_path) == 1 then
    local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(index_path), "\n"))
    if ok and type(data) == "table" and type(data.entries) == "table" then
      for _, entry in ipairs(data.entries) do
        if entry.name == session then
          if cwd and entry.cwd == cwd then
            best = entry
            break
          end
          if not best then
            best = entry
          end
        end
      end
    end
  end

  if best and best.file then
    return dir .. "/" .. best.file:gsub("%.json$", ".stream.ndjson")
  end

  return nil
end

local function load_events(session, cwd)
  local events = {}
  local path = find_stream_path(session, cwd)

  if not path or vim.fn.filereadable(path) ~= 1 then
    return events
  end

  for _, raw in ipairs(vim.fn.readfile(path)) do
    if raw ~= "" then
      local ok, msg = pcall(vim.json.decode, raw)
      if ok then
        ingest(msg, events)
      end
    end
  end

  return events
end

local function config_for(view)
  return vim.tbl_deep_extend("force", defaults, (view.config or {}).view or {})
end

local function build_transcript(view)
  local out = {}
  local cfg = config_for(view)

  local function line(text, hl)
    table.insert(out, { text = text, hl = hl })
  end

  local function block(text, hl)
    for _, l in ipairs(vim.split(text or "", "\n", { plain = true })) do
      table.insert(out, { text = l, hl = hl })
    end
  end

  local status
  if view.running then
    status = "● running"
    if view.queue and view.queue > 0 then
      status = status .. " (queue " .. view.queue .. ")"
    end
  else
    status = "○ idle"
  end

  local file = view.file and vim.fn.fnamemodify(view.file, ":.") or "[no file]"
  line("# Pi session " .. view.session, "NeopiViewHeader")
  line(
    string.format(
      "%s  ·  %s  ·  %s  ·  thinking %s",
      file,
      view.cwd or "",
      status,
      view.show_thinking and "on" or "off (t)"
    ),
    "NeopiViewStatus"
  )
  line("", nil)

  if #view.events == 0 then
    line("(no history yet — press i to send a prompt)", "NeopiViewStatus")
    line("", nil)
  end

  for _, event in ipairs(view.events) do
    if event.kind == "user" then
      line("## You", "NeopiViewRole")
      block(event.text, nil)
      line("", nil)
    elseif event.kind == "assistant" then
      line("## Pi", "NeopiViewRole")
      block(event.text, "NeopiViewAssistant")
      line("", nil)
    elseif event.kind == "thinking" then
      if view.show_thinking then
        line("## Thinking", "NeopiViewRole")
        block(event.text, "NeopiViewThinking")
        line("", nil)
      else
        line("> 🧠 thinking hidden (" .. #(event.text or "") .. " chars) — press t", "NeopiViewThinking")
      end
    elseif event.kind == "tool" then
      line(string.format("- %s %s", TOOL_ICON[event.status or ""] or "·", event.title or "tool"), "NeopiViewTool")
    elseif event.kind == "error" then
      line("## Error", "NeopiViewRole")
      block(event.text, "NeopiViewError")
      line("", nil)
    end
  end

  return out
end

local function update_follow(bufnr)
  local view = views[bufnr]
  if not view then
    return
  end

  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end

  local last = vim.api.nvim_buf_line_count(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  view.follow = cursor >= last
end

local function render(bufnr)
  local view = views[bufnr]
  if not view or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local out = build_transcript(view)
  local lines = {}
  for i, item in ipairs(out) do
    lines[i] = item.text
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for i, item in ipairs(out) do
    if item.hl then
      vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
        line_hl_group = item.hl,
        priority = 200,
      })
    end
  end

  if config_for(view).autoscroll and view.follow then
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_win_set_cursor(win, { math.max(1, #lines), 0 })
    end
  end
end

local function schedule_render(bufnr)
  local view = views[bufnr]
  if not view or view.render_pending then
    return
  end

  view.render_pending = true
  vim.defer_fn(function()
    local current = views[bufnr]
    if not current then
      return
    end
    current.render_pending = false
    render(bufnr)
  end, config_for(view).render_interval_ms)
end

local function apply_running_state(view, msg)
  if msg.method ~= "session/update" then
    return
  end

  local update = (msg.params or {}).update
  local meta = update and update.sessionUpdate == "session_info_update" and update._meta and update._meta.piAcp
  if meta then
    view.running = meta.running and true or false
    view.queue = meta.queueDepth or 0
  end
end

local function compose(bufnr)
  local view = views[bufnr]
  if not view then
    return
  end

  vim.ui.input({ prompt = "Pi: " }, function(input)
    if not input or vim.trim(input) == "" then
      return
    end
    M.send(bufnr, input)
  end)
end

local function reload(bufnr)
  local view = views[bufnr]
  if not view then
    return
  end

  view.events = load_events(view.session, view.cwd)
  render(bufnr)
end

local function toggle_thinking(bufnr)
  local view = views[bufnr]
  if not view then
    return
  end

  view.show_thinking = not view.show_thinking
  render(bufnr)
end

local function open_source(bufnr)
  local view = views[bufnr]
  if not view or not view.file or vim.fn.filereadable(view.file) ~= 1 then
    vim.notify("Neopi: source file is not available", vim.log.levels.WARN)
    return
  end

  vim.cmd.edit(vim.fn.fnameescape(view.file))
end

local function close_view(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then
    vim.api.nvim_win_close(wins[1], true)
  elseif vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

local function cancel(bufnr)
  local view = views[bufnr]
  if not view then
    return
  end

  local backend = require("neopi.backends.acpx")
  backend.cancel(view.config, view.session, view.cwd)
  vim.notify("Neopi: cancelling " .. view.session, vim.log.levels.INFO)
end

local function setup_buffer(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "markdown"

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
  end

  map("i", function()
    compose(bufnr)
  end, "Neopi: send prompt")
  map("<CR>", function()
    compose(bufnr)
  end, "Neopi: send prompt")
  map("t", function()
    toggle_thinking(bufnr)
  end, "Neopi: toggle thinking")
  map("R", function()
    reload(bufnr)
  end, "Neopi: reload history")
  map("c", function()
    cancel(bufnr)
  end, "Neopi: cancel")
  map("o", function()
    open_source(bufnr)
  end, "Neopi: open source file")
  map("q", function()
    close_view(bufnr)
  end, "Neopi: close view")

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
      update_follow(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      views[bufnr] = nil
    end,
  })
end

local function setup_window()
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].list = false
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winfixwidth = true
end

function M.open(opts)
  opts = opts or {}
  local session = opts.session

  if not session or session == "" then
    vim.notify("Neopi: no session to view", vim.log.levels.WARN)
    return nil
  end

  for bufnr, view in pairs(views) do
    if view.session == session and vim.api.nvim_buf_is_valid(bufnr) then
      local wins = vim.fn.win_findbuf(bufnr)
      if #wins > 0 then
        vim.api.nvim_set_current_win(wins[1])
        return bufnr
      end
    end
  end

  setup_highlights()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "neopi://session/" .. session)

  local view = {
    bufnr = bufnr,
    session = session,
    cwd = opts.cwd or vim.fn.getcwd(),
    file = opts.file,
    config = opts.config or {},
    events = load_events(session, opts.cwd or vim.fn.getcwd()),
    show_thinking = ((opts.config or {}).view or {}).show_thinking ~= false,
    running = false,
    queue = 0,
    follow = true,
    render_pending = false,
  }
  views[bufnr] = view

  setup_buffer(bufnr)

  local split = ((opts.config or {}).view or {}).split or defaults.split
  if split == "split" then
    vim.cmd("botright split")
  else
    vim.cmd("botright vsplit")
  end

  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
  setup_window()
  render(bufnr)

  return bufnr
end

function M.send(bufnr, text)
  local view = views[bufnr]
  if not view then
    return
  end

  table.insert(view.events, { kind = "user", text = text })
  view.running = true
  view.follow = true
  render(bufnr)

  local backend = require("neopi.backends.acpx")
  local result, err = backend.send_stream(text, view.config, {
    on_event = function(msg)
      local current = views[bufnr]
      if not current then
        return
      end

      -- We already appended the prompt locally; the stream echoes it back as a
      -- session/prompt request from the client.
      if msg and msg.method == "session/prompt" then
        return
      end

      ingest(msg, current.events)
      apply_running_state(current, msg)
      schedule_render(bufnr)
    end,
    on_done = function()
      local current = views[bufnr]
      if not current then
        return
      end
      current.running = false
      current.queue = 0
      schedule_render(bufnr)

      local neopi = require("neopi")
      if neopi.refresh_changed_buffers and ((current.config or {}).acpx or {}).refresh_buffers_on_done ~= false then
        vim.schedule(neopi.refresh_changed_buffers)
      end
    end,
    on_error = function(result)
      local current = views[bufnr]
      if not current then
        return
      end
      current.running = false
      current.queue = 0
      local message = "acpx session failed"
      if result and result.errors and #result.errors > 0 then
        message = table.concat(result.errors, "\n")
      end
      table.insert(current.events, { kind = "error", text = message })
      schedule_render(bufnr)
    end,
  }, {
    session = view.session,
    cwd = view.cwd,
  })

  if not result then
    view.running = false
    table.insert(view.events, { kind = "error", text = err or "Failed to start acpx stream" })
    schedule_render(bufnr)
  end

  return result
end

function M.is_view(bufnr)
  return views[bufnr] ~= nil
end

return M
