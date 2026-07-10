---@class utest.Adapter
---@field ft string
---@field query string
---@field is_subtest fun(name:string):boolean
---@field get_cwd fun(file:string):string
---@field test_file_command fun(file:string):string[]
---@field test_command fun(test:utest.Test, file:string)
---@field parse_output fun(output:string[], file:string):utest.AdapterTestResult
---@field extract_test_output fun(output:string[], test_name:string|nil):string[]
---@field extract_error_message fun(output:string[]):string|nil

---@alias utest.TestStatus "success"|"fail"|"running"|"skipped"

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
---@field status utest.TestStatus
---@field output string[]
---@field error_line number|nil

---@class utest.Job
---@field job_id number
---@field test_id string
---@field file string
---@field name string
---@field line number
---@field start_time number

---@class utest.JobResult
---@field status utest.TestStatus
---@field output string
---@field raw_output? string
---@field timestamp number
---@field file string
---@field error_message? string
---@field name? string
---@field line? number

local test_failed_msg = "[Test failed]"
local H = {
  ---@type table<string, utest.Adapter>
  adapters = {},
  ---@type table<string, vim.treesitter.Query>
  queries = {},

  ---@type table<string, utest.Job>
  jobs = {},

  ---@type table<string, utest.JobResult>
  results = {},

  sns = nil,
  dns = nil,
  extmarks = {},
  diagnostics = {},
}

