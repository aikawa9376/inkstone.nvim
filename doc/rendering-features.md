# Paragraphs, table views, media, typography and folds

These features render without changing source bytes. Search, yank and save keep
the original Markdown. `:Inkstone disable` restores source rendering.

Cursor restoration follows `anti_conceal` for typography,
joined paragraphs, table/list/chart views and replaced formula blocks. With
`anti_conceal.enabled = false`, moving onto their source rows keeps the rendered
view. When enabled, the configured `above`/`below` range restores source as a
whole layout. `disabled_modes` and normal `render_modes` still apply.

## Japanese paragraph layout

```lua
require('inkstone').setup({
    paragraph = {
        wrap = true,
        join = false, -- preserve source newlines; true joins soft newlines
        japanese = { enabled = true, budoux = true },
    },
})
```

Top-level paragraphs use the available window width, bundled BudouX phrase
boundaries and basic kinsoku rules. With the default `wrap = true, join = false`,
source rows remain visible and editable. Inline virtual whitespace fills unused
space at chosen wrap positions; Neovim wraps the following source character.
There are no replacement virtual rows. `gj`/`gk`, `g0`/`g$`, character selection,
mouse positioning and operators use real source positions. `g0yg$` yanks a
screen row; `yy` still yanks the entire logical source line. Virtual whitespace
never enters registers or saved text. Block selection retains Neovim's native
semantics over logical buffer rows.

Native padding stays in place through anti-conceal while rendering is active;
inline Markdown decorations still obey anti-conceal independently. Visual modes
follow `render_modes`. With the ordinary default `{ 'n', 'c', 't' }`, entering
`v`, `V` or block Visual temporarily removes decorations and wrap padding,
restores source window options, and shows the original Markdown. Returning to
Normal restores the rendered layout. Selection and yank use the raw source's
native screen rows while Visual is active, which can differ from BudouX rows.
Explicitly include `v`, `V`, `\22`, or use `render_modes=true` to keep rendering
in those modes. The inherited nofile/preview defaults are `true`; filetype
overrides can restrict them.

Native paragraphs preserve normal rendering in operator-pending and command-line
modes even if `render_modes` omits them. Operators, `:`, `/` and `?` keep their
starting geometry, including accept/cancel. In
particular, an override such as `render_modes = { 'n', 't' }` does not temporarily
remove decorations and reset conceal/wrap options during command/search input.
Anti-conceal still uses the actual selection range. Widths follow source characters, including
concealed Markdown delimiters, so concealed rows can appear shorter. English
words and source whitespace are preserved. While this layout is active, Inkstone
temporarily disables `linebreak` to prevent Neovim making a second wrap decision
across padding. It restores the previous window value when native layout stops,
including disable, buffer switches and shared-window fallback. An explicit
`win_options.linebreak` overrides this policy; setting its rendered value to true
uses ordinary native wrapping without BudouX padding.

Source newlines stay separate and each long source line wraps independently.
Set `paragraph.join = true` to join
soft source newlines with a space for English, or without an added space between
adjacent CJK text. Two trailing spaces or a trailing backslash always preserve
an explicit line break. Inline highlights, links
and inline code keep their rendered decorations. Joining uses the virtual-row
renderer. With anti-conceal enabled, the original joined paragraph returns when its
source overlaps the configured cursor range; leaving it restores the layout.
With anti-conceal disabled the layout stays visible under the cursor.
The side preview can show the rendered paragraph while the source is
being edited.

`wrap` and `join` are independent. `wrap = false, join = true` joins soft source
lines without wrapping the virtual output to the window width. With both false,
paragraphs use Neovim's ordinary source wrapping. `join` is false by default.
Paragraphs inside lists and quotes retain their existing layout. Native wrapping
accounts for number/sign/fold gutters, ordinary `breakindent`, `showbreak`, and
paragraph margins/indentation. It falls back to ordinary source wrapping for
shared buffers displayed in multiple windows, `nowrap`, `list`, number columns
with `cpoptions+=n`, very narrow windows, control characters/tabs, unsupported
breakindent options, or rows with additional inline virtual text such as link
icons/code padding. Image anchors and converted math retain their source layout.
Closing a shared view, resizing or changing wrap options rebuilds the layout.
This is not full JIS X 4051 conformance.

