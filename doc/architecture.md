# Inkstone architecture

Inkstone is a standalone fork of render-markdown.nvim. All runtime modules,
commands, globals, namespaces and highlights use the Inkstone identity. It does
not depend on the original plugin being loaded. Baseline configuration and
Markdown feature coverage remain available; source provenance is in UPSTREAM.json.

## Pipeline

1. `core/manager.lua` attaches to configured filetypes and schedules updates.
2. `request/view.lua` captures visible ranges plus a ten-row margin and asks the
   native Tree-sitter parser to parse asynchronously. Completion checks the
   buffer tick, mode, request identity, window validity and displayed buffer.
3. `core/handlers.lua` snapshots native trees once for a synchronous handler
   pass and evaluates inline handlers before block handlers. Highlights, folds
   and media share that enumeration; successful passes release the snapshot.
   Explicit alternate table views expand query ranges only within their row
   bound. Typography/table filters remove superseded source decorations before
   folds and media are resolved.
4. `lib/node.lua` wraps syntax nodes, retrieving text only when accessed.
5. `render/compat.lua` applies width-preserving display substitutions to virtual
   chunks and visible source text after handlers. `text/compat.lua` owns the
   literal cluster rules and the built-in kana equivalents. Source overlays
   avoid concealed/replaced regions, and virtual chunks retain base highlights.
6. Renderers emit mark descriptions. `core/ui.lua` converts and
   applies them through Neovim extmarks; buffers are never rewritten.

## Performance boundaries

Code-body backgrounds and padding are limited to coalesced viewport ranges.
Full-block widths are retained for consistent borders. Width caches hold no
TSNodes and have per-buffer entry/row limits. Buffer `on_lines` callbacks discard
only overlapping summaries and move unaffected source ranges after row insertions
or deletions. Width-option changes, reloads and unaccounted changedticks still
invalidate conservatively. Unload/wipe releases the cache and attachment state.
The first cold width scan still reads the whole block.

Paragraph reflow reuses its measured display units for wrapping. Its bounded
layout cache compares exact, canonical snapshots of source slices, hard breaks,
final inline insertions/highlights/conceals, prefix, width, margins, Japanese
options and display-width settings. Cached results are copied before emission
so compatibility transforms cannot mutate them. It permits up to 64 entries
and a 4MiB estimated retention budget per buffer, with reset/wipe cleanup;
this budget is an estimate, not an exact bound on Lua heap allocation. Queries
and inline handlers still run, preserving dynamic callback behavior.

One window text-width snapshot serves each handler pass: repeated `getwininfo`
calls can otherwise repeat native highlighter preparation. Table child lookup
seeks each visible range by binary search instead of enumerating every row.

Changed renders reconcile full mark descriptions and retain equal extmarks.
After source edits, retained marks must also match their native start/end
coordinates. Replacement-line assembly is reused while its visible replacement
and conceal-mark objects, changedtick and line count are unchanged. Custom
`on.clear` callbacks keep the previous full-clear path so they still observe an
empty namespace. Disable/setup/wipe perform full cleanup.

Highlight groups are appended cheaply and sorted only before a row is consumed.
Conceal intervals also coalesce lazily before consumption. Disabled trace logging
does not materialize node text. Guarded sibling traversal rejects empty nodes and nondecreasing starts
without placing an arbitrary maximum on valid lists.

The scheduler renders the leading event and the latest pending event after a
burst. Buffer wipe disposes timers and drops manager/UI/config/context state.
A setup reset also disposes old UI decorators. No background native worker is
started by this version.

## Japanese layout

`text/grapheme.lua` produces display clusters for tested combining marks,
Japanese dakuten and common emoji sequences. `text/layout.lua` uses the bundled
BudouX Japanese model to prefer phrase boundaries, then basic kinsoku boundaries,
then a width-preserving hard break if the constraints cannot be satisfied.
Widths use Neovim's display-width function. Table wrapping preserves inline
highlight segments while rebuilding virtual rows; `inkstone.text` exposes the
same layout without changing a source buffer.

Top-level paragraphs use `text/paragraph.lua` to join soft breaks, preserve hard
breaks and wrap rendered inline chunks with the same Japanese layout kernel.
`paragraph.wrap` is enabled by default. Lists/quotes, image anchors and converted
math retain their existing layout. Anti-conceal overlapping a replaced source
row restores the complete paragraph; disabling it retains the rendered view.
`Marks:replace` translates half-open
Tree-sitter ranges to the inclusive end-row semantics of `conceal_lines`;
`lib/replacements.lua` anchors virtual output after the whole hidden range.
When anti-conceal is enabled, tables containing replaced rows restore the entire
table's source on cursor-range overlap, including fitting rows and the delimiter. Table
marks carry their owning source range so adjacent blank-row borders disappear
too; inline decorations inside the table are also hidden. Leaving the table
restores the complete rendered layout. Disabled anti-conceal keeps table/list/
chart/paragraph/typography/formula views rendered even on their source rows.
Source editing uses Neovim's normal wrap/nowrap behavior.

