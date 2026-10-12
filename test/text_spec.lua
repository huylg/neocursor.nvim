vim.opt.rtp:prepend(vim.fn.getcwd())
local text = require("neocursor.text")
local function apply(old, new)
  local patched = old
  local edits = text.patches(old, new)
  for i = #edits, 1, -1 do
    local p = edits[i]
    assert(old:sub(p.start + 1, p.finish) == p.old)
    patched = patched:sub(1, p.start) .. p.text .. patched:sub(p.finish + 1)
  end
  assert(patched == new, vim.inspect({ old = old, new = new, patched = patched, edits = edits }))
end
for _, pair in ipairs({
  { "", "x" },
  { "x", "" },
  { "abc", "abc" },
  { "a b c", "A b C" },
  { 'local cafe = "茶"', 'local café = "茶"' },
  { "😃aaa\nb", "😄a\nβ" },
  { "x\nremove\ny", "x\ny" },
  { "foo()", "foo(argument)" },
  { "a", "\na\n" },
}) do
  apply(pair[1], pair[2])
end
math.randomseed(12)
local alphabet = { "a", "b", "c", "\n", "é", "茶", "😃" }
for _ = 1, 250 do
  local a, b = {}, {}
  for _ = 1, math.random(0, 35) do
    a[#a + 1] = alphabet[math.random(#alphabet)]
  end
  for _ = 1, math.random(0, 35) do
    b[#b + 1] = alphabet[math.random(#alphabet)]
  end
  apply(table.concat(a), table.concat(b))
end
assert(text.compatible("old_name", "n_name", "new_name"))
assert(not text.compatible("old_name", "WRONG_name", "new_name"))
assert(#text.patches("a unchanged b", "A unchanged B") == 2)
print("ALL PASS: UTF-8 patches, disjoint edits, deletion and shortest-path retention")
vim.cmd("qa!")
