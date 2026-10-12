-- Offline callback/expr integration contract, without loading the user's config.
-- The callback uses the user's neocursor -> snippet_forward -> Tab priority.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
vim.opt.expandtab = false
local nc = require("neocursor")
local root = vim.fn.getcwd()
local failed = 0
local snippets, snippet_calls = false, 0
local function check(name, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  print(
    (ok and "ok " or "FAIL ")
      .. name
      .. (ok and "" or " got=" .. vim.inspect(got) .. " want=" .. vim.inspect(want))
  )
end
local function input(keys) vim.api.nvim_input(keys) end
local function sleep(ms) coroutine.yield(ms) end
local function poll(name, fn)
  for _ = 1, 150 do
    if fn() then
      check(name, true, true)
      return true
    end
    sleep(20)
  end
  check(name, false, true)
  return false
end
local function line(n) return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1] end
local function seed()
  nc.dismiss()
  nc.dismiss()
  vim.api.nvim_buf_set_lines(
    0,
    0,
    -1,
    false,
    { "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5" }
  )
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end
vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.tempname() .. ".py"))
nc.setup({
  map_tab = false,
  normal_mode = true,
  debounce = 100000,
  prefetch = false,
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})
local function callback()
  if nc.accept() then return end
  -- Stand-in for blink.snippet_forward(): the bool contract is all the mapping uses.
  if snippets then
    snippet_calls = snippet_calls + 1
    return
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
end
vim.keymap.set("i", "<Tab>", callback)
local co = coroutine.create(function()
  seed()
  input("A")
  sleep(30)
  nc.suggest()
  poll("callback integration receives edit", nc.has_suggestion)
  snippets = true
  input("<Tab>")
  sleep(60)
  check("edit acceptance has priority over snippet", line(1), "line1 = 100")
  check("snippet was not advanced", snippet_calls, 0)
  input("<Tab><Tab>")
  sleep(80)
  check("callback jump then accept preserves chain", line(4), "line4 = 400")
  nc.dismiss()
  nc.dismiss()
  input("<Tab>")
  sleep(30)
  check("snippet fallback owns Tab without prediction", snippet_calls, 1)
  snippets = false
  input("<Tab>")
  sleep(30)
  check(
    "literal fallback inserts Tab",
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("\t") ~= nil,
    true
  )
  input("<Esc>")
  sleep(30)

  seed()
  vim.keymap.set("i", "<Tab>", function()
    if nc.accept() then return "" end
    return "<Tab>"
  end, { expr = true })
  input("A")
  sleep(30)
  nc.suggest()
  poll("expr integration receives edit", nc.has_suggestion)
  input("<Tab><Tab>")
  sleep(80)
  check("expr accept applies under deferred textlock", line(1), "line1 = 100")
  check(
    "rapid expr Tab does not leak indentation",
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("\t") == nil,
    true
  )
  input("<Tab>")
  sleep(60)
  -- A rapid burst may already have jumped; ensure the next deliberate press applies.
  if line(4) ~= "line4 = 400" then
    input("<Tab>")
    sleep(60)
  end
  check("expr integration can finish the chain", line(4), "line4 = 400")
  nc.stop()
  print(failed == 0 and "ALL PASS" or failed .. " FAILURES")
  vim.cmd(failed == 0 and "qa!" or "cquit!")
end)
local function resume()
  local ok, ms = coroutine.resume(co)
  if not ok then
    print(ms)
    vim.cmd("cquit!")
    return
  end
  if coroutine.status(co) ~= "dead" then vim.defer_fn(resume, ms) end
end
vim.defer_fn(resume, 40)
