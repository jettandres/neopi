local M = {}

local function has_mini_notify()
  return type(_G.MiniNotify) == "table"
    and type(_G.MiniNotify.add) == "function"
    and type(_G.MiniNotify.update) == "function"
    and type(_G.MiniNotify.remove) == "function"
end

local function level_name(level)
  if level == vim.log.levels.ERROR then
    return "ERROR"
  end
  if level == vim.log.levels.WARN then
    return "WARN"
  end
  if level == vim.log.levels.INFO then
    return "INFO"
  end
  return "INFO"
end

local Notification = {}
Notification.__index = Notification

function Notification:update(message, level, hl_group)
  if not self.id or not has_mini_notify() then
    vim.schedule(function()
      vim.notify(message, level or vim.log.levels.INFO)
    end)
    return
  end

  local id = self.id
  local update = {
    msg = message,
    level = level_name(level or vim.log.levels.INFO),
    hl_group = hl_group or self.hl_group,
  }

  vim.schedule(function()
    if has_mini_notify() then
      _G.MiniNotify.update(id, update)
    end
  end)
end

function Notification:finish(message, level, hl_group, ttl_ms)
  self:update(message, level, hl_group)

  if self.id and has_mini_notify() and ttl_ms and ttl_ms > 0 then
    local id = self.id
    vim.defer_fn(function()
      if has_mini_notify() then
        _G.MiniNotify.remove(id)
      end
    end, ttl_ms)
  end
end

function Notification:remove()
  if not self.id then
    return
  end

  local id = self.id
  vim.schedule(function()
    if has_mini_notify() then
      _G.MiniNotify.remove(id)
    end
  end)
end

function M.start(message, level, hl_group, data)
  level = level or vim.log.levels.INFO
  hl_group = hl_group or "DiagnosticInfo"

  if not has_mini_notify() then
    vim.notify(message, level)
    return setmetatable({ id = nil, hl_group = hl_group }, Notification)
  end

  local id = _G.MiniNotify.add(message, level_name(level), hl_group, vim.tbl_extend("force", {
    source = "neopi",
  }, data or {}))

  return setmetatable({ id = id, hl_group = hl_group }, Notification)
end

return M
