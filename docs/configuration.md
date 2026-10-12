# Configuration

[← back to README](../README.md)

Every option is optional. The [README](../README.md#configuration) has the
summary table; this page is the full reference.

```lua
require("neocursor").setup({
  debounce    = 250, -- omit to use server timing
  prefetch    = true,
  jump_loading_timeout = 1000,
  map_tab     = true,
  normal_mode = false,
  map_partial = "<M-Right>",
  filetypes   = nil,
  show_hints  = true,
  sidecar_cmd = { "uv", "run", "--with", "httpx[http2]" },
})
```

`:NeocursorDebug` prints the resolved configuration, which is the fastest way to
confirm an option actually took effect.

---

## Contents

- [`debounce`](#debounce)
- [`prefetch`](#prefetch)
- [`jump_loading_timeout`](#jump_loading_timeout)
- [`normal_mode`](#normal_mode)
- [`map_tab`](#map_tab)
- [`map_partial`](#map_partial)
- [`filetypes`](#filetypes)
- [`show_hints`](#show_hints)
- [`sidecar_cmd`](#sidecar_cmd)

---

## `debounce`

`number` — default `250`

Milliseconds of idle time before a request goes out.

An explicit value is authoritative. If omitted, neocursor adopts the server's
`CppConfig` timing and uses 250 ms until configuration arrives or if it fails.
Use a non-negative number of milliseconds.

---

## `prefetch`

`boolean` — default `true`

Prepare one predicted destination before you jump. This can increase backend
usage even if you never follow the prediction. Set `false` to request only after
jumping. Foreground typing and speculative work use separate bounded workers;
there is no recursive background prefetch chain.

Loaded buffers supply their unsaved content. Other files are read without
opening a window. Cached edits are validated again at landing. Jumps preserve
unsaved buffers and never write files.

---

## `jump_loading_timeout`

`number` — default `1000`

After an explicit jump, or while awaiting the next edit in a streamed chain,
Tab is consumed for this many milliseconds while the edit loads. A loading hint
appears when prediction hints are enabled. Tab never queues acceptance of an
unseen edit: press it again after the preview appears.

Completion, errors, dismissal, typing or navigation end the loading state early.
After the timeout, normal snippet/indentation fallback resumes; a still-valid
reply may appear later. Set `0` to disable this waiting behavior.

For custom mappings, `accept()` returns `true` while it consumes a loading-state
Tab, while `has_suggestion()` stays `false` until there is an actual edit.

---

## `normal_mode`

`boolean` — default `false`

Set to `true` to request and show suggestions in Normal mode as well as Insert
and Replace modes. Previews and pending replies survive switching between
these modes. Normal-mode edits and buffer entry trigger requests; navigation
uses the same recent-edit and line-change rules as Insert mode.

`<Tab>` accepts or jumps in Normal mode when `map_tab` is enabled. With
`map_tab = false`, map it yourself to `require("neocursor").accept()`.
`<Esc>` in Normal mode dismisses and still performs its usual action; leaving
Insert mode keeps the preview, so press `<Esc>` again to dismiss it.
Visual, operator-pending and command-line modes clear previews and drop replies.

---

## `map_tab`

`boolean` — default `true`

Whether neocursor maps `<Tab>` in Insert mode and, with `normal_mode = true`,
Normal mode.

Set to `false` when nvim-cmp, blink.cmp, or a snippet engine already owns the
key, then call `require("neocursor").accept()` from your own handler. Full
pattern: [Installation](./installation.md#letting-nvim-cmp--blinkcmp-own-tab).

---

## `map_partial`

`string` or `false` — default `"<M-Right>"`

Key for accepting the current suggestion one word at a time, rather than all of
it. Useful when a completion is right for the first few words and wrong after.

Pass a different keystring to remap it, or `false` to leave the key unmapped.

---

## `filetypes`

`string[]` or `nil` — default `nil`

Allow-list of filetypes. `nil` means every normal buffer.

```lua
filetypes = { "python", "lua", "typescript" }
```

Special buffers — anything with a non-empty `buftype`, such as terminals, help
windows and file pickers — are always skipped regardless of this setting.
`:NeocursorDebug` reports `attach ok` for the current buffer.

---

## `show_hints`

`boolean` or `table` — default `true`

Controls the two labels neocursor paints. **Suggestions are never affected** —
ghost text, diffs, and every `<Tab>` behavior are identical either way. This is
purely what you see.

| Surface | Looks like | Marks | Hiding it costs |
|---|---|---|---|
| `edit` | `⟪neocursor · <Tab> accept · <Esc> dismiss⟫` | a pending edit | the diff still shows the change, but `<Esc>` stops advertising itself |
| `prediction` | `⟪<Tab> → L42⟫` | a jump target | the only on-screen sign a jump is queued |

```lua
show_hints = true                     -- default: both visible
show_hints = false                    -- hide both
show_hints = { edit = false }         -- hide the label, keep the jump pill
show_hints = { prediction = false }   -- hide the pill, keep the label
```

An omitted key in the table form defaults to visible, so `{ edit = false }` and
`{ edit = false, prediction = true }` are equivalent.

### Before you hide the prediction pill

The two surfaces are not symmetrical. The `edit` label is mostly decoration —
the diff underneath already tells you what will happen, though the label is also
where `<Esc> dismiss` is advertised. The `prediction` pill is the *only*
indication that a jump is queued; hide it and `<Tab>` will still jump, you just
won't know where until it lands.

If you want a quieter buffer without losing that, hide the label and keep the
pill:

```lua
show_hints = { edit = false }
```

---

## `sidecar_cmd`

`string[]` — default `{ "uv", "run", "--with", "httpx[http2]" }`

How the Python sidecar is launched. The plugin appends the script path, so this
is the prefix — interpreter and dependency handling only.

Override this only for unusual Python setups (a vendored interpreter, an
air-gapped machine with deps pre-installed). If suggestions stop working after
changing it, clear the override and confirm the default works before debugging
further — see [Troubleshooting](./troubleshooting.md#the-sidecar-wont-start).
