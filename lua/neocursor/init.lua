-- neocursor.nvim — Cursor Tab, in neovim.
-- Talks to the Python sidecar over stdio; renders the suggested edit as inline
-- ghost text (see preview.lua). <Tab> applies it.

local M = {}

local preview = require("neocursor.preview")
local heuristics = require("neocursor.heuristics")
local text_edit = require("neocursor.text")
local uv = vim.uv or vim.loop

local state = {
  job = nil,
  ready = false,
  seq = 0, -- monotonically increasing request identity
  partial = "", -- stdout line-reassembly buffer
  timer = nil,
  suggestion = nil, -- { bufnr, start0, end0_excl, lines, mode, buf_lines }
  cfg = nil,
  seen = nil, -- { buf, tick, row, col } last observed state; our own edits' echoes match it
  req = nil, -- foreground request and its source/expected snapshots
  requests = {},
  prefetch = nil,
  loading = nil,
  context_gen = 0,
  attached = {},
  last_edit_at = nil, -- os.time() of the last real text edit (Cursor's lastEditTime)
  last_line = nil, -- last cursor row seen, to detect line changes (Cursor's lastLine)
  queue = nil, -- { list = {edit,...}, idx } multi-edit chain from one response
  prediction = nil, -- { path, line } next-jump target (cursorPredictionTarget)
  pred_rejects = {}, -- [path:line] = {count, ts} — Cursor: 30s TTL, max 5, mute at 2
  viewed = {}, -- [bufnr] = ms of last BufEnter (recency for additionalFiles)
  dbase = {}, -- [bufnr] = { path, text } baseline snapshot for diffing
  dtraj = {}, -- [path]  = { {diff, ts}, ... } committed edit trajectory
  rejects = {}, -- [key]   = times the user dismissed this exact suggestion
  dismissed = 0, -- dismissals since the last accept (Cursor:
  -- numberOfClearedSuggestionsSinceLastAccept — see the note
  -- on rejected_too_many for why we count dismissals, not clears)
  log = {}, -- ring buffer of event strings for :NeocursorLog
  log_buf = nil,
  log_dirty = false,
  awaiting = false, -- a request is in flight (sent, no reply yet) — dashboard phase
  stderr_tail = {}, -- last stderr lines, replayed if the sidecar dies before ready
  timer_gen = 0, -- bumped on cancel so an already-queued debounce callback cannot send
  apply_gen = 0, -- non-zero while an accept's own echo events must not refetch
}

-- Hint chrome — the ⟪neocursor · <Tab> …⟫ label on an edit and the ⟪<Tab> → L42⟫
-- pill at a jump target — is display-only. Hiding it changes what you see, never
-- what <Tab> does, so every gate below still fires exactly as it did.
local HINTS_ALL = { edit = true, prediction = true }

--- show_hints: true/nil = all, false = none, table = per-surface.
local function normalize_hints(v)
  if v == false then return { edit = false, prediction = false } end
  if type(v) == "table" then return { edit = v.edit ~= false, prediction = v.prediction ~= false } end
  return { edit = true, prediction = true }
end

-- state.cfg is nil until setup() runs; default to showing everything.
local function hints() return (state.cfg and state.cfg.show_hints) or HINTS_ALL end

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h") -- .../lua/neocursor/init.lua -> root
end

local function clear_suggestion()
  if state.suggestion then
    preview.clear(state.suggestion.bufnr)
    state.suggestion = nil
  end
  state.queue = nil -- abandon any pending multi-edit chain
end

local function buf_relpath(b)
  local n = vim.api.nvim_buf_get_name(b)
  if n == "" then return nil end
  return vim.fs.normalize(vim.fn.fnamemodify(n, ":."))
end

local function buf_text(b) return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") end

-- Relative "N seconds/minutes ago" for the dashboard's clock fields.
local function ago(t)
  if not t then return "never" end
  local d = os.time() - t
  if d <= 0 then return "now" end
  if d < 60 then return d .. "s ago" end
  return math.floor(d / 60) .. "m ago"
end

-- Defined with the other edit helpers below. Declared here so the log
-- dashboard can report what <Tab> would do without a second copy of the rule.
local cursor_at
local prefetch_prediction, prediction_target, send_request, commit_diff, schedule_request
local function now_ms() return uv.hrtime() / 1e6 end

-- Persistent debug surface rendered by :NeocursorLog. The top block is a LIVE
-- dashboard of the state machine — the phase we're in, what <Tab> would do at
-- this instant (Cursor's cursorAtInlineEdit rule), the self-echo guard, the
-- prediction ledger, the debounce timer — so the *current* dynamics are legible
-- without reading the history backwards. Below the separator: the event log,
-- newest first, so the freshest line sits right under the dashboard. Both the
-- dashboard and the latest events stay on screen at any window height (the view
-- is pinned to the top), which is why the log is reversed rather than tailed.
local function log_refresh()
  state.log_dirty = false
  local buf = state.log_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local c = state.cfg or {}
  local s = state.suggestion

  -- what a <Tab> press would do RIGHT NOW (inlined cursorAtInlineEdit)
  local tab_now
  if s and vim.api.nvim_buf_is_valid(s.bufnr) then
    if vim.api.nvim_get_current_buf() ~= s.bufnr then
      tab_now = "— other buf"
    else
      local at = cursor_at(s.start0, s.end0_excl)
      tab_now = at and "ACCEPT edit" or ("JUMP → L" .. (s.start0 + 1))
    end
  elseif state.loading then
    tab_now = "WAIT (consumed)"
  elseif state.prediction then
    tab_now = "PREDICT jump"
  else
    tab_now = "literal ⇥"
  end

  -- which node of the pipeline we're sitting in
  local phase
  if state.loading then
    phase = "JUMP LOADING"
  elseif s then
    phase = state.queue and "CHAINING" or "SHOWING"
  elseif state.timer then
    phase = "DEBOUNCING"
  elseif state.awaiting then
    phase = "IN-FLIGHT"
  else
    phase = "IDLE"
  end

  local pred = "none"
  if state.prediction then
    local p = state.prediction
    local r = state.pred_rejects[(p.path or "") .. ":" .. tostring(p.line)]
    pred = ("%s:%s%s"):format(
      p.path or "·",
      tostring(p.line),
      r and (r.count >= 2 and "  ⌀muted" or ("  rej×" .. r.count)) or ""
    )
  end

  local sidecar = state.ready and "● ready" or (state.job and "◐ starting" or "○ down")
  local sugg = s and ("%s L%d · %d ln"):format(s.mode, s.start0 + 1, #s.lines) or "none"
  local chain = state.queue and (state.queue.idx .. "/" .. #state.queue.list) or "—"
  local seen = state.seen
      and ("L%d:%d ↻%s"):format(state.seen.row, state.seen.col, tostring(state.seen.tick))
    or "—"
  local fused = c.is_fused == nil and "?" or tostring(c.is_fused)

  local bar = string.rep("─", 58)
  local lines = {
    "┌" .. bar .. "┐",
    ("  phase   ▸ %-12s   sidecar   %s  (job %s)"):format(phase, sidecar, tostring(state.job or "-")),
    ("  TAB now ▸ %-12s   seq %d · last ok %s"):format(tab_now, state.seq, ago(state.last_ok_at)),
    ("  suggest   %-16s  debounce %sms · timer %s"):format(
      sugg,
      c.debounce or "?",
      state.timer and "ticking" or "idle"
    ),
    ("  chain     %-16s  heur %d · excl %d · fused %s"):format(
      chain,
      c.heuristics and #c.heuristics or 0,
      c.exclude_patterns and #c.exclude_patterns or 0,
      fused
    ),
    ("  predict   %-16s  guard(seen) %s"):format(pred, seen),
    ("  err %s · suppress %s · dismissed %d/%s%s"):format(
      tostring(state.last_error or "none"),
      tostring(state.last_suppressed or "none"),
      state.dismissed,
      tostring(c.max_cleared or 20),
      state.dismissed > (c.max_cleared or 20) and "  MUTED (accept one to resume)" or ""
    ),
    ("  request   %s · prefetch %s"):format(
      state.req and state.req.purpose or "none",
      state.prefetch and (state.prefetch.done and "ready" or "loading") or "none"
    ),
    "├─ log ─ newest first " .. string.rep("─", 37) .. "┤",
  }
  for i = #state.log, 1, -1 do
    lines[#lines + 1] = state.log[i]
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 }) -- pin to top: dashboard always visible
    end
  end
end

local function log(line)
  state.log[#state.log + 1] = os.date("%H:%M:%S") .. "  " .. line
  if #state.log > 500 then table.remove(state.log, 1) end
  if not state.log_dirty then
    state.log_dirty = true
    vim.schedule(log_refresh)
  end
end

-- A request owns an immutable source snapshot and a mutable expected snapshot.
-- Only known local edits can advance expected; a changedtick alone is not proof.
local function cancel_request(r, reason)
  if not r or r.cancelled then return end
  r.cancelled = true
  if state.job and not r.done and state.protocol == 2 then
    pcall(vim.fn.chansend, state.job, vim.json.encode({ op = "cancel", id = r.id }) .. "\n")
  end
  r.done = true
  if r == state.req then state.awaiting = false end
  log(("CANCEL  #%d %s %s"):format(r.id, r.purpose, reason or ""))
end

local function invalidate(reason, keep_foreground)
  if not keep_foreground then
    cancel_request(state.req, reason)
    state.awaiting = false
  end
  cancel_request(state.prefetch, reason)
  state.prefetch = nil
  if state.loading then preview.clear_prediction(state.loading.bufnr) end
  state.loading = nil
  state.deferred_apply = nil
  state.context_gen = state.context_gen + 1
end

local function begin_loading(buf)
  local loading = { bufnr = buf, until_ms = now_ms() + state.cfg.jump_loading_timeout }
  state.loading = loading
  if hints().prediction then
    preview.prediction(buf, vim.api.nvim_win_get_cursor(0)[1] - 1, "Tab · loading…")
  end
  vim.defer_fn(function()
    if state.loading == loading then
      state.loading = nil
      preview.clear_prediction(buf)
      log("LOADING expired; normal Tab fallback restored")
    end
  end, state.cfg.jump_loading_timeout)
end

local function end_loading()
  if state.loading then preview.clear_prediction(state.loading.bufnr) end
  state.loading = nil
end

-- Tunables the sidecar fetched from Cursor's CppConfig (debounce, context
-- exclude-list, active heuristics, rejection threshold). Nil fields are left
-- at their defaults so a failed fetch degrades gracefully.
local function apply_config(cfg)
  state.protocol = cfg.protocol or 1
  if not state.cfg.explicit_debounce and type(cfg.debounce) == "number" and cfg.debounce > 0 then
    state.cfg.debounce = cfg.debounce
  end
  if type(cfg.exclude_patterns) == "table" then state.cfg.exclude_patterns = cfg.exclude_patterns end
  if type(cfg.heuristics) == "table" then state.cfg.heuristics = cfg.heuristics end
  if type(cfg.reject_hard) == "number" then state.cfg.reject_hard = cfg.reject_hard end
  if type(cfg.max_cleared) == "number" then state.cfg.max_cleared = cfg.max_cleared end
  if type(cfg.is_fused) == "boolean" then state.cfg.is_fused = cfg.is_fused end
  for _, name in ipairs(state.cfg.heuristics) do
    if type(heuristics[name]) ~= "function" then log("HEURISTIC unsupported: " .. name) end
  end
  log(
    ("CONFIG  debounce=%sms heuristics=%d excludes=%d"):format(
      state.cfg.debounce,
      #state.cfg.heuristics,
      #state.cfg.exclude_patterns
    )
  )
end

-- Normal-mode support is opt-in; visual, operator-pending and command modes
-- cannot act on previews and must drop replies arriving after a mode change.
local function suggestion_mode(mode)
  mode = mode or vim.api.nvim_get_mode().mode
  return mode:match("^[iR]") ~= nil
    or (state.cfg and state.cfg.normal_mode and (mode == "n" or mode:match("^ni") ~= nil))
end

-- Is the cursor currently on the edit's target region? This is Cursor's
-- `cursorAtInlineEdit`: when false, <Tab> jumps here; when true, <Tab> accepts.
-- An insert that starts at or past the last buffer line has no row of its own;
-- the cursor on that last line is already there.
function cursor_at(start0, end0_excl)
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local lc = vim.api.nvim_buf_line_count(vim.api.nvim_get_current_buf())
  if start0 >= lc then return row0 == lc - 1 end
  if end0_excl <= start0 then return row0 == start0 end
  return row0 >= start0 and row0 < end0_excl
end

-- Record the buffer/cursor state our own edit or jump just produced. The
-- TextChangedI/CursorMovedI events it enqueues only fire after we return to the
-- main loop; they observe exactly this state and are swallowed by the autocmd's
-- duplicate check, so applying or jumping never clears the suggestion/chain it
-- just revealed.
local function mark_seen(bufnr)
  local cur = vim.api.nvim_win_get_cursor(0)
  state.seen = {
    buf = bufnr,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    row = cur[1],
    col = cur[2],
    line = vim.api.nvim_get_current_line(),
  }
end

-- Cover the echo of a buffer change we just made. mark_seen is not enough when
-- something else bumps changedtick before our autocmd runs (another TextChangedI
-- listener editing the buffer): the tick no longer matches, the echo looks like
-- typing, and the refetch repaints the chain edit the accept just revealed.
-- The generation stays set through that burst — the echo autocmd clears it on
-- the following schedule, which runs after every event in the burst — with a
-- short fallback so a missing echo cannot mute the next real keystroke.
local function begin_apply(bufnr)
  state.apply_gen = state.apply_gen + 1
  state.apply_finish_queued = false
  local gen = state.apply_gen
  local function finish()
    if state.apply_gen ~= gen then return end
    state.apply_gen = 0
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then mark_seen(bufnr) end
  end
  state.apply_finish = function()
    if state.apply_gen ~= gen or state.apply_finish_queued then return end
    state.apply_finish_queued = true
    vim.schedule(function()
      state.apply_finish_queued = false
      finish()
    end)
  end
  vim.defer_fn(finish, 30)
end

-- Render one edit. If its text simply extends what the user has already typed
-- (prefix equals buffer content from the range start up to the cursor, nothing
-- meaningful after), show it as inline ghost text; otherwise a block diff.
-- Returns false if the edit is a no-op (identical to what's already there).
local function show_edit(edit)
  local bufnr = edit.bufnr
  local start0, end0_excl, lines = edit.start0, edit.end0_excl, edit.lines
  local cur = vim.api.nvim_win_get_cursor(0) -- { row1, col0 }
  local row1, col0 = cur[1], cur[2]
  local text = table.concat(lines, "\n")

  local cur_range = vim.api.nvim_buf_get_lines(bufnr, start0, end0_excl, false)
  if edit.original and not edit.snapshot and not vim.deep_equal(cur_range, edit.original) then
    log("DROP    queued edit conflicts with current text")
    return false
  end
  if vim.deep_equal(cur_range, lines) then return false end -- no-op

  local mode, ghost = "diff", nil
  if start0 <= row1 - 1 and row1 - 1 < end0_excl then
    local old = table.concat(cur_range, "\n")
    local change = text_edit.change(old, text)
    local offset = text_edit.offset(cur_range, row1 - 1 - start0, col0)
    if change.old == "" and change.start == offset and change.text ~= "" then
      mode, ghost = "inline", change.text
    end
  end

  local at = mode ~= "inline" and cursor_at(start0, end0_excl) or nil
  local prev = state.suggestion
  -- Already on screen. A second paint (echo re-anchor, or the same reply
  -- arriving again) clears the hint and draws it once more.
  if
    prev
    and prev.bufnr == bufnr
    and prev.mode == mode
    and prev.at == at
    and prev.start0 == start0
    and prev.end0_excl == end0_excl
    and table.concat(prev.lines, "\n") == text
    and prev.snapshot == buf_text(bufnr)
    and (mode ~= "inline" or (prev.ghost_row == row1 and prev.ghost_col == col0))
  then
    return true
  end

  state.suggestion = {
    bufnr = bufnr,
    start0 = start0,
    end0_excl = end0_excl,
    lines = lines,
    mode = mode,
    at = at,
    ghost_row = row1,
    ghost_col = col0,
    ghost = ghost,
    original = cur_range,
    snapshot = buf_text(bufnr),
    request = edit.request,
    index = edit.index,
    buf_lines = vim.api.nvim_buf_line_count(bufnr), -- re-anchors end0_excl as typing adds lines
  }
  if mode == "inline" then
    preview.inline(bufnr, row1 - 1, col0, ghost)
  else
    -- Advertise <Esc>, not <C-]>: leaving insert already dismisses (the
    -- ModeChanged handler in setup files the rejection), so the label is true
    -- without mapping a key —
    -- and it names the one key every neovim user presses without thinking.
    local label = hints().edit and ((at and "<Tab> accept" or "<Tab> jump") .. " · <Esc> dismiss") or nil
    if #cur_range == 1 and #lines == 1 then
      preview.characters(bufnr, start0, cur_range[1], lines[1], label)
    else
      preview.diff(bufnr, start0, cur_range, lines, label)
    end
  end
  end_loading()
  local rq = edit.request
  if rq and not rq.display_ms then
    rq.display_ms = now_ms() - rq.started
    log(("TIMING  #%d display=%.1fms purpose=%s"):format(rq.id, rq.display_ms, rq.purpose))
  end
  log(("SHOW    %-6s L%d  (%d ln)"):format(mode, start0 + 1, #lines))
  return true
end

-- After applying the current edit, walk to the next one in the chain — locally,
-- no network. Adjust the line numbers of edits below by the applied line delta,
-- jump the cursor there, and render it. This is the "tab, tab, tab" loop.
local function advance_after_apply(applied)
  -- Every accept path lands here — Tab, word-at-a-time, and typing the ghost
  -- out in full — so this is the one place the churn budget refills.
  state.dismissed = 0
  if commit_diff then commit_diff(applied.bufnr) end
  if applied.request and applied.request.prediction then state.prediction = applied.request.prediction end
  local r = applied.request
  if r and not r.cancelled then
    r.expected = buf_text(applied.bufnr)
    r.transforms[#r.transforms + 1] = {
      start0 = applied.start0,
      end0 = applied.end0_excl,
      delta = #applied.lines - (applied.end0_excl - applied.start0),
    }
  end
  local p = state.prediction
  if p and (not p.path or p.path == buf_relpath(applied.bufnr)) and p.line > applied.end0_excl then
    p.line = p.line + #applied.lines - (applied.end0_excl - applied.start0)
  end
  local q = state.queue
  if not q then return end
  local delta = #applied.lines - (applied.end0_excl - applied.start0)
  q.idx = q.idx + 1
  if delta ~= 0 then
    for k = q.idx, #q.list do
      local e = q.list[k]
      if e.start0 >= applied.end0_excl then
        e.start0 = e.start0 + delta
        e.end0_excl = e.end0_excl + delta
      end
    end
  end
  -- Show the next edit in place; the cursor stays put, so the next <Tab> JUMPS
  -- to it (Cursor's cursorAtInlineEdit rule), and the <Tab> after that accepts.
  while q.idx <= #q.list do
    if show_edit(q.list[q.idx]) then return end
    q.idx = q.idx + 1 -- skip no-op edits
  end
  if not (q.request and not q.request.done and not q.request.cancelled) then state.queue = nil end -- retain the append point while the stream is still open
end

local function reject_key(path, edit)
  return path .. "@" .. edit.start0 .. ":" .. table.concat(edit.lines, "\n")
end

-- Lines the user just deleted (the newest diff's "-" lines), for the
-- reverting-user-change heuristic.
local function recently_removed(path)
  local traj = state.dtraj[path]
  if not traj or #traj == 0 then return nil end
  local set = {}
  for line in traj[#traj].diff:gmatch("[^\n]+") do
    if line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then set[line:sub(2)] = true end
  end
  return set
end

-- Cursor-prediction rejection ledger, ported verbatim from their controller:
-- keyed path:line, 30s expiry, at most 5 entries (evict oldest), and a target
-- is only muted once it has been rejected twice (count >= 2).
local PRED_REJECT_TTL, PRED_REJECT_MAX = 30 * 1000, 5

local function pred_key(p) return (p.path or "") .. ":" .. tostring(p.line) end

local function record_pred_reject(p)
  local now = os.time() * 1000
  local r = state.pred_rejects[pred_key(p)]
  if r then
    r.count, r.ts = r.count + 1, now
  else
    state.pred_rejects[pred_key(p)] = { count = 1, ts = now }
  end
  local n, oldest, okey = 0, math.huge, nil
  for k, v in pairs(state.pred_rejects) do
    n = n + 1
    if v.ts < oldest then
      oldest, okey = v.ts, k
    end
  end
  if n > PRED_REJECT_MAX and okey then state.pred_rejects[okey] = nil end
end

local function pred_recently_rejected(p)
  local now = os.time() * 1000
  for k, v in pairs(state.pred_rejects) do
    if now - v.ts > PRED_REJECT_TTL then state.pred_rejects[k] = nil end
  end
  local r = state.pred_rejects[pred_key(p)]
  return r ~= nil and r.count >= 2
end

-- Cursor's hasRejectedTooManySuggestions. The per-suggestion ledger above only
-- catches the model REPEATING itself; this catches it being wrong in a new way
-- every time. Past the budget, stop volunteering — but only on the passive
-- triggers (entering insert, moving to another line). Typing still asks, which
-- is Cursor's split too: their content-change and linter-error paths never
-- consult this gate. Reset by accepting anything, or by leaving the buffer.
--
-- Count explicit dismissals, rather than repainting or retaining a preview.
-- Compatible typing keeps the same edit alive and must not consume this budget.

local function rejected_too_many() return state.dismissed > ((state.cfg and state.cfg.max_cleared) or 20) end

-- Cursor's Escape is TIERED, and the tiers matter: their first press files the
-- suggestion as rejected and deliberately keeps the jump target alive (the
-- handler calls maybeShowHintLineWidget right after); only a second press, with
-- nothing showing, reaches clearCursorPrediction. Collapsing the two would mute
-- jump targets the user never actually said no to.
--
-- Tier 1 — file the visible edit as rejected and clear it. Returns false when
-- there was nothing to reject.
local function reject_suggestion()
  local s = state.suggestion
  if not s then return false end
  local key = reject_key(buf_relpath(s.bufnr) or "", s)
  state.rejects[key] = (state.rejects[key] or 0) + 1
  state.dismissed = state.dismissed + 1
  log(
    ("DISMISS L%d  (rejected ×%d · %d/%s before mute)"):format(
      s.start0 + 1,
      state.rejects[key],
      state.dismissed,
      tostring((state.cfg and state.cfg.max_cleared) or 20)
    )
  )
  clear_suggestion()
  return true
end

-- Tier 2 — reject the jump target itself (30s TTL, muted at 2).
local function reject_prediction(bufnr)
  if not state.prediction then return false end
  record_pred_reject(state.prediction)
  state.prediction = nil
  preview.clear_prediction(bufnr or 0)
  return true
end

-- Paint the "Tab →" hint at the prediction target (Cursor's hint widget).
-- Returns false when there is nothing worth jumping to (no prediction, or it
-- points at the line the cursor is already on).
local function show_prediction()
  local p = state.prediction
  if not (p and p.line) then return false end
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = buf_relpath(bufnr)
  -- painting is optional (show_hints); the jump target itself is not, so the
  -- true/false this returns must stay the same either way
  local paint = hints().prediction
  if not paint then preview.clear_prediction(bufnr) end
  if (not p.path) or p.path == rel then
    local lc = vim.api.nvim_buf_line_count(bufnr)
    local row1 = math.min(math.max(p.line, 1), lc)
    if row1 == vim.api.nvim_win_get_cursor(0)[1] then return false end
    if prefetch_prediction then prefetch_prediction(p) end
    local visible = row1 >= vim.fn.line("w0") and row1 <= vim.fn.line("w$")
    local anchor = visible and row1 - 1 or vim.api.nvim_win_get_cursor(0)[1] - 1
    local snippet = vim.api.nvim_buf_get_lines(bufnr, row1 - 1, row1, false)[1] or ""
    if paint then
      preview.prediction(
        bufnr,
        anchor,
        "<Tab> → L" .. row1 .. (visible and "" or " · " .. snippet:sub(1, 80))
      )
    end
  else
    -- cross-file target: anchor the hint at the cursor, name the destination
    if prefetch_prediction then prefetch_prediction(p) end
    local cur0 = vim.api.nvim_win_get_cursor(0)[1] - 1
    local suffix = p.preview and (" · " .. p.preview) or ""
    local cached = state.prefetch
    if cached and not cached.done then suffix = suffix .. " · loading…" end
    if paint then preview.prediction(bufnr, cur0, ("<Tab> → %s:%d"):format(p.path, p.line) .. suffix) end
  end
  log(("PRED    → %s:%d"):format(p.path or "·", p.line))
  return true
end

-- All stream events enter through a request record, including promoted prefetches.
local function normalize_edit(r, e, index)
  if type(e) ~= "table" or type(e.text) ~= "string" then return nil end
  local range = e.range or { start = r.line + 1, endInclusive = r.line + 1 }
  if
    type(range.start) ~= "number"
    or type(range.endInclusive) ~= "number"
    or range.start % 1 ~= 0
    or range.endInclusive % 1 ~= 0
  then
    return nil
  end
  local first, last = range.start - 1, range.endInclusive
  if first < 0 or last < first or last > #r.source_lines or first > #r.source_lines then
    log("DROP    invalid edit range")
    return nil
  end
  local original = {}
  for i = first + 1, last do
    original[#original + 1] = r.source_lines[i]
  end
  for _, t in ipairs(r.transforms) do
    if first >= t.end0 then
      first, last = first + t.delta, last + t.delta
    elseif last > t.start0 then
      return nil
    end -- overlapping a locally accepted/typed edit
  end
  local have = vim.api.nvim_buf_get_lines(r.bufnr, first, last, false)
  if not vim.deep_equal(have, original) then
    log("DROP    edit content conflict")
    return nil
  end
  local lines = e.text == "" and last > first and {} or text_edit.lines(e.text)
  return {
    bufnr = r.bufnr,
    start0 = first,
    end0_excl = last,
    lines = lines,
    original = original,
    request = r,
    index = index,
  }
end

local function display_pending(r)
  if r.cancelled or r ~= state.req or not suggestion_mode() or vim.api.nvim_get_current_buf() ~= r.bufnr then
    return
  end
  if buf_text(r.bufnr) ~= r.expected then
    cancel_request(r, "snapshot changed")
    return
  end
  local q = state.queue
  if not q or q.request ~= r then
    clear_suggestion()
    q = { list = {}, idx = 1, request = r }
    state.queue = q
  end
  while r.events[r.next_index] do
    local index = r.next_index
    r.next_index = index + 1
    local e = normalize_edit(r, r.events[index], index)
    if e then
      local why = heuristics.should_suppress(state.cfg.heuristics, {
        bufnr = r.bufnr,
        start0 = e.start0,
        end0_excl = e.end0_excl,
        lines = e.lines,
        recently_removed = recently_removed(r.path),
        rejections = state.rejects,
        key = reject_key(r.path, e),
        hard_reject = state.cfg.reject_hard,
      })
      if why then
        state.last_suppressed = why
        log("SUPPRESS " .. why)
      else
        q.list[#q.list + 1] = e
      end
    end
  end
  if state.suggestion then return end
  while q.idx <= #q.list do
    if show_edit(q.list[q.idx]) then return end
    q.idx = q.idx + 1
  end
  if r.done then
    state.queue = nil
    end_loading()
  end
  if r.prediction and not pred_recently_rejected(r.prediction) then
    state.prediction = r.prediction
    show_prediction()
  elseif r.done then
    log("NOOP    stream exhausted")
  end
end

local function handle_result(res)
  local r = state.requests[res.id]
  if not r or r.cancelled then
    log(
      "DROP    invalidated response #"
        .. tostring(res.id)
        .. (
          not suggestion_mode()
            and (state.cfg.normal_mode and " outside enabled modes" or " outside insert")
          or ""
        )
    )
    return
  end
  if res.aborted or res.event == "cancelled" then
    r.cancelled = true
    r.done = true
    if r == state.req then
      state.awaiting = false
      end_loading()
    end
    return
  end
  if res.error then
    r.done = true
    cancel_request(r, "transport error")
    state.last_error = res.error
    log("ERR     #" .. r.id .. " " .. tostring(res.error))
    if r == state.req then
      state.awaiting = false
      end_loading()
    end
    return
  end
  if res.event == "timing" then
    log(
      ("TIMING  #%d headers=%sms first-chunk=%sms"):format(
        r.id,
        tostring(res.headers_ms),
        tostring(res.first_chunk_ms)
      )
    )
    return
  elseif res.event == "edit" then
    if type(res.index) ~= "number" or res.index < 1 or res.index % 1 ~= 0 then return end
    if r.events[res.index] then return end -- duplicate delivery
    r.events[res.index] = res.edit
    if not r.first_edit_ms then
      r.first_edit_ms = now_ms() - r.started
      log(("TIMING  #%d first-edit=%.1fms"):format(r.id, r.first_edit_ms))
    end
  elseif res.event == "prediction" then
    r.prediction = res.prediction
    if r.prediction and (not r.prediction.path or r.prediction.path == r.path) then
      for _, t in ipairs(r.transforms) do
        if r.prediction.line and r.prediction.line > t.end0 then
          r.prediction.line = r.prediction.line + t.delta
        end
      end
    end
  elseif res.event == "done" then
    r.done = true
  elseif not res.event then -- legacy, single-result sidecars
    local edits = res.edits or {}
    if #edits == 0 and (res.range or (res.text or "") ~= "") then
      edits = { { text = res.text, range = res.range } }
    end
    r.events = edits
    r.prediction = res.prediction
    r.done = true
  else
    return
  end
  if r.prediction then r.prediction.workspace = r.workspace end
  state.last_ok_at = os.time()
  if r == state.req then
    if r.prediction and not pred_recently_rejected(r.prediction) then state.prediction = r.prediction end
    state.awaiting = not r.done
    log(("RES     #%d %s"):format(r.id, res.event or "complete"))
    display_pending(r)
  elseif r == state.prefetch and state.prediction and not state.suggestion then
    show_prediction()
  end
end

local function handle_line(line)
  -- luanil so JSON null decodes to nil, not vim.NIL (which is a truthy userdata
  -- and would crash `res.prediction`/`e.range` guards).
  local ok, res = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not (ok and type(res) == "table") then return end
  if res.config then
    apply_config(res.config)
  else
    handle_result(res)
  end
end

local function on_stdout(_, data)
  if not data then return end
  data[1] = state.partial .. (data[1] or "")
  state.partial = table.remove(data) or ""
  for _, l in ipairs(data) do
    l = l:gsub("\r$", "") -- Windows: jobstart splits on \n and leaves the \r
    if l ~= "" then handle_line(l) end
  end
end

local function on_stderr(_, data)
  if not data then return end
  for _, l in ipairs(data) do
    l = l:gsub("\r$", "")
    if l ~= "" then
      if l:find("ready") then
        state.ready = true
        log("SIDECAR ready")
      else
        state.last_stderr = l
        -- Keep a short tail: the sidecar's fatal errors (no Cursor install, not
        -- signed in) are multi-line, and they're all a user gets to debug with.
        table.insert(state.stderr_tail, l)
        if #state.stderr_tail > 20 then table.remove(state.stderr_tail, 1) end
        log("SIDECAR " .. l)
      end
    end
  end
end

function M.start()
  if state.job then return end
  local cmd = vim.deepcopy(state.cfg.sidecar_cmd)
  table.insert(cmd, plugin_root() .. "/sidecar.py")
  state.stderr_tail = {}
  state.job_epoch = (state.job_epoch or 0) + 1
  local epoch = state.job_epoch
  local job = vim.fn.jobstart(cmd, {
    on_stdout = function(...)
      if state.job_epoch == epoch then on_stdout(...) end
    end,
    on_stderr = function(...)
      if state.job_epoch == epoch then on_stderr(...) end
    end,
    on_exit = function()
      if state.job_epoch ~= epoch then return end
      local never_ready = not state.ready
      state.job = nil
      state.ready = false
      state.awaiting = false
      end_loading()
      invalidate("sidecar exited")
      log("SIDECAR exited")
      -- Died during startup: say why instead of going quietly inert.
      if never_ready then
        local why = table.concat(state.stderr_tail, "\n")
        vim.notify(
          "neocursor: sidecar exited during startup" .. (why ~= "" and ("\n" .. why) or ""),
          vim.log.levels.ERROR
        )
      end
    end,
  })
  if job <= 0 then
    vim.notify("neocursor: failed to launch sidecar", vim.log.levels.ERROR)
    log("SIDECAR launch failed")
    return
  end
  state.job = job
  log("SIDECAR launching")
end

-- Gather the proximity context Cursor's native Tab sends as `additionalFiles`:
-- other visible splits (isOpen=true) plus the most-recently-visited buffers
-- (isOpen=false), each reduced to a bounded on-screen/near-cursor slice.
local function collect_additional_files(cur_buf)
  local MAX_FILES, MAX_LINES = 8, 200
  local files, seen = {}, {}

  local function relpath(b)
    local n = vim.api.nvim_buf_get_name(b)
    if n == "" then return nil end
    return vim.fs.normalize(vim.fn.fnamemodify(n, ":."))
  end
  local function usable(b)
    return vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= ""
  end
  local function excluded(path)
    for _, pat in ipairs(state.cfg.exclude_patterns or {}) do
      if path:find(pat, 1, true) then return true end
    end
    return false
  end
  local function push(b, is_open, top, bot, ts)
    local path = relpath(b)
    if not path or excluded(path) or #files >= MAX_FILES then return end
    bot = math.min(bot, top + MAX_LINES - 1)
    local lines = vim.api.nvim_buf_get_lines(b, top - 1, bot, false)
    if #lines == 0 then return end
    seen[b] = true
    files[#files + 1] = {
      path = path,
      is_open = is_open,
      last_viewed_at = ts,
      ranges = { { start = top, stop = top + #lines - 1, content = table.concat(lines, "\n") } },
    }
  end

  -- 1) other visible splits → exactly what's on screen there
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if b ~= cur_buf and not seen[b] and usable(b) then
      push(b, true, math.max(1, vim.fn.line("w0", win)), vim.fn.line("w$", win), state.viewed[b])
    end
  end

  -- 2) recently-visited buffers not on screen → a slice around their last cursor
  local mru = {}
  for b, t in pairs(state.viewed) do
    if b ~= cur_buf and not seen[b] and usable(b) then mru[#mru + 1] = { b = b, t = t } end
  end
  table.sort(mru, function(x, y)
    if x.t == y.t then return x.b < y.b end
    return x.t > y.t
  end)
  for _, e in ipairs(mru) do
    if #files >= MAX_FILES then break end
    local total = vim.api.nvim_buf_line_count(e.b)
    local mark = vim.api.nvim_buf_get_mark(e.b, '"')
    local center = (mark[1] > 0) and mark[1] or 1
    local top = math.max(1, center - math.floor(MAX_LINES / 2))
    push(e.b, false, top, math.min(total, top + MAX_LINES - 1), e.t)
  end

  return files
end

local function cap(s, n)
  if #s > n then return s:sub(1, n) .. "\n… (truncated)" end
  return s
end

-- linterErrors: current-buffer diagnostics → native LinterError shape (0-indexed).
-- vim.diagnostic.severity (ERROR/WARN/INFO/HINT = 1/2/3/4) matches Cursor's enum 1:1.
local SEV = {
  [vim.diagnostic.severity.ERROR] = 1,
  [vim.diagnostic.severity.WARN] = 2,
  [vim.diagnostic.severity.INFO] = 3,
  [vim.diagnostic.severity.HINT] = 4,
}
local function collect_linter_errors(buf, path)
  if not path then return nil end
  local diags = vim.diagnostic.get(buf)
  if #diags == 0 then return nil end
  local errors = {}
  for _, d in ipairs(diags) do
    if #errors >= 30 then break end
    errors[#errors + 1] = {
      message = d.message or "",
      source = d.source,
      severity = SEV[d.severity] or 1,
      range = {
        sl = d.lnum or 0,
        sc = d.col or 0,
        el = d.end_lnum or d.lnum or 0,
        ec = d.end_col or d.col or 0,
      },
    }
  end
  return { path = path, errors = errors }
end

-- diff trajectory: baseline snapshot per buffer; unified diff baseline→current is
-- the edit. commit_diff() coalesces at logical boundaries (leaving insert/BufLeave).
local MAX_TRAJ, DIFF_CAP = 6, 4000

local function ensure_baseline(buf, path)
  if path and not state.dbase[buf] then state.dbase[buf] = { path = path, text = buf_text(buf) } end
end

-- returns (diff_string, current_text) or nil if unchanged
local function buf_diff(buf)
  local b = state.dbase[buf]
  if not b then return nil end
  local cur = buf_text(buf)
  if cur == b.text then return nil end
  -- ctxlen=0: emit ONLY the changed lines, no surrounding context. Cursor's
  -- backend uses diffHistory to locate the in-progress edit; 3 lines of context
  -- (the old default) bury the change and make it mis-locate — on a real file
  -- that silently flips the reply to edits=0. Verified against the live backend:
  -- same request, ctxlen=3 → 0 edits, ctxlen=0 → the correct completion.
  local d = vim.diff(b.text .. "\n", cur .. "\n", { result_type = "unified", ctxlen = 0 })
  if type(d) ~= "string" or d == "" then return nil end
  return cap(d, DIFF_CAP), cur
end

function commit_diff(buf)
  local path = buf_relpath(buf)
  if not path then return end
  local d, cur = buf_diff(buf)
  if not d then return end
  local traj = state.dtraj[path]
  if not traj then
    traj = {}
    state.dtraj[path] = traj
  end
  traj[#traj + 1] = { diff = d, ts = os.time() * 1000 }
  while #traj > MAX_TRAJ do
    table.remove(traj, 1)
  end
  state.dbase[buf] = { path = path, text = cur }
  local paths = {}
  for key, history in pairs(state.dtraj) do
    paths[#paths + 1] = { path = key, ts = history[#history].ts }
  end
  table.sort(paths, function(a, b)
    if a.ts == b.ts then return a.path < b.path end
    return a.ts > b.ts
  end)
  for i = 21, #paths do
    state.dtraj[paths[i].path] = nil
  end
end

local function collect_file_diff_histories(cur_buf, cur_path)
  local by_path = {}
  for path, traj in pairs(state.dtraj) do
    if #traj > 0 then
      local diffs, ts = {}, {}
      for _, e in ipairs(traj) do
        diffs[#diffs + 1] = e.diff
        ts[#ts + 1] = e.ts
      end
      by_path[path] = { file_name = path, diff_history = diffs, diff_history_timestamps = ts }
    end
  end
  -- append the uncommitted in-progress edit of the current file as the newest step
  local d = buf_diff(cur_buf)
  if d and cur_path then
    local rec = by_path[cur_path]
    if not rec then
      rec = { file_name = cur_path, diff_history = {}, diff_history_timestamps = {} }
      by_path[cur_path] = rec
    end
    rec.diff_history[#rec.diff_history + 1] = d
    rec.diff_history_timestamps[#rec.diff_history_timestamps + 1] = os.time() * 1000
  end
  local arr = {}
  for _, rec in pairs(by_path) do
    arr[#arr + 1] = rec
  end
  table.sort(arr, function(a, b) return a.file_name < b.file_name end)
  if #arr == 0 then return nil end
  return arr
end

local function issue_request(buf, content, path, row, col, purpose, workspace)
  state.seq = state.seq + 1
  local r = {
    id = state.seq,
    bufnr = buf,
    source = content,
    expected = content,
    source_lines = text_edit.lines(content),
    path = path,
    line = row,
    col = col,
    purpose = purpose,
    workspace = workspace or vim.fn.getcwd(),
    started = now_ms(),
    events = {},
    next_index = 1,
    transforms = {},
    context_gen = state.context_gen,
  }
  state.requests[r.id] = r
  -- Cancelled and completed records cannot contribute to a future stream.
  for id, previous in pairs(state.requests) do
    if id < r.id - 32 and previous ~= state.req and previous ~= state.prefetch then
      state.requests[id] = nil
    end
  end
  local req = {
    id = r.id,
    path = path,
    content = content,
    line = row,
    col = col,
    purpose = purpose,
    language = buf and vim.bo[buf].filetype or (vim.filetype.match({ filename = path }) or "plaintext"),
    additional_files = collect_additional_files(buf),
    linter_errors = buf and collect_linter_errors(buf, path) or nil,
    file_diff_histories = collect_file_diff_histories(
      vim.api.nvim_get_current_buf(),
      buf_relpath(vim.api.nvim_get_current_buf())
    ),
  }
  vim.fn.chansend(state.job, vim.json.encode(req) .. "\n")
  log(("REQ     #%d %s %s %d:%d"):format(r.id, purpose, path, row, col))
  return r
end

function send_request()
  if not state.job or not suggestion_mode() then return end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then return end
  cancel_request(state.req, "superseded")
  local path = buf_relpath(buf) or "untitled"
  ensure_baseline(buf, buf_relpath(buf))
  commit_diff(buf)
  local cur = vim.api.nvim_win_get_cursor(0)
  state.req = issue_request(buf, buf_text(buf), path, cur[1] - 1, cur[2], "foreground")
  state.awaiting = true
end

function prediction_target(p)
  local path = p.path or buf_relpath(vim.api.nvim_get_current_buf())
  if not path then return nil end
  path = vim.fs.normalize(path)
  local absolute = path:match("^/") or path:match("^%a:/")
  path = vim.fs.normalize(absolute and path or ((p.workspace or vim.fn.getcwd()) .. "/" .. path))
  local buf = vim.fn.bufnr(path)
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then return path, buf, buf_text(buf) end
  if vim.fn.filereadable(path) ~= 1 then return path, nil, nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return path, nil, nil end
  local content = table.concat(lines, "\n")
  if content:find("%z") then return path, nil, nil end
  return path, nil, content
end

function prefetch_prediction(p)
  if not state.cfg.prefetch or not state.job or (state.req and not state.req.done) then return end
  local path, buf, content = prediction_target(p)
  if not content then return end
  local row = math.min(math.max(p.line, 1), #text_edit.lines(content)) - 1
  local cached = state.prefetch
  if
    cached
    and not cached.cancelled
    and cached.target == path
    and cached.line == row
    and cached.source == content
    and cached.context_gen == state.context_gen
  then
    local first = cached.events[1]
    p.preview = ((first and first.text) or text_edit.lines(content)[row + 1] or ""):match("[^\n]*"):sub(1, 80)
    return
  end
  cancel_request(cached, "new destination")
  local line = text_edit.lines(content)[row + 1] or ""
  p.preview = line:sub(1, 80)
  local r = issue_request(
    buf,
    content,
    p.path or buf_relpath(buf),
    row,
    (line:find("%S") or (#line + 1)) - 1,
    "prefetch",
    p.workspace
  )
  r.target = path
  state.prefetch = r
  log("PREFETCH miss; preparing destination")
end

local function should_attach(bufnr)
  if vim.bo[bufnr].buftype ~= "" then return false end -- skip prompts/terminals/nofile
  local fts = state.cfg.filetypes
  if fts and #fts > 0 and not vim.tbl_contains(fts, vim.bo[bufnr].filetype) then return false end
  return true
end

local function cancel_timer()
  -- Bump even when no timer is stored: the uv callback may already have queued
  -- its vim.schedule send, and stopping the handle does not dequeue that.
  state.timer_gen = state.timer_gen + 1
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- keep=true leaves an existing preview visible until a fresh request resolves.
function schedule_request(keep)
  if not should_attach(vim.api.nvim_get_current_buf()) then return end
  if not keep then clear_suggestion() end
  cancel_timer()
  local gen = state.timer_gen
  state.timer = uv.new_timer()
  state.timer:start(
    state.cfg.debounce,
    0,
    vim.schedule_wrap(function()
      if gen ~= state.timer_gen then return end -- cancelled after the callback was queued
      cancel_timer()
      send_request()
    end)
  )
end

-- Compatible typing updates the remaining edit locally. Unrelated changes
-- rebase its range; conflicting changes discard it and request a fresh edit.
local function try_retain()
  local s = state.suggestion
  if not s or vim.api.nvim_get_current_buf() ~= s.bufnr then return false end
  local current = buf_text(s.bufnr)
  if current == s.snapshot then return "shown" end
  local before = text_edit.lines(s.snapshot)
  local change = text_edit.change(s.snapshot, current)
  local first = text_edit.offset(before, s.start0, 0)
  local finish = s.end0_excl >= #before and #s.snapshot or text_edit.offset(before, s.end0_excl, 0)
  local oldrow = select(1, text_edit.position(s.snapshot, change.finish))
  local newrow = select(1, text_edit.position(current, change.start + #change.text))
  local delta = newrow - oldrow
  local before_region = change.finish < first or (change.finish == first and change.text:sub(-1) == "\n")
  local outside = before_region or (change.start >= finish and s.end0_excl < #before)
  if not outside then
    local target = table.concat(text_edit.replace(before, s.start0, s.end0_excl, s.lines), "\n")
    if not text_edit.compatible(s.snapshot, current, target) then return false end
  end
  local q = state.queue
  if q then
    for k = q.idx, #q.list do
      local e = q.list[k]
      if e.start0 >= oldrow + 1 then
        e.start0, e.end0_excl = e.start0 + delta, e.end0_excl + delta
      elseif e == q.list[q.idx] and not outside then
        e.end0_excl = e.end0_excl + delta
      end
    end
  end
  if before_region then
    s.start0, s.end0_excl = s.start0 + delta, s.end0_excl + delta
  elseif not outside then
    s.end0_excl = s.end0_excl + delta
  end
  if s.request then
    s.request.expected = current
    s.request.transforms[#s.request.transforms + 1] =
      { start0 = select(1, text_edit.position(s.snapshot, change.start)), end0 = oldrow + 1, delta = delta }
  end
  if not show_edit(s) then
    preview.clear(s.bufnr)
    state.suggestion = nil
    log("CONSUME L" .. (s.start0 + 1) .. " typed through")
    advance_after_apply(s)
    if state.suggestion or show_prediction() then return "shown" end
    if state.queue and state.queue.request and not state.queue.request.done then
      begin_loading(s.bufnr)
      return "shown"
    end
    return nil
  end
  return "shown" -- compatible typing requires no replacement request
end

-- Cursor moves made while an expr mapping evaluates are silently REVERTED when
-- the evaluation ends (:h expr-mapping "the cursor position is restored") —
-- blink/cmp integrations call M.accept() from exactly such mappings, and nvim
-- restores the cursor even though it now permits the buffer edit itself. So:
-- move synchronously (correct for our own callback mapping), then verify one
-- tick later — post-eval, where moving is legal — and re-apply if it was undone.
local function enforce_cursor(bufnr, pos)
  vim.schedule(function()
    if vim.api.nvim_get_current_buf() ~= bufnr then return end
    local cur = vim.api.nvim_win_get_cursor(0)
    if cur[1] ~= pos[1] or cur[2] ~= pos[2] then
      pcall(vim.api.nvim_win_set_cursor, 0, pos)
      mark_seen(bufnr) -- the enforced move fires its own echo; swallow it too
    end
  end)
end

-- Apply the edit under the cursor, then reveal the next one in the chain — all
-- synchronously, so a rapid tab-tab-tab can never slip a literal <Tab> into the
-- buffer between apply and re-render. The cursor stays at the applied edit; the
-- next <Tab> JUMPS to the revealed one (Cursor's cursorAtInlineEdit rule).
local function do_accept(s)
  if not vim.api.nvim_buf_is_valid(s.bufnr) then return end
  if buf_text(s.bufnr) ~= s.snapshot then
    invalidate("accept snapshot changed")
    clear_suggestion()
    schedule_request()
    return
  end
  preview.clear(s.bufnr)
  state.suggestion = nil
  cancel_timer() -- a request scheduled before the accept would race the chain
  vim.cmd("let &g:undolevels=&g:undolevels") -- one undo reverts the whole accept
  begin_apply(s.bufnr)
  local lc = vim.api.nvim_buf_line_count(s.bufnr)
  -- A range that starts past EOF is an append. Clamping both ends keeps
  -- set_lines from seeing start > end, and puts the cursor on the new text.
  local from = math.min(s.start0, lc)
  local to = math.min(math.max(s.end0_excl, from), lc)
  local before = vim.api.nvim_buf_get_lines(s.bufnr, 0, -1, false)
  local target = table.concat(text_edit.replace(before, from, to, s.lines), "\n")
  local patches = text_edit.patches(s.snapshot, target)
  local cur = vim.api.nvim_win_get_cursor(0)
  local original_offset = text_edit.offset(before, cur[1] - 1, cur[2])
  local offset, delta = original_offset, 0
  for _, change in ipairs(patches) do
    if original_offset >= change.start and original_offset <= change.finish then
      offset = change.start + delta + #change.text
      break
    elseif original_offset > change.finish then
      delta = delta + #change.text - (change.finish - change.start)
      offset = original_offset + delta
    end
  end
  for i = #patches, 1, -1 do
    local change = patches[i]
    local sr, sc = text_edit.position(s.snapshot, change.start)
    local er, ec = text_edit.position(s.snapshot, change.finish)
    if i < #patches then vim.cmd("undojoin") end
    vim.api.nvim_buf_set_text(s.bufnr, sr, sc, er, ec, text_edit.lines(change.text))
  end
  local row, col = text_edit.position(target, offset)
  local pos = { row + 1, col }
  pcall(vim.api.nvim_win_set_cursor, 0, pos)
  mark_seen(s.bufnr)
  advance_after_apply(s) -- local; no network
  enforce_cursor(s.bufnr, pos)
  if not state.suggestion then
    -- chain done: hand Tab over to the cursor prediction if the server sent
    -- one (Cursor's maybeShowHintLineWidget + retrigger-on-accept); otherwise
    -- just fetch a fresh suggestion here
    if state.queue and state.queue.request and not state.queue.request.done then
      begin_loading(s.bufnr)
    elseif not show_prediction() then
      state.prediction = nil
      schedule_request()
    end
  end
end

-- Move the cursor onto the edit (local, instant). This flips cursorAtInlineEdit
-- true, so the NEXT <Tab> accepts. Preview stays; its hint refreshes to "accept".
local function do_jump(s)
  if not vim.api.nvim_buf_is_valid(s.bufnr) then return end
  local lc = vim.api.nvim_buf_line_count(s.bufnr)
  local pos = { math.min(s.start0 + 1, lc), 0 }
  vim.api.nvim_win_set_cursor(0, pos)
  show_edit(s)
  mark_seen(s.bufnr)
  enforce_cursor(s.bufnr, pos)
end

-- Our own <Tab> mapping runs free of textlock, so fn runs synchronously. An
-- expr-map integrator (blink/cmp fallback chains) calls M.accept() under
-- textlock, where buffer/cursor changes throw — retry those once, deferred.
local function run_or_defer(fn, s)
  local ok, err = pcall(fn, s)
  if not ok then
    local msg = tostring(err)
    if msg:find("E565") or msg:find("E523") or msg:find("textlock") then
      local pending = {}
      state.deferred_apply = pending
      vim.schedule(function()
        if state.deferred_apply ~= pending then return end
        local ok2, err2 = pcall(fn, s)
        if state.deferred_apply == pending then state.deferred_apply = nil end
        if not ok2 then log("ERR     apply failed: " .. tostring(err2)) end
      end)
    else
      log("ERR     apply failed: " .. msg)
    end
  end
end

-- Jump to the server's predicted next location (Cursor's tabToLineBefore-
-- AcceptingCpp): m' first so <C-o>/'' goes back, land at the line's first
-- non-blank column, then retrigger immediately — the next suggestion appears
-- at the landing point with no debounce. Cross-file targets open the file.
local function do_accept_prediction(p)
  local path, target_buf, content = prediction_target(p)
  if not content then
    invalidate("missing destination")
    state.last_error = "Cannot open predicted file: " .. tostring(path)
    log("ERR     " .. state.last_error)
    state.prediction = nil
    preview.clear_prediction(0)
    vim.notify("neocursor: " .. state.last_error, vim.log.levels.WARN)
    return
  end
  local cached = state.prefetch
  local hit = cached
    and not cached.cancelled
    and cached.target == path
    and cached.source == content
    and cached.context_gen == state.context_gen
  preview.clear_prediction(0)
  state.prediction = nil
  cancel_timer()
  cancel_request(state.req, "jump")
  pcall(vim.cmd, "normal! m'")
  state.jumping = true
  -- hide preserves an unsaved source buffer without writing or discarding it.
  local ok, err = true, nil
  if target_buf ~= vim.api.nvim_get_current_buf() then
    if target_buf then
      ok, err = pcall(vim.cmd, "hide buffer " .. target_buf)
    else
      ok, err = pcall(vim.cmd, "hide edit " .. vim.fn.fnameescape(path))
    end
  end
  state.jumping = false
  if not ok then
    state.last_error = tostring(err)
    log("ERR     jump " .. tostring(err))
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local row = math.min(math.max(p.line, 1), vim.api.nvim_buf_line_count(buf))
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local pos = { row, (line:find("%S") or (#line + 1)) - 1 }
  vim.api.nvim_win_set_cursor(0, pos)
  mark_seen(buf)
  enforce_cursor(buf, pos)
  clear_suggestion()
  state.prefetch = nil
  if hit and buf_text(buf) == cached.source then
    cached.bufnr = buf
    cached.purpose = "foreground"
    state.req = cached
    state.awaiting = not cached.done
    log("PREFETCH hit; promoted destination")
    display_pending(cached)
  else
    cancel_request(cached, "cache invalid at jump")
    send_request()
  end
  if not state.suggestion and state.awaiting then begin_loading(buf) end
  log(("PREDGO  %s:%d"):format(path, row))
end

-- Cursor's shouldTabInsteadOfAccepting: on a blank line, Tab should indent,
-- not accept — but only for non-fused models (their check), and never for an
-- inline ghost sitting right at the cursor.
local function tab_should_indent(s)
  if vim.api.nvim_get_mode().mode == "n" then return false end
  if state.cfg.is_fused ~= false then return false end
  if s.mode == "inline" then return false end
  return vim.api.nvim_get_current_line():match("^%s*$") ~= nil
end

-- <Tab> handler, Cursor's full priority order: pending edit (jump-first,
-- accept-second) → cursor prediction jump → nothing (caller falls back to a
-- literal tab). Returns true when Tab was consumed.
function M.accept()
  if state.deferred_apply then return true end
  if
    state.loading
    and state.loading.bufnr == vim.api.nvim_get_current_buf()
    and now_ms() < state.loading.until_ms
    and not state.suggestion
  then
    log("TAB     consumed while destination loads")
    return true
  end
  local s = state.suggestion
  if s then
    if vim.api.nvim_get_current_buf() ~= s.bufnr then
      clear_suggestion() -- suggestion belongs to another buffer; Tab stays a tab
      return false
    end
    if cursor_at(s.start0, s.end0_excl) then
      if tab_should_indent(s) then return false end
      log("ACCEPT  L" .. (s.start0 + 1))
      run_or_defer(do_accept, s)
    else
      log("JUMP    L" .. (s.start0 + 1))
      run_or_defer(do_jump, s)
    end
    return true
  end
  local p = state.prediction
  if p then
    run_or_defer(do_accept_prediction, p)
    return true
  end
  return false
end

-- Accept only the next word of an inline ghost (Cursor's acceptCppPartial):
-- insert the fragment, shrink the ghost in place, and when the last fragment
-- lands, walk the chain exactly like a full accept.
local function do_accept_partial(s)
  if not vim.api.nvim_buf_is_valid(s.bufnr) or buf_text(s.bufnr) ~= s.snapshot then
    invalidate("partial accept snapshot changed")
    clear_suggestion()
    schedule_request()
    return
  end
  cancel_timer()
  local bufnr = s.bufnr
  local cur = vim.api.nvim_win_get_cursor(0)
  local row1, col0 = cur[1], cur[2]
  local ok, prefix_lines = pcall(vim.api.nvim_buf_get_text, bufnr, s.start0, 0, row1 - 1, col0, {})
  if not ok then return end
  local text = table.concat(s.lines, "\n")
  local prefix = table.concat(prefix_lines, "\n")
  if text:sub(1, #prefix) ~= prefix then return end
  local ghost = s.ghost or text:sub(#prefix + 1)
  if ghost == "" then return end
  -- next word = leading blanks + one non-blank run; a leading newline is taken
  -- alone with its indentation (accepting the line break)
  local frag = ghost:match("^\n%s*") or ghost:match("^%s*[^%s]+") or ghost
  local flines = vim.split(frag, "\n", { plain = true })
  vim.cmd("let &g:undolevels=&g:undolevels")
  begin_apply(bufnr)
  vim.api.nvim_buf_set_text(bufnr, row1 - 1, col0, row1 - 1, col0, flines)
  local nrow1 = row1 + #flines - 1
  local ncol = #flines > 1 and #flines[#flines] or (col0 + #frag)
  pcall(vim.api.nvim_win_set_cursor, 0, { nrow1, ncol })
  mark_seen(bufnr)
  local lc = vim.api.nvim_buf_line_count(bufnr)
  local delta = lc - (s.buf_lines or lc)
  if delta ~= 0 then
    s.end0_excl = s.end0_excl + delta
    if state.queue then
      for k = state.queue.idx + 1, #state.queue.list do
        local e = state.queue.list[k]
        if e.start0 >= s.end0_excl - delta then
          e.start0, e.end0_excl = e.start0 + delta, e.end0_excl + delta
        end
      end
    end
  end
  if s.request then
    s.request.expected = buf_text(bufnr)
    s.request.transforms[#s.request.transforms + 1] = { start0 = row1 - 1, end0 = row1, delta = delta }
  end
  log(("PARTIAL L%d  +%d ch"):format(s.start0 + 1, #frag))
  if not show_edit(s) then -- ghost fully consumed: behaves like a full accept
    preview.clear(bufnr)
    state.suggestion = nil
    advance_after_apply(s)
    if not state.suggestion then
      if state.queue and state.queue.request and not state.queue.request.done then
        begin_loading(bufnr)
      elseif not show_prediction() then
        state.prediction = nil
        schedule_request()
      end
    end
  end
  enforce_cursor(bufnr, { nrow1, ncol })
end

function M.accept_partial()
  if state.deferred_apply then return true end
  local s = state.suggestion
  if not (s and s.mode == "inline" and vim.api.nvim_get_current_buf() == s.bufnr) then return false end
  run_or_defer(do_accept_partial, s)
  return true
end
function M.has_prediction() return state.prediction ~= nil end

-- exposed for test/hints_spec.lua; pure, no state
M._normalize_hints = normalize_hints
-- exposed for test/modes_spec.lua: the event log, oldest first, so a round can
-- assert *why* a suggestion is gone (DISMISS vs DROP), not just that it is
function M._log_lines() return vim.deepcopy(state.log) end

-- Dismiss without leaving insert mode. <Esc> does the same thing and then exits
-- insert; this is the variant for when you want to keep typing. <C-]> is the
-- key copilot.vim, copilot.lua and avante.nvim all use for it.
function M.dismiss()
  local bufnr = vim.api.nvim_get_current_buf()
  end_loading()
  invalidate("dismiss")
  -- tier 1 first, tier 2 only when there was no edit to dismiss — press it
  -- twice to clear an edit and then its jump target, exactly like Cursor.
  if not reject_suggestion() then reject_prediction(bufnr) end
  cancel_timer() -- a request already in the debounce would repaint what we just cleared
end

function M.log()
  if not (state.log_buf and vim.api.nvim_buf_is_valid(state.log_buf)) then
    state.log_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.log_buf].bufhidden = "hide"
    vim.bo[state.log_buf].filetype = "neocursorlog"
    pcall(vim.api.nvim_buf_set_name, state.log_buf, "neocursor://log")
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == state.log_buf then
      vim.api.nvim_win_close(win, true) -- toggle off if already open
      return
    end
  end
  vim.cmd("botright 20split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.log_buf)
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].wrap = false, false, false
  log_refresh()
  vim.cmd("wincmd p") -- keep focus where the user was typing
end
function M.has_suggestion() return state.suggestion ~= nil end
function M.suggest() send_request() end -- manual trigger (:NeocursorSuggest)

-- Kill the sidecar and reset transient state. Lets setup() be re-run with a
-- different sidecar_cmd (specs swap in a canned sidecar mid-session).
function M.stop()
  end_loading()
  invalidate("stop")
  state.prediction = nil
  preview.clear_prediction(0)
  if state.job then
    state.job_epoch = (state.job_epoch or 0) + 1
    vim.fn.jobstop(state.job)
    state.job = nil
  end
  state.ready = false
  state.partial = ""
  state.protocol = 1
  state.req = nil
  state.requests = {}
  state.seen = nil
  state.apply_gen = 0
  cancel_timer()
  clear_suggestion()
end

function M.setup(opts)
  opts = opts or {}
  for _, key in ipairs({ "debounce", "jump_loading_timeout" }) do
    local value = opts[key]
    assert(
      value == nil or (type(value) == "number" and value >= 0 and value < math.huge),
      "neocursor: " .. key .. " must be a finite non-negative number"
    )
  end
  state.cfg = {
    debounce = opts.debounce or 250,
    explicit_debounce = opts.debounce ~= nil,
    prefetch = opts.prefetch ~= false,
    jump_loading_timeout = opts.jump_loading_timeout or 1000,
    sidecar_cmd = opts.sidecar_cmd or { "uv", "run", "--with", "httpx[http2]" },
    normal_mode = opts.normal_mode == true,
    map_tab = opts.map_tab ~= false, -- set false when another plugin (cmp) owns <Tab>
    filetypes = opts.filetypes, -- optional allow-list; nil = all normal buffers
    show_hints = normalize_hints(opts.show_hints), -- display-only chrome; see normalize_hints
    exclude_patterns = {}, -- filled from CppConfig (skip .env/.pem/... as context)
    heuristics = {}, -- filled from CppConfig (active suppression rules)
    reject_hard = 2,
    max_cleared = 20, -- CppConfig maxNumberOfClearedSuggestionsSinceLastAccept
    is_fused = nil, -- CppConfig isFusedCursorPredictionModel (nil = unknown)
    map_partial = opts.map_partial ~= false
        and (type(opts.map_partial) == "string" and opts.map_partial or "<M-Right>")
      or nil,
  }
  ensure_baseline(vim.api.nvim_get_current_buf(), buf_relpath(vim.api.nvim_get_current_buf()))
  M.start()

  local grp = vim.api.nvim_create_augroup("neocursor", { clear = true })
  local change_events = { "TextChangedI", "TextChangedP", "CursorMovedI" }
  if state.cfg.normal_mode then vim.list_extend(change_events, { "TextChanged", "CursorMoved" }) end
  local function on_change(args)
    if not suggestion_mode() then return end
    local buf = vim.api.nvim_get_current_buf()
    local cur = vim.api.nvim_win_get_cursor(0)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    -- Our own apply. Swallow it even when the tick no longer matches mark_seen,
    -- and drop the guard only after this whole burst (a listener ahead of us
    -- may edit the buffer and queue more TextChangedI before we return).
    if state.apply_gen ~= 0 then
      if args.event == "TextChangedI" or args.event == "TextChangedP" or args.event == "TextChanged" then
        state.last_edit_at = os.time()
      end
      state.last_line = cur[1]
      state.seen = {
        buf = buf,
        tick = tick,
        row = cur[1],
        col = cur[2],
        line = vim.api.nvim_get_current_line(),
      }
      if state.apply_finish then state.apply_finish() end
      return
    end
    local seen = state.seen
    local cur_line = vim.api.nvim_get_current_line()
    state.seen = { buf = buf, tick = tick, row = cur[1], col = cur[2], line = cur_line }
    -- identical state = the echo of our own apply/jump, or the second of the
    -- two events one keystroke fires — nothing actually happened
    if seen and seen.buf == buf and seen.tick == tick and seen.row == cur[1] and seen.col == cur[2] then
      return
    end
    local prev_line = state.last_line
    state.last_line = cur[1]
    -- Tick moved, cursor and this line did not. autoread/checktime does this
    -- (updatetime writes the file, then reloads it): changedtick bumps, the
    -- bytes do not. Treating that as typing clears the suggestion and paints
    -- the same reply again.
    if
      seen
      and seen.buf == buf
      and seen.row == cur[1]
      and seen.col == cur[2]
      and seen.line == cur_line
      and args.event ~= "TextChanged"
      and state.suggestion
      and state.suggestion.bufnr == buf
      and state.suggestion.snapshot == buf_text(buf)
    then
      return
    end
    -- A real text edit is authoritatively the TextChangedI event (Cursor's
    -- onDidChangeContent → lastEditTime). The tick heuristic below can't tell
    -- a genuine edit from a buffer switch, so the reading-code clock keys off
    -- the event name instead.
    if args.event == "TextChangedI" or args.event == "TextChangedP" or args.event == "TextChanged" then
      state.last_edit_at = os.time()
    end
    local typed = not seen or seen.buf ~= buf or seen.tick ~= tick
    if typed then
      state.viewed[buf] = os.time() * 1000
      end_loading()
      invalidate("buffer edit", true)
      local retained = try_retain()
      if retained == "shown" then
        cancel_timer() -- chain (or its jump target) is already showing
      else
        cancel_request(state.req, "incompatible typing")
        state.prediction = nil
        preview.clear_prediction(buf)
        schedule_request() -- deviated from the suggestion: clear and refetch
      end
    else
      end_loading()
      -- Pure cursor movement. Cursor's onDidChangeCursorPosition fires a
      -- request ONLY on a line change, and never while "reading code" (no
      -- edit in the last 60s) — a within-line move or idle navigation sends
      -- nothing. A visible suggestion is kept alive across moves (its hint is
      -- re-anchored), matching Cursor keeping the inline edit as a jump target.
      local s = state.suggestion
      if s and vim.api.nvim_get_current_buf() == s.bufnr then
        show_edit(s) -- re-anchor the jump⇄accept hint; no new request while shown
      else
        local line_changed = prev_line ~= cur[1]
        local reading = not state.last_edit_at or (os.time() - state.last_edit_at) >= 60
        if line_changed and not reading and not rejected_too_many() then schedule_request() end
      end
    end
  end
  vim.api.nvim_create_autocmd(change_events, { group = grp, callback = on_change })
  local function attach(buf)
    if state.attached[buf] or vim.bo[buf].buftype ~= "" then return end
    state.attached[buf] = true
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        if state.buffer_callbacks[buf] then return end
        state.buffer_callbacks[buf] = true
        vim.schedule(function()
          state.buffer_callbacks[buf] = nil
          if vim.api.nvim_buf_is_valid(buf) and buf == vim.api.nvim_get_current_buf() then
            on_change({
              buf = buf,
              event = vim.api.nvim_get_mode().mode == "n" and "TextChanged" or "TextChangedI",
            })
          else
            invalidate("context buffer changed", true)
          end
        end)
      end,
      on_reload = function()
        vim.schedule(function()
          if
            state.req
            and state.req.bufnr == buf
            and vim.api.nvim_buf_is_valid(buf)
            and buf_text(buf) ~= state.req.expected
          then
            invalidate("reload")
            clear_suggestion()
            if buf == vim.api.nvim_get_current_buf() and suggestion_mode() then schedule_request() end
          end
        end)
      end,
      on_detach = function()
        state.attached[buf] = nil
        vim.schedule(function()
          if state.prefetch and state.prefetch.bufnr == buf then invalidate("destination detached", true) end
          if state.req and state.req.bufnr == buf then
            invalidate("source detached")
            clear_suggestion()
          end
        end)
      end,
    })
  end
  state.buffer_callbacks = state.buffer_callbacks or {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then attach(buf) end
  end
  vim.api.nvim_create_autocmd("BufEnter", { group = grp, callback = function(args) attach(args.buf) end })
  local diag_keys = {}
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = grp,
    callback = function(args)
      local key = vim.inspect(vim.diagnostic.get(args.buf))
      if diag_keys[args.buf] == key then return end
      diag_keys[args.buf] = key
      if args.buf == vim.api.nvim_get_current_buf() and suggestion_mode() and not state.suggestion then
        -- LSP diagnostics often arrive just after a keystroke. They do not
        -- invalidate the request's text snapshot: keep that work (and its
        -- debounce deadline) alive. The next request gathers fresh errors.
        if state.timer or (state.req and not state.req.done and not state.req.cancelled) then return end
        schedule_request(true)
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = grp,
    callback = function()
      state.last_line = vim.api.nvim_win_get_cursor(0)[1] -- baseline; first move isn't a "line change"
      if rejected_too_many() then return end -- Cursor gates its EditorChange trigger the same way
      if not state.suggestion then schedule_request(true) end -- keep a live chain on mode switches
    end,
  })
  -- With normal_mode enabled, supported-mode switches keep the preview;
  -- entering another mode clears it without filing a rejection. By default,
  -- leaving insert ends the suggestion. Whether it *counts* depends on how you
  -- left:
  --   "dismiss"  <Esc>, <C-c>, <C-\><C-n> — a "no". Cursor's Escape files a hard
  --              rejection before clearing, so ours must too, or the identical
  --              suggestion returns the moment you re-enter insert.
  --   "detour"   <C-o> — one normal command, then straight back. Not a "no":
  --              the display goes (the command may edit the buffer under it),
  --              but nothing is filed, so the return trip re-offers it.
  --   "buffer"   BufLeave — our analogue of Cursor's onDidBlurEditorText: come
  --              back to a clean slate.
  -- The jump target is dropped every time but NEVER filed as rejected: leaving
  -- insert is a mode change, not a "no" to where the model wanted to send you.
  local function on_leave(buf, how)
    if state.jumping then return end
    end_loading()
    invalidate(
      how
        .. (
          how ~= "buffer" and (state.cfg.normal_mode and " outside enabled modes" or " outside insert") or ""
        )
    )
    commit_diff(buf) -- coalesce the just-finished edit into the trajectory
    cancel_timer() -- don't fire a request for a mode/buffer we just left
    if how == "detour" then
      clear_suggestion()
    else
      reject_suggestion()
    end
    state.prediction = nil
    preview.clear_prediction(buf)
    -- Only a buffer switch resets the churn budget. Merely leaving insert
    -- happens constantly in neovim, and resetting there would defang it.
    if how == "buffer" then state.dismissed = 0 end
  end
  -- ModeChanged, not InsertLeave: <C-c> exits insert WITHOUT firing InsertLeave
  -- (:h i_CTRL-C), which left the suggestion painted in normal mode where no
  -- key could reach it. ModeChanged sees every exit — for an unmapped <C-c>
  -- (an interrupt, not a keypress) Neovim defers it past got_int and fires it
  -- from normal_check, still before any other key is read. The pattern admits
  -- every insert/replace variant as the old mode; the callback then ignores
  -- hops that stay inside insert (i → ic while a completion menu is up, and back).
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = grp,
    pattern = state.cfg.normal_mode and "*:*" or "[iR]*:*",
    callback = function(args)
      local new_mode = vim.v.event.new_mode
      if state.cfg.normal_mode then
        local old_mode = vim.v.event.old_mode
        if suggestion_mode(old_mode) and suggestion_mode(new_mode) then
          if old_mode:match("^[iR]") and (new_mode == "n" or new_mode:match("^ni")) then
            commit_diff(args.buf)
          end
          return -- keep pending previews and replies across insert/normal switches
        end
        if suggestion_mode(new_mode) then
          if not rejected_too_many() then schedule_request(true) end
          return
        end
        if not suggestion_mode(old_mode) then return end
      end
      if new_mode:match("^[iR]") then return end
      on_leave(args.buf, (state.cfg.normal_mode or new_mode:match("^ni")) and "detour" or "dismiss")
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = grp,
    callback = function(args) on_leave(args.buf, "buffer") end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = grp,
    callback = function(args)
      if vim.bo[args.buf].buftype == "" and vim.api.nvim_buf_get_name(args.buf) ~= "" then
        state.viewed[args.buf] = os.time() * 1000
        ensure_baseline(args.buf, buf_relpath(args.buf))
        if not state.jumping and state.cfg.normal_mode and suggestion_mode() and not rejected_too_many() then
          state.last_line = vim.api.nvim_win_get_cursor(0)[1]
          schedule_request(true)
        end
      end
    end,
  })

  if state.cfg.map_tab then
    -- A callback mapping, not an expr map: expr evaluation runs under textlock,
    -- which forces the apply onto the next tick — and a fast tab-tab would slip
    -- a literal <Tab> into the buffer in between. Here the accept is
    -- synchronous; only a no-suggestion Tab falls through.
    vim.keymap.set(state.cfg.normal_mode and { "i", "n" } or "i", "<Tab>", function()
      if M.accept() then return end
      local tab = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
      vim.api.nvim_feedkeys(tab, "n", false)
    end, { desc = "neocursor: accept / jump / literal tab" })
  end

  if state.cfg.map_partial then
    local pkey = state.cfg.map_partial
    vim.keymap.set(state.cfg.normal_mode and { "i", "n" } or "i", pkey, function()
      if M.accept_partial() then return end
      local orig = vim.api.nvim_replace_termcodes(pkey, true, false, true)
      vim.api.nvim_feedkeys(orig, "n", false)
    end, { desc = "neocursor: accept next word of ghost" })
  end

  vim.keymap.set("i", "<C-]>", M.dismiss, { desc = "neocursor: dismiss" })
  if state.cfg.normal_mode then
    vim.keymap.set("n", "<Esc>", function()
      M.dismiss()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    end, { desc = "neocursor: dismiss" })
    vim.schedule(function()
      if suggestion_mode() then schedule_request(true) end
    end)
  end
  vim.api.nvim_create_user_command("NeocursorSuggest", M.suggest, { desc = "request a suggestion now" })
  vim.api.nvim_create_user_command("NeocursorLog", M.log, { desc = "toggle the neocursor live log pane" })

  vim.api.nvim_create_user_command("NeocursorDebug", function()
    local s = state.suggestion
    local dbuf = vim.api.nvim_get_current_buf()
    local dlint = collect_linter_errors(dbuf, buf_relpath(dbuf))
    local dfdh = collect_file_diff_histories(dbuf, buf_relpath(dbuf))
    local lines = {
      "── neocursor debug ──",
      "sidecar job : " .. tostring(state.job) .. (state.ready and "  READY" or "  (no ready signal)"),
      "requests    : seq=" .. tostring(state.seq) .. "  last_ok=" .. tostring(state.last_ok_at or "never"),
      "suggestion  : " .. (s and (s.mode .. "  lines=" .. #s.lines) or "none"),
      "chain       : " .. (state.queue and (state.queue.idx .. "/" .. #state.queue.list) or "none"),
      "config      : debounce="
        .. state.cfg.debounce
        .. "ms  heuristics="
        .. #state.cfg.heuristics
        .. "  excludes="
        .. #state.cfg.exclude_patterns,
      "normal mode : " .. tostring(state.cfg.normal_mode),
      "prefetch    : " .. tostring(state.cfg.prefetch) .. (state.prefetch and " (cached/in flight)" or ""),
      "jump wait   : " .. tostring(state.cfg.jump_loading_timeout) .. "ms",
      "timing      : first edit="
        .. tostring(state.req and state.req.first_edit_ms)
        .. "ms display="
        .. tostring(state.req and state.req.display_ms)
        .. "ms",
      "hints       : edit=" .. tostring(hints().edit) .. "  prediction=" .. tostring(hints().prediction),
      "last suppress: " .. tostring(state.last_suppressed or "none"),
      "dismissed   : "
        .. state.dismissed
        .. "/"
        .. tostring(state.cfg.max_cleared or 20)
        .. (rejected_too_many() and "  (muted — passive triggers off until you accept)" or ""),
      "buffer      : buftype='" .. vim.bo.buftype .. "'  filetype='" .. vim.bo.filetype .. "'",
      "attach ok   : " .. tostring(should_attach(vim.api.nvim_get_current_buf())),
      "ctx files   : " .. tostring(#collect_additional_files(dbuf)),
      "linter errs : " .. tostring(dlint and #dlint.errors or 0),
      "diff files  : " .. tostring(dfdh and #dfdh or 0),
      "last error  : " .. tostring(state.last_error or "none"),
      "last stderr : " .. tostring(state.last_stderr or "none"),
    }
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "neocursor diagnostics" })

  vim.notify(
    "neocursor ready — "
      .. (state.cfg.normal_mode and "normal and insert modes" or "type in insert mode")
      .. "; <Tab> accepts",
    vim.log.levels.INFO
  )
end

return M
