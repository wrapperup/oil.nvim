local config = require("oil.config")
local columns = require("oil.columns")
local layout = require("oil.layout")
local loading = require("oil.loading")
local util = require("oil.util")
local Progress = {}

local FPS = 20

function Progress.new()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  return setmetatable({
    lines = { "", "" },
    count = "",
    spinner = "",
    bufnr = bufnr,
    winid = nil,
    min_bufnr = nil,
    min_winid = nil,
    autocmds = {},
    closing = false,
  }, {
    __index = Progress,
  })
end

---@param opts nil|table
---    cancel fun()
function Progress:show(opts)
  opts = opts or {}
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    return
  end
  self.closing = false
  self.cancel = opts.cancel
  local loading_iter = loading.get_bar_iter()
  local spinner = loading.get_iter("dots")
  self.timer = vim.loop.new_timer()
  self.timer:start(
    0,
    math.floor(1000 / FPS),
    vim.schedule_wrap(function()
      self.lines[2] = string.format("%s %s", self.count, loading_iter())
      self.spinner = spinner()
      self:_render()
    end)
  )
  local width, height = layout.calculate_dims(120, 10, config.progress)
  self.winid = vim.api.nvim_open_win(self.bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((layout.get_editor_height() - height) / 2),
    col = math.floor((layout.get_editor_width() - width) / 2),
    zindex = 152, -- render on top of the floating window title
    style = "minimal",
    border = config.progress.border,
  })
  vim.bo[self.bufnr].filetype = "oil_progress"
  for k, v in pairs(config.preview.win_options) do
    vim.api.nvim_win_set_option(self.winid, k, v)
  end
  table.insert(
    self.autocmds,
    vim.api.nvim_create_autocmd("VimResized", {
      callback = function()
        self:_reposition()
      end,
    })
  )
  table.insert(
    self.autocmds,
    vim.api.nvim_create_autocmd("WinLeave", {
      callback = function()
        self:minimize()
      end,
    })
  )
  local cancel = self.cancel or function() end
  local minimize = function()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
      vim.api.nvim_win_close(self.winid, true)
    end
  end
  vim.keymap.set("n", "c", cancel, { buffer = self.bufnr, nowait = true })
  vim.keymap.set("n", "C", cancel, { buffer = self.bufnr, nowait = true })
  vim.keymap.set("n", "m", minimize, { buffer = self.bufnr, nowait = true })
  vim.keymap.set("n", "M", minimize, { buffer = self.bufnr, nowait = true })
end

function Progress:_render()
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    util.render_text(
      self.bufnr,
      self.lines,
      { winid = self.winid, actions = { "[M]inimize", "[C]ancel" } }
    )
  end
  if self.min_bufnr and vim.api.nvim_buf_is_valid(self.min_bufnr) then
    util.render_text(
      self.min_bufnr,
      { string.format("%sOil: %s", self.spinner, self.count) },
      { winid = self.min_winid, h_align = "left" }
    )
  end
end

function Progress:_reposition()
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    local min_width = 120
    local line_width = vim.api.nvim_strwidth(self.lines[1])
    if line_width > min_width then
      min_width = line_width
    end
    local width, height = layout.calculate_dims(min_width, 10, config.progress)
    vim.api.nvim_win_set_config(self.winid, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((layout.get_editor_height() - height) / 2),
      col = math.floor((layout.get_editor_width() - width) / 2),
      zindex = 152, -- render on top of the floating window title
    })
  end
end

function Progress:_cleanup_main_win()
  if self.winid then
    if vim.api.nvim_win_is_valid(self.winid) then
      vim.api.nvim_win_close(self.winid, true)
    end
    self.winid = nil
  end
  for _, id in ipairs(self.autocmds) do
    vim.api.nvim_del_autocmd(id)
  end
  self.autocmds = {}
  self.bufnr = nil
end

function Progress:minimize()
  if self.closing then
    return
  end
  self:_cleanup_main_win()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = 16,
    height = 1,
    anchor = "SE",
    row = layout.get_editor_height(),
    col = layout.get_editor_width(),
    zindex = 152, -- render on top of the floating window title
    style = "minimal",
    border = config.progress.minimized_border,
  })
  self.min_bufnr = bufnr
  self.min_winid = winid
  self:_render()
end

---@param action oil.Action
---@param idx integer
---@param total integer
function Progress:set_action(action, idx, total)
  local adapter = util.get_adapter_for_action(action)
  local change_line
  if action.type == "change" then
    change_line = columns.render_change_action(adapter, action)
  else
    change_line = adapter.render_action(action)
  end
  self.lines[1] = change_line
  self.count = string.format("%d/%d", idx, total)
  self:_reposition()
  self:_render()
end

function Progress:close()
  self.closing = true
  if self.timer then
    self.timer:close()
    self.timer = nil
  end
  self:_cleanup_main_win()
  if self.min_winid and vim.api.nvim_win_is_valid(self.min_winid) then
    vim.api.nvim_win_close(self.min_winid, true)
  end
  self.min_winid = nil
  self.min_bufnr = nil
end

return Progress