## LaTeX formulas

`latex.enabled = true` converts `$...$` and `$$...$$` through the first available
command in `latex.converter = { 'utftex', 'latex2text' }`. Install a converter
yourself; on Arch Linux, `python-pylatexenc` provides `latex2text`. Markdown's
formula nodes supply source ranges when a separate LaTeX parser/injection is
unavailable. Code spans and fenced code remain literal. Injected LaTeX trees
continue to take precedence, so formulas are never rendered twice.

The converter determines the appearance: `latex2text` 2.x produces mostly flat
Unicode text such as `√(3x-1)+(1+x)^2` and `lim_n→∞ (1 + 1/n)^n`; it does not
typeset stacked fractions like a TeX image. `utftex` supports multiline Unicode
math layouts. The current math path displays converter text, not Kitty images.
At the default `latex.position = 'center'`, inline formulas replace their source
and standalone multiline blocks replace all source rows with the converted
layout. Moving onto them follows `anti_conceal`; disabling it keeps the rich
view visible. Explicit `above`/`below` positions, and multiline formulas sharing
their boundary lines with other prose, retain source plus preview. Converter
results are cached per available converter list, so switching from latex2text
to utftex rebuilds the layout. Failed conversion keeps readable source.

Try `nvim --clean -u demo/rich_init.lua demo/latex.md` without downloading demo
dependencies. `:checkhealth inkstone` reports available converters.
For multiline Unicode math, install
[utftex](https://github.com/bartp5/libtexprintf) separately; it is not in Arch's
official repositories. A source build uses `./autogen.sh`,
`./configure --prefix="$HOME/.local" --disable-shared`, `make`, `make check`
and `make install`; ensure the chosen prefix's `bin` is on Neovim's PATH.
Inkstone detects available converters and does not install them automatically.

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

Snacks' own document renderer retains ownership of ordinary images and Mermaid
in buffers it has already attached to; Inkstone avoids creating duplicate
placements. Its native image configuration then controls those placements.
Images inside supported tables are an exception: Inkstone owns their cell
layout and uses Snacks for image conversion and graphics transport.
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

### Images inside tables

With `pipe_table.wrap = true`, `cell = 'trimmed'` or `'padded'`, and a Snacks
backend supporting Kitty Unicode image placeholders, images render inside
their cells. Image columns request up to `media.max_width` columns and share
the available window width. Each image fits its cell's content width and
`media.max_height`; the row grows to the tallest cell, with continuous vertical
borders. Captions remain above the previews. Source text is unchanged.

This also applies to static GIF/video previews that the installed backend can
convert. It does not add playback or install video converters. Missing images
and unavailable converters leave readable captions/links.

Window resizing recomputes the cell bounds. Anti-conceal restores the source
table and removes its image placements while editing; leaving restores the
previews. Switching to list/chart removes cell images. Snacks' native document
discovery excludes these managed tables, and existing native table placements
are retired, so enabling Snacks document images does not duplicate them.
Images outside the table keep their existing renderer.

Cell image layout currently requires one window displaying the buffer and
`conceallevel >= 2`. Other table styles, shared views and backends without
Unicode placeholders retain their existing image behavior.

## Table / list / chart

The top border, header pipes and header/body separator use the color and styles
from `pipe_table.head`. Their font weight is controlled by `pipe_table.head_bold`
(default `false`), which removes inherited bold without changing the theme's
heading highlight. Set it to `true` for bold heading borders. Source-based and
wrapped virtual rows use the same setting; inline cell contents retain their
syntax and explicit Markdown styles. Body rows and the bottom border use
`pipe_table.row`.

Place the cursor in a table and run `:Inkstone toggle_table` to cycle through
table → list → chart → table. `:Inkstone toggle_list` switches between table and
list; `:Inkstone toggle_chart` switches between table and chart. A table without
numeric columns skips the chart during cycling. An explicit chart request
explains why it cannot chart the data.

```lua
require('inkstone').setup({
    pipe_table = {
        view = 'table', -- default view; 'list' / 'chart' also available
        head_bold = false, -- true enables bold heading borders
        view_max_rows = 1000,
        chart = { kind = 'bar', height = 12 }, -- kind can be 'line'
    },
})
vim.keymap.set('n', '<leader>mv', '<Plug>(InkstoneToggleView)')
vim.keymap.set('n', '<leader>ml', '<Plug>(InkstoneToggleList)')
vim.keymap.set('n', '<leader>mg', '<Plug>(InkstoneToggleChart)')
```

The unified `:Inkstone toggle_view` / `<Plug>(InkstoneToggleView)` action cycles
table views, toggles the containing fold or opens media at the cursor. Closed
ancestor folds open before their hidden children can be selected. Inside an
expanded fold, a table takes priority over the enclosing fold. Numeric tables
cycle table → list → chart → table; other tables cycle table → list → table.
Literal tables in code examples are excluded unless `nested = true`.

Attached buffers have a Normal-mode, buffer-local `Ctrl+i` mapping for this
contextual action, including the side preview. Where there is no target, or
Inkstone is disabled, `Ctrl+i` retains native jump-forward movement and counts.
Only media on the cursor row is opened; an earlier image is not selected by
this action. The separate `:Inkstone media` command can still open earlier media.
The side preview also maps Enter and `za` to the contextual action.
`<Plug>(InkstoneToggleTable)` is the table-only cycle. Override the buffer-local
`Ctrl+i` mapping in `on.attach` if another binding is preferred. Terminals that
encode Ctrl+i as Tab also trigger this mapping with Tab.

List view follows LazyAgent's column-name/value cards, preserving rendered
inline chunks and Japanese wrapping. Chart view treats numeric columns as
series and the first nonnumeric column as category labels. Decimal, scientific
notation, correctly grouped thousands, negative/zero values and consistent
unit suffixes are supported. Empty cells, `-` and `—` are gaps. Series with
different units are rejected instead of sharing a misleading axis. Data is
never executed as code.

Charts are generated as SVG, rasterized by `media.chart_command = { 'rsvg-convert' }`
and displayed through Snacks. Without that backend/converter they use text bars.
The alternate view's header remains a visible interaction anchor. With
anti-conceal disabled, cursor movement keeps the chosen table/list/chart view.
With it enabled, overlapping its range restores the whole source table and
hides its chart; leaving the range restores the view. Per-table state
follows row insertions with native extmark anchors and resets on wipe/setup.
Source bytes are unchanged. Views are bounded by `view_max_rows`; source edits
can invalidate a selected table when the whole anchored range is removed.

## Kitty text sizing

Kitty 0.40+ and Neovim 0.12+ can display genuinely larger/smaller text using
[OSC 66](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/). This changes
the displayed text size, with original Markdown retained for editing/yank/save.
Under tmux, support is detected from its cached `client_termtype` over the tmux
socket. Inkstone never sends a terminal identity query through tmux: a repeated
XTVERSION reply can be translated into keys before Neovim sees it. Unknown or
old terminal identities keep normal text; tmux options and key timeouts are
unchanged. Outside tmux, support requires a positive Kitty XTVERSION reply;
other terminals and headless sessions keep normal text and reserve no extra rows.
While awaiting a direct-terminal reply (up to 1.2 seconds), Inkstone temporarily enables
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
        recovery = false, -- true enables periodic recovery after external tmux redraws
    },
})
```

Top-level headings reserve enough rows for their scaled text and wrap to the
available width. Setext headings use the same H1 (`===`) and H2 (`---`) sizes
as `#` and `##`. Multiline Setext titles retain their source line breaks, and
their underlines are hidden without hiding the following paragraph. A blank
line before `---` keeps it a thematic break, outside typography. Existing
`heading.atx` / `heading.setext` settings still control which headings render.
When the same buffer is open in multiple windows, headings and small text
automatically use their normal size so every view remains readable. This also
includes floating views and windows in other tabs. Closing the extra views
restores sizing; different Markdown buffers can still use sizing in both splits.
Literal single-line `<small>supporting text</small>` spans use
the smaller size. Nested/indented headings and spans already replaced by table
or paragraph layouts retain their existing rendering. Set `paragraph.wrap = false`
when using small spans in long paragraphs. Unrepresentable narrow placements
fall back to normal text. Fractional sizes use the protocol's rational bounds.
Integer-size ASCII uses Kitty's normal character layout to avoid visible
padding between fixed-width text groups. Fractional sizes keep fitting words
intact and prefer natural spaces between packets. Overlong words still use
fraction-aligned chunks where possible; highlight boundaries and indivisible
wide characters can require padding.
Fractional spaces reuse the preceding word's unused width to reduce unusually
wide word gaps. At 1.5x, ordinary single spaces in the tested ASCII cases span
1.5–2 native cells; the cell grid still prevents perfectly uniform fractional
spacing. This keeps literal spaces and independently highlighted whitespace.
While sized text is active, its native grid cells contain spaces rather than
a duplicate normal-size title or small span. This prevents ordinary redraws
from exposing an unscaled copy without Markdown markers. The source buffer
and the normal renderer used when typography is disabled remain intact.

