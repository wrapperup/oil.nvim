local cache = require("oil.cache")
local columns = require("oil.columns")
local config = require("oil.config")
local keymap_util = require("oil.keymap_util")
local loading = require("oil.loading")
local util = require("oil.util")
local FIELD = require("oil.constants").FIELD
local M = {}

-- map of path->last entry under cursor
local last_cursor_entry = {}

---@param entry oil.InternalEntry
---@param bufnr integer
---@return boolean
M.should_display = function(entry, bufnr)
  local name = entry[FIELD.name]
  return not config.view_options.is_always_hidden(name, bufnr)
    and (not config.view_options.is_hidden_file(name, bufnr) or config.view_options.show_hidden)
end

---@param bufname string
---@param name nil|string
M.set_last_cursor = function(bufname, name)
  last_cursor_entry[bufname] = name
end

---Set the cursor to the last_cursor_entry if one exists
M.maybe_set_cursor = function()
  local oil = require("oil")
  local bufname = vim.api.nvim_buf_get_name(0)
  local entry_name = last_cursor_entry[bufname]
  if not entry_name then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(0)
  for lnum = 1, line_count do
    local entry = oil.get_entry_on_line(0, lnum)
    if entry and entry.name == entry_name then
      local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, true)[1]
      local id_str = line:match("^/(%d+)")
      local col = line:find(entry_name, 1, true) or (id_str:len() + 1)
      vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
      M.set_last_cursor(bufname, nil)
      break
    end
  end
end

---@param bufname string
---@return nil|string
M.get_last_cursor = function(bufname)
  return last_cursor_entry[bufname]
end

local function are_any_modified()
  local buffers = M.get_all_buffers()
  for _, bufnr in ipairs(buffers) do
    if vim.bo[bufnr].modified then
      return true
    end
  end
  return false
end

M.toggle_hidden = function()
  local any_modified = are_any_modified()
  if any_modified then
    vim.notify("Cannot toggle hidden files when you have unsaved changes", vim.log.levels.WARN)
  else
    config.view_options.show_hidden = not config.view_options.show_hidden
    M.rerender_all_oil_buffers({ refetch = false })
  end
end

---@param is_hidden_file fun(filename: string, bufnr: nil|integer): boolean
M.set_is_hidden_file = function(is_hidden_file)
  local any_modified = are_any_modified()
  if any_modified then
    vim.notify("Cannot change is_hidden_file when you have unsaved changes", vim.log.levels.WARN)
  else
    config.view_options.is_hidden_file = is_hidden_file
    M.rerender_all_oil_buffers({ refetch = false })
  end
end

M.set_columns = function(cols)
  local any_modified = are_any_modified()
  if any_modified then
    vim.notify("Cannot change columns when you have unsaved changes", vim.log.levels.WARN)
  else
    config.columns = cols
    -- TODO only refetch if we don't have all the necessary data for the columns
    M.rerender_all_oil_buffers({ refetch = true })
  end
end

-- List of bufnrs
local session = {}

---@return integer[]
M.get_all_buffers = function()
  return vim.tbl_filter(vim.api.nvim_buf_is_loaded, vim.tbl_keys(session))
end

local buffers_locked = false
---Make all oil buffers nomodifiable
M.lock_buffers = function()
  buffers_locked = true
  for bufnr in pairs(session) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      vim.bo[bufnr].modifiable = false
    end
  end
end

---Restore normal modifiable settings for oil buffers
M.unlock_buffers = function()
  buffers_locked = false
  for bufnr in pairs(session) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local adapter = util.get_adapter(bufnr)
      if adapter then
        vim.bo[bufnr].modifiable = adapter.is_modifiable(bufnr)
      end
    end
  end
end

---@param opts table
---@note
--- This DISCARDS ALL MODIFICATIONS a user has made to oil buffers
M.rerender_all_oil_buffers = function(opts)
  local buffers = M.get_all_buffers()
  local hidden_buffers = {}
  for _, bufnr in ipairs(buffers) do
    hidden_buffers[bufnr] = true
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      hidden_buffers[vim.api.nvim_win_get_buf(winid)] = nil
    end
  end
  for _, bufnr in ipairs(buffers) do
    if hidden_buffers[bufnr] then
      vim.b[bufnr].oil_dirty = opts
      -- We also need to mark this as nomodified so it doesn't interfere with quitting vim
      vim.bo[bufnr].modified = false
    else
      M.render_buffer_async(bufnr, opts)
    end
  end
