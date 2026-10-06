local M = {}

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO)
  end)
end

local function write_prompt_file(prompt)
  local path = vim.fn.tempname()
  local ok = vim.fn.writefile(vim.split(prompt, "\n", { plain = true }), path, "b")
  if ok ~= 0 then
    return nil, "Failed to write temporary prompt file"
  end
  return path, nil
end

local function new_session_name()
  return "neopi-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
end

local function append_data(target, data)
  if data then
    vim.list_extend(target, data)
  end
end

local function permission_flag(permissions)
  if permissions == "approve-all" then
    return "--approve-all"
  end

  if permissions == "approve-reads" then
    return "--approve-reads"
  end

  if permissions == "deny-all" then
    return "--deny-all"
  end

  return nil
end

-- pi-acp spawns the `pi` binary from PATH. Forward Neopi's configured pi_command
-- so that acpx uses the same Pi installation (and therefore the same default
-- model from Pi's own settings) instead of whatever `pi` resolves to on PATH.
local function job_env(config)
  local pi_command = config.pi_command
  if not pi_command or pi_command == "" then
    return nil
  end

  return { PI_ACP_PI_COMMAND = pi_command }
end

function M.ensure_available(config)
  local command = (config.acpx and config.acpx.command) or "acpx"
  if vim.fn.executable(command) ~= 1 then
    return false, "Neopi acpx backend requires the `" .. command .. "` executable"
  end

  return true, nil
end

function M.send(prompt, config, callbacks, opts)
  callbacks = callbacks or {}
  opts = opts or {}
  local acpx_cfg = config.acpx or {}
  local command = acpx_cfg.command or "acpx"
  local agent = acpx_cfg.agent or "pi"
  local format = acpx_cfg.format or "text"
  local permissions = acpx_cfg.permissions or "approve-all"
  local cwd = vim.fn.getcwd()
  local session = opts.session or acpx_cfg.session or new_session_name()
  local create_session = opts.create_session
  if create_session == nil then
    create_session = opts.session == nil and acpx_cfg.session == nil
  end

  local prompt_file, err = write_prompt_file(prompt)
  if not prompt_file then
    return nil, err
  end

  local result = {
    id = session,
    kind = "acpx_session",
    output = {},
    errors = {},
  }

  local prompt_args = {
    command,
    "--cwd",
    cwd,
    "--format",
    format,
  }

  local permissions_arg = permission_flag(permissions)
  if permissions_arg then
    table.insert(prompt_args, permissions_arg)
  end

  vim.list_extend(prompt_args, {
    agent,
    "-s",
    session,
    "--file",
    prompt_file,
  })

  local function start_prompt_job()
    local job_id = vim.fn.jobstart(prompt_args, {
      cwd = cwd,
      env = job_env(config),
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        append_data(result.output, data)
      end,
      on_stderr = function(_, data)
        append_data(result.errors, data)
      end,
      on_exit = function(_, code)
        vim.fn.delete(prompt_file)
        if code == 0 then
          if callbacks.on_done then
            callbacks.on_done(result)
          end
          notify("Pi acpx session finished: " .. session, vim.log.levels.INFO)
        else
          if callbacks.on_error then
            callbacks.on_error(result)
          end
          local msg = "Pi acpx session failed: " .. session
          if #result.errors > 0 then
            msg = msg .. "\n" .. table.concat(result.errors, "\n")
          end
          notify(msg, vim.log.levels.ERROR)
        end
      end,
    })

    if job_id <= 0 then
      vim.fn.delete(prompt_file)
      if callbacks.on_error then
        callbacks.on_error(result)
      end
      notify("Failed to start acpx prompt job", vim.log.levels.ERROR)
    end
  end

  if not create_session then
    start_prompt_job()
    return result, nil
  end

  local new_args = {
    command,
    "--cwd",
    cwd,
    agent,
    "sessions",
    "new",
    "--name",
    session,
  }

  local new_job = vim.fn.jobstart(new_args, {
    cwd = cwd,
    env = job_env(config),
    stdout_buffered = true,
    stderr_buffered = true,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.fn.delete(prompt_file)
        if callbacks.on_error then
          callbacks.on_error(result)
        end
        notify("Failed to create acpx session: " .. session, vim.log.levels.ERROR)
        return
      end

      start_prompt_job()
    end,
  })

  if new_job <= 0 then
    vim.fn.delete(prompt_file)
    if callbacks.on_error then
      callbacks.on_error(result)
    end
    return nil, "Failed to start acpx session creation job"
  end

  return result, nil
end

return M
