local M = {}

local indicators = require("neopi.indicators")
local notify = require("neopi.notify")

local defaults = {
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
    resume_by_region = true,
  },
  notifications = {
    enabled = true,
    acpx_running = true,
    done_ttl_ms = 5000,
    error_ttl_ms = 8000,
  },
  session_hints = {
    enabled = true,
    message = "Pi session exists — :Pi will resume it",
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
      session = "NeopiSession",
    },
  },
  view = {
    split = "vsplit",
    show_thinking = true,
  },
}

M.config = vim.deepcopy(defaults)

local region_ns = vim.api.nvim_create_namespace("neopi_session_regions")
local hint_ns = vim.api.nvim_create_namespace("neopi_session_hints")
local state = {
  session_regions = {},
  hint_extmarks = {},
}

local function merge_config(config)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), config or {})
end

local function git_root(cwd)
  local output = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not output[1] or output[1] == "" then
    return nil
  end
  return output[1]
end

local function relative_path(path, cwd)
  if path == "" then
    return "[No file]"
  end

  local rel = vim.fn.fnamemodify(path, ":.")
  if rel and rel ~= "" then
    return rel
  end

  return path:gsub("^" .. vim.pesc(cwd) .. "/?", "")
end

local function get_selected_code(opts)
  if not opts.line1 or not opts.line2 or opts.range == 0 then
    local line = vim.api.nvim_win_get_cursor(0)[1]
    return line, line, vim.api.nvim_buf_get_lines(0, line - 1, line, false)
  end

  return opts.line1, opts.line2, vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
end

local function indicator_range(opts)
  if opts and opts.line1 and opts.line2 and opts.range and opts.range > 0 then
    return opts.line1 - 1, opts.line2 - 1
  end

  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  return line, line
end

local function selected_range(opts)
  return indicator_range(opts)
end

local function range_overlaps(a_start, a_end, b_start, b_end)
  return a_start <= b_end and b_start <= a_end
end