`core/folds.lua` discovers code fences, callouts and paired details blocks in
Markdown trees. It filters hidden child decorations and emits conceal/summary
marks; explicit toggle state follows source edits via a separate extmark
namespace. It does not set the user's foldmethod. `core/media.lua` collects
visible image/diagram requests after folding, uses async local conversion and
delegates graphics to Snacks. Pending placements reject edited/wiped buffers;
disable/setup/wipe close placements and cancel jobs. Native Snacks document
placements are not duplicated. See `doc/rendering-features.md` for configuration,
dependencies and remaining boundaries.

## Rich table views and media viewport

`core/table_views.lua` owns per-table display mode with movable, invalidating
extmark spans. It seeks real Markdown table nodes, avoiding fenced-code text.
The card design follows LazyAgent's local column-heading/value layout; this
implementation builds styled virtual rows from native cells instead of changing
the buffer. A visible header anchors interactions. Anti-conceal overlapping its
range restores the whole source table and suppresses its graph. Source range
deletion drops the mode instead of transferring it to a new table at that row.

`text/chart.lua` consumes declarative numeric cells and emits bar/line SVG or
text bars. Series must share units; missing values are gaps. The media pipeline
rasterizes SVG with a local command and caches it by content/options. Charts
are Inkstone-owned even when Snacks owns ordinary image/Mermaid placements.
`core/actions.lua` dispatches a shared view action to table modes, folds or media.

`core/viewer.lua` owns floating image/PDF viewport state, zoom, pan, page and
request generation. ImageMagick produces a bounded PNG crop asynchronously;
stale generations cannot publish after later interactions. Failed page-forward
preserves the previous page. Close/wipe/setup/disable cancel work and remove
private output. Snacks owns final transport/placements and URL conversion.
Ordinary PDF links are manual-view items, not duplicate inline images.

`request/context.lua:transient` creates read-only collection/validation contexts
without replacing the active render context. Manual media actions and chart
validation must use it so pending parse callbacks and typography/table edit
metadata remain attached to the actual render request.

## Kitty typography

`core/typography.lua` owns literal display runs, screen-space placement, terminal
detection and repaint lifecycle. Headings reserve their scaled rows through
normal extmarks; eligible `<small>` HTML spans retain source cell positions.
Inline code containing those literal tags is not interpreted as markup.
Payloads contain sanitized text and grapheme-safe chunks within OSC 66's bounds.
Fractional runs use denominator-aligned chunk limits when representable within
the protocol's seven-cell width bound. Arbitrary limits rounded each chunk up
and inserted visible padding inside words, such as "Images an" / "d diagrams"
at 1.5x. Full ASCII chunks now occupy their exact scaled advance; a final short
chunk may retain trailing padding. Highlight boundaries and indivisible wide
graphemes still obey the protocol's integer cell constraints.
Kitty 0.40+ is required: under tmux, read its cached `client_termtype` alongside
pane geometry over the tmux socket; do not send XTVERSION through passthrough.
tmux consumes its first terminal-identity reply, then may translate later ones
into ordinary/extended keys before Neovim receives them. A Neovim key timeout
guard cannot protect this path. Missing/old cached identities use normal text.
Outside tmux, require a positive Kitty XTVERSION response. Neovim 0.12's
`nvim_ui_send` is required; unsupported/headless cases retain normal rendering.
The direct-terminal XTVERSION probe temporarily holds `ttimeout=true` and `ttimeoutlen>=1200`
until its reply or 1.2-second timeout. Without this guard, split DCS input can
expire into ordinary mapped keys and modify the source when users configure
very short key-code timeouts. It restores only options still matching its
assigned values. Retries reuse the in-flight query; clearing request waiters
does not cancel the reply drain because an already sent query cannot be recalled.

The overlay bypasses tmux using standard passthrough after reading its pane
coordinates, status placement and allow-passthrough option. It never patches
or configures tmux. Each drawn line retains its buffer/window/entry ownership,
native and tmux-adjusted bounds, and output payload. Native damage marks that
line for replay; the painter compares lines independently, so a redraw in one
place does not clear or resend every heading. Clearing an unrelated buffer is
a no-op for placements. Changed geometry/content/entry sets erase only owned
extents before native redraw. Command-line height changes preserve still-visible
lines when their origin and width are unchanged. Floats and popup menus erase
only intersecting lines before they draw, never the rest of the page. Decoration
callbacks alone do not prove damage: post-flush snapshots of native cells and
attributes suppress replays when a window-wide option redraw leaves the actual
placement unchanged. Snapshot reads are limited to flagged/new visible rectangles;
routine foreign-repaint recovery reuses their snapshots.

