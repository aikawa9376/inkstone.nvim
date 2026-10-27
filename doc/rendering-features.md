# Paragraphs, table views, media, typography and folds

These features render without changing source bytes. Search, yank and save keep
the original Markdown. `:Inkstone disable` restores source rendering.

## Japanese paragraph layout

```lua
require('inkstone').setup({
    paragraph = {
        wrap = true,
        japanese = { enabled = true, budoux = true },
    },
})
```

Top-level paragraphs use the available window width, bundled BudouX phrase
boundaries and basic kinsoku rules. Soft source newlines join with a space for
English; adjacent CJK text joins without adding a space. Two trailing spaces or
a trailing backslash preserve an explicit line break. Inline highlights, links
and inline code keep their rendered decorations. Width and layout are rebuilt
on resize. The original paragraph returns when the cursor enters any of its
source rows, even with `anti_conceal.enabled = false`; leaving it restores the
layout. The side preview can show the rendered paragraph while the source is
being edited.

`paragraph.wrap = false` restores the previous Neovim wrapping behavior.
Paragraphs inside lists and quotes retain their existing layout. Paragraphs
containing image anchors or externally converted math retain source-row layout
so their image/math placements remain anchored correctly. Very narrow windows
fall back to source display. This is not full JIS X 4051 conformance.

## Images and diagrams

The optional graphics backend is `folke/snacks.nvim`. Its terminal support and
conversion dependencies apply; run `:checkhealth snacks` and
`:checkhealth inkstone`. Inkstone does not install tools or download packages.

```lua
require('inkstone').setup({
    media = {
        enabled = true,
        images = true,
        mermaid = true,
        plantuml = true,
        max_width = 80,
        max_height = 30,
        timeout = 15000, -- milliseconds
        mermaid_command = { 'mmdc' },
        plantuml_command = { 'plantuml' },
    },
})
```

Inline image syntax such as `![caption](assets/photo.png)` and HTTP(S) image
URLs are supported. Relative files resolve against the source document,
including in `:Inkstone preview`. For unnamed or transcript buffers, the base is
the working directory; set `vim.b.inkstone_root` to override it.

Fences marked `mermaid` or `plantuml` are converted to PNG by the configured
local command. `mmdc` (Mermaid CLI) or PlantUML and their own runtime dependencies
must already be installed. Commands are argument lists and run asynchronously
with a timeout. Output is reused from
`stdpath('cache') .. '/inkstone/media'` (configurable as `media.cache_dir`).
Changing source invalidates the pending placement; disabling rendering or
wiping the buffer closes Inkstone placements and cancels its pending jobs.

Snacks' own document renderer retains ownership of images and Mermaid in
buffers it has already attached to; Inkstone avoids creating duplicate
placements. Its native image configuration then controls those placements.
Use Snacks' `image.doc.enabled = false` if Inkstone should own document media
placements, while leaving the Snacks image backend available. PlantUML is
handled by Inkstone.

`:Inkstone media` opens a floating view for the image or diagram at/before the
cursor. It also recognizes ordinary PDF links such as `[paper](paper.pdf#page=3)`.
The viewport uses ImageMagick (`media.viewer_command = { 'magick' }`); PDF
rasterization also needs its Ghostscript delegate. Keys are `+` / `-` for zoom,
`hjkl` for pan, `0` for fit, `[` / `]` for PDF pages and `q` / Escape to close.
The mouse wheel zooms. Cropping is asynchronous and bounded to the viewport;
later interactions supersede earlier results. The last page stays visible if
page-forward goes past the document. Temporary crops and jobs are released on
close, source wipe, disable and setup. HTTP(S) resources use Snacks' downloader.
Missing backends/converters leave the Markdown readable; the manual command
and health checks explain missing dependencies.
This integration does not implement animated video playback.

## Table / list / chart

Place the cursor in a table and run `:Inkstone toggle_table` to cycle through
table → list → chart → table. `:Inkstone toggle_list` switches between table and
list; `:Inkstone toggle_chart` switches between table and chart. A table without
numeric columns skips the chart during cycling. An explicit chart request
explains why it cannot chart the data.

```lua
require('inkstone').setup({
    pipe_table = {
        view = 'table', -- default view; 'list' / 'chart' also available
        view_max_rows = 1000,
        chart = { kind = 'bar', height = 12 }, -- kind can be 'line'
    },
})
vim.keymap.set('n', '<leader>mv', '<Plug>(InkstoneToggleView)')
vim.keymap.set('n', '<leader>ml', '<Plug>(InkstoneToggleList)')
vim.keymap.set('n', '<leader>mg', '<Plug>(InkstoneToggleChart)')
```

The unified `:Inkstone toggle_view` / `<Plug>(InkstoneToggleView)` action cycles
table views, toggles the containing fold or opens media, in that order. The
side preview maps Enter and `za` to that action. Ordinary source buffers keep
their existing keybindings. `<Plug>(InkstoneToggleTable)` is the table-only cycle.

