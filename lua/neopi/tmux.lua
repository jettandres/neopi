local M = {}

local state = {
  neovim_pane = nil,
  pi_panes = {},
}

local function systemlist(args)
  local output = vim.fn.systemlist(args)
  local code = vim.v.shell_error
  return code, output
end

local function write_prompt_file(prompt)
  local path = vim.fn.tempname()
  local ok = vim.fn.writefile(vim.split(prompt, "\n", { plain = true }), path, "b")
  if ok ~= 0 then
    return nil, "Failed to write temporary prompt file"
  end
  return path, nil
end

local function paste_prompt(pane_id, prompt)
  local path, err = write_prompt_file(prompt)
  if not path then
    return false, err
  end

  local buffer_name = "neopi-" .. tostring(vim.loop.hrtime())

  local load_code, load_output = systemlist({ "tmux", "load-buffer", "-b", buffer_name, path })
  vim.fn.delete(path)
  if load_code ~= 0 then
    return false, table.concat(load_output, "\n")
  end

  local paste_code, paste_output = systemlist({ "tmux", "paste-buffer", "-dpr", "-b", buffer_name, "-t", pane_id })
  if paste_code ~= 0 then
    return false, table.concat(paste_output, "\n")
  end

  local enter_code, enter_output = systemlist({ "tmux", "send-keys", "-t", pane_id, "Enter" })
  if enter_code ~= 0 then
    return false, table.concat(enter_output, "\n")
  end

  return true, nil
end

local function current_pane()
  local pane = vim.env.TMUX_PANE
  if pane and pane ~= "" then
    return pane
  end

  local code, output = systemlist({ "tmux", "display-message", "-p", "#{pane_id}" })
  if code ~= 0 or not output[1] or output[1] == "" then
    return nil
  end

  return output[1]
end

local function live_pane_ids()
  local code, output = systemlist({ "tmux", "list-panes", "-F", "#{pane_id}" })
  if code ~= 0 then
    return {}
  end

  local live = {}
  for _, pane_id in ipairs(output) do
    if pane_id ~= "" then
      live[pane_id] = true
    end
  end

  return live
end

local function prune_pi_panes()
  local live = live_pane_ids()
  local panes = {}

  for _, pane_id in ipairs(state.pi_panes) do
    if live[pane_id] then
      table.insert(panes, pane_id)
    end
  end

  state.pi_panes = panes
end

function M.ensure_inside_tmux()
  if not vim.env.TMUX or vim.env.TMUX == "" then
    return false, "Neopi requires Neovim to be running inside tmux"
  end

  if vim.fn.executable("tmux") ~= 1 then
    return false, "Neopi requires the `tmux` executable"
  end

  return true, nil
end

function M.open_pi_pane(prompt, config)
  state.neovim_pane = state.neovim_pane or current_pane()

  prune_pi_panes()

  local cwd = vim.fn.getcwd()
  local command = config.pi_command or "pi"
  local tmux_cfg = config.tmux or {}
  local args

  if #state.pi_panes == 0 then
    args = {
      "tmux",
      "split-window",
      "-h",
      "-d",
      "-P",
      "-F",
      "#{pane_id}",
      "-l",
      tostring(tmux_cfg.right_pane_width or 40) .. "%",
      "-c",
      cwd,
      command,
    }
  else
    args = {
      "tmux",
      "split-window",
      "-v",
      "-d",
      "-P",
      "-F",
      "#{pane_id}",
      "-t",
      state.pi_panes[#state.pi_panes],
      "-c",
      cwd,
      command,
    }
  end

  local code, output = systemlist(args)
  if code ~= 0 then
    return nil, table.concat(output, "\n")
  end

  local pane_id = output[1]
  table.insert(state.pi_panes, pane_id)

  local delay = tonumber(tmux_cfg.prompt_delay_ms) or 0
  if delay > 0 then
    vim.wait(delay)
  end

  local pasted, paste_err = paste_prompt(pane_id, prompt)
  if not pasted then
    return nil, paste_err
  end

  if tmux_cfg.focus_back_to_neovim ~= false and state.neovim_pane then
    systemlist({ "tmux", "select-pane", "-t", state.neovim_pane })
  end

  return pane_id, nil
end

return M
