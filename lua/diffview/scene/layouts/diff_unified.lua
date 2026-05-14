--[[
  Unified Diff Layout

  Displays diffs in a single window with deleted lines shown as virtual text
  and added lines highlighted inline. This provides a unified diff view
  similar to `git diff` output.
]]

local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Layout = require("diffview.scene.layout").Layout
local oop = require("diffview.oop")

local Window = lazy.access("diffview.scene.window", "Window") ---@type Window|LazyModule
local unified_renderer = lazy.require("diffview.unified.renderer") ---@module "diffview.unified.renderer"

local api = vim.api
local await = async.await

local M = {}

-- Create namespace at module load time (not in async context)
local UNIFIED_NS = api.nvim_create_namespace("diffview_unified")

---@class DiffUnified : Layout
---@field a vcs.File? Reference to the "old" file (for fetching content)
---@field b Window The main window showing the "new" file
---@field ns_id integer Namespace for unified diff extmarks
---@field old_lines string[]? Cached old file content
---@field hunks unified.Hunk[]? Cached hunks for navigation
local DiffUnified = oop.create_class("DiffUnified", Layout)

---@alias DiffUnified.WindowSymbol "a"|"b"

---@class DiffUnified.init.Opt
---@field a vcs.File? The "old" file
---@field b vcs.File The "new" file
---@field winid_b integer?

DiffUnified.name = "diff_unified"

---@param opt DiffUnified.init.Opt
function DiffUnified:init(opt)
  self:super()
  -- Wrap 'a' in a table with 'file' property for compatibility with convert_layout
  self.a = opt.a and { file = opt.a } or nil
  self.b = Window({ file = opt.b, id = opt.winid_b })
  self:use_windows(self.b)
  self.ns_id = UNIFIED_NS  -- Use shared namespace (created at module load)
  self.old_lines = nil
  self.hunks = nil
end

---@override
---@param self DiffUnified
---@param pivot integer?
DiffUnified.create = async.void(function(self, pivot)
  self:create_pre()
  local curwin

  pivot = pivot or self:find_pivot()
  assert(api.nvim_win_is_valid(pivot), "Layout creation requires a valid window pivot!")

  -- Close all windows except pivot
  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      win:close(true)
    end
  end

  -- Create single window
  api.nvim_win_call(pivot, function()
    vim.cmd("aboveleft vsp")
    curwin = api.nvim_get_current_win()

    if self.b then
      self.b:set_id(curwin)
    else
      self.b = Window({ id = curwin })
    end
  end)

  api.nvim_win_close(pivot, true)
  self.windows = { self.b }
  await(self:create_post())
end)

---@param file vcs.File
function DiffUnified:set_file_a(file)
  self.a = file and { file = file } or nil
  if file then
    file.symbol = "a"
  end
end

---@param file vcs.File
function DiffUnified:set_file_b(file)
  self.b:set_file(file)
  file.symbol = "b"
end

---Fetch content from the old file.
---@param self DiffUnified
---@return string[]? lines
DiffUnified.fetch_old_content = async.wrap(function(self, callback)
  if not self.a or not self.a.file then
    callback({})
    return
  end

  local err, lines = await(self.a.file:produce_data())

  if err then
    callback({})
    return
  end

  callback(lines or {})
end)

---Apply unified diff rendering to the buffer.
---@param self DiffUnified
DiffUnified.render_unified = async.void(function(self)
  if not self.b or not self.b.file then return end

  local bufnr = self.b.file.bufnr
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  -- Fetch old content if not cached
  if not self.old_lines then
    self.old_lines = await(self:fetch_old_content())
  end

  -- Switch to main thread for vim API calls
  await(async.scheduler())

  -- Revalidate after scheduler
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  -- Get new content from buffer
  local new_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Render the unified diff and get result with hunks
  local result = unified_renderer.render(bufnr, self.ns_id, self.old_lines or {}, new_lines)

  -- Store hunks for navigation
  self.hunks = result.hunks

  -- Scroll to first change if we have one and window is valid
  if result.first_change_line and self.b.id and api.nvim_win_is_valid(self.b.id) then
    local line_count = api.nvim_buf_line_count(bufnr)
    local target_line = math.min(math.max(result.first_change_line, 1), line_count)
    api.nvim_win_set_cursor(self.b.id, { target_line, 0 })
    api.nvim_win_call(self.b.id, function()
      vim.cmd("normal! zz")
    end)
  end
end)

---Clear unified diff rendering.
function DiffUnified:clear_unified()
  self.hunks = nil
  if self.b and self.b.file and self.b.file.bufnr then
    unified_renderer.clear(self.b.file.bufnr, self.ns_id)
  end
end

---@param self DiffUnified
---@param entry FileEntry
DiffUnified.use_entry = async.void(function(self, entry)
  local layout = entry.layout --[[@as DiffUnified ]]
  assert(layout:instanceof(DiffUnified))

  -- Clear previous unified rendering (this also clears hunks)
  self:clear_unified()
  self.old_lines = nil

  -- Set files - layout.a is { file = vcs.File } or nil
  if layout.a and layout.a.file then
    self:set_file_a(layout.a.file)
  end
  self:set_file_b(layout.b.file)

  if self:is_valid() then
    await(self:open_files())
    -- Apply unified diff rendering after files are loaded
    await(self:render_unified())
  end
end)

function DiffUnified:get_main_win()
  return self.b
end

---@override
function DiffUnified:destroy()
  self:clear_unified()
  Layout.destroy(self)
end

---Override to disable native diff mode for unified view.
---@param self DiffUnified
DiffUnified.open_files = async.void(function(self)
  if #self:files() < #self.windows then
    self:open_null()
    self.emitter:emit("files_opened")
    return
  end

  -- Turn off diff mode (we use virtual lines instead)
  vim.cmd("diffoff!")

  if not self:is_files_loaded() then
    self:open_null()

    for _, win in ipairs(self.windows) do
      await(win:load_file())
    end
  end

  await(async.scheduler())

  for _, win in ipairs(self.windows) do
    await(win:open_file())
  end

  -- Disable diff-related window options for unified view
  if self.b and self.b.id and api.nvim_win_is_valid(self.b.id) then
    api.nvim_win_call(self.b.id, function()
      vim.wo.diff = false
      vim.wo.scrollbind = false
      vim.wo.cursorbind = false
      vim.wo.foldmethod = "manual"
      vim.wo.signcolumn = "no"
    end)
  end

  self.emitter:emit("files_opened")
end)

---Unified diff uses a single visible file window; never replace it with a null window.
---@override
---@param rev Rev
---@param status string Git status symbol.
---@param sym DiffUnified.WindowSymbol
function DiffUnified.should_null(rev, status, sym)
  return false
end

M.DiffUnified = DiffUnified
return M