List view follows LazyAgent's column-name/value cards, preserving rendered
inline chunks and Japanese wrapping. Chart view treats numeric columns as
series and the first nonnumeric column as category labels. Decimal, scientific
notation, correctly grouped thousands, negative/zero values and consistent
unit suffixes are supported. Empty cells, `-` and `—` are gaps. Series with
different units are rejected instead of sharing a misleading axis. Data is
never executed as code.

Charts are generated as SVG, rasterized by `media.chart_command = { 'rsvg-convert' }`
and displayed through Snacks. Without that backend/converter they use text bars.
The alternate view's header remains a visible interaction anchor. Entering a
body source row restores the whole source table for editing and hides its chart;
returning to the header or leaving restores the chosen view. Per-table state
follows row insertions with native extmark anchors and resets on wipe/setup.
Source bytes are unchanged. Views are bounded by `view_max_rows`; source edits
can invalidate a selected table when the whole anchored range is removed.

## Kitty text sizing

Kitty 0.40+ and Neovim 0.12+ can display genuinely larger/smaller text using
[OSC 66](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/). This changes
the displayed text size, with original Markdown retained for editing/yank/save.
Support requires a positive Kitty XTVERSION reply; other terminals and headless
sessions keep normal text and do not reserve extra rows.
While awaiting that reply (up to 1.2 seconds), Inkstone temporarily enables
`ttimeout` and raises `ttimeoutlen` to at least 1200ms so fragmented terminal
responses cannot be mistaken for mapped keys with settings such as
`ttimeoutlen=1`. It restores the previous values after the reply or timeout,
preserving changes made while waiting. Disabling a buffer during the query
still drains the pending reply before releasing this guard.

```lua
require('inkstone').setup({
    typography = {
        enabled = 'auto', -- false disables; :Inkstone typography toggles this buffer
        headings = { 2, 1.5, 1.25, 1, 1, 1 }, -- H1 through H6
        small = 0.8,
    },
})
```

Top-level headings reserve enough rows for their scaled text and wrap to the
available width. Literal single-line `<small>supporting text</small>` spans use
the smaller size. Nested/indented headings and spans already replaced by table
or paragraph layouts retain their existing rendering. Set `paragraph.wrap = false`
when using small spans in long paragraphs. Unrepresentable narrow placements
fall back to normal text. Fractional sizes use the protocol's rational bounds.

Stock tmux works with `set -g allow-passthrough on`. Inkstone reads the pane
offset and top status-bar height and uses standard passthrough; it does not
patch tmux or change its options. Raw text is erased before Neovim redraws and
replayed afterward, with a 250ms recovery tick while placements exist. Floating
windows and popup menus take precedence. Cursor entry restores source text;
disable/setup/wipe stop owned placement timers. This is a terminal text overlay,
so an unrelated repaint can briefly show normal text before recovery. The
terminal tests cover multicell size metadata, tmux refresh, pane offsets, source
restoration and float occlusion; they do not prove every GPU/font combination.

`demo/rich.md` includes a table, image, scaled headings and small text for trying
the views. From this checkout, `nvim --clean -u demo/rich_init.lua demo/rich.md`
starts an isolated demo using already installed parsers and optional Snacks;
it installs nothing and does not alter dotfiles. Enter is the unified action
in this demo. `:checkhealth inkstone` reports typography and converter availability.

## Folding

`:Inkstone toggle_fold` toggles the innermost code fence, callout or `<details>`
block containing the cursor. It changes display state without taking over
Neovim's `foldmethod`, editing source or replacing existing keybindings.

```lua
require('inkstone').setup({
    folds = { enabled = true, code = true, callout = true, details = true },
})
vim.keymap.set('n', '<leader>mf', '<Plug>(InkstoneToggleFold)')
```

The side preview has buffer-local `za` and `<CR>` view actions. Code blocks start
expanded. Obsidian callouts beginning with `> [!NOTE]-` start collapsed;
`> [!NOTE]+` starts expanded. `<details>` starts collapsed unless it has an
`open` attribute. A `<summary>` on the opening line or following line supplies
its title. Nested details are supported. Toggle state follows inserted lines
using buffer-local extmark anchors and is released on buffer wipe/setup.

## ACP tables

When a table contains wrapped replacement rows, entering any row of that table
restores the whole table's source. This removes its virtual rows, table borders
and inline decorations together, so a long link destination cannot mix a raw
source row with the rendered table layout. Moving outside restores the rendered
table. This also applies with `anti_conceal.enabled = false`. While editing,
Neovim's normal source wrapping remains visible; `nowrap` clips source rows.
Source bytes, yank and save are unchanged.

ACP transcripts often indent each source row by one space. Wrapped virtual
table rows retain this prefix, matching source-based rows, delimiter and outer
borders. `tests/terminal_compat.py` checks a Japanese comparison table with long
GitHub URLs at `conceallevel=3` through stock tmux and Kitty's VT parser, plus
paragraph restoration and folding. It does not establish GPU/font appearance
or support on every terminal.
