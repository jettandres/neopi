local M = {}

local tmux = require("neopi.tmux")

local defaults = {
  pi_command = "pi",
  tmux = {
    right_pane_width = 40,
    focus_back_to_neovim = true,
  },
  prompt = {
    include_file_path = true,
    include_filetype = true,
    include_line_range = true,
    include_cwd = true,
    include_git_root = true,
  },
}

M.config = vim.deepcopy(defaults)

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

function M.pi(opts)
  opts = opts or {}

  local ok, err = tmux.ensure_inside_tmux()
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local prompt = build_prompt(opts.args or "", opts)
  local pane_id, pane_err = tmux.open_pi_pane(prompt, M.config)

  if not pane_id then
    vim.notify(pane_err or "Failed to open Pi tmux pane", vim.log.levels.ERROR)
    return
  end

  vim.notify("Sent prompt to Pi pane " .. pane_id, vim.log.levels.INFO)
end

function M.setup(config)
  merge_config(config)

  pcall(vim.api.nvim_del_user_command, "Pi")
  vim.api.nvim_create_user_command("Pi", function(opts)
    M.pi(opts)
  end, {
    nargs = "*",
    range = true,
    desc = "Send selection and prompt to Pi in a tmux pane",
  })
end

return M
