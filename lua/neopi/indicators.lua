local M = {}

local ns = vim.api.nvim_create_namespace("neopi_indicators")

local default_spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function line_is_valid(bufnr, line)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr) and line and line >= 0 and line < vim.api.nvim_buf_line_count(bufnr)
end

local Indicator = {}
Indicator.__index = Indicator

function Indicator:update(text, hl_group)
  if not line_is_valid(self.bufnr, self.line) then
    self:stop()
    return
  end

  self.extmark = vim.api.nvim_buf_set_extmark(self.bufnr, ns, self.line, 0, {
    id = self.extmark,
    virt_text = { { text, hl_group or "Comment" } },
    virt_text_pos = "eol",
  })
end

function Indicator:stop()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

function Indicator:clear()
  self:stop()
  if self.extmark and vim.api.nvim_buf_is_valid(self.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, self.bufnr, ns, self.extmark)
  end
  self.extmark = nil
end

function Indicator:done(text, hl_group, ttl_ms)
  self:stop()
  vim.schedule(function()
    self:update(text, hl_group or "DiagnosticOk")
  end)

  if ttl_ms and ttl_ms > 0 then
    vim.defer_fn(function()
      self:clear()
    end, ttl_ms)
  end
end

function M.start(opts)
  opts = opts or {}

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or (vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not line_is_valid(bufnr, line) then
    return nil
  end

  local frames = opts.spinner or default_spinner
  local interval = opts.interval_ms or 120
  local message = opts.message or "Pi running..."

  local indicator = setmetatable({
    bufnr = bufnr,
    line = line,
    frame = 1,
    extmark = nil,
    timer = nil,
  }, Indicator)

  indicator:update(frames[1] .. " " .. message, "Comment")

  local timer = vim.loop.new_timer()
  indicator.timer = timer
  timer:start(interval, interval, function()
    vim.schedule(function()
      if not indicator.timer then
        return
      end
      indicator.frame = (indicator.frame % #frames) + 1
      indicator:update(frames[indicator.frame] .. " " .. message, "Comment")
    end)
  end)

  return indicator
end

return M
