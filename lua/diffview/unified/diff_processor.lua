--[[
  Unified Diff Processor

  Processes diff output into structured hunks for unified view rendering.
  Uses vim.diff() for line-level diffing and the Diff class for word-level diffs.
]]

local lazy = require("diffview.lazy")
local Diff = lazy.access("diffview.diff", "Diff") ---@type Diff|LazyModule
local EditToken = lazy.access("diffview.diff", "EditToken") ---@type EditToken|LazyModule

local M = {}

---@class unified.Hunk
---@field old_start integer Line number in old file (1-indexed)
---@field old_count integer Number of lines in old
---@field new_start integer Line number in new file (1-indexed)
---@field new_count integer Number of lines in new
---@field old_lines string[] Deleted lines content
---@field new_lines string[] Added lines content
---@field type "add"|"delete"|"change"

---@class unified.WordDiff
---@field old_segments {text: string, changed: boolean}[]
---@field new_segments {text: string, changed: boolean}[]

---Parse unified diff output from vim.diff() into structured hunks.
---@param old_lines string[] Lines from the old file
---@param new_lines string[] Lines from the new file
---@return unified.Hunk[]
function M.compute_hunks(old_lines, new_lines)
  -- Handle empty files properly
  local old_text = #old_lines > 0 and (table.concat(old_lines, "\n") .. "\n") or ""
  local new_text = #new_lines > 0 and (table.concat(new_lines, "\n") .. "\n") or ""

  -- Use vim.diff to get indices format output
  local diff_result = vim.diff(old_text, new_text, { result_type = "indices" })

  local hunks = {}

  for _, hunk_data in ipairs(diff_result) do
    local old_start, old_count, new_start, new_count = unpack(hunk_data)

    -- Extract the actual line content
    local old_hunk_lines = {}
    local new_hunk_lines = {}

    for i = old_start, old_start + old_count - 1 do
      table.insert(old_hunk_lines, old_lines[i] or "")
    end

    for i = new_start, new_start + new_count - 1 do
      table.insert(new_hunk_lines, new_lines[i] or "")
    end

    -- Determine hunk type
    local hunk_type
    if old_count == 0 then
      hunk_type = "add"
    elseif new_count == 0 then
      hunk_type = "delete"
    else
      hunk_type = "change"
    end

    table.insert(hunks, {
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      old_lines = old_hunk_lines,
      new_lines = new_hunk_lines,
      type = hunk_type,
    })
  end

  return hunks
end

---Compute word-level diff between two lines.
---@param old_line string
---@param new_line string
---@return unified.WordDiff
function M.compute_word_diff(old_line, new_line)
  -- Split lines into words (preserving whitespace as separate tokens)
  local old_tokens = M.tokenize(old_line)
  local new_tokens = M.tokenize(new_line)

  local diff = Diff.__get()(old_tokens, new_tokens)
  local script = diff:create_edit_script()

  local old_segments = {}
  local new_segments = {}

  local old_idx = 1
  local new_idx = 1

  for _, token in ipairs(script) do
    local et = EditToken.__get()

    if token == et.NOOP then
      -- Both tokens are the same
      table.insert(old_segments, { text = old_tokens[old_idx], changed = false })
      table.insert(new_segments, { text = new_tokens[new_idx], changed = false })
      old_idx = old_idx + 1
      new_idx = new_idx + 1
    elseif token == et.DELETE then
      -- Token was deleted from old
      table.insert(old_segments, { text = old_tokens[old_idx], changed = true })
      old_idx = old_idx + 1
    elseif token == et.INSERT then
      -- Token was inserted in new
      table.insert(new_segments, { text = new_tokens[new_idx], changed = true })
      new_idx = new_idx + 1
    elseif token == et.REPLACE then
      -- Token was replaced
      table.insert(old_segments, { text = old_tokens[old_idx], changed = true })
      table.insert(new_segments, { text = new_tokens[new_idx], changed = true })
      old_idx = old_idx + 1
      new_idx = new_idx + 1
    end
  end

  return {
    old_segments = old_segments,
    new_segments = new_segments,
  }
end

---Tokenize a line into words and whitespace for word-level diffing.
---@param line string
---@return string[]
function M.tokenize(line)
  local tokens = {}
  local current = ""
  local in_whitespace = false

  for i = 1, #line do
    local char = line:sub(i, i)
    local is_ws = char:match("%s") ~= nil

    if is_ws ~= in_whitespace then
      if #current > 0 then
        table.insert(tokens, current)
      end
      current = char
      in_whitespace = is_ws
    else
      current = current .. char
    end
  end

  if #current > 0 then
    table.insert(tokens, current)
  end

  return tokens
end

---Convert hunks to render instructions for unified view.
---Returns a list of instructions for where to place virtual lines and highlights.
---@param hunks unified.Hunk[]
---@return table[] render_instructions
function M.hunks_to_render_instructions(hunks)
  local instructions = {}

  for _, hunk in ipairs(hunks) do
    if hunk.type == "add" then
      -- Pure additions: highlight the added lines in the buffer
      for i = 1, hunk.new_count do
        table.insert(instructions, {
          type = "highlight_line",
          line = hunk.new_start + i - 1,
          hl_group = "DiffviewUnifiedAdd",
        })
      end
    elseif hunk.type == "delete" then
      -- Pure deletions: show as virtual lines above
      -- Virtual lines appear above the line that follows the deletion
      local anchor_line = hunk.new_start
      for i, deleted_line in ipairs(hunk.old_lines) do
        table.insert(instructions, {
          type = "virtual_line",
          anchor_line = anchor_line,
          content = deleted_line,
          hl_group = "DiffviewUnifiedDelete",
          is_first = i == 1,
        })
      end
    elseif hunk.type == "change" then
      -- Changes: show old lines as virtual, highlight new lines
      -- Also compute word-level diff for 1:1 changes
      local anchor_line = hunk.new_start

      -- Show deleted lines as virtual text
      for i, deleted_line in ipairs(hunk.old_lines) do
        table.insert(instructions, {
          type = "virtual_line",
          anchor_line = anchor_line,
          content = deleted_line,
          hl_group = "DiffviewUnifiedDelete",
          is_first = i == 1,
        })
      end

      -- Highlight added lines
      for i = 1, hunk.new_count do
        table.insert(instructions, {
          type = "highlight_line",
          line = hunk.new_start + i - 1,
          hl_group = "DiffviewUnifiedAdd",
        })
      end

      -- If 1:1 change, add word diff info
      if hunk.old_count == 1 and hunk.new_count == 1 then
        local word_diff = M.compute_word_diff(hunk.old_lines[1], hunk.new_lines[1])
        table.insert(instructions, {
          type = "word_diff",
          line = hunk.new_start,
          word_diff = word_diff,
        })
      end
    end
  end

  return instructions
end

return M
