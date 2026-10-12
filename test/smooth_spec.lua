-- Offline integration: real Neovim, jobstart, streaming, prefetch and retention.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
local nc = require("neocursor")
local preview = require("neocursor.preview")
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local failed = 0
local function check(name, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  print(
    (ok and "ok " or "FAIL ")
      .. name
      .. (ok and "" or " got=" .. vim.inspect(got) .. " want=" .. vim.inspect(want))
  )
end
local function wait(cond) return vim.wait(1800, cond, 5) end
local function pause(ms)
  vim.wait(ms, function() return false end, 5)
end
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function logs(fragment)
  local count = 0
  for _, l in ipairs(nc._log_lines()) do
    if l:find(fragment, 1, true) then count = count + 1 end
  end
  return count
end
local function fresh(name, content, opts)
  nc.stop()
  local existing = vim.fn.bufnr(dir .. "/" .. name)
  if existing >= 0 then vim.api.nvim_buf_delete(existing, { force = true }) end
  vim.cmd("enew!")
  vim.api.nvim_buf_set_name(0, dir .. "/" .. name)
  vim.bo.filetype = "python"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, content)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  nc.setup(vim.tbl_extend("force", {
    normal_mode = true,
    map_tab = false,
    debounce = 100000,
    jump_loading_timeout = 500,
    sidecar_cmd = {
      vim.fn.executable("python3") == 1 and "python3" or "python",
      root .. "/test/stream_sidecar.py",
    },
  }, opts or {}))
  pause(40)
  nc.suggest()
end
fresh("diagnostics.py", { "old" })
local diagnostic_requests = logs("REQ ")
local diagnostic_ns = vim.api.nvim_create_namespace("neocursor-test-diagnostics")
for i = 1, 4 do
  vim.diagnostic.set(diagnostic_ns, 0, { { lnum = 0, col = 0, message = "LSP update " .. i } })
  pause(5)
end
check("diagnostics preserve the in-flight request", logs("REQ "), diagnostic_requests)
check("diagnostics do not cancel an unchanged snapshot", logs("diagnostics changed"), 0)
check("original request still displays after diagnostic burst", wait(nc.has_suggestion), true)
vim.diagnostic.reset(diagnostic_ns)

fresh("stream.py", { "old", "second", "third" })
check("first streamed edit arrives", wait(nc.has_suggestion), true)
check("stream not finished at first preview", logs("first-edit=") > 0, true)
nc.accept()
check("first acceptance inserts a line", lines(), { "first", "inserted", "second", "third" })
check("early Tab during streamed chain is consumed", nc.accept(), true)
check("no unseen edit accepted", lines(), { "first", "inserted", "second", "third" })
check("later streamed edit arrives", wait(nc.has_suggestion), true)
nc.accept()
nc.accept()
check("later ranges rebase once; duplicate ignored", lines(), { "first", "inserted", "second", "THIRD" })
pause(120)

fresh("dismiss.py", { "old" })
nc.dismiss()
pause(180)
check("dismiss invalidates outstanding response", nc.has_suggestion(), false)

fresh("retain.py", { "foo(old_name)" })
check("rewrite arrives", wait(nc.has_suggestion), true)
local reqs = logs("REQ ")
vim.api.nvim_buf_set_text(0, 0, 4, 0, 7, { "n" })
pause(50)
check("compatible partial rewrite stays visible", nc.has_suggestion(), true)
check("compatible typing does not refetch", logs("REQ "), reqs)
nc.accept()
check("retained rewrite accepts", lines(), { "foo(new_name)" })
pause(40)

fresh("retain.py", { "foo(old_name)" })
wait(nc.has_suggestion)
vim.api.nvim_buf_set_text(0, 0, 4, 0, 7, { "WRONG" })
pause(50)
check("incompatible rewrite clears preview", nc.has_suggestion(), false)

fresh("retain.py", { "foo(old_name)" })
wait(nc.has_suggestion)
vim.api.nvim_buf_set_text(0, 0, 13, 0, 13, { "X" })
pause(50)
check("incompatible typing at EOF clears preview", nc.has_suggestion(), false)

fresh("inline.py", { "foo()" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
wait(nc.has_suggestion)
local marks = vim.api.nvim_buf_get_extmarks(0, preview.namespace(), 0, -1, { details = true })
check("completion before closing punctuation is inline", marks[1] and marks[1][4].virt_text_pos, "inline")
check("inline ghost excludes suffix", marks[1] and marks[1][4].virt_text[1][1], "argument")
nc.accept_partial()
check("partial acceptance preserves closing punctuation", lines(), { "foo(argument)" })
pause(40)

fresh("unicode.py", { 'local cafe = "茶"' })
wait(nc.has_suggestion)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
nc.accept()
check("Unicode replacement preserves byte boundaries", lines(), { 'local café = "茶"' })
check("cursor outside edit remains in place", vim.api.nvim_win_get_cursor(0), { 1, 0 })
vim.cmd("undo")
check("one undo restores original", lines(), { 'local cafe = "茶"' })
vim.cmd("redo")
check("redo restores accepted edit", lines(), { 'local café = "茶"' })
pause(40)

fresh("delete.py", { "keep", "remove", "tail" })
wait(nc.has_suggestion)
nc.accept()
nc.accept()
check("empty edit deletes line instead of inserting blank", lines(), { "keep", "tail" })
pause(40)

fresh("blank_insert.py", { "keep", "tail" })
wait(nc.has_suggestion)
local blank_visible = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, preview.namespace(), 0, -1, { details = true })) do
  if mark[4].virt_lines then blank_visible = true end
