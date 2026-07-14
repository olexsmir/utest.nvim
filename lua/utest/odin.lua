local odin = {}
odin.ft = "odin"

-- source: https://github.com/joseildofilho/neotest-odin/blob/main/lua/neotest-odin/init.lua
odin.query = [[
(procedure_declaration
  (attributes
    (attribute
      (identifier) @_attr (#eq? @_attr "test")))
  (identifier) @test.name) @test.definition
]]

---@param file string
---@return string Unique temp prefix for the test binary and the JSON report
local function get_prefix(file)
  local tmpdir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
  return tmpdir .. "/utest-odin-" .. vim.fn.sha256(file):sub(1, 8)
end

---@param file string
---@param names string[] Test names to run, empty runs the whole package
---@return string[]
local function build_command(file, names)
  local prefix = get_prefix(file)
  vim.fn.delete(prefix .. ".json")
  local cmd = {
    "odin",
    "test",
    ".",
    "-error-pos-style:unix",
    "-define:ODIN_TEST_FANCY=false",
    "-define:ODIN_TEST_GO_TO_ERROR=true",
    "-out:" .. prefix,
    "-define:ODIN_TEST_JSON_REPORT=" .. prefix .. ".json",
  }
  if #names > 0 then table.insert(cmd, "-define:ODIN_TEST_NAMES=" .. table.concat(names, ",")) end
  return cmd
end

---@param _name string
---@return boolean
function odin.is_subtest(_name) return false end

---@param file string
---@return string
function odin.get_cwd(file) return vim.fn.fnamemodify(file, ":h") end

---@param file string
---@return string[]
function odin.test_file_command(file) return build_command(file, {}) end

---@param test utest.Test Test info with name, parent, is_subtest fields
---@param file string File path
---@return string[] Command arguments
function odin.test_command(test, file) return build_command(file, { test.name }) end

---@param _output string[] output lines, unused: the JSON report is the source of truth
---@param file string
---@return utest.AdapterTestResult[]
function odin.parse_output(_output, file)
  local prefix = get_prefix(file)
  local results = {}
  local ok, lines = pcall(vim.fn.readfile, prefix .. ".json")
  if ok then
    local report = vim.json.decode(table.concat(lines, "\n"))
    if type(report) == "table" then
      for _, tests in pairs(report.packages) do
        for _, t in ipairs(tests) do
          table.insert(results, {
            name = t.name,
            status = t.success and "success" or "fail",
            output = {},
          })
        end
      end
    end
  end
  vim.fn.delete(prefix .. ".json")
  vim.fn.delete(prefix)
  return results
end

---@param output string[] output lines
---@param _test_name string|nil specific test name to get output for
---@return string[]
function odin.extract_test_output(output, _test_name)
  local result = {}
  for _, line in ipairs(output) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match "^%[INFO %]" then table.insert(result, trimmed) end
  end
  return result
end

---@param output string[]
---@return string|nil
function odin.extract_error_message(output)
  for _, line in ipairs(output) do
    if line:match "%.odin:%d+:%d+:" or line:match "%.odin%(%d+:%d+%):" then
      return vim.trim(line)
    end
  end
  return nil
end

return odin
