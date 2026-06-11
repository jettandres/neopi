local M = {}

local ns = vim.api.nvim_create_namespace("neopi_indicators")

local default_spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local default_highlights = {
  running = "NeopiRunning",
  success = "NeopiSuccess",
  error = "NeopiError",
}

function M.setup_highlights()
  vim.api.nvim_set_hl(0, "NeopiRunning", { fg = "#e0af68", default = true })
  vim.api.nvim_set_hl(0, "NeopiSuccess", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "NeopiError", { fg = "#f7768e", default = true })
end

local function line_is_valid(bufnr, line)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr) and line and line >= 0 and line < vim.api.nvim_buf_line_count(bufnr)
end

local Indicator = {}
Indicator.__index = Indicator

function Indicator:update_number_highlights(hl_group)
  if not self.number_highlight or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  for _, extmark in ipairs(self.number_extmarks) do
    pcall(vim.api.nvim_buf_del_extmark, self.bufnr, ns, extmark)
  end
  self.number_extmarks = {}

  local last_line = vim.api.nvim_buf_line_count(self.bufnr) - 1
  local start_line = math.max(0, self.start_line)
  local end_line = math.min(last_line, self.end_line)

  for line = start_line, end_line do
    local extmark = vim.api.nvim_buf_set_extmark(self.bufnr, ns, line, 0, {
      number_hl_group = hl_group,
    })
    table.insert(self.number_extmarks, extmark)
  end
end

function Indicator:update(text, hl_group, number_hl_group)
  if not line_is_valid(self.bufnr, self.line) then
    self:stop()
    return
  end

  self.extmark = vim.api.nvim_buf_set_extmark(self.bufnr, ns, self.line, 0, {
    id = self.extmark,
    virt_text = { { text, hl_group or "Comment" } },
    virt_text_pos = "eol",
  })

  if number_hl_group then
    self:update_number_highlights(number_hl_group)
  end
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
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    if self.extmark then
      pcall(vim.api.nvim_buf_del_extmark, self.bufnr, ns, self.extmark)
    end

    for _, extmark in ipairs(self.number_extmarks or {}) do
      pcall(vim.api.nvim_buf_del_extmark, self.bufnr, ns, extmark)
    end
  end

  self.extmark = nil
  self.number_extmarks = {}
end

function Indicator:done(text, hl_group, ttl_ms, number_hl_group)
  self:stop()
  vim.schedule(function()
    self:update(text, hl_group or "DiagnosticOk", number_hl_group)
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
  local highlights = vim.tbl_deep_extend("force", default_highlights, opts.highlights or {})

  local indicator = setmetatable({
    bufnr = bufnr,
    line = line,
    start_line = opts.start_line or line,
    end_line = opts.end_line or line,
    frame = 1,
    extmark = nil,
    number_extmarks = {},
    number_highlight = opts.number_highlight ~= false,
    highlights = highlights,
    timer = nil,
  }, Indicator)

  indicator:update(frames[1] .. " " .. message, "Comment", highlights.running)

  local timer = vim.loop.new_timer()
  indicator.timer = timer
  timer:start(interval, interval, function()
    vim.schedule(function()
      if not indicator.timer then
        return
      end
      indicator.frame = (indicator.frame % #frames) + 1
      indicator:update(frames[indicator.frame] .. " " .. message, "Comment", highlights.running)
    end)
  end)

  return indicator
end

return M
