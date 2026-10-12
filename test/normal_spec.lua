-- Opt-in Normal-mode suggestions, driven through Neovim's real main loop.
-- nvim --headless -u NONE -c "luafile test/normal_spec.lua"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.opt.showmode = false
io.stdout:setvbuf("no")
local nc = require("neocursor")
local failed = 0
local function check(desc, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", desc,
    ok and "" or (" got=" .. vim.inspect(got) .. " want=" .. vim.inspect(want))))
end
local function mode() return vim.api.nvim_get_mode().mode end
local function input(keys) vim.api.nvim_input(keys) end
local function sleep(ms) coroutine.yield(ms) end
local function poll(desc, cond)
  for _ = 1, 250 do
    if cond() then check(desc, true, true); return true end
    sleep(20)
  end
  check(desc, false, true)
  return false
end
local function logged(text, since)
  for i = since + 1, #nc._log_lines() do
    if nc._log_lines()[i]:find(text, 1, true) then return true end
  end
  return false
end
vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.tempname() .. ".py"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5",
})
nc.setup({
  normal_mode = true,
  debounce = 30,
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})
local co = coroutine.create(function()
  poll("suggestion arrives without entering Insert", nc.has_suggestion)
  check("editor starts in Normal", mode(), "n")
  input("<Tab>")
  sleep(100)
  check("Normal Tab accepts", vim.api.nvim_buf_get_lines(0, 0, 1, false), { "line1 = 100" })
  check("accept stays in Normal", mode(), "n")
  input("<Tab><Tab>")
  sleep(100)
  check("Normal Tab jumps then accepts the chain", vim.api.nvim_buf_get_lines(0, 3, 4, false), { "line4 = 400" })
  input("<Esc><Esc>") -- dismiss both the edit and prediction, if present
  sleep(100)
  check("Normal Esc dismisses", nc.has_suggestion(), false)

  local mark = #nc._log_lines()
  input("gg0x") -- edit without moving the cursor: preview must be refreshed
  poll("Normal edit sends a request", function() return logged("REQ", mark) end)
  poll("Normal edit gets a fresh preview", nc.has_suggestion)
  input("i")
  sleep(100)
  check("preview survives entering Insert", nc.has_suggestion(), true)
  input("<Esc>")
  sleep(100)
  check("preview survives leaving Insert", nc.has_suggestion(), true)
  check("Insert Escape enters Normal", mode(), "n")

  input("v")
  sleep(100)
  check("Visual mode clears previews", nc.has_suggestion(), false)
  input("<Esc>")
  poll("returning to Normal refreshes", nc.has_suggestion)
  input("d")
  sleep(100)
  check("operator-pending clears previews", nc.has_suggestion(), false)
  input("<Esc>")
  poll("Normal refreshes after cancelling operator", nc.has_suggestion)
  input("<Esc><Esc>")
  sleep(100)

  mark = #nc._log_lines()
  input("A9")
  poll("Insert request is sent", function() return logged("REQ", mark) end)
  input("<Esc>") -- response arrives after the switch to Normal
  poll("pending Insert reply renders in Normal", nc.has_suggestion)
  check("late reply stays in Normal", mode(), "n")
  input("<Esc><Esc>")
  sleep(100)
  mark = #nc._log_lines()
  nc.suggest()
  input("v")
  poll("reply outside supported modes is dropped", function() return logged("outside enabled modes", mark) end)
  check("late Visual reply has no preview", nc.has_suggestion(), false)
  io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
  vim.cmd(failed == 0 and "qall!" or "cquit!")
end)
local function resume()
  local ok, ms = coroutine.resume(co)
  if not ok then io.stderr:write(tostring(ms) .. "\n"); vim.cmd("cquit!"); return end
  if coroutine.status(co) ~= "dead" then vim.defer_fn(resume, ms) end
end
vim.defer_fn(resume, 50)
