-- UTF-8-safe text operations shared by retention, rendering and acceptance.
local M = {}
local function chars(s)
  local out = {}
  for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = c
  end
  return out
end

-- Minimal encompassing change; offsets are zero-based bytes, end-exclusive.
function M.change(old, new)
  local a, b = chars(old), chars(new)
  local first, tail = 0, 0
  while first < #a and first < #b and a[first + 1] == b[first + 1] do
    first = first + 1
  end
  while tail < #a - first and tail < #b - first and a[#a - tail] == b[#b - tail] do
    tail = tail + 1
  end
  local prefix = table.concat(a, "", 1, first)
  local removed = table.concat(a, "", first + 1, #a - tail)
  return {
    start = #prefix,
    finish = #prefix + #removed,
    text = table.concat(b, "", first + 1, #b - tail),
    old = removed,
  }
end

local function encoded(s)
  local out = {}
  for _, c in ipairs(chars(s)) do
    out[#out + 1] = (c:gsub(".", function(v) return ("%02x"):format(v:byte()) end))
  end
  return #out == 0 and "" or table.concat(out, "\n") .. "\n"
end

-- Minimal disjoint changes. Encoding codepoints as lines lets native xdiff
-- preserve unchanged spans without splitting UTF-8 sequences (including LF).
function M.patches(old, new)
  local c = M.change(old, new)
  if c.old == "" or c.text == "" then return { c } end
  local a, b = chars(c.old), chars(c.text)
  local offsets = { 0 }
  for i, v in ipairs(a) do
    offsets[i + 1] = offsets[i] + #v
  end
  local patches = {}
  for _, h in
    ipairs(vim.diff(encoded(c.old), encoded(c.text), { result_type = "indices", algorithm = "minimal" }))
  do
    local ai = h[2] == 0 and h[1] or h[1] - 1
    local bi = h[4] == 0 and h[3] + 1 or h[3]
    patches[#patches + 1] = {
      start = c.start + offsets[ai + 1],
      finish = c.start + offsets[ai + h[2] + 1],
      text = table.concat(b, "", bi, bi + h[4] - 1),
      old = table.concat(a, "", ai + 1, ai + h[2]),
    }
  end
  return patches
end

-- Minimum insertion/deletion distance, calculated by Neovim's native diff.
function M.distance(a, b)
  local c = M.change(a, b)
  if c.old == "" then return #chars(c.text) end
  if c.text == "" then return #chars(c.old) end
  local n = 0
  for _, h in
    ipairs(vim.diff(encoded(c.old), encoded(c.text), { result_type = "indices", algorithm = "minimal" }))
  do
    n = n + h[2] + h[4]
  end
  return n
end

function M.compatible(old, current, target)
  return M.distance(old, target) == M.distance(old, current) + M.distance(current, target)
end

function M.position(s, offset)
  local prefix = s:sub(1, offset)
  local _, row = prefix:gsub("\n", "")
  return row, #(prefix:match("[^\n]*$") or "")
end

function M.offset(lines, row, col)
  local n = col
  for i = 1, row do
    n = n + #(lines[i] or "") + 1
  end
  return n
end

function M.replace(lines, first, last, replacement)
  local result = {}
  for i = 1, first do
    result[#result + 1] = lines[i]
  end
  vim.list_extend(result, replacement)
  for i = last + 1, #lines do
    result[#result + 1] = lines[i]
  end
  if #result == 0 then result = { "" } end
  return result
end

function M.lines(s) return vim.split(s, "\n", { plain = true }) end

return M
