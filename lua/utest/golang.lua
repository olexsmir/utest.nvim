local golang = {}
golang.ft = "go"
golang.query = [[
; func TestXxx(t *testing.T)
((function_declaration
  name: (identifier) @test.name)
  (#match? @test.name "^Test")
  (#not-match? @test.name "^TestMain$")) @test.definition

; t.Run("subtest name", func(t *testing.T) {...})
(call_expression
  function: (selector_expression
    operand: (identifier) @_operand
    (#match? @_operand "^(t|s|suite)$")
    field: (field_identifier) @_method)
  (#match? @_method "^Run$")
  arguments: (argument_list . (interpreted_string_literal) @test.name)) @test.definition

; ============================================================================
; Table-driven tests with named slice variable and keyed fields
; Detects table tests with struct fields using keys (e.g., {name: "test1"}).
; Pattern:
;   tt := []struct{ name string }{
;     {name: "test1"},  // @test.name = "test1"
;     {name: "test2"},  // @test.name = "test2"
;   }
;   for _, tc := range tt {
;     t.Run(tc.name, func(t *testing.T) { ... })
;   }
(block
  (statement_list
    (short_var_declaration
      left: (expression_list (identifier) @test.cases)
      right: (expression_list
        (composite_literal
          (literal_value
            (literal_element
              (literal_value
                (keyed_element
                  (literal_element (identifier) @test.field.name)
                  (literal_element (interpreted_string_literal) @test.name)))) @test.definition))))
    (for_statement
      (range_clause
        left: (expression_list (identifier) @test.case)
        right: (identifier) @test.cases1
        (#eq? @test.cases @test.cases1))
      body: (block
        (statement_list
          (expression_statement
            (call_expression
              function: (selector_expression
                operand: (identifier) @test.operand
                (#match? @test.operand "^[t]$")
                field: (field_identifier) @test.method
                (#match? @test.method "^Run$"))
              arguments: (argument_list
                (selector_expression
                  operand: (identifier) @test.case1
                  (#eq? @test.case @test.case1)
                  field: (field_identifier) @test.field.name1
                  (#eq? @test.field.name @test.field.name1))))))))))

; ============================================================================
; Map-based table-driven tests
; Detects table tests where test cases are defined in a map with string keys.
; Pattern:
;   testCases := map[string]struct{ want int }{
;     "test1": {want: 1},  // @test.name = "test1"
;     "test2": {want: 2},  // @test.name = "test2"
;   }
;   for name, tc := range testCases {
;     t.Run(name, func(t *testing.T) { ... })
;   }
(block
  (statement_list
    (short_var_declaration
      left: (expression_list (identifier) @test.cases)
      right: (expression_list
        (composite_literal
          (literal_value
            (keyed_element
              (literal_element (interpreted_string_literal) @test.name)
              (literal_element (literal_value) @test.definition))))))
    (for_statement
      (range_clause
        left: (expression_list
          (identifier) @test.key.name
          (identifier) @test.case)
        right: (identifier) @test.cases1
        (#eq? @test.cases @test.cases1))
      body: (block
        (statement_list
          (expression_statement
            (call_expression
              function: (selector_expression
                operand: (identifier) @test.operand
                (#match? @test.operand "^[t]$")
                field: (field_identifier) @test.method
                (#match? @test.method "^Run$"))
              arguments: (argument_list
                ((identifier) @test.key.name1
                  (#eq? @test.key.name @test.key.name1))))))))))
]]

---@param name string
---@return boolean
function golang.is_subtest(name)
  return not name:match "^Test"
end

---@param file string
---@return string
function golang.get_cwd(file)
  return vim.fn.fnamemodify(file, ":h")
end

---@param file string
---@return string[]
function golang.test_file_command(file)
  local pkg_dir = golang.get_cwd(file)
  return { "go", "test", "-vet=off", "-json", "-v", "-count=1", pkg_dir }
end

---@param test table Test info with name, parent, is_subtest fields
---@param file string File path
---@return string[] Command arguments
function golang.test_command(test, file)
  local pkg_dir = golang.get_cwd(file)
  local run_pattern = ""
  if test.is_subtest and test.parent then
    run_pattern = "^"
      .. vim.fn.escape(test.parent, "[](){}.*+?^$\\")
      .. "/"
      .. vim.fn.escape(test.name:gsub(" ", "_"), "[](){}.*+?^$\\")
      .. "$"
  else
    run_pattern = "^" .. vim.fn.escape(test.name, "[](){}.*+?^$\\") .. "$"
  end

  return { "go", "test", "-vet=off", "-json", "-v", "-count=1", "-run", run_pattern, pkg_dir }
end

function golang.parse_output(output, file)
  local results = {}
  local file_basename = vim.fn.fnamemodify(file, ":t")
  local test_outputs = {} ---@type table<string, string[]>
  local test_status = {} ---@type table<string, utest.TestStatus>
  for _, line in ipairs(output) do
    if line == "" then goto continue end

    local ok, event = pcall(vim.json.decode, line)
    if not ok or not event then goto continue end

    local test_name = event.Test
    if not test_name then goto continue end

    if event.Action == "run" then
      test_outputs[test_name] = test_outputs[test_name] or {}
    elseif event.Action == "output" then
      test_outputs[test_name] = test_outputs[test_name] or {}
      if event.Output then
        local output_line = (event.Output:gsub("\n$", ""))
        table.insert(test_outputs[test_name], output_line)
      end
    elseif event.Action == "pass" then
      test_status[test_name] = "success"
    elseif event.Action == "skip" then
      test_status[test_name] = "skipped"
    elseif event.Action == "fail" then
      test_status[test_name] = "fail"
    end

    ::continue::
  end

  -- build results
  for name, status in pairs(test_status) do
    local output_lines = test_outputs[name] or {}
    local error_line = nil
    if status == "fail" then
      for _, out_line in ipairs(output_lines) do
        local line_num = out_line:match(file_basename .. ":(%d+):")
        if line_num then
          error_line = tonumber(line_num)
          break
        end
      end
    end

    table.insert(results, {
      name = name,
      status = status,
      output = output_lines,
      error_line = error_line,
    })
  end

  return results
end

---@param output string[] output lines, json format
---@param test_name string|nil specific test name to get output for
---@return string[]
function golang.extract_test_output(output, test_name)
  local result = {}
  for _, line in ipairs(output) do
    local ok, event = pcall(vim.json.decode, line)
    if ok and event and event.Action == "output" and event.Output then
      local trimmed = vim.trim(event.Output)
      if trimmed ~= "" then
        if test_name then
          if (event.Test or "") == test_name then table.insert(result, trimmed) end
        else
          table.insert(result, trimmed)
        end
      end
    end
  end
  return result
end

---@param output string[]
---@return string|nil
function golang.extract_error_message(output)
  for _, line in ipairs(output) do
    if line:match "%.go:%d+:" then return vim.trim(line) end
  end
  return nil
end

return golang
