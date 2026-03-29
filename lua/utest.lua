---@class utest.Adapter
---@field ft string
---@field query string
---@field get_package_dir fun(file:string):string
---@field build_file_command fun(file:string):string[]
---@field build_command fun(test:table, file:string) -- FIXME: `table`
---@field parse_output fun(output:string[], file:string):utest.AdapterTestResult
---@field extract_test_output fun(output:string[], test_name:string|nil):string[]
---@field extract_error_message fun(output:string[]):string|nil

---@alias utest.TestStatus "pass"|"fail"|"running"

---@class utest.Test
---@field name string
---@field file string
---@field line number
---@field end_line number
---@field col number
---@field end_col number
---@field is_subtest boolean
---@field parent string|nil

---@class utest.AdapterTestResult
---@field name string
---@field status "pass"|"fail"
---@field output string[]
---@field error_line number|nil

local S = { jobs = {}, results = {} }
local H = {
  ---@type table<string, utest.Adapter>
  adapters = {},
  ---@type table<string, vim.treesitter.Query>
  queries = {},

  sns = nil,
  dns = nil,
  extmarks = {},
  diagnostics = {},
}

local utest = {}
utest.config = {
  icons = { success = "", failed = "", running = "" }, -- TODO: add skipped
  timeout = 30,
}

function utest.setup(opts)
  utest.config = vim.tbl_deep_extend("keep", utest.config, opts)

  H.sns = vim.api.nvim_create_namespace "utest_signs"
  H.dns = vim.api.nvim_create_namespace "utest_diagnostics"
  H.adapters.go = require "utest.golang"
end

function utest.run()
  local bufnr = vim.api.nvim_get_current_buf()
  local adapter = H.adapters[vim.bo[bufnr].filetype]
  if not adapter then
    vim.notify("[utest] no adapter for this filetype", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1] - 1

  local test = H.find_nearest_test(bufnr, cursor_line, adapter)
  if not test then
    vim.notify("[utest] no near test found", vim.log.levels.INFO)
    return
  end

  H.execute_test(test, adapter, bufnr)
end

function utest.run_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local adapter = H.adapters[vim.bo[bufnr].filetype]
  if not adapter then
    vim.notify("[utest] no adapter for this filetype", vim.log.levels.WARN)
    return
  end

  local tests = H.find_tests(bufnr, adapter)
  if #tests == 0 then
    vim.notify("[utest] no tests found in file", vim.log.levels.INFO)
    return
  end

  for _, test in ipairs(tests) do
    H.execute_test(test, adapter, bufnr)
  end
end

function utest.cancel()
  local cancelled = 0
  for id, info in pairs(S.jobs) do
    pcall(vim.fn.jobstop, id)
    if info.test_id then
      S.results[info.test_id] = {
        status = "fail",
        output = "",
        error_message = "Test cancelled",
        timestamp = os.time(),
        file = info.file,
        line = info.line,
        name = info.name,
      }
    end
    cancelled = cancelled + 1
  end
  S.jobs = {}

  if cancelled > 0 then
    vim.notify("[utest] cancelled running test(s)", vim.log.levels.INFO)
  else
    vim.notify("[utest] no running tests to cancel", vim.log.levels.INFO)
  end
end

function utest.clear()
  local bufnr = vim.api.nvim_get_current_buf()
  S.clear_file(vim.api.nvim_buf_get_name(bufnr))
  H.signs_clear_buffer(bufnr)
  H.diagnostics_clear_buffer(bufnr)
  H.qf_clear()
end

function utest.qf()
  local qfitems = {}
  for test_id, result in pairs(S.get_failed()) do
    local file, line, name = test_id:match "^(.+):(%d+):(.+)$"
    if file and line then
      local error_text = result.test_output or result.error_message or "[Test failed]"
      local lines = vim.split(error_text, "\n", { plain = true })
      for i, lcontent in ipairs(lines) do
        lcontent = vim.trim(lcontent)
        if lcontent ~= "" then
          local text = (i == 1) and (name .. ": " .. lcontent) or ("  " .. lcontent)
          table.insert(qfitems, {
            filename = file,
            lnum = tonumber(line) + 1,
            col = 1,
            text = text,
            type = "E",
          })
        end
      end
    end
  end

  if #qfitems == 0 then
    vim.notify("[utest] No failed tests", vim.log.levels.INFO)
    return
  end

  vim.fn.setqflist({}, "r", { title = "utest: failed tests", items = qfitems })