local function get_region_range(bufnr, region)
  local positions = {}
  for _, extmark in ipairs(region.extmarks or {}) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, region_ns, extmark, {})
    if pos and pos[1] then
      table.insert(positions, pos[1])
    end
  end

  if #positions == 0 then
    return nil, nil
  end

  table.sort(positions)
  return positions[1], positions[#positions]
end

local function find_overlapping_session_region(bufnr, start_line, end_line)
  local regions = state.session_regions[bufnr] or {}
  local best_region = nil
  local best_score = -1
  local live_regions = {}

  for _, region in ipairs(regions) do
    local region_start, region_end = get_region_range(bufnr, region)
    if region_start and region_end then
      table.insert(live_regions, region)
      if range_overlaps(start_line, end_line, region_start, region_end) then
        local score = math.min(end_line, region_end) - math.max(start_line, region_start)
        if score > best_score then
          best_score = score
          best_region = region
        end
      end
    end
  end

  state.session_regions[bufnr] = live_regions
  return best_region
end

local function find_session_region_at_line(bufnr, line)
  return find_overlapping_session_region(bufnr, line, line)
end

local function clear_session_hint(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local extmark = state.hint_extmarks[bufnr]
  if extmark then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, hint_ns, extmark)
    state.hint_extmarks[bufnr] = nil
  end
end

local function update_session_hint()
  local cfg = M.config.session_hints or {}
  local bufnr = vim.api.nvim_get_current_buf()

  clear_session_hint(bufnr)

  if cfg.enabled == false or M.config.acpx.resume_by_region == false then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local region = find_session_region_at_line(bufnr, line)
  if not region then
    return
  end

  local hl_group = (M.config.indicators.highlights and M.config.indicators.highlights.session) or "NeopiSession"
  local message = cfg.message or "Pi session exists — :Pi will resume it"
  state.hint_extmarks[bufnr] = vim.api.nvim_buf_set_extmark(bufnr, hint_ns, line, 0, {
    virt_text = { { message .. " (" .. region.session .. ")", hl_group } },
    virt_text_pos = "eol",
  })
end

local function attach_session_region(bufnr, start_line, end_line, session_id)
  local cfg = M.config.indicators or {}
  if cfg.number_highlight == false or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local regions = state.session_regions[bufnr] or {}
  local extmarks = {}
  local hl_group = (cfg.highlights and cfg.highlights.session) or "NeopiSession"
  local last_line = vim.api.nvim_buf_line_count(bufnr) - 1

  for line = math.max(0, start_line), math.min(last_line, end_line) do
    local extmark = vim.api.nvim_buf_set_extmark(bufnr, region_ns, line, 0, {
      number_hl_group = hl_group,
      priority = 10,
    })
    table.insert(extmarks, extmark)
  end

  table.insert(regions, {
    session = session_id,
    extmarks = extmarks,
    cwd = vim.fn.getcwd(),
    file = vim.api.nvim_buf_get_name(bufnr),
  })
  state.session_regions[bufnr] = regions
end

local function start_indicator(opts, message)
  local cfg = M.config.indicators or {}
  if cfg.enabled == false then
    return nil
  end

  local start_line, end_line = indicator_range(opts)

  return indicators.start({
    bufnr = vim.api.nvim_get_current_buf(),
    line = start_line,
    start_line = start_line,
    end_line = end_line,
    spinner = cfg.spinner,
    interval_ms = cfg.interval_ms,
    message = message,
    number_highlight = cfg.number_highlight,
    highlights = cfg.highlights,
  })
end

local function backend_module(name)
  if name == "tmux" then
    return require("neopi.backends.tmux")
  end

  if name == "acpx" then
    return require("neopi.backends.acpx")
  end

  return nil, "Unknown Neopi backend: " .. tostring(name)
end

local function build_prompt(user_prompt, opts)
  local cfg = M.config.prompt
  local cwd = vim.fn.getcwd()
  local file = vim.api.nvim_buf_get_name(0)
  local start_line, end_line, lines = get_selected_code(opts)
  local filetype = vim.bo.filetype

  local out = {}

  table.insert(out, "User request:")
  table.insert(out, user_prompt ~= "" and user_prompt or "Please review this code.")
  table.insert(out, "")
  table.insert(out, "Context:")

  if cfg.include_file_path then
    table.insert(out, "- File: " .. relative_path(file, cwd))
    if file ~= "" then
      table.insert(out, "- Absolute path: " .. file)
    end
  end

  if cfg.include_filetype then
    table.insert(out, "- Filetype: " .. (filetype ~= "" and filetype or "unknown"))
  end

  if cfg.include_line_range then
    table.insert(out, string.format("- Selection: lines %d-%d", start_line, end_line))
  end

  if cfg.include_cwd then
    table.insert(out, "- Working directory: " .. cwd)
  end

  if cfg.include_git_root then
    local root = git_root(cwd)
    if root then
      table.insert(out, "- Git root: " .. root)
    end
  end

  table.insert(out, "")
  table.insert(out, "Selected code:")
  table.insert(out, "```" .. (filetype ~= "" and filetype or "text"))
  vim.list_extend(out, lines)
  table.insert(out, "```")

  return table.concat(out, "\n")
end

local function is_file_buffer(bufnr)
  return bufnr
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

local function refresh_changed_buffers()
  local conflicts = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_file_buffer(bufnr) then
      if vim.bo[bufnr].modified then
        -- `checktime` refuses to reload a buffer with unsaved changes, so use
        -- its (captured) warning to detect that Pi changed the file and warn
        -- the user instead of letting a later :w silently overwrite Pi's work.
        local ok, res = pcall(vim.api.nvim_exec2, "silent! checktime " .. bufnr, { output = true })
        local output = (ok and res and res.output) or ""
        if output:find("has changed", 1, true) then
          table.insert(conflicts, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":."))
        end
      else
        -- `checktime <buf>` targets a specific buffer, unlike a bare
        -- `:checktime` which (when invoked from Lua) only refreshes the
        -- current buffer. This lets Pi's edits show up even when you switched
        -- away while it worked.
        pcall(vim.cmd, "silent! checktime " .. bufnr)
      end
    end
  end

  if #conflicts > 0 then
    vim.notify(
      "neopi: Pi changed "
        .. table.concat(conflicts, ", ")
        .. " on disk, but the buffer has unsaved changes. Your changes were kept; run :edit! to load Pi's version.",
      vim.log.levels.WARN
    )
  end
end

M.refresh_changed_buffers = refresh_changed_buffers

