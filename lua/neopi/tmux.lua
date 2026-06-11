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

local function command_for_prompt(prompt, config)
  local path, err = write_prompt_file(prompt)
  if not path then
    return nil, err
  end

  local quoted_path = vim.fn.shellescape(path)
  local pi_command = config.pi_command or "pi"

  return string.format(
    "prompt=$(cat %s); rm -f %s; exec %s \"$prompt\"",
    quoted_path,
    quoted_path,
    pi_command
  ), nil
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

local function pane_exists(pane_id)
  if not pane_id then
    return false
  end

  local code = systemlist({ "tmux", "display-message", "-t", pane_id, "-p", "#{pane_id}" })
  return code == 0
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

  local command, command_err = command_for_prompt(prompt, config)
  if not command then
    return nil, command_err
  end

  local cwd = vim.fn.getcwd()
  local tmux_cfg = config.tmux or {}
  local args

  if #state.pi_panes == 0 or not pane_exists(state.pi_panes[#state.pi_panes]) then
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

  if tmux_cfg.focus_back_to_neovim ~= false and state.neovim_pane then
    systemlist({ "tmux", "select-pane", "-t", state.neovim_pane })
  end

  return pane_id, nil
end

return M