end

-- STATE ======================================================================

function S.make_test_id(file, line, name)
  return string.format("%s:%d:%s", file, line, name)
end

function S.clear_file(file)
  for id, _ in pairs(S.results) do
    if id:match("^" .. vim.pesc(file) .. ":") then S.results[id] = nil end
  end
end

function S.get_failed()
  local f = {}
  for id, r in pairs(S.results) do
    if r.status == "fail" then f[id] = r end
  end
  return f
end

-- HELPERS ====================================================================

function H.qf_clear()
  local qf = vim.fn.getqflist { title = 1 }
  if qf.title == "utest: failed tests" then vim.fn.setqflist({}, "r") end
end

-- SIGNS

local sign_highlights = {
  pass = "DiagnosticOk",
  fail = "DiagnosticError",
  running = "DiagnosticInfo",
}

---@param bufnr number
---@param line number
---@param status utest.TestStatus
---@param test_id string
function H.sign_place(bufnr, line, status, test_id)
  local icon = utest.config.icons.success
  if status == "fail" then
    icon = utest.config.icons.failed
  elseif status == "running" then
    icon = utest.config.icons.running
  end

  if not H.extmarks[bufnr] then H.extmarks[bufnr] = {} end

  local existing_id = H.extmarks[bufnr][test_id]
  if existing_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, H.sns, existing_id)
    H.extmarks[bufnr][test_id] = nil
  end

  local hl = sign_highlights[status] -- FIXME: might fail if status is invalid
  local ok, res = pcall(vim.api.nvim_buf_set_extmark, bufnr, H.sns, line, 0, {
    priority = 1000,
    sign_text = icon,
    sign_hl_group = hl,
  })
  if ok and test_id then H.extmarks[bufnr][test_id] = res end
end

--- get current line of a sign y test_id
---@param bufnr number
---@param test_id string
function H.sign_get_current_line(bufnr, test_id)
  if not H.extmarks[bufnr] or not H.extmarks[bufnr][test_id] then return nil end
  local ok, mark =
      pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, H.sns, H.extmarks[bufnr][test_id], {})
  if ok and mark and #mark >= 1 then return mark[1] end
  return nil
end

---@param bufnr number
function H.signs_clear_buffer(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, H.sns, 0, -1)
  H.extmarks[bufnr] = nil
end

--- clears all utest diagnostics in a buffer
---@param bufnr number
function H.diagnostics_clear_buffer(bufnr)
  H.diagnostics[bufnr] = nil
  vim.diagnostic.reset(H.dns, bufnr)
end

--- clear diagnostic at a specific line
---@param bufnr number
---@param line number 0-indexed line number
function H.diagnostics_clear(bufnr, line)
  if H.diagnostics[bufnr] then
    H.diagnostics[bufnr][line] = nil
    H.diagnostics_refresh(bufnr)
  end
end

--- set diagnostic at a line
---@param bufnr number
---@param line number 0-indexed line number
---@param message string|nil
---@param output string[]|nil Full output lines
function H.diagnostics_set(bufnr, line, message, output)
  if not H.diagnostics[bufnr] then H.diagnostics[bufnr] = {} end
  local msg = message or "[Test failed]"
  if output and #output > 0 then
    local readable_lines = {}
    for _, out_line in ipairs(output) do
      --  TODO: this should be in utest.golang, only support plain text
      local trimmed = vim.trim(out_line)
      if trimmed ~= "" then table.insert(readable_lines, trimmed) end
    end

    if #readable_lines > 0 then
      local output_text = table.concat(readable_lines, "\n")
      if output_text ~= "" then msg = msg .. "\n" .. output_text end
    end
  end

  H.diagnostics[bufnr][line] = {
    lnum = line,
    col = 0,
    severity = vim.diagnostic.severity.ERROR,
    source = "utest",
    message = msg,
  }
  H.diagnostics_refresh(bufnr)
end

