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
math retain their existing layout. Cursor entry into any replaced source row
restores the complete source paragraph. `Marks:replace` translates half-open
Tree-sitter ranges to the inclusive end-row semantics of `conceal_lines`;
`lib/replacements.lua` anchors virtual output after the whole hidden range.
Tables containing replaced rows restore the entire table's source when the
cursor enters any table row, including fitting rows and the delimiter. Table
marks carry their owning source range so adjacent blank-row borders disappear
too; inline decorations inside the table are also hidden. Leaving the table
restores the complete rendered layout, including when anti-conceal is disabled.
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
the buffer. A visible header anchors interactions. Moving into a body source
row restores the whole source table and suppresses its graph. Source range
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
Only a positive Kitty 0.40+ XTVERSION response enables output. Neovim 0.12's
`nvim_ui_send` is required; unsupported/headless cases retain normal rendering.
The XTVERSION probe temporarily holds `ttimeout=true` and `ttimeoutlen>=1200`
until its reply or 1.2-second timeout. Without this guard, split DCS input can
expire into ordinary mapped keys and modify the source when users configure
very short key-code timeouts. It restores only options still matching its
assigned values. Retries reuse the in-flight query; clearing request waiters
does not cancel the reply drain because an already sent query cannot be recalled.

The overlay bypasses tmux using standard passthrough after reading its pane
coordinates, status placement and allow-passthrough option. It never patches
or configures tmux. A decoration provider erases old multicell text before the
native redraw and schedules replay after the grid flush. A scoped 250ms timer
recovers foreign repaint damage. Size-only changes also clear the previous
multicell extent in the same output packet, even if grid extmarks were reused.
Float/popup bounds and active tabs are checked
before drawing; original source returns for cursor editing. Terminal geometry
refreshes retain request waiters until the fallback frame is rebuilt. Setup,
disable and wipe release owned placement timers and request waiters; a pending
probe retains its bounded timer and input guard until reply or timeout.

The source bytes and normal grid remain authoritative. This is a scoped
terminal overlay, not a replacement Neovim TUI, and brief fallback/flicker during
unrelated redraws is possible. `doc/rendering-features.md` owns configuration,
eligibility and user-facing limits; `demo/rich.md` is the interactive sample.

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