Sized text inherits the theme's text/background colors and inline styles,
including bold, italic, underline/undercurl and strikethrough. Heading color
groups and window-local highlights are respected; theme or highlight changes
apply on the next redraw. This follows the renderer's named highlight groups,
not arbitrary decorations applied by other plugins to individual screen cells.

Stock tmux works with `set -g allow-passthrough on`. Inkstone reads the pane
offset and top status-bar height and uses standard passthrough; it does not
patch tmux or change its options. Cursor-only redraws leave unaffected overlays
in place. Placement ownership is tracked per displayed line:
command input and floating terminals on unrelated screen rows do not
erase other headings. Floating windows and popup menus take precedence only
where they overlap. Background layout is retained while a different scratch
buffer is edited.
Inactive buffers use normal-mode rendering; scratch-local Insert mode and
decoration refreshes do not remove background row reservations. Covered glyphs
stay hidden until the popup moves or closes. At the end of each Neovim redraw,
visible sized text is replayed before the terminal frame commits, with an
additional coalesced repair after the native flush. Under tmux, native row
output is flushed before the text passthrough so the frame includes both.
Visibility checks do not flush a partially assembled Neovim frame.
A float sharing
the lower row of a large glyph can require clearing that glyph before native
drawing and restoring it afterward, even when the float is horizontally beside
it. Otherwise normal blanks can skip the glyph and shift a later border under
[Kitty's multicell overwrite rules](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/#wrapping-and-overwriting-behavior).
This preserves the reserved layout and restores uncovered glyphs. Ordinary
unchanged replays do not pre-clear glyphs. Native
output can erase multicells while writing identical spaces, so equal cell
contents or missing source-row callbacks cannot safely skip repair. Idle
H1/H2/H3 text is not resent. Layout/content changes clear obsolete
owned extents before rebuilding the grid. Cursor entry restores source only when anti-conceal is enabled;
disable/setup/wipe stop owned placement timers. This is a terminal text overlay,
so an external tmux repaint can erase the overlay without notifying Neovim.
Use `:Inkstone refresh` to restore the overlay in that case. If automatic recovery
is preferred, `typography.recovery=true` enables the former 250ms replay loop
only for opted-in buffers. Periodic output can cause fractional text to flicker;
it is disabled by default. The
terminal tests cover multicell size metadata, tmux refresh, pane offsets, source
restoration and float occlusion; they do not prove every GPU/font combination.

With `allow-passthrough=all`, Inkstone still suppresses output from hidden tmux
windows or panes hidden by zoom. A visible pane keeps its typography when focus
moves to a sibling; background output rechecks visibility so later window
switches cannot replay old headings into the new view. Returning to the pane
restores its text through focus notifications or the next Neovim redraw.

If you use `aikawa9376/auto-cursorline.nvim`, update it together with Inkstone.
While the cursor is on enlarged/small rendered text, Inkstone temporarily
suppresses auto-cursorline for that window. Moving to ordinary body text or
restoring source resumes its normal delayed highlight. Other owners of the
window suppression flag are preserved. In typography windows the delayed body
highlight uses a window-scoped row decoration, avoiding native cursorline option
redraws that can briefly expose unscaled text. Native behavior returns after
leaving typography. `cursorlineopt=screenline` keeps native wrap semantics.
Equal native screen cells do not establish that the terminal text survived;
completed redraws still repair their visible headings. Switching buffers/tabs or closing a window retires its
old overlay before the new view draws, so enlarged glyphs do not remain over it.

`demo/rich.md` includes a table, image, scaled headings and small text for trying
the views. From this checkout, `nvim --clean -u demo/rich_init.lua demo/rich.md`
starts an isolated demo using already installed parsers and optional Snacks;
it installs nothing and does not alter dotfiles. Enter is the unified action
in this demo. `:checkhealth inkstone` reports typography and converter availability.

## Folding

`:Inkstone toggle_fold` toggles the innermost visible code fence, callout or
`<details>` block containing the cursor. A cursor inside a collapsed parent
opens that parent before its hidden children can be toggled. It changes display
state without taking over Neovim's `foldmethod` or editing source.

```lua
require('inkstone').setup({
    folds = { enabled = true, code = true, callout = true, details = true, position = 'right' },
})
vim.keymap.set('n', '<leader>mf', '<Plug>(InkstoneToggleFold)')
```

The side preview has buffer-local `za` and `<CR>` view actions. Code blocks start
expanded. Obsidian callouts beginning with `> [!NOTE]-` start collapsed;
`> [!NOTE]+` starts expanded. `<details>` starts collapsed unless it has an
`open` attribute. A `<summary>` on the opening line or following line supplies
its title; blank lines before the summary and multiline summaries are allowed. Nested details are
supported. Toggle state follows inserted lines using buffer-local extmark
anchors and is released on buffer wipe/setup.

While rendered, the `<details>` and `<summary>` wrappers become a styled
header instead of raw HTML tags, including on the cursor line. The header uses
`InkstoneDetailsHeader` (linked to `Title`); the expanded body uses
`InkstoneDetailsBody` (linked to `NormalFloat`). Code backgrounds keep their own
color. No extra body columns are inserted, so table and code widths stay aligned.
Visual/raw views retain the original tags. The standard tag is `<details>`;
the singular `<detail>` is not a details control.

The body retains normal Markdown decorations for headings, lists, tables,
links and code, even without blank lines after the summary. This uses a
Markdown body injection and does not require an HTML parser. Standalone HTML
buffers and fenced HTML examples remain literal; this is not a browser HTML
layout engine. Inline body text on the same line as the opening/summary tags
is outside the supported block layout.

Code fences have independent fold state inside details. `Ctrl+i` on code folds
the code; use the details title to fold the enclosing details. Reopening a
parent preserves the children's states. `folds.position = 'right'` is the
default: the triangle (`▶` closed / `▼` open) always stays on the left with
the title or language name, while `N lines` is aligned to the window's right
edge. Counts remain visible in both states for details, code and callouts.
N counts source rows after the opening row, including summary/blank lines and
the closing tag. Long titles are clipped
to leave space for the information; alignment follows window resizing and gutters.

Set `folds.position = 'left'` for the compact `▶ N lines · title` /
`▶ N lines · language` prefix (using `▼` when expanded). Callout counts follow
their displayed title. This setting controls counts rather than triangle position;
`code.position` independently controls ordinary expanded code-language labels.
Collapsed code summaries stay visible at the cursor and cannot be covered by
the usual code-language overlay or padding. Expanded code reserves header space
for the triangle and count, including right-positioned language labels, and
retains its decorated control at the cursor. Visual/raw modes continue
to follow `render_modes`.
Anti-conceal margins
around the visible fold anchor do not reopen a collapsed body; deliberate
cursor entry into its source can still restore it when anti-conceal is enabled.

Visible ranges skip currently hidden fold rows. Opening or closing a long fold
automatically decorates the newly visible content, including code after a closed
fold, without requiring a cursor move or scroll. Hidden code bodies stay outside
the render viewport.

After updating the plugin, restart Neovim to load the new modules.
Updating files alone does not replace already loaded Lua modules. An older
running instance may lack `folds.position` even when its checkout is current.

Attached buffers, including ordinary Markdown buffers and the side preview,
automatically have Normal-mode, buffer-local `j/k`, `gj/gk` and Up/Down mappings
that skip hidden fold bodies, summary tags and closing details tags. Additional
key configuration is not required. Counts such as `2j` and `2gj` are supported;
`gj/gk` retain native screen-line movement through soft wraps. Raw views and
disabled rendering retain native movement. Operators and Visual-mode motions
keep their existing behavior. Override these defaults in `on.attach` if needed.

`<Plug>(InkstoneMoveDown)` / `<Plug>(InkstoneMoveUp)` remain available for other
key choices, with Lua equivalents `require('inkstone').move_down()` and
`require('inkstone').move_up()`.

## Code decoration

Fenced blocks retain their language label, background and padding inside
details. Open fences and blocks ending without a final newline keep their last
body row decorated. Indented code blocks receive background and padding; they
have no declared language to infer syntax colors from.

Language colors use installed Tree-sitter parsers and highlight queries. When
a native highlighter is active, it owns syntax colors. Otherwise Inkstone uses
the already parsed code injection trees to color only visible code rows.
`code.syntax = false` disables this fallback; it does not disable an existing
native highlighter. Missing parsers or unknown languages retain readable code
and its block decorations without guessed syntax or automatic downloads.

Common fence aliases include `sh` / `shell` / `zsh` → `bash`, `py` → `python`,
`js` / `jsx` → `javascript`, `ts` → `typescript`, `yml` → `yaml`,
`md` → `markdown`, `rb` → `ruby`, `rs` → `rust`, and `ps1` → `powershell`.
Explicit user language registrations and parsers installed under an alias name
take precedence. The default `nested = false` still keeps Markdown/HTML source
examples literal inside code blocks while allowing their syntax colors.

## ACP tables

With anti-conceal enabled, entering any row of a wrapped table
restores the whole table's source. This removes its virtual rows, table borders
and inline decorations together, so a long link destination cannot mix a raw
source row with the rendered table layout. Moving outside restores the rendered
table. With `anti_conceal.enabled = false`, the rendered layout stays visible
under the cursor. While editing source,
Neovim's normal source wrapping remains visible; `nowrap` clips source rows.
Source bytes, yank and save are unchanged.

ACP transcripts often indent each source row by one space. Wrapped virtual
table rows retain this prefix, matching source-based rows, delimiter and outer
borders. `tests/terminal_compat.py` checks a Japanese comparison table with long
GitHub URLs at `conceallevel=3` through stock tmux and Kitty's VT parser, plus
paragraph restoration and folding. It does not establish GPU/font appearance
or support on every terminal.