--- refresh diagnostics for a buffer
---@param bufnr number
function H.diagnostics_refresh(bufnr)
  local diags = {}
  if H.diagnostics[bufnr] then
    for _, diag in pairs(H.diagnostics[bufnr]) do
      table.insert(diags, diag)
    end
  end
  vim.diagnostic.set(H.dns, bufnr, diags)
end

-- RUNNER

-- TODO: refactor
---@param test unknown TODO: fix type
---@param adapter utest.Adapter
---@param bufnr number
function H.execute_test(test, adapter, bufnr)
  local cmd = adapter.build_command(test, test.file)
  local test_id = S.make_test_id(test.file, test.line, test.name)
  local output_lines = {}
  local timed_out = false

  S.results[test_id] = {
    status = "running",
    output = "",
    timestamp = os.time(),
  }
  H.sign_place(bufnr, test.line, "running", test_id)

  local timeout_timer, job_id = nil, nil
  local function cleanup()
    if timeout_timer then
      timeout_timer:stop()
      timeout_timer:close()
      timeout_timer = nil
    end
    if job_id and S.jobs[job_id] then S.jobs[job_id] = nil end
  end

  local function on_output(_, data, _)
    if data then
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(output_lines, line) end
      end
    end
  end

  local function on_exit(_, exit_code)
    if timed_out then return end
    cleanup()

    local full_output = table.concat(output_lines, "\n")
    local results = adapter.parse_output(output_lines, test.file)

    -- find result for ths specific test
    local test_result = nil
    local search_name = test.name
    if test.is_subtest and test.parent then
      search_name = test.parent .. "/" .. test.name:gsub(" ", "_")
    end
    for _, r in ipairs(results) do
      if r.name == search_name or r.name == test.name then
        test_result = r
        break
      end
    end

    -- fallback: use exit code if no specific result found
    if not test_result then
      test_result = {
        name = test.name,
        status = exit_code == 0 and "pass" or "fail",
        output = output_lines,
        error_line = nil,
      }
    end

    -- ensure status validity
    local final_status = test_result.status
    if final_status ~= "pass" and final_status ~= "fail" then
      final_status = exit_code == 0 and "pass" or "fail"
    end
    test_result.status = final_status

    -- get human redabble output
    local test_output = {}
    if adapter.extract_test_output then
      test_output = adapter.extract_test_output(output_lines, search_name)
    end

    S.results[test_id] = {
      status = test_result.status,
      output = full_output,
      test_output = table.concat(test_output, "\n"),
      error_message = test_result.status == "fail" and adapter.extract_error_message(output_lines)
          or nil,
      timestamp = os.time(),
      file = test.file,
      line = test.line,
      name = test.name,
    }

    -- update ui
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      H.sign_place(bufnr, test.line, test_result.status, test_id)
      if test_result.status == "fail" then
        -- Only set diagnostic if there's no diagnostic already at this line
        -- This prevents multiple diagnostics when parent/child tests both fail
        local existing = vim.diagnostic.get(bufnr, { namespace = H.dns, lnum = test.line })
        if #existing == 0 then
          H.diagnostics_set(
            bufnr,
            test.line,
            S.results[test_id].test_output or S.results[test_id].error_message or "[Test failed]",
            test_output
          )
        end
      else
        H.diagnostics_clear(bufnr, test.line)
      end
    end)
  end

  job_id = vim.fn.jobstart(cmd, {
    cwd = adapter.get_package_dir(test.file),
    on_stdout = on_output,
    on_stderr = on_output,
    on_exit = on_exit,
    stdout_buffered = true,
    stderr_buffered = true,
  })

  if job_id < 0 then
    vim.notify("[utest] failed to start test: " .. test.name, vim.log.levels.ERROR)
    cleanup()
    return
  end

  S.jobs[job_id] = {
    job_id = job_id,
    test_id = test_id,
    file = test.file,
    line = test.line,
    name = test.name,
    start_time = os.time(),
    output = output_lines,
  }

  local timeout = utest.config.timeout * 1000
  timeout_timer = vim.uv.new_timer()

  -- stylua: ignore
  timeout_timer:start(timeout, 0, vim.schedule_wrap(function() ---@diagnostic disable-line: need-check-nil
    if S.jobs[job_id] then
      timed_out = true
      vim.fn.jobstop(job_id)
      S.results[test_id] = {
        status = "fail",
        output = table.concat(output_lines, "\n"),
        error_message = "Test timed out after " .. utest.config.timeout .. "s",
        timestamp = os.time(),
        file = test.file,
        line = test.line,
        name = test.name,
      }
      H.sign_place(bufnr, test.line, "fail", test_id)
      H.diagnostics_set(bufnr, test.line, "Test timed out", output_lines)
      cleanup()
    end
  end))
