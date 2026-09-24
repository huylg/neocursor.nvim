-- Headless behavioral spec for the tab-tab flow. Run from the repo root:
--   nvim --headless -u NONE -c "luafile test/flow_spec.lua"
--
-- Structure: the main thread blocks inside feedkeys(..., "x!") — a live insert
-- session whose vgetc wait runs the event loop, exactly like interactive use.
-- Timers drive the keystrokes and assertions, and end each round with <Esc>,
-- which unblocks the main thread. Asserted here are the parts that regressed:
-- suggestions surviving the echo events of our own apply/jump, two-phase
-- jump→accept, chain advance, and rapid tab-tab-tab never leaking a literal
-- <Tab> into the buffer.
-- an accept never copying a buffer-local 'undolevels' into the global option.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false -- a stale swap prompt would hang a headless run
io.stdout:setvbuf("no")

local failed = 0
local function check(desc, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", desc,
    ok and "" or ("  got=" .. vim.inspect(got) .. "  want=" .. vim.inspect(want))))
end

local nc = require("neocursor")
local preview = require("neocursor.preview")
-- A listener registered BEFORE neocursor's (setup is below) that edits the buffer
-- during the accept echo. That bumps changedtick, so mark_seen no longer matches
-- and — without the apply guard — the echo is treated as typing, the chain diff
-- is cleared, and the refetch paints it a second time.
local bump_echo = false
vim.api.nvim_create_autocmd("TextChangedI", {
  callback = function(args)
    if not bump_echo then return end
    if vim.api.nvim_get_current_line() ~= "line1 = 100" then return end
    bump_echo = false
    local row = vim.api.nvim_buf_get_lines(args.buf, 4, 5, false)[1]
    vim.api.nvim_buf_set_lines(args.buf, 4, 5, false, { (row or "") .. " " })
    vim.api.nvim_buf_set_lines(args.buf, 4, 5, false, { row })
  end,
})
-- NEOCURSOR_SPEC_NO_HINTS=1 reruns this whole spec with the hint chrome off.
-- Hiding hints is display-only, so every behavioral assertion below — jump,
-- accept, chain advance — must hold identically in both modes.
local no_hints = os.getenv("NEOCURSOR_SPEC_NO_HINTS") == "1"
io.stdout:write(no_hints and "-- show_hints = false --\n" or "-- show_hints = default --\n")
nc.setup({
  debounce = 30,
  show_hints = not no_hints,
  -- "python3" doesn't exist on Windows; the canned sidecar is stdlib-only
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})

vim.cmd("edit " .. root .. "/test/spec_scratch.py") -- named file, normal buftype
local seed = { "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5" }
vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)

local function feed(keys) -- blocking: runs the insert session until <Esc>
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x!", false)
end
local function input(keys) -- queued: consumed by the blocked insert loop
  vim.api.nvim_input(keys)
end
local function later(ms, fn) vim.defer_fn(fn, ms) end
local function poll(cond, timeout_ms, on_ok, on_fail)
  local waited = 0
  local function tick()
    if cond() then return on_ok() end
    waited = waited + 20
    if waited >= timeout_ms then return on_fail() end
    later(20, tick)
  end
  tick()
end
local function line(n) return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1] end
local function buf_text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end

-- Round 1: type → suggestion → Tab (accept) → Tab (jump) → Tab (accept),
-- pausing between presses so each one's echo events fire before we assert.
local function round1()
  poll(nc.has_suggestion, 3000, function()
    check("suggestion arrives after typing", true, true)
    input("<Tab>")
    later(120, function()
      check("accept applies edit 1", line(1), "line1 = 100")
      check("chain edit 2 survives echo events", nc.has_suggestion(), true)
      input("<Tab>")
      later(120, function()
        check("jump moves cursor to edit 2", vim.api.nvim_win_get_cursor(0)[1], 4)
        check("suggestion survives jump echo", nc.has_suggestion(), true)
        input("<Tab>")
        later(120, function()
          check("accept applies edit 2", line(4), "line4 = 400")
          check("no literal <Tab> leaked into buffer", buf_text():find("\t") == nil, true)
          input("<Esc>")
        end)
      end)
    end)
  end, function()
    check("suggestion arrives after typing", false, true)
    input("<Esc>")
  end)
end

-- Round 2: the whole tab-tab-tab burst in one keystream. Under a deferred
-- accept this slipped literal tabs into the buffer mid-chain.
local function round2()
  poll(nc.has_suggestion, 3000, function()
    check("suggestion arrives (round 2)", true, true)
    input("<Tab><Tab><Tab>")
    later(200, function()
      check("rapid tab-tab-tab lands both edits", { line(1), line(4) },
        { "line1 = 100", "line4 = 400" })
      check("rapid gesture leaks no literal <Tab>", buf_text():find("\t") == nil, true)
      input("<Esc>")
    end)
  end, function()
    check("suggestion arrives (round 2)", false, true)
    input("<Esc>")
  end)