end

M.set_win_options = function()
  local winid = vim.api.nvim_get_current_win()
  for k, v in pairs(config.win_options) do
    if config.restore_win_options then
      local varname = "_oil_" .. k
      if not pcall(vim.api.nvim_win_get_var, winid, varname) then
        local prev_value = vim.wo[k]
        vim.api.nvim_win_set_var(winid, varname, prev_value)
      end
    end
    vim.api.nvim_win_set_option(winid, k, v)
  end
end

M.restore_win_options = function()
  local winid = vim.api.nvim_get_current_win()
  for k in pairs(config.win_options) do
    local varname = "_oil_" .. k
    local has_opt, opt = pcall(vim.api.nvim_win_get_var, winid, varname)
    if has_opt then
      vim.api.nvim_win_set_option(winid, k, opt)
    end
  end
end

---Get a list of visible oil buffers and a list of hidden oil buffers
---@note
--- If any buffers are modified, return values are nil
---@return nil|integer[]
---@return nil|integer[]
local function get_visible_hidden_buffers()
  local buffers = M.get_all_buffers()
  local hidden_buffers = {}
  for _, bufnr in ipairs(buffers) do
    if vim.bo[bufnr].modified then
      return
    end
    hidden_buffers[bufnr] = true
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      hidden_buffers[vim.api.nvim_win_get_buf(winid)] = nil
    end
  end
  local visible_buffers = vim.tbl_filter(function(bufnr)
    return not hidden_buffers[bufnr]
  end, buffers)
  return visible_buffers, vim.tbl_keys(hidden_buffers)
end

---Delete unmodified, hidden oil buffers and if none remain, clear the cache
M.delete_hidden_buffers = function()
  local visible_buffers, hidden_buffers = get_visible_hidden_buffers()
  if not visible_buffers or not hidden_buffers or not vim.tbl_isempty(visible_buffers) then
    return
  end
  for _, bufnr in ipairs(hidden_buffers) do
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  cache.clear_everything()
end

---@param bufnr integer
M.initialize = function(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_clear_autocmds({
    buffer = bufnr,
    group = "Oil",
  })
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].syntax = "oil"
  vim.bo[bufnr].filetype = "oil"
  vim.b[bufnr].EditorConfig_disable = 1
  session[bufnr] = true
  for k, v in pairs(config.buf_options) do
    vim.api.nvim_buf_set_option(bufnr, k, v)
  end
  M.set_win_options()
  vim.api.nvim_create_autocmd("BufHidden", {
    desc = "Delete oil buffers when no longer in use",
    group = "Oil",
    nested = true,
    buffer = bufnr,
    callback = function()
      -- First wait a short time (10ms) for the buffer change to settle
      vim.defer_fn(function()
        local visible_buffers = get_visible_hidden_buffers()
        -- Only kick off the 2-second timer if we don't have any visible oil buffers
        if visible_buffers and vim.tbl_isempty(visible_buffers) then
          vim.defer_fn(function()
            M.delete_hidden_buffers()
          end, 2000)
        end
      end, 10)
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = "Oil",
    nested = true,
    once = true,
    buffer = bufnr,
    callback = function()
      session[bufnr] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = "Oil",
    buffer = bufnr,
    callback = function(args)
      local opts = vim.b[args.buf].oil_dirty
      if opts then
        vim.b[args.buf].oil_dirty = nil
        M.render_buffer_async(args.buf, opts)
      end
    end,
  })
  local timer
  vim.api.nvim_create_autocmd("CursorMoved", {
    desc = "Update oil preview window",
    group = "Oil",
    buffer = bufnr,
    callback = function()
      local oil = require("oil")
      local parser = require("oil.mutator.parser")
      if vim.wo.previewwindow then
        return
      end

      -- Force the cursor to be after the (concealed) ID at the beginning of the line
      local adapter = util.get_adapter(bufnr)
      if adapter then
        local cur = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(bufnr, cur[1] - 1, cur[1], true)[1]
        local column_defs = columns.get_supported_columns(adapter)
        local result = parser.parse_line(adapter, line, column_defs)
        if result and result.data then
          local min_col = result.ranges.id[2] + 1
          if cur[2] < min_col then
            vim.api.nvim_win_set_cursor(0, { cur[1], min_col })
          end
        end
      end

      -- Debounce and update the preview window
      if timer then
        timer:again()
        return
      end
      timer = vim.loop.new_timer()
      if not timer then
        return
      end
      timer:start(10, 100, function()
        timer:stop()
        timer:close()
        timer = nil
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() ~= bufnr then
            return
          end
          local entry = oil.get_cursor_entry()
          if entry then
            local winid = util.get_preview_win()
            if winid then
              if entry.id ~= vim.w[winid].oil_entry_id then
                oil.select({ preview = true })
              end
            end
          end
        end)
      end)
    end,
  })
  M.render_buffer_async(bufnr, {}, function(err)
    if err then
      vim.notify(
        string.format("Error rendering oil buffer %s: %s", vim.api.nvim_buf_get_name(bufnr), err),
        vim.log.levels.ERROR
      )
    else
      vim.api.nvim_exec_autocmds(
        "User",
        { pattern = "OilEnter", modeline = false, data = { buf = bufnr } }
      )
    end
  end)
  keymap_util.set_keymaps("", config.keymaps, bufnr)