end
check("blank insertion has a visible preview", blank_visible, true)
nc.accept()
nc.accept()
check("empty insertion adds a blank line", lines(), { "keep", "", "tail" })
pause(40)

vim.fn.writefile({ "disk target" }, dir .. "/target.py")
fresh("jump.py", { "unsaved source" })
check("cross-file prediction arrives", wait(nc.has_prediction), true)
pause(400)
local source = vim.api.nvim_get_current_buf()
check("prefetch did not open destination", vim.api.nvim_get_current_buf(), source)
nc.accept()
check("cached jump displays edit immediately", nc.has_suggestion(), true)
check("jump targets other file", vim.fn.expand("%:t"), "target.py")
check("source remains unsaved", vim.bo[source].modified, true)
check("prefetch hit recorded", logs("PREFETCH hit") > 0, true)
nc.accept()
check("cross-file edit accepts", lines(), { "disk target ready" })
pause(40)

fresh("same.py", { "source", "destination" })
wait(nc.has_prediction)
nc.accept()
check("same-file jump reaches destination", vim.api.nvim_win_get_cursor(0)[1], 2)
check("Tab while jump loads is consumed", nc.accept(), true)
check("loading Tab leaves buffer unchanged", lines(), { "source", "destination" })
check("pending prefetch promotes and renders", wait(nc.has_suggestion), true)
check("loading did not auto-accept edit", lines(), { "source", "destination" })
nc.accept()
check("next deliberate Tab accepts", lines(), { "source", "destination ready" })
pause(40)

fresh("same.py", { "source", "destination" }, { prefetch = false, jump_loading_timeout = 70 })
wait(nc.has_prediction)
nc.accept()
check("uncached jump consumes immediate Tab", nc.accept(), true)
pause(100)
check("loading timeout restores fallback", nc.accept(), false)
check("valid response can arrive after loading timeout", wait(nc.has_suggestion), true)

-- Cached destination content is always the loaded buffer, including unsaved edits.
local target = vim.fn.bufnr(dir .. "/target.py")
vim.api.nvim_buf_set_lines(target, 0, -1, false, { "unsaved target" })
fresh("jump.py", { "another source" })
wait(nc.has_prediction)
pause(400)
nc.accept()
check("jump keeps unsaved target content", lines(), { "unsaved target" })
check("unsaved target prefetch is ready", nc.has_suggestion(), true)
nc.accept()
check("cached edit was based on unsaved content", lines(), { "unsaved target ready" })
pause(40)

fresh("jump.py", { "source with stale cache" })
wait(nc.has_prediction)
pause(400)
vim.api.nvim_buf_set_lines(target, 0, -1, false, { "changed after prefetch" })
pause(40)
nc.accept()
check("changed destination invalidates cached edit", nc.has_suggestion(), false)
check("stale cache does not overwrite destination", lines(), { "changed after prefetch" })
check("destination gets fresh foreground response", wait(nc.has_suggestion), true)
nc.accept()
check("fresh edit uses changed destination", lines(), { "changed after prefetch ready" })
pause(40)

fresh("same.py", { "source", "destination" })
wait(nc.has_prediction)
pause(400)
nc.accept()
check("same-file prefetch displays immediately", nc.has_suggestion(), true)
nc.dismiss()
pause(100)
check("dismissed prefetched edit stays dismissed", nc.has_suggestion(), false)

fresh("stream.py", { "old", "second", "third" })
wait(nc.has_suggestion)
nc.accept()
nc.dismiss()
pause(450)
check("dismiss drops later streamed chain edits", nc.has_suggestion(), false)
check("dismiss never undoes accepted edit", lines(), { "first", "inserted", "second", "third" })

fresh("retain.py", { "foo(old_name)", "tail" })
wait(nc.has_suggestion)
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new header" })
pause(50)
check("unrelated insertion rebases visible edit", nc.has_suggestion(), true)
nc.accept()
nc.accept()
check("rebased edit preserves unrelated insertion", lines(), { "new header", "foo(new_name)", "tail" })
pause(40)

fresh("out_of_order.py", { "first", "second" })
wait(nc.has_suggestion)
nc.accept()
nc.accept()
nc.accept()
check("out-of-order edit events apply in sequence", lines(), { "FIRST", "SECOND" })

fresh("missing.py", { "source" })
wait(nc.has_prediction)
local previous = vim.api.nvim_get_current_buf()
nc.accept()
check("missing destination retains source", vim.api.nvim_get_current_buf(), previous)
check("missing destination ends prediction", nc.has_prediction(), false)

fresh("error.py", { "source" })
pause(150)
check("transport error does not render edit", nc.has_suggestion(), false)
check("transport error restores Tab fallback", nc.accept(), false)

nc.stop()
vim.fn.delete(dir, "rf")
print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
vim.cmd(failed == 0 and "qa!" or "cquit!")