end

-- Round 3: pure cursor movement must NOT kill a shown suggestion — the backend
-- won't reliably re-offer an edit after a 1-column move, so clearing on
-- movement loses suggestions permanently (the CLAUDE.md field failure).
local function round3()
  poll(nc.has_suggestion, 5000, function()
    check("suggestion arrives (round 3)", true, true)
    input("<Left>")
    later(100, function() -- asserted inside the refetch window: retention, not resurrection
      check("suggestion survives cursor movement", nc.has_suggestion(), true)
      input("<Tab>")
      later(150, function()
        check("Tab still accepts after movement", line(1), "line1 = 100")
        input("<Esc>")
      end)
    end)
  end, function()
    check("suggestion arrives (round 3)", false, true)
    input("<Esc>")
  end)
end

-- Round 4: the continuous flow — chain exhausted → server's prediction target
-- becomes the "Tab →" hint → Tab jumps there and retriggers.
local function round4()
  poll(nc.has_suggestion, 5000, function()
    check("suggestion arrives (round 4)", true, true)
    input("<Tab><Tab><Tab>") -- accept L1, jump L4, accept L4 → chain exhausted
    later(200, function()
      check("prediction hint appears after chain", nc.has_prediction(), true)
      input("<Tab>")
      later(150, function()
        check("Tab jumps to predicted line", vim.api.nvim_win_get_cursor(0)[1], 2)
        check("prediction consumed by jump", nc.has_prediction(), false)
        input("<Esc>")
      end)
    end)
  end, function()
    check("suggestion arrives (round 4)", false, true)
    input("<Esc>")
  end)
end

-- Round 5: word-level partial accept of an inline ghost; consuming the last
-- fragment walks the chain like a full accept.
local function round5()
  poll(nc.has_suggestion, 5000, function()
    check("inline ghost arrives (round 5)", true, true)
    input("<M-Right>")
    later(150, function()
      check("partial accept completes the line", line(1), "line1 = 100")
      check("chain advances after ghost consumed", nc.has_suggestion(), true)
      input("<Esc>")
    end)
  end, function()
    check("inline ghost arrives (round 5)", false, true)
    input("<Esc>")
  end)
end

-- Round 6: panel buffers (diffview/mason/neogit-style) set buffer-local
-- 'undolevels' to -1/0. Accepting must close the undo block WITHOUT copying
-- that local value into the global option — a leak disables undo everywhere.
local function round6()
  poll(nc.has_suggestion, 3000, function()
    check("suggestion arrives (round 6)", true, true)
    local before = vim.api.nvim_get_option_value("undolevels", { scope = "global" })
    input("<Tab>")
    later(120, function()
      check("accept applies edit with local undolevels", line(1), "line1 = 100")
      local after = vim.api.nvim_get_option_value("undolevels", { scope = "global" })
      check("accept leaves global 'undolevels' unchanged", after, before)
      vim.cmd("setlocal undolevels<") -- drop the buffer-local override
      input("<Esc>")
    end)
  end, function()
    check("suggestion arrives (round 6)", false, true)
    input("<Esc>")
  end)
end

vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round1)
feed("Ax") -- blocks while round1 runs; returns on its <Esc>

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round2)
feed("Ay") -- blocks while round2 runs; returns on its <Esc>

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round3)
feed("Az") -- blocks while round3 runs; returns on its <Esc>

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round4)
feed("Aw") -- blocks while round4 runs; returns on its <Esc>

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round5)
feed("A0") -- "line1 = 10" is a prefix of the fake's edit → inline ghost "0"

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_set_option_value("undolevels", -1, { buf = 0 }) -- what panel buffers do
later(50, round6)
feed("A6") -- blocks while round6 runs; returns on its <Esc>

-- Round 7: accepting an inline ghost reveals the next diff locally. A
-- TextChangedI listener that edits the buffer in that echo used to make the
-- tick miss mark_seen, so the echo refetched and painted the same hint again.
local function hint_count()
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, preview.namespace(), 0, -1, { details = true })) do
    local text = ""
    for _, chunk in ipairs(m[4].virt_text or {}) do text = text .. chunk[1] end
    if text:find("neocursor", 1, true) then n = n + 1 end
  end
  return n