With updated auto-cursorline.nvim, `sync_cursorline` temporarily owns
`w:auto_cursorline_disabled` while the cursor is on a shown typography range.
It restores the previous value on ordinary rows, buffer/window changes or
typography clear, and does not claim an already true flag owned elsewhere.
The optional loaded auto_cursorline module is notified immediately, so both
active highlights and queued enable timers honor suppression. Source restored
by anti-conceal retains normal cursorline behavior. No plugin is loaded just
for this integration and no global cursorline setting is changed.

A scoped 250ms timer recovers foreign repaint damage by reissuing identical
multicells without a preceding glyph erase. Ordinary dirty-line replays use
the same approach; only obsolete extents and trailing unscaled fallback cells
need explicit clearing. This avoids blank intermediate rows during command-line
typing, floating terminal updates and recovery. Size-only changes still clear
the previous extent even when grid extmarks were reused. Float/popup bounds and active tabs are checked
before drawing; cursor source restoration follows anti-conceal. Terminal geometry
refreshes retain request waiters until the fallback frame is rebuilt. Setup,
disable and wipe release owned placement timers and request waiters; a pending
probe retains its bounded timer and input guard until reply or timeout.

The source bytes and normal grid remain authoritative. This is a scoped
terminal overlay, not a replacement Neovim TUI, and brief fallback/flicker during
unrelated redraws is possible. `doc/rendering-features.md` owns configuration,
eligibility and user-facing limits; `demo/rich.md` is the interactive sample.

## LaTeX source ranges and converters

The built-in LaTeX handler converts formula source to Unicode using `utftex`
or `latex2text`; its layout consumes source ranges, not the LaTeX AST structure.
`core/handlers.lua` prefers injected LaTeX roots, then collects `latex_block`
nodes from existing Markdown-inline trees only when no LaTeX roots exist and a
converter is available. This keeps math working without the optional LaTeX
parser/injection, excludes literal code, preserves nested/viewport filtering,
and avoids duplicate formulas. Custom LaTeX handlers retain their original AST
contract and do not receive Markdown nodes through this fallback.
`tests/rich.lua` checks real `latex2text` conversion with LaTeX trees filtered
out, including inline/block output and source preservation. The converter
determines flat versus multiline appearance; this path does not typeset images.
The default centered layout replaces standalone multiline source blocks with
`Marks:replace`, so raw LaTeX does not remain below the result. Explicit above/
below previews and prose-sharing boundaries retain source. Conversion cache
keys include the available converter chain: adding utftex cannot reuse cached
flat latex2text output. Failed results keep source instead of rendering `error`.

## Next work

- Update affected rows inside a large width summary rather than rescanning that
  entire summary; retain exact invalidation and memory bounds.
- Reduce repeated native highlight/query work on long logical lines and cache
  table cell layouts after profiling; dynamic callbacks must still execute.
- Reuse marks that move to different source rows after edits, with validated
  native coordinates and correct cursor/anti-conceal behavior.
- Shared parser timeout/retry policy that does not alter other plugins' native
  highlighters. Async time slicing changes responsiveness, not native parse cost.
- Extend paragraph layout to nested lists/quotes and richer display navigation.
- Optional native layout kernel only after measurements justify the cost. Keep
  Neovim display-width parity, pass incremental data, reject stale results and
  retain a working Lua fallback. A worker cannot share Neovim-owned TSNode pointers.

## Validation

`tests/run.lua` exercises the new behavior with actual parser binaries and UI
extmarks. The inherited Plenary tests remain under `tests/`; unit tests need
Plenary, and rendering tests additionally need mini.icons and appropriate
Tree-sitter parsers. These checks do not constitute complete terminal/font,
Neovim-version, Unicode or JIS conformance coverage.
`tests/rich.lua` covers alternate table state, chart data/conversion, actual
image/PDF crops, source preservation and pure typography geometry. Converter
checks are skipped if their optional binaries are unavailable. The terminal
suite additionally checks real Snacks image transfer into Kitty's graphics
manager, OSC 66 multicell sizes, source restoration, tmux pane/status offsets,
extended-keys mode, popup occlusion and old-Kitty fallback. These remain native
VT/graphics-protocol checks, not GPU/font appearance validation.

`make terminal` starts isolated stock tmux and Neovim instances in pseudo
terminals, feeding real output to the installed Kitty native VT parser. It
checks table cells (including wrapped virtual rows), repaint, original buffer
bytes, yank and opt-out. This verifies terminal cell state, not GPU glyphs.
The compatibility pass stays within viewport ranges for source overlays and
does not change source offsets, measured widths or the terminal output layer.
