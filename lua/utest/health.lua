---@param parser string
local function check_treesitter(parser)
  local ok, p = pcall(vim.treesitter.get_parser, 0, parser)
  if ok and p ~= nil then
    vim.health.ok("`" .. parser .. "` parser is installed")
  else
    vim.health.error("`" .. parser .. "` parser not found")
  end
end

---@param bin string
local function check_binary(bin)
  if vim.fn.executable(bin) == 1 then
    vim.health.ok(bin .. " is found oh PATH: `" .. vim.fn.exepath(bin) .. "`")
  else
    vim.health.error(bin .. " not found on PATH")
  end
end

local health = {}
function health.check()
  vim.health.start "Go adapter"
  check_treesitter "go"
  check_binary "go"
end

return health
