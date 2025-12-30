--[[
  Unified Diff Renderer

  Renders unified diff view using Neovim's extmark API with virtual lines.
  Deleted lines are shown as virtual text above their position.
  Added lines are highlighted inline.
]]

local lazy = require("diffview.lazy")
local diff_processor = lazy.require("diffview.unified.diff_processor") ---@module "diffview.unified.diff_processor"

local api = vim.api

local M = {}

---Render unified diff in a buffer.
---@param bufnr integer Buffer number
---@param ns_id integer Namespace ID for extmarks
---@param old_lines string[] Old file content
---@param new_lines string[] New file content
function M.render(bufnr, ns_id, old_lines, new_lines)
  -- Clear any existing unified diff rendering
  M.clear(bufnr, ns_id)

  -- Compute hunks
  local hunks = diff_processor.compute_hunks(old_lines, new_lines)

  -- Convert to render instructions
  local instructions = diff_processor.hunks_to_render_instructions(hunks)

  -- Group virtual lines by anchor line
  local virtual_lines_by_anchor = {}

  -- Apply render instructions
  for _, instr in ipairs(instructions) do
    if instr.type == "virtual_line" then
      local anchor = instr.anchor_line
      if not virtual_lines_by_anchor[anchor] then
        virtual_lines_by_anchor[anchor] = {}
      end
      table.insert(virtual_lines_by_anchor[anchor], {
        content = instr.content,
        hl_group = instr.hl_group,
      })
    elseif instr.type == "highlight_line" then
      M.highlight_line(bufnr, ns_id, instr.line, instr.hl_group)
    elseif instr.type == "word_diff" then
      M.apply_word_diff(bufnr, ns_id, instr.line, instr.word_diff)
    end
  end

  -- Apply virtual lines (grouped by anchor)
  for anchor_line, virt_lines in pairs(virtual_lines_by_anchor) do
    M.add_virtual_lines(bufnr, ns_id, anchor_line, virt_lines)
  end
end

---Clear all unified diff extmarks from a buffer.
---@param bufnr integer Buffer number
---@param ns_id integer Namespace ID
function M.clear(bufnr, ns_id)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

---Highlight an entire line.
---@param bufnr integer Buffer number
---@param ns_id integer Namespace ID
---@param line integer Line number (1-indexed)
---@param hl_group string Highlight group name
function M.highlight_line(bufnr, ns_id, line, hl_group)
  local line_idx = line - 1 -- Convert to 0-indexed

  if line_idx < 0 then return end

  local line_count = api.nvim_buf_line_count(bufnr)
  if line_idx >= line_count then return end

  api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
    end_row = line_idx,
    end_col = 0,
    hl_group = hl_group,
    hl_eol = true,
    priority = 100,
  })
end

---Add virtual lines above a position.
---@param bufnr integer Buffer number
---@param ns_id integer Namespace ID
---@param anchor_line integer Line to anchor above (1-indexed)
---@param lines {content: string, hl_group: string}[] Virtual lines to add
function M.add_virtual_lines(bufnr, ns_id, anchor_line, lines)
  local anchor_idx = anchor_line - 1 -- Convert to 0-indexed

  -- Ensure anchor is valid (use line 0 if anchoring before file start)
  local line_count = api.nvim_buf_line_count(bufnr)
  if anchor_idx < 0 then
    anchor_idx = 0
  elseif anchor_idx > line_count then
    anchor_idx = line_count
  end

  -- Build virt_lines structure
  local virt_lines = {}
  for _, vl in ipairs(lines) do
    -- Each virtual line is a list of {text, hl_group} chunks
    local prefix = "- "
    table.insert(virt_lines, {
      { prefix, "DiffviewUnifiedDelete" },
      { vl.content, vl.hl_group },
    })
  end

  -- Set extmark with virtual lines
  api.nvim_buf_set_extmark(bufnr, ns_id, anchor_idx, 0, {
    virt_lines = virt_lines,
    virt_lines_above = true,
    priority = 100,
  })
end

---Apply word-level diff highlighting to a line.
---@param bufnr integer Buffer number
---@param ns_id integer Namespace ID
---@param line integer Line number (1-indexed)
---@param word_diff unified.WordDiff Word diff data
function M.apply_word_diff(bufnr, ns_id, line, word_diff)
  local line_idx = line - 1

  if line_idx < 0 then return end

  local line_count = api.nvim_buf_line_count(bufnr)
  if line_idx >= line_count then return end

  -- Apply highlights to changed segments in the new line
  local col = 0
  for _, segment in ipairs(word_diff.new_segments) do
    if segment.changed then
      api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, col, {
        end_col = col + #segment.text,
        hl_group = "DiffviewUnifiedWordAdd",
        priority = 150, -- Higher priority than line highlight
      })
    end
    col = col + #segment.text
  end
end

---Render with old lines displayed as virtual text in deleted line display.
---This formats the virtual line with word-level diff highlighting.
---@param old_line string The deleted line
---@param word_diff unified.WordDiff? Optional word diff data
---@return table[] chunks List of {text, hl_group} chunks
function M.format_deleted_line(old_line, word_diff)
  if not word_diff then
    return {
      { "- ", "DiffviewUnifiedDelete" },
      { old_line, "DiffviewUnifiedDelete" },
    }
  end

  -- Build chunks with word-level highlighting
  local chunks = {
    { "- ", "DiffviewUnifiedDelete" },
  }

  for _, segment in ipairs(word_diff.old_segments) do
    local hl = segment.changed and "DiffviewUnifiedWordDelete" or "DiffviewUnifiedDelete"
    table.insert(chunks, { segment.text, hl })
  end

  return chunks
end

return M