local utest = {}
utest.config = {
  timeout = 30,
  icons = {
    failed = "",
    running = "",
    skipped = "",
    success = "",
  },
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

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local test = H.find_nearest_test(bufnr, cursor_line, adapter)
  if not test then
    vim.notify("[utest] no near test found", vim.log.levels.INFO)
    return
  end

  H.run_tests({ test }, adapter, bufnr)
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

  H.run_tests(tests, adapter, bufnr)
end

function utest.cancel()
  local cancelled = 0
  for id, info in pairs(H.jobs) do
    pcall(vim.fn.jobstop, id)
    if info.test_ids then
      for _, test_id in ipairs(info.test_ids) do
        local file, line, name = test_id:match "^(.+):(%d+):(.+)$"
        H.results[test_id] = {
          status = "fail",
          output = "",
          error_message = "Test cancelled",
          timestamp = os.time(),
          file = file,
          line = line and tonumber(line) or nil,
          name = name,
        }
      end
    elseif info.test_id then
      H.results[info.test_id] = {
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
  H.jobs = {}

  if cancelled > 0 then
    vim.notify("[utest] cancelled running test(s)", vim.log.levels.INFO)
  else
    vim.notify("[utest] no running tests to cancel", vim.log.levels.INFO)
  end
end

function utest.clear()
  local bufnr = vim.api.nvim_get_current_buf()
  H.clear_file(vim.api.nvim_buf_get_name(bufnr))
  H.signs_clear_buffer(bufnr)
  H.diagnostics_clear_buffer(bufnr)
  H.qf_clear()
end

function utest.qf()
  local qfitems = {}
  for test_id, result in pairs(H.get_failed()) do
    local file, line, name = test_id:match "^(.+):(%d+):(.+)$"
    if file and line then
      local error_text = (result.output ~= nil and result.output ~= "" and result.output)
        or result.error_message
        or test_failed_msg
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

-- HELPERS ====================================================================

function H.make_test_id(file, line, name) return string.format("%s:%d:%s", file, line, name) end

function H.clear_file(file)
  for id, _ in pairs(H.results) do
    if id:match("^" .. vim.pesc(file) .. ":") then H.results[id] = nil end
  end
end

function H.get_failed()
  local f = {}
  for id, r in pairs(H.results) do
    if r.status == "fail" then f[id] = r end
  end
  return f
end

function H.qf_clear()
  local qf = vim.fn.getqflist { title = 1 }
  if qf.title == "utest: failed tests" then vim.fn.setqflist({}, "r") end
end

-- SIGNS

---@type table<utest.TestStatus, string>
local sign_highlights = {
  success = "DiagnosticOk",
  skipped = "DiagnosticInfo",
  fail = "DiagnosticError",
  running = "DiagnosticInfo",
}

---@param bufnr number
---@param line number
---@param status utest.TestStatus
---@param test_id string
function H.sign_place(bufnr, line, status, test_id)
  if not H.extmarks[bufnr] then H.extmarks[bufnr] = {} end

  local existing_id = H.extmarks[bufnr][test_id]
  if existing_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, H.sns, existing_id)
    H.extmarks[bufnr][test_id] = nil
  end

  -- FIXME: might fail if status is invalid
  local icon = utest.config.icons[status]
  local hl = sign_highlights[status]

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
function H.diagnostics_set(bufnr, line, message)
  if not H.diagnostics[bufnr] then H.diagnostics[bufnr] = {} end
  H.diagnostics[bufnr][line] = {
    lnum = line,
    col = 0,
    severity = vim.diagnostic.severity.ERROR,
    source = "utest",
    message = message or test_failed_msg,
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

---@param tests utest.Test[]
---@param adapter utest.Adapter
---@param bufnr number
function H.run_tests(tests, adapter, bufnr)
  local is_single = #tests == 1
  local test = tests[1]
  local file = test.file
  local cmd = is_single and adapter.test_command(test, file) or adapter.test_file_command(file)
  local cwd = adapter.get_cwd(file)
  local output_lines = {}
  local timed_out = false

  -- Build test lookup table and mark all as running
  local test_map = {}
  local tid_list = {}
  for _, t in ipairs(tests) do
    local tid = H.make_test_id(t.file, t.line, t.name)
    test_map[tid] = t
    tid_list[#tid_list + 1] = tid
    H.results[tid] = { status = "running", output = "", timestamp = os.time(), file = t.file }
    H.sign_place(bufnr, t.line, "running", tid)
  end

  local job_id, timeout_timer

  local function cleanup()
    if timeout_timer then
      timeout_timer:stop()
      timeout_timer:close()
    end
    if job_id and H.jobs[job_id] then H.jobs[job_id] = nil end
  end

  local function on_exit(_, exit_code)
    if timed_out then return end
    cleanup()

    local full_output = table.concat(output_lines, "\n")
    local parsed = adapter.parse_output(output_lines, file)

    -- Build name → result map for fast lookup
    local result_map = {}
    for _, r in ipairs(parsed) do
      result_map[r.name] = r
    end

    for tid, t in pairs(test_map) do
      local search_name = t.name
      if t.is_subtest and t.parent then search_name = t.parent .. "/" .. t.name:gsub(" ", "_") end
      local tr = result_map[search_name] or result_map[t.name]

      local status
      if tr then
        status = tr.status
      else
        status = exit_code == 0 and "success" or "fail"
      end
      if status ~= "success" and status ~= "fail" and status ~= "skipped" then
        status = exit_code == 0 and "success" or "fail"
      end

      local test_output = adapter.extract_test_output(output_lines, search_name)
      H.results[tid] = {
        status = status,
        output = table.concat(test_output, "\n"),
        raw_output = full_output,
        error_message = status == "fail" and adapter.extract_error_message(output_lines) or nil,
        timestamp = os.time(),
        file = t.file,
        line = t.line,
        name = t.name,
      }
    end

    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      for tid, t in pairs(test_map) do
        local r = H.results[tid]
        local s = r.status
        H.sign_place(bufnr, t.line, s, tid)
        if s == "fail" then
          local d = vim.diagnostic.get(bufnr, { namespace = H.dns, lnum = t.line })
          if #d == 0 then
            H.diagnostics_set(
              bufnr,
              t.line,
              r.output ~= nil and r.output ~= "" and r.output or r.error_message or test_failed_msg
            )
          end
        else
          H.diagnostics_clear(bufnr, t.line)
        end
      end
    end)
  end

  job_id = vim.fn.jobstart(cmd, {
    cwd = cwd,
    on_stdout = function(_, data, _)
      if data then
        for _, l in ipairs(data) do
          if l ~= "" then table.insert(output_lines, l) end
        end
      end
    end,
    on_stderr = function(_, data, _)
      if data then
        for _, l in ipairs(data) do
          if l ~= "" then table.insert(output_lines, l) end
        end
      end
    end,
    on_exit = on_exit,
    stdout_buffered = true,
    stderr_buffered = true,
  })

  if job_id < 0 then
    vim.notify("[utest] failed to start tests", vim.log.levels.ERROR)
    return
  end

  H.jobs[job_id] = {
    job_id = job_id,
    test_ids = tid_list,
    file = file,
    start_time = os.time(),
    output = output_lines,
  }

  timeout_timer = vim.uv.new_timer()

  -- stylua: ignore
  timeout_timer:start(utest.config.timeout * 1000, 0, vim.schedule_wrap(function() ---@diagnostic disable-line: need-check-nil
    if not H.jobs[job_id] then return end
    timed_out = true
    vim.fn.jobstop(job_id)
    for tid, t in pairs(test_map) do
      H.results[tid] = {
        status = "fail",
        output = table.concat(output_lines, "\n"),
        error_message = "Test timed out after " .. utest.config.timeout .. "s",
        timestamp = os.time(), file = t.file, line = t.line, name = t.name,
      }
      H.sign_place(bufnr, t.line, "fail", tid)
      H.diagnostics_set(bufnr, t.line, "Test timed out")
    end
    H.jobs[job_id] = nil
  end))  -- stylua: ignore
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

---@param bufnr number
---@param adapter utest.Adapter
---@return utest.Test[]
function H.find_tests(bufnr, adapter)
  local query = H.get_query(adapter.ft, adapter.query)
  if not query then
    vim.notify("[utest] failed to run " .. adapter.ft .. " adapter query", vim.log.levels.ERROR)
    return {}
  end

  local pok, parser = pcall(vim.treesitter.get_parser, bufnr, adapter.ft)
  if not pok or not parser then
    vim.notify("[utest] failed to get treesitter parser", vim.log.levels.ERROR)
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then return {} end

  local file = vim.api.nvim_buf_get_name(bufnr)
  local root = tree:root()
  local tests = {}

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
      local start_row, start_col, end_row, end_col = test_def:range()
      table.insert(tests, {
        name = test_name,
        file = file,
        line = start_row,
        col = start_col,
        end_line = end_row,
        end_col = end_col,
        is_subtest = adapter.is_subtest(test_name),
        parent = nil,
      })
    end
  end

  -- Deduplicate: when multiple query patterns match overlapping AST regions
  -- (e.g. function_declaration + table test entry), keep the narrower match
  table.sort(tests, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return (a.end_line - a.line) < (b.end_line - b.line)
  end)

  local seen = {}
  local deduped = {}
  for _, test in ipairs(tests) do
    local key = test.line .. ":" .. test.name
    if not seen[key] then
      seen[key] = true
      table.insert(deduped, test)
    end
  end
  tests = deduped

  -- Resolve parent relationships for subtests (including nested subtests)
  -- Uses line ranges to determine proper parent hierarchy
  table.sort(tests, function(a, b) return a.line < b.line end)

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
        if innermost_parent.parent then -- TODO: too go dependent
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
