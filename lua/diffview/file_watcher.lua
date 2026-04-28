local debounce = require("diffview.debounce")
local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"

local api = vim.api
local logger = DiffviewGlobal.logger
local uv = vim.uv or vim.loop

local M = {}

---@class diffview.FileWatcher
---@field view DiffView
---@field opt table
---@field handles uv_fs_event_t[]
---@field pending { path: string?, is_git_event: boolean }[]
---@field refresh ManagedFn?
---@field focus_autocmd integer?
local FileWatcher = {}
FileWatcher.__index = FileWatcher

local function join_path(...)
  return table.concat({ ... }, "/"):gsub("/+", "/")
end

local function path_starts_with(path, prefix)
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

local function normalize_path(root, filename)
  if not filename or filename == "" then
    return nil
  end

  if filename:sub(1, 1) == "/" then
    return filename
  end

  return join_path(root, filename)
end

local function is_git_path(view, path, is_git_event)
  if is_git_event then
    return true
  end

  if not path then
    return false
  end

  local git_dir = view.adapter.ctx.dir
  if git_dir and path_starts_with(path, git_dir) then
    return true
  end

  local top = view.adapter.ctx.toplevel
  if top and path_starts_with(path, join_path(top, ".git")) then
    return true
  end

  return path:find("/%.git/") ~= nil or path:match("/%.git$") ~= nil
end

local function is_gitignored(view, path)
  if not path then
    return false
  end

  local top = view.adapter.ctx.toplevel
  if not top or not path_starts_with(path, top) then
    return false
  end

  local relpath = path:sub(#top + 2)
  if relpath == "" then
    return false
  end

  local cmd = vim.deepcopy(config.get_config().git_cmd)
  vim.list_extend(cmd, { "-C", top, "check-ignore", "-q", "--", relpath })
  vim.fn.system(cmd)

  return vim.v.shell_error == 0
end

local function should_refresh(view, opt, event)
  if not event.path then
    return true
  end

  if is_git_path(view, event.path, event.is_git_event) then
    return true
  end

  if opt.ignore_gitignored and is_gitignored(view, event.path) then
    return false
  end

  return true
end

function FileWatcher.new(view, opt)
  local self = setmetatable({
    view = view,
    opt = opt,
    handles = {},
    pending = {},
  }, FileWatcher)

  self.refresh = debounce.debounce_trailing(opt.debounce or 150, false, function()
    local pending = self.pending
    self.pending = {}

    for _, event in ipairs(pending) do
      if should_refresh(self.view, self.opt, event) then
        self.view:update_file_panel()
        return
      end
    end
  end)

  return self
end

function FileWatcher:queue(path, is_git_event)
  self.pending[#self.pending + 1] = {
    path = path,
    is_git_event = is_git_event,
  }
  self.refresh()
end

function FileWatcher:start_handle(path, opt)
  if not uv.new_fs_event then
    logger:debug("[FileWatcher] uv fs_event is not available.")
    return false
  end

  local handle = uv.new_fs_event()
  if not handle then
    logger:fmt_debug("[FileWatcher] Failed to create fs_event handle for %s.", path)
    return false
  end

  local ok, result, start_err = pcall(function()
    return handle:start(path, { recursive = opt.recursive }, vim.schedule_wrap(function(fs_err, filename)
      if fs_err then
        logger:fmt_debug("[FileWatcher] fs_event error for %s: %s", path, fs_err)
        return
      end

      self:queue(normalize_path(path, filename), opt.is_git_event)
    end))
  end)

  if not ok or result == nil then
    if not handle:is_closing() then
      handle:close()
    end
    logger:fmt_debug("[FileWatcher] Failed to watch %s: %s", path, start_err or result)
    return false
  end

  self.handles[#self.handles + 1] = handle
  return true
end

function FileWatcher:start()
  local top = self.view.adapter.ctx.toplevel
  if not top then
    logger:debug("[FileWatcher] No repository top-level to watch.")
    return
  end

  local recursive = self:start_handle(top, { recursive = true, is_git_event = false })
  if not recursive then
    self:start_handle(top, { recursive = false, is_git_event = false })
  end

  local git_dir = self.view.adapter.ctx.dir
  if git_dir and not path_starts_with(git_dir, top) then
    self:start_handle(git_dir, { recursive = false, is_git_event = true })
  end

  if self.opt.update_on_focus then
    self.focus_autocmd = api.nvim_create_autocmd("FocusGained", {
      group = api.nvim_create_augroup(("diffview_file_watcher_%d"):format(self.view.tabpage), {}),
      callback = function()
        if self.view.ready and self.view:is_cur_tabpage() then
          self.view:update_file_panel()
        end
      end,
    })
  end
end

function FileWatcher:close()
  if self.refresh then
    self.refresh:close()
    self.refresh = nil
  end

  if self.focus_autocmd then
    pcall(api.nvim_del_autocmd, self.focus_autocmd)
    self.focus_autocmd = nil
  end

  for _, handle in ipairs(self.handles) do
    handle:stop()
    if not handle:is_closing() then
      handle:close()
    end
  end

  self.handles = {}
  self.pending = {}
end

function M.watch(view, opt)
  local watcher = FileWatcher.new(view, opt)
  watcher:start()

  if #watcher.handles == 0 and not watcher.focus_autocmd then
    watcher:close()
    return nil
  end

  return watcher
end

return M
