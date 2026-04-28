local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("diffview.unified.diff_processor", function()
  local diff_processor = require("diffview.unified.diff_processor")

  describe("compute_hunks()", function()
    it("returns no hunks for identical input", function()
      eq({}, diff_processor.compute_hunks({ "alpha", "beta" }, { "alpha", "beta" }))
    end)

    it("computes additions", function()
      eq({
        {
          old_start = 1,
          old_count = 0,
          new_start = 2,
          new_count = 1,
          old_lines = {},
          new_lines = { "bravo" },
          type = "add",
        },
      }, diff_processor.compute_hunks({ "alpha", "charlie" }, { "alpha", "bravo", "charlie" }))
    end)

    it("computes deletions", function()
      eq({
        {
          old_start = 2,
          old_count = 1,
          new_start = 1,
          new_count = 0,
          old_lines = { "bravo" },
          new_lines = {},
          type = "delete",
        },
      }, diff_processor.compute_hunks({ "alpha", "bravo", "charlie" }, { "alpha", "charlie" }))
    end)

    it("computes changed lines", function()
      eq({
        {
          old_start = 2,
          old_count = 1,
          new_start = 2,
          new_count = 1,
          old_lines = { "bravo" },
          new_lines = { "delta" },
          type = "change",
        },
      }, diff_processor.compute_hunks({ "alpha", "bravo" }, { "alpha", "delta" }))
    end)

    it("handles empty old files", function()
      eq({
        {
          old_start = 0,
          old_count = 0,
          new_start = 1,
          new_count = 1,
          old_lines = {},
          new_lines = { "alpha" },
          type = "add",
        },
      }, diff_processor.compute_hunks({}, { "alpha" }))
    end)
  end)
end)
