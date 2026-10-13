-- Real Insert-mode input: continue a matching ghost or refresh from new text.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
vim.opt.showmode = false
vim.opt.autoindent = false
vim.opt.smartindent = false
vim.opt.completeopt = { "menuone", "noselect", "noinsert" }
io.stdout:setvbuf("no")
local nc = require("neocursor")
local preview = require("neocursor.preview")
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local failed = 0
local function check(name, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  io.stdout:write(
    (ok and "ok " or "FAIL ")
      .. name
      .. (ok and "" or " got=" .. vim.inspect(got) .. " want=" .. vim.inspect(want))
      .. "\n"
  )
end
local function sleep(ms) coroutine.yield(ms) end
local function input(keys) vim.api.nvim_input(keys) end
local function poll(name, condition)
  for _ = 1, 200 do
    if condition() then return true end
    sleep(10)
  end
  check(name, false, true)
  return false
end
local function requests()
  local n = 0
  for _, line in ipairs(nc._log_lines()) do
    if line:find("REQ ", 1, true) then n = n + 1 end
  end
  return n
end
local function ghost()
  local marks = vim.api.nvim_buf_get_extmarks(0, preview.namespace(), 0, -1, { details = true })
  if #marks ~= 1 then return nil end
  local detail = marks[1][4]
  local parts = { detail.virt_text and detail.virt_text[1][1] or "" }
  for _, line in ipairs(detail.virt_lines or {}) do
    parts[#parts + 1] = line[1][1]
  end
  return table.concat(parts, "\n")
end
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function fresh(name, seed, cursor)
  input("<Esc>")
  sleep(30)
  nc.stop()
  vim.cmd("enew!")
  local previous = vim.fn.bufnr(dir .. "/" .. name)
  if previous >= 0 then vim.api.nvim_buf_delete(previous, { force = true }) end
  vim.api.nvim_buf_set_name(0, dir .. "/" .. name)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
  vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
  nc.setup({
    debounce = 40,
    map_tab = false,
    prefetch = false,
    sidecar_cmd = {
      vim.fn.executable("python3") == 1 and "python3" or "python",
      root .. "/test/stream_sidecar.py",
    },
  })
  input(cursor and "i" or "A")
  poll("initial suggestion arrives for " .. name, nc.has_suggestion)
end
local co = coroutine.create(function()
  fresh("typing.py", { "foo" })
  check("initial inline completion", ghost(), "bar")
  local count = requests()
  input("b")
  sleep(20)
  check("matching character trims the visible ghost", ghost(), "ar")
  input("a")
  sleep(20)
  check("next matching character continues the same completion", ghost(), "r")
  check("matching typing does not request again", requests(), count)
  input("r")
  poll(
    "typing through asks for continuing completion",
    function() return requests() > count and nc.has_suggestion() end
  )
  check("typed-through content is preserved", lines(), { "foobar" })
  check("new completion follows fully typed suggestion", ghost(), "bar")

  fresh("typing.py", { "foo" })
  count = requests()
  input("x")
  sleep(20)
  check("mismatched character clears old preview immediately", nc.has_suggestion(), false)
  poll("mismatch refreshes", function() return requests() > count and nc.has_suggestion() end)
  nc.accept()
  check("fresh completion uses latest typed text", lines(), { "fooxbar" })

  fresh("typing_remote.py", { "foo", "tail" })
  count = requests()
  -- The backend can suggest a later-line edit while the user stays put.
  input("x")
  sleep(20)
  check("same-cursor typing clears a suggestion on a later line", nc.has_suggestion(), false)
  poll(
    "same-cursor typing refreshes context",
    function() return requests() > count and nc.has_suggestion() end
  )
  nc.accept()
  check("refresh follows typing without moving to the stale edit", lines(), { "fooxbar", "tail" })

  fresh("typing.py", { "foo" })
  count = requests()
  input("a") -- occurs in 'bar', but is not the next suggested character
  sleep(20)
  check("subsequence is not treated as matching prefix", nc.has_suggestion(), false)
  poll("skipped prefix refreshes", function() return requests() > count and nc.has_suggestion() end)
  nc.accept()
  check("refresh does not insert text behind the cursor", lines(), { "fooabar" })

  fresh("typing_unicode.py", { "foo" })
  count = requests()
  input("茶")
  sleep(30)
  check("Unicode typing consumes a complete character", ghost(), "色")
  check("Unicode prefix stays local", requests(), count)
  nc.accept()
  check("remaining Unicode completion accepts", lines(), { "foo茶色" })

  fresh("typing.py", { "foo()" }, { 1, 4 })
  count = requests()
  input("b")
  sleep(20)
  check("matching prefix before punctuation trims ghost", ghost(), "ar")
  check("completion before punctuation stays local", requests(), count)
  nc.accept()
  check("typing and accepting preserve closing punctuation", lines(), { "foo(bar)" })

  fresh("typing.py", { "foo" })
  count = requests()
  input("<BS>")
  sleep(20)
  check("backspace clears old completion", nc.has_suggestion(), false)
  poll("backspace refreshes", function() return requests() > count and nc.has_suggestion() end)
  nc.accept()
  check("backspace refresh uses shortened text", lines(), { "fobar" })

  fresh("typing_multiline.py", { "foo", "tail" })
  count = requests()
  input("<CR>b")
  sleep(30)
  check("newline and prefix continue multiline ghost", ghost(), "ar\nbaz")
  check("multiline prefix does not refetch", requests(), count)
  nc.accept()
  check("multiline acceptance preserves following buffer lines", lines(), { "foo", "bar", "baz", "tail" })

  fresh("typing.py", { "foo", "tail" })
  count = requests()
  input("<Down><End>x")
  sleep(20)
  check("typing elsewhere clears contextual suggestion", nc.has_suggestion(), false)
  poll(
    "typing elsewhere gets fresh completion",
    function() return requests() > count and nc.has_suggestion() end
  )
  nc.accept()
  check("new completion targets the latest cursor", lines(), { "foo", "tailxbar" })

  fresh("typing.py", { "foo" })
  count = requests()
  vim.fn.complete(1, { "foobuffer", "foobar" })
  sleep(20)
  check("completion popup is open", vim.fn.pumvisible(), 1)
  input("b")
  sleep(20)
  check("typing with popup consumes matching prefix", ghost(), "ar")
  check("popup typing keeps matching completion local", requests(), count)
  input("<C-e>x")
  sleep(20)
  check("mismatch after popup clears preview", nc.has_suggestion(), false)
  poll("popup mismatch refreshes", function() return requests() > count and nc.has_suggestion() end)
  nc.accept()
  check("popup refresh uses latest content", lines(), { "foobxbar" })

  nc.stop()
  vim.fn.delete(dir, "rf")
  io.stdout:write(failed == 0 and "ALL PASS\n" or failed .. " FAILURES\n")
  vim.cmd(failed == 0 and "qa!" or "cq!")
end)
local function resume()
  local ok, ms = coroutine.resume(co)
  if not ok then
    io.stderr:write(tostring(ms) .. "\n")
    vim.cmd("cq!")
    return
  end
  if coroutine.status(co) ~= "dead" then vim.defer_fn(resume, ms) end
end
vim.defer_fn(resume, 20)