function M.pi(opts)
  opts = opts or {}

  local backend_name = M.config.backend or "tmux"
  local backend, backend_err = backend_module(backend_name)
  if not backend then
    vim.notify(backend_err, vim.log.levels.ERROR)
    return
  end

  local prompt = build_prompt(opts.args or "", opts)

  if backend_name == "tmux" then
    local ok, err = backend.ensure_inside_tmux()
    if not ok then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    local indicator = start_indicator(opts, "Sending to Pi...")
    local pane_id, pane_err = backend.open_pi_pane(prompt, M.config)
    if not pane_id then
      if indicator then
        indicator:done("✗ Failed to send to Pi", "DiagnosticError", M.config.indicators.error_ttl_ms, M.config.indicators.highlights.error)
      end
      vim.notify(pane_err or "Failed to open Pi tmux pane", vim.log.levels.ERROR)
      return
    end

    if indicator then
      indicator:done("✓ Sent to Pi pane " .. pane_id, "DiagnosticOk", M.config.indicators.success_ttl_ms, M.config.indicators.highlights.success)
    end
    vim.notify("Sent prompt to Pi pane " .. pane_id, vim.log.levels.INFO)
    return
  end

  if backend_name == "acpx" then
    local ok, err = backend.ensure_available(M.config)
    if not ok then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    clear_session_hint(bufnr)
    local start_line, end_line = selected_range(opts)
    local existing_region
    if M.config.acpx.resume_by_region ~= false then
      existing_region = find_overlapping_session_region(bufnr, start_line, end_line)
    end

    local indicator_message = existing_region and "Pi resuming via acpx..." or "Pi running via acpx..."
    local indicator = start_indicator(opts, indicator_message)
    local running_notification
    local session, session_err = backend.send(prompt, M.config, {
      on_done = function(result)
        if M.config.acpx.refresh_buffers_on_done ~= false then
          vim.schedule(refresh_changed_buffers)
        end

        if indicator then
          indicator:done("✓ Pi done " .. result.id, "DiagnosticOk", M.config.indicators.success_ttl_ms, M.config.indicators.highlights.success)
        end

        if running_notification then
          running_notification:finish("✓ Pi acpx session done: " .. result.id, vim.log.levels.INFO, "DiagnosticOk", M.config.notifications.done_ttl_ms)
        end
      end,
      on_error = function(result)
        -- A failed run may still have written some files before erroring out.
        if M.config.acpx.refresh_buffers_on_done ~= false then
          vim.schedule(refresh_changed_buffers)
        end

        if indicator then
          indicator:done("✗ Pi failed " .. result.id, "DiagnosticError", M.config.indicators.error_ttl_ms, M.config.indicators.highlights.error)
        end

        if running_notification then
          running_notification:finish("✗ Pi acpx session failed: " .. result.id, vim.log.levels.ERROR, "DiagnosticError", M.config.notifications.error_ttl_ms)
        end
      end,
    }, existing_region and {
      session = existing_region.session,
      create_session = false,
    } or {})
    if not session then
      if indicator then
        indicator:done("✗ Failed to start Pi", "DiagnosticError", M.config.indicators.error_ttl_ms, M.config.indicators.highlights.error)
      end
      vim.notify(session_err or "Failed to start acpx session", vim.log.levels.ERROR)
      return
    end

    if not existing_region and M.config.acpx.resume_by_region ~= false then
      attach_session_region(bufnr, start_line, end_line, session.id)
    end

    if M.config.notifications.enabled ~= false and M.config.notifications.acpx_running ~= false then
      local message = existing_region and "Pi acpx session resumed: " or "Pi acpx session running: "
      running_notification = notify.start(message .. session.id, vim.log.levels.INFO, "DiagnosticInfo", {
        backend = "acpx",
        session = session.id,
      })
    end

    vim.notify("Started Pi acpx session " .. session.id, vim.log.levels.INFO)
    return
  end
end

function M.setup(config)
  merge_config(config)
  indicators.setup_highlights()

  pcall(vim.api.nvim_del_user_command, "Pi")
  vim.api.nvim_create_user_command("Pi", function(opts)
    M.pi(opts)
  end, {
    nargs = "*",
    range = true,
    desc = "Send selection and prompt to Pi",
  })

  pcall(vim.api.nvim_del_user_command, "PiView")
  vim.api.nvim_create_user_command("PiView", function(opts)
    local name = vim.trim(opts.args or "")
    local session
    local ctx

    if name ~= "" then
      session = name
      ctx = { cwd = vim.fn.getcwd(), file = vim.api.nvim_buf_get_name(0) }
    else
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1] - 1
      local region = find_session_region_at_line(bufnr, line)
      if not region then
        vim.notify(
          "Neopi: no Pi session at cursor (move to a highlighted region or pass a session id)",
          vim.log.levels.WARN
        )
        return
      end

      session = region.session
      ctx = { cwd = region.cwd, file = region.file }
    end

    require("neopi.view").open({
      session = session,
      cwd = ctx.cwd,
      file = ctx.file,
      config = M.config,
    })
  end, {
    nargs = "?",
    desc = "Open a Neopi acpx session view",
  })

  local group = vim.api.nvim_create_augroup("neopi_session_hints", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = group,
    callback = update_session_hint,
  })
end

return M