end

-- TREESITTER PARSER

---@param lang string
---@param query string
---@return vim.treesitter.Query|nil
function H.get_query(lang, query)
  if H.queries[lang] then return H.queries[lang] end

  local ok, q = pcall(vim.treesitter.query.parse, lang, query)
  if not ok then return nil end

  H.queries[lang] = q
  return q
end

-- TODO: refactor
---@param bufnr number
---@param adapter utest.Adapter
---@return utest.Test[]
function H.find_tests(bufnr, adapter)
  local query = H.get_query(adapter.ft, adapter.query)
  if not query then return {} end -- TODO: show error

  local pok, parser = pcall(vim.treesitter.get_parser, bufnr, adapter.ft)
  if not pok or not parser then return {} end -- TODO: show error

  local tree = parser:parse()[1]
  if not tree then return {} end

  local file = vim.api.nvim_buf_get_name(bufnr)
  local root = tree:root()
  local tests = {}

  -- TODO: this is probably overly complicated
  for _, match, _ in query:iter_matches(root, bufnr, 0, -1) do
    local test_name, test_def = nil, nil
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      if not name then goto continue_match end

      local node = type(nodes) == "table" and nodes[1] or nodes
      if name == "test.name" then
        test_name = vim.treesitter.get_node_text(node, bufnr)
        test_name = test_name:gsub('^"', ""):gsub('"$', "")
      elseif name == "test.definition" then
        test_def = node
      end

      ::continue_match::
    end

    if test_name and test_def then
      -- TODO: it's knows about go too much
      local start_row, start_col, end_row, end_col = test_def:range()
      local is_subtest = not test_name:match "^Test" and not test_name:match "^Example"
      table.insert(tests, {
        name = test_name,
        file = file,
        line = start_row,
        col = start_col,
        end_line = end_row,
        end_col = end_col,
        is_subtest = is_subtest,
        parent = nil,
      })
    end
  end

  -- Resolve parent relationships for subtests (including nested subtests)
  -- Uses line ranges to determine proper parent hierarchy
  table.sort(tests, function(a, b)
    return a.line < b.line
  end)

  -- Build parent hierarchy by checking which tests contain others based on line ranges
  -- Treesitter uses half-open intervals [start, end), so we use <= for start and < for end
  for i, test in ipairs(tests) do
    if test.is_subtest then
      local innermost_parent = nil
      local innermost_parent_line = -1

      for j, potential_parent in ipairs(tests) do
        if i ~= j then
          -- Check if potential_parent contains this test using line ranges
          if potential_parent.line <= test.line and test.line < potential_parent.end_line then
            -- Found a containing test, check if it's the innermost one
            if potential_parent.line > innermost_parent_line then
              innermost_parent = potential_parent
              innermost_parent_line = potential_parent.line
            end
          end
        end
      end

      if innermost_parent then
        -- Build full parent path for nested subtests
        if innermost_parent.parent then
          test.parent = innermost_parent.parent .. "/" .. innermost_parent.name
        else
          test.parent = innermost_parent.name
        end
      end
    end
  end

  return tests
end

---@param bufnr number
---@param cursor_line number
---@param adapter utest.Adapter
---@return utest.Test|nil
function H.find_nearest_test(bufnr, cursor_line, adapter)
  local tests = H.find_tests(bufnr, adapter)
  if #tests == 0 then return nil end

  local nearest = nil
  local nearest_distance = math.huge
  for _, test in ipairs(tests) do
    if cursor_line >= test.line and cursor_line <= test.end_line then
      -- prefer the innermost test (subtest)
      if not nearest or test.line > nearest.line then nearest = test end
    elseif cursor_line >= test.line then
      local distance = cursor_line - test.line
      if distance < nearest_distance then
        nearest = test
        nearest_distance = distance
      end
    end
  end
  return nearest
end

return utest
