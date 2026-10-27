# Paragraphs, media and folds

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
cursor. Press `q` to close it. Missing backends/converters leave the Markdown
readable; the manual command and health checks explain missing dependencies.
This integration does not implement animated video playback.

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

The side preview has buffer-local `za` and `<CR>` mappings. Code blocks start
expanded. Obsidian callouts beginning with `> [!NOTE]-` start collapsed;
`> [!NOTE]+` starts expanded. `<details>` starts collapsed unless it has an
`open` attribute. A `<summary>` on the opening line or following line supplies
its title. Nested details are supported. Toggle state follows inserted lines
using buffer-local extmark anchors and is released on buffer wipe/setup.

## ACP tables

ACP transcripts often indent each source row by one space. Wrapped virtual
table rows retain this prefix, matching source-based rows, delimiter and outer
borders. `tests/terminal_compat.py` checks a Japanese comparison table with long
GitHub URLs at `conceallevel=3` through stock tmux and Kitty's VT parser, plus
paragraph restoration and folding. It does not establish GPU/font appearance
or support on every terminal.