end
local function round7()
  poll(nc.has_suggestion, 5000, function()
    check("inline ghost arrives (round 7)", true, true)
    bump_echo = true
    input("<Tab>")
    later(800, function()
      check("accept applies inline edit", line(1), "line1 = 100")
      check("chain survives an echo that bumps changedtick", nc.has_suggestion(), true)
      local lines = nc._log_lines()
      local acc = 0
      for i, l in ipairs(lines) do
        if l:find("ACCEPT", 1, true) then acc = i end
      end
      local req, shows = 0, 0
      for i = acc + 1, #lines do
        if lines[i]:find("REQ ", 1, true) then req = req + 1 end
        if lines[i]:find("SHOW    diff", 1, true) then shows = shows + 1 end
      end
      check("accept echo does not refetch", req, 0)
      check("chain diff is shown once", shows, 1)
      check("one discoverability hint", hint_count(), no_hints and 0 or 1)
      input("<Esc>")
    end)
  end, function()
    check("inline ghost arrives (round 7)", false, true)
    input("<Esc>")
  end)
end

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("setlocal undolevels<")
later(50, round7)
feed("A0") -- inline ghost, same prefix as round 5

-- Round 8: an insert that begins past the last line. It used to render above
-- that line (virt_lines_above after the anchor was clamped), and <Tab> jumped
-- at a row that does not exist, so the accept never ran.
local function round8()
  poll(nc.has_suggestion, 5000, function()
    local placed
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, preview.namespace(), 0, -1, { details = true })) do
      local vl = m[4].virt_lines
      if vl then
        placed = { row = m[2], above = m[4].virt_lines_above == true, text = vl[1][1][1] }
      end
    end
    check("EOF insert renders under the last line", placed,
      { row = 2, above = false, text = "appended" })
    input("<Tab>")
    later(200, function()
      check("Tab accepts an insert past the last line", buf_text(),
        "alpha\nbeta\n__eof__\nappended\nsecond")
      input("<Esc>")
    end)
  end, function()
    check("EOF suggestion arrives", false, true)
    input("<Esc>")
  end)
end

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta", "__eof__" })
vim.api.nvim_win_set_cursor(0, { 3, 0 })
later(50, round8)
feed("A")

-- Round 9: a listener edits the buffer *after* the accept echo has been
-- swallowed (vim.schedule, so the apply guard has already dropped). The cursor
-- never moved. That used to look like typing and repaint the chain diff.
local defer_bump = false
vim.api.nvim_create_autocmd("TextChangedI", {
  callback = function(args)
    if not defer_bump then return end
    if vim.api.nvim_get_current_line() ~= "line1 = 100" then return end
    defer_bump = false
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(args.buf) then return end
      local row = vim.api.nvim_buf_get_lines(args.buf, 4, 5, false)[1]
      vim.api.nvim_buf_set_lines(args.buf, 4, 5, false, { (row or "") .. " " })
      vim.api.nvim_buf_set_lines(args.buf, 4, 5, false, { row })
    end)
  end,
})
local function round9()
  poll(nc.has_suggestion, 5000, function()
    check("inline ghost arrives (round 9)", true, true)
    defer_bump = true
    input("<Tab>")
    later(800, function()
      check("accept applies inline edit (round 9)", line(1), "line1 = 100")
      check("chain survives a deferred tick bump", nc.has_suggestion(), true)
      local lines = nc._log_lines()
      local acc = 0
      for i, l in ipairs(lines) do
        if l:find("ACCEPT", 1, true) then acc = i end
      end
      local req, shows = 0, 0
      for i = acc + 1, #lines do
        if lines[i]:find("REQ ", 1, true) then req = req + 1 end
        if lines[i]:find("SHOW    diff", 1, true) then shows = shows + 1 end
      end
      check("deferred bump does not refetch", req, 0)
      check("deferred bump does not repaint", shows, 1)
      input("<Esc>")
    end)
  end, function()
    check("inline ghost arrives (round 9)", false, true)
    input("<Esc>")
  end)
end

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round9)
feed("A0")

-- Round 10: autoread reloads the file after it is written (the user's
-- autowriteall + checktime on CursorHoldI, updatetime 1000ms). changedtick
-- bumps, the bytes and the cursor do not. That used to paint the suggestion again.
local function round10()
  poll(nc.has_suggestion, 5000, function()
    check("inline ghost arrives (round 10)", true, true)
    vim.o.autoread = true
    vim.cmd("silent write!")
    vim.fn.system({ "touch", vim.fn.expand("%:p") })
    local before = #nc._log_lines()
    vim.cmd("checktime")
    later(400, function()
      check("reload keeps the suggestion", nc.has_suggestion(), true)
      check("reload keeps the typed line", line(1), "line1 = 10")
      local lines = nc._log_lines()
      local req, shows = 0, 0
      for i = before + 1, #lines do
        if lines[i]:find("REQ ", 1, true) then req = req + 1 end
        if lines[i]:find("SHOW", 1, true) then shows = shows + 1 end
      end
      check("file reload does not refetch", req, 0)
      check("file reload does not repaint", shows, 0)
      input("<Esc>")
    end)
  end, function()
    check("inline ghost arrives (round 10)", false, true)
    input("<Esc>")
  end)
end

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round10)
feed("A0")

io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
vim.cmd(failed == 0 and "qall!" or "cquit!")