end

---@param entry oil.InternalEntry
---@return boolean
local function is_entry_directory(entry)
  local type = entry[FIELD.type]
  if type == "directory" then
    return true
  elseif type == "link" then
    local meta = entry[FIELD.meta]
    return meta and meta.link_stat and meta.link_stat.type == "directory"
  else
    return false
  end
end

---@param bufnr integer
---@param opts nil|table
---    jump boolean
---    jump_first boolean
---@return boolean
local function render_buffer(bufnr, opts)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  opts = vim.tbl_extend("keep", opts or {}, {
    jump = false,
    jump_first = false,
  })
  local scheme = util.parse_url(bufname)
  local adapter = util.get_adapter(bufnr)
  if not scheme or not adapter then
    return false
  end
  local entries = cache.list_url(bufname)
  local entry_list = vim.tbl_values(entries)

  table.sort(entry_list, function(a, b)
    local a_isdir = is_entry_directory(a)
    local b_isdir = is_entry_directory(b)
    if a_isdir ~= b_isdir then
      return a_isdir
    end
    return a[FIELD.name] < b[FIELD.name]
  end)

  local jump_idx
  if opts.jump_first then
    jump_idx = 1
  end
  local seek_after_render_found = false
  local seek_after_render = M.get_last_cursor(bufname)
  local column_defs = columns.get_supported_columns(scheme)
  local line_table = {}
  local col_width = {}
  for i in ipairs(column_defs) do
    col_width[i + 1] = 1
  end
  local virt_text = {}
  for _, entry in ipairs(entry_list) do
    if not M.should_display(entry, bufnr) then
      goto continue
    end
    local cols = M.format_entry_cols(entry, column_defs, col_width, adapter)
    table.insert(line_table, cols)

    local name = entry[FIELD.name]
    if seek_after_render == name then
      seek_after_render_found = true
      jump_idx = #line_table
      M.set_last_cursor(bufname, nil)
    end
    ::continue::
  end

  local lines, highlights = util.render_table(line_table, col_width)

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  util.set_highlights(bufnr, highlights)
  local ns = vim.api.nvim_create_namespace("Oil")
  for _, v in ipairs(virt_text) do
    local lnum, col, ext_opts = unpack(v)
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, col, ext_opts)
  end
  if opts.jump then
    -- TODO why is the schedule necessary?
    vim.schedule(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
          -- If we're not jumping to a specific lnum, use the current lnum so we can adjust the col
          local lnum = jump_idx or vim.api.nvim_win_get_cursor(winid)[1]
          local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, true)[1]
          local id_str = line:match("^/(%d+)")
          local id = tonumber(id_str)
          if id then
            local entry = cache.get_entry_by_id(id)
            if entry then
              local name = entry[FIELD.name]
              local col = line:find(name, 1, true) or (id_str:len() + 1)
              vim.api.nvim_win_set_cursor(winid, { lnum, col - 1 })
            end
          end
        end
      end
    end)
  end
  return seek_after_render_found
end

---@private
---@param entry oil.InternalEntry
---@param column_defs table[]
---@param col_width integer[]
---@param adapter oil.Adapter
---@return oil.TextChunk[]
M.format_entry_cols = function(entry, column_defs, col_width, adapter)
  local name = entry[FIELD.name]
  -- First put the unique ID
  local cols = {}
  local id_key = cache.format_id(entry[FIELD.id])
  col_width[1] = id_key:len()
  table.insert(cols, id_key)
  -- Then add all the configured columns
  for i, column in ipairs(column_defs) do
    local chunk = columns.render_col(adapter, column, entry)
    local text = type(chunk) == "table" and chunk[1] or chunk
    col_width[i + 1] = math.max(col_width[i + 1], vim.api.nvim_strwidth(text))
    table.insert(cols, chunk)
  end
  -- Always add the entry name at the end
  local entry_type = entry[FIELD.type]
  if entry_type == "directory" then
    table.insert(cols, { name .. "/", "OilDir" })
  elseif entry_type == "socket" then
    table.insert(cols, { name, "OilSocket" })
  elseif entry_type == "link" then
    local meta = entry[FIELD.meta]
    local link_text
    if meta then
      if meta.link_stat and meta.link_stat.type == "directory" then
        name = name .. "/"
      end

      if meta.link then
        link_text = "->" .. " " .. meta.link
        if meta.link_stat and meta.link_stat.type == "directory" then
          link_text = util.addslash(link_text)
        end
      end
    end

    table.insert(cols, { name, "OilLink" })
    if link_text then
      table.insert(cols, { link_text, "Comment" })
    end
  else
    table.insert(cols, { name, "OilFile" })
  end
  return cols
end

---@param bufnr integer
---@param opts nil|table
---    preserve_undo nil|boolean
---    refetch nil|boolean Defaults to true
---@param callback nil|fun(err: nil|string)
M.render_buffer_async = function(bufnr, opts, callback)
  opts = vim.tbl_deep_extend("keep", opts or {}, {
    preserve_undo = false,
    refetch = true,
  })
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local scheme, dir = util.parse_url(bufname)
  local preserve_undo = opts.preserve_undo and config.adapters[scheme] == "files"
  if not preserve_undo then
    -- Undo should not return to a blank buffer
    -- Method taken from :h clear-undo
    vim.bo[bufnr].undolevels = -1
  end
  local handle_error = vim.schedule_wrap(function(message)
    if not preserve_undo then
      vim.bo[bufnr].undolevels = vim.api.nvim_get_option("undolevels")
    end
    util.render_text(bufnr, { "Error: " .. message })
    if callback then
      callback(message)
    else
      error(message)
    end
  end)
  if not dir then
    handle_error(string.format("Could not parse oil url '%s'", bufname))
    return
  end
  local adapter = util.get_adapter(bufnr)
  if not adapter then
    handle_error(string.format("[oil] no adapter for buffer '%s'", bufname))
    return
  end
  local start_ms = vim.loop.hrtime() / 1e6
  local seek_after_render_found = false
  local first = true
  vim.bo[bufnr].modifiable = false
  loading.set_loading(bufnr, true)

  local finish = vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    loading.set_loading(bufnr, false)
    render_buffer(bufnr, { jump = true })
    if not preserve_undo then
      vim.bo[bufnr].undolevels = vim.api.nvim_get_option("undolevels")
    end
    vim.bo[bufnr].modifiable = not buffers_locked and adapter.is_modifiable(bufnr)
    if callback then
      callback()
    end
  end)
  if not opts.refetch then
    finish()
    return
  end

  adapter.list(bufname, config.columns, function(err, has_more)
    loading.set_loading(bufnr, false)
    if err then
      handle_error(err)
      return
    elseif has_more then
      local now = vim.loop.hrtime() / 1e6
      local delta = now - start_ms
      -- If we've been chugging for more than 40ms, go ahead and render what we have
      if delta > 40 then
        start_ms = now
        vim.schedule(function()
          seek_after_render_found =
            render_buffer(bufnr, { jump = not seek_after_render_found, jump_first = first })
        end)
      end
      first = false
    else
      -- done iterating
      finish()
    end
  end)
end

return M
