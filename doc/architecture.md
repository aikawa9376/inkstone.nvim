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
   View ranges skip shown `fold_hidden` intervals, extending the row budget to
   cover visible content beyond long folds without including their hidden bodies.
   The same range calculation checks coverage. After displaying conceal marks,
   `core/ui.lua` schedules another update if any buffer window exposes content
   outside the parsed ranges, so fold layout changes settle without a scroll.
   Changed source ticks invalidate old conceal coordinates for range planning.
   When `nvim_win_text_height()` supports `max_height` and returns `end_row`,
   `lib/env.lua:range` measures actual screen rows in native code, including
   character conceal, wrapping, native folds and virtual filler. It starts at
   the real topline/skipcol and adjusts for visible topfill; the ten-row source
   margin is applied afterward. Calls are split around known fold conceal
   intervals so native measurement does not walk giant hidden bodies. Native
   folds crossing these intervals advance to `foldclosedend` once rather than
   counting the same fold twice. Unsupported APIs and stale source coordinates
   use the previous source-row planner. Capability detection is cached per process.
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

Code examples remain literal by default (`nested = false`). `core/ts.lua:render`
checks each injected tree's location in its Markdown ancestors for fenced or
indented code blocks. The shared view traversal and handler snapshot exclude
those trees, so handlers, typography, table views, folds and media use the same
boundary, including manual table/fold actions. Markdown injected into a non-code
host remains eligible. Outer code backgrounds/borders and native syntax
highlighting remain available; `nested = true` opts back into inner rendering.
Width-preserving display compatibility corrections still apply to source text.

`queries/markdown/injections.scm` extends the native injection query for compact
details bodies that Markdown otherwise consumes as an opaque `html_block`.
`core/ts.lua` registers a predicate and range directive that exclude the opening
and summary tags and final closing tag. The body remains one contiguous source
range, so fences containing literal HTML tags parse correctly. Injecting separate
HTML text nodes would split those fences. Ordinary blank-separated Markdown
continues to use its native captures; no HTML parser is required for this feature.

`core/code_syntax.lua` registers common fence aliases without overriding user
registrations or actual alias-named parsers. Existing parser injections are
invalidated once per buffer/alias generation. Code renderers use code-language
trees from the shared native snapshot for viewport-bounded syntax colors when
no native highlighter is active; an active highlighter owns its own colors.
The context records highlighter state so starting/stopping it invalidates marks.
No parsers are downloaded or source strings reparsed separately. Code syntax
and plugin rendering within code examples remain separate policies.

## Performance boundaries

Code-body backgrounds and padding are limited to coalesced viewport ranges.
Full-block widths are retained for consistent borders. Width caches hold no
TSNodes and have per-buffer entry/row limits. Buffer `on_lines` callbacks discard
only overlapping summaries and move unaffected source ranges after row insertions
or deletions. Width-option changes, reloads and unaccounted changedticks still
invalidate conservatively. Unload/wipe releases the cache and attachment state.
The first cold width scan still reads the whole block.

Native paragraph wrapping caches source-position boundaries by source text,
first/continuation budgets, Japanese options and display-width settings, using
the same bounded layout cache. Unit decomposition and BudouX run only on misses
for source rows intersecting the viewport ranges. Nonzero paragraph margins or
indentation can still require a whole-paragraph width summary. Colors remain
native and need no layout rebuild.
Joined paragraph reflow reuses its measured display units for wrapping. Its bounded
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

Top-level paragraphs default to `paragraph.wrap=true, paragraph.join=false`.
`render/markdown/paragraph.lua:softwrap` keeps source rows and inserts only
end-of-screen-row whitespace using persistent inline extmarks. `text/layout.lua`
shares BudouX/kinsoku decisions between virtual layout and source-backed ranges;
source ranges preserve every whitespace byte. `lib/softwrap.lua` calculates
source byte offsets and first/continuation budgets, matching native gutters,
breakindent/showbreak and paragraph padding. Native motions/operators own source
positions; anti-conceal does not remove wrap padding.
Neovim 0.13 development builds with conceal-aware wrap already apply their
displayed-width layout to Inkstone's persistent conceal extmarks and Tree-sitter
conceal. No new enable flag is needed. This improves native reflow and source
positions. A cached behavioral probe in `lib/softwrap.lua:conceal_aware`
distinguishes it from earlier builds using a hidden scratch window and public
text-height measurement. `request/highlights.lua` preserves native Tree-sitter
conceal intervals separately from renderer-added conceal. For eligible rows,
BudouX segments visible text and maps boundaries to original byte positions.
Raw and projected padding are cached separately; `paragraph_concealed` selects
the matching marks during display from the window's conceallevel, concealcursor,
mode and cursor row. Cursor movement therefore needs no layout reparse.
Visual modes follow `render_modes`; ordinary defaults omit them, so selection
temporarily restores raw Markdown, source wrapping and window options. Leaving
Visual restores decorations and native BudouX padding. Explicit Visual entries
or `render_modes=true` retain rendering. No blanket Visual-to-Normal override
is applied: source selection takes precedence over keeping rendered geometry.
When native paragraphs and normal-mode rendering are enabled, UI rendering
retains normal-mode geometry for pending operators and command/search input,
even if those modes are omitted from `render_modes`.
Anti-conceal still sees the actual mode/selection. Filetype overrides that omit
`c` (for example LazyAgent's `{ 'n', 't' }`) otherwise clear decorations and
restore raw conceal/linebreak options until command/search exit. That transition
reproduces without Noice; Noice's popup can expose the unrendered source when
it closes. Native continuity prevents the clear/reset rather than hiding it
with a timeout. Joined layouts and views without normal paragraph rendering
retain their configured mode policy.

`core/ui.lua` temporarily disables native `linebreak` while this layout is
active, restoring the exact prior per-window value when it stops. The softwrap
module clears owned options on setup, buffer leave/wipe and window close.
Explicit `win_options.linebreak` takes precedence; true disables BudouX padding.
`core/manager.lua` rebuilds geometry on window lifetime and relevant option
events. Because persistent extmarks are buffer-wide, multiple views fall back
to ordinary source wrapping until only one window remains. Other conservative
fallbacks cover tabs/control characters, unsupported indent
settings, `cpoptions+=n` with numbers and additional inline insertions. Source
is never replaced on fallback. See `doc/rendering-features.md`, "Japanese
paragraph layout", for the user contract and limits.
`list` display preserves source character widths for ordinary tab-free rows and
does not disable the layout. Splits showing different buffers remain eligible.

Explicit `join=true` still uses `text/paragraph.lua` to wrap rendered inline
chunks as virtual rows. It combines soft breaks but retains hard breaks and
can run with wrapping disabled. Lists/quotes, image anchors and converted
math retain their existing layout. Anti-conceal overlapping joined replaced source
row restores the complete paragraph; disabling it retains the rendered view.
`Marks:replace` translates half-open
Tree-sitter ranges to the inclusive end-row semantics of `conceal_lines`;
`lib/replacements.lua` anchors virtual output after the whole hidden range.
When anti-conceal is enabled, tables containing replaced rows restore the entire
table's source on cursor-range overlap, including fitting rows and the delimiter. Table
marks carry their owning source range so adjacent blank-row borders disappear
too; inline decorations inside the table are also hidden. Leaving the table
restores the complete rendered layout. Disabled anti-conceal keeps table/list/
chart/joined-paragraph/typography/formula views rendered even on their source rows.
Source editing uses Neovim's normal wrap/nowrap behavior.

With joining disabled, each source row keeps its own leading whitespace;
continuation indentation follows native `breakindent`. A transcript banner at
column zero and an indented body can share a paragraph without inheriting one
another's prefix. Native styles, including foreign extmark role colors, remain
on their original source rather than being copied into virtual chunks.

`request/highlights.lua` projects multiline captures onto each intersecting
visible row using that row's byte endpoints. The end column of a multiline
capture cannot be used on its first row: it can land inside a UTF-8 character,
splitting virtual highlight chunks into visible invalid-byte placeholders and
inflating measured widths. Captures spanning disjoint views are deduplicated,
and source line reads remain bounded to the visible ranges.

Inline render captures are also deduplicated before producing marks or updating
inline widths/highlights. `core/handlers.lua` shares a capture set across all
roots of one language in a render pass; `handler/markdown_inline.lua` keys it by
capture, node type and source byte range. Overlapping injected trees can expose
the same source link with different node IDs. Node IDs or row-only keys cannot
identify logical links: a row with two distinct links must retain two icons.
The set is local to the pass, so later edits and refreshes render normally.
This complements parser-side injection guards and covers disjoint-view repeats;
deduplicating final extmarks alone would leave inflated inline width state.

`parser/link.lua:text_fragment` recovers shortcut labels followed by single-line
HTTP(S) text-fragment destinations with unmatched literal opening parentheses.
The scan is bounded to the inline tree and URL token; ordinary invalid Markdown
is not reinterpreted. `render/inline/shortcut.lua` delegates recovered links to
the normal link renderer, which adds explicit prefix/destination conceal marks
and updates the shared display-width state. Link icons keep these rows on the
native-wrap path rather than inserting padding based on the exposed URL.

Link icon descriptions carry a source `link_range`. `core/links.lua` intersects
these displayed ranges with native conceal snapshots and shown explicit conceal
marks for Normal-mode `h/l` movement. Touching half-open ranges merge without
swallowing visible characters. It rejects stale buffer ticks and honors current
cursor-line conceal and mark visibility; individual key presses do not parse.
`core/manager.lua` installs buffer-local defaults before `on.attach`, alongside
the fold motions. Counts traverse visible positions; raw views, operators and
Visual retain native motions.

Replacement chunks also carry persistent foreign extmark range highlights,
including LazyAgent transcript role colors. `Highlights:extmarks` queries only
visible ranges with overlap enabled, clips multiline byte ranges per row, and
orders them with Tree-sitter captures by priority. It excludes Inkstone's own
namespaces to avoid importing previous render output. These styles participate
in paragraph layout snapshots, so a refreshed render sees external decoration
changes even when source text has not changed. Ephemeral decorations and
window-only matches are not captured.

`core/folds.lua` discovers code fences, callouts and paired details blocks in
Markdown trees. It filters hidden child decorations and emits conceal/summary
marks; explicit toggle state follows source edits via a separate extmark
namespace. Details summaries may follow blank lines; their source rows and the
closing details tag are hidden while expanded. Toggle selection stops at a
collapsed ancestor, so source motions into its hidden code cannot toggle that
child. Closed code folds retain a visible delimiter/summary anchor even without
a language label.
Their dedicated overlay summary replaces renderer-owned marks on the opening
fence (retaining any container prefix), so language overlays and code padding
cannot cover the collapse indicator. It remains visible at the cursor during
rendering; raw/Visual mode still follows the normal render-mode policy.
Triangles stay left (`▶` closed / `▼` expanded) on details and callouts, and on
collapsed code. `folds.position` defaults to `right`: `N lines` is appended to
the displayed summary/language label with exactly one space, in the same overlay
chunks as that label. It does not align to the window edge. Details/callouts
retain counts when expanded. Expanded code receives no fold glyph, count or
additional header padding. Callout count overlays and triangles use priority
5001, above Neovim's default 4096 virtual-text priority, so quote markers do not
cover the controls. Detail/collapsed-code counts share their header overlay.
Titles reserve space for the triangle and count when clipping to a narrow
window. Callout count overlays use the rendered title's endpoint as their
window column, since concealed-source EOL can precede the displayed title end.
No window-edge metadata or right-edge padding option is used.
`core/colors.lua:fold_icon` derives `InkstoneFoldIcon` from resolved Comment
attributes with GUI/cterm italic disabled, refreshing it on ColorScheme or a
changed source definition without altering the shared Comment group.
`position=left` uses `▶/▼ N lines · title/language`; callout counts follow their
displayed title with a separator. N counts source rows
after the opening row, including summary/blank lines and closing tags.
Explicitly reopened code retains its ordinary opening-row renderer marks under
anti-conceal at the cursor. Untoggled code follows normal anti-conceal policy.
`code.position` independently positions the original expanded language
label. The inherited renderer snapshots disable folds; actual controls, open and
closed counts, and both positions are covered by the UI and terminal suites.
Details controls overlay the original tag row and pad to its display width, so
native cursor-line conceal rules cannot expose trailing HTML. Multiline summary
rows and the closing tag are hidden, with blank overlays for cursor restoration.
The title uses `InkstoneDetailsHeader`; viewport-clipped body backgrounds use
`InkstoneDetailsBody` at priority 80, below code backgrounds. These marks remain
visible under anti-conceal while Normal-mode rendering is active. They add no
columns to the body and do not alter source bytes.
Closed body marks carry `fold_closed`: `Updater:hide` ignores anti-conceal
margin-only overlap when the actual cursor is outside that body. Deliberate
source entry can still restore it under enabled anti-conceal. Child fold state
is independent and survives parent close/reopen. `tests/softwrap.lua` covers
nested open/close cycles with right-aligned, padded code labels and anti-conceal
margins that previously caused absent indicators or visible collapsed bodies.

`folds.attach` installs buffer-local Normal-mode `j/k`, `gj/gk` and Up/Down
defaults in all attached buffers before `on.attach`, so user overrides remain
possible. `folds.move` backs these defaults and the `InkstoneMoveDown` /
`InkstoneMoveUp` Plug mappings. It reads only displayed `fold_hidden` marks from
the decorator, skips those inclusive ranges, and counts source or screen rows
according to the initiating motion. Mode/anti-conceal
restoration therefore makes the motions native without reparsing trees. Jumps
retain the preferred column, respect native folds and stop at the anchor when
a collapsed block reaches EOF. Raw/disabled views use native motions. It does
not set the user's foldmethod, operator-pending maps or Visual maps.
`tests/features.lua` covers summary extraction, parent selection and code
anchors; `tests/softwrap.lua` exercises actual grid output and mapped motions
through an 800-line details/code block, counts, raw fallback and native folds.
The ordinary-buffer regression sends actual `j/k`, `gj/gk` and arrow input
without test-installed movement mappings, with anti-conceal both enabled and
disabled. Soft-wrap and operator tests retain native screen/source semantics.

`core/media.lua` collects visible image/diagram requests after folding,
uses async local conversion and
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
`core/actions.lua` dispatches a shared view action to collapsed ancestors first,
then tables, open folds and media on the cursor row. Table queries share the
code-example boundary predicate. `manager.attach` installs its buffer-local
Normal-mode Ctrl+i action before `on.attach`, allowing user overrides. Unmatched
or disabled-buffer keypresses retain native counted jump-forward movement;
explicit `toggle_view` calls simply do nothing without a target. Async dispatch
rejects source/cursor/window changes before selecting a target. Numeric tables
retain the existing table/list/chart cycle; nonnumeric tables skip charts.
`tests/rich.lua` covers dispatch/hidden-child boundaries and media selection;
`tests/softwrap.lua` sends actual Ctrl+i input through table cycles, code,
callout/details toggles and native jump fallback.

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

`core/table_media.lua` coordinates table image cells before block rendering.
It collects visible image candidates from the request's eligible inline trees.
For one-window, padded/trimmed wrapped tables with conceallevel >= 2 and a
Snacks placeholder backend, the table parser includes image width preferences
in ordinary column allocation. `render/markdown/table.lua:wrapped_row` appends
each loaded grid below its cell caption and aligns every row through the same
column budgets, including vertical borders and shorter neighboring cells.

`core/media.lua` owns loading and placement lifetime. Cell requests include
their width/height budgets; changed source or geometry closes the old placement.
The adapter overrides only each managed placement's `state`/`render_grid`
methods. It calls the backend's existing grid builder on a proxy, capturing
its image-ID highlights and Unicode placeholder chunks instead of letting it
emit separate virtual lines. Backend transfer and fitting remain native.
Grid readiness schedules a guarded render; stale completions cannot publish.
Table source restoration, view changes, disable and wipe remove placements.

The optional Snacks integration wraps `image.doc.find` once and filters only
managed table ranges in active Inkstone contexts. It leaves unrelated buffers,
ordinary images and global Snacks options intact. Public placement cleanup
retires previously rendered native table grids identified in the Snacks
namespace. This adapter depends on the installed backend's `state`,
`render_grid`, `_render` grid shape and `SnacksImage<placement-id>` highlights;
it is an integration boundary to revalidate when updating Snacks. Unsupported
backends/shared buffers use their existing image behavior. The terminal test
`test_table_images_share_cell_rows_and_replace_native_document_placements`
uses real native preexisting images, PNG/GIF grids, resize, anti-conceal,
list transitions and source preservation with stock tmux/Kitty.

## Kitty typography

`core/typography.lua` owns literal display runs, screen-space placement, terminal
detection and repaint lifecycle. Headings reserve their scaled rows through
normal extmarks; eligible `<small>` HTML spans retain source cell positions.
Decorations and layout are shared per buffer, and each buffer's terminal
placements have one owner window. Showing the same buffer in multiple windows
(including floats or other tabs) therefore uses normal-size rendering in all
of its views. Window lifecycle changes force a new layout when the view set
changes; returning to one window restores sizing. Separate buffers retain
independent typography in their splits.
`core/ui.lua:Updater:run` resolves editing mode per buffer: only the active
buffer follows the global mode; inactive buffers retain normal-mode rendering.
Scratch-local OptionSet or decoration refreshes must not apply the scratch's
Insert mode to the background document. Clearing that document removes its
scaled-row reservations, changes its height and moves later text under the
float. Covered glyphs are still suppressed by occlusion while their layout
remains intact. `tests/softwrap.lua` covers the buffer/window-option contract;
`test_decorated_scratch_keeps_background_typography_geometry` checks actual
Kitty multicells, the complete decorated popup rectangle, unchanged source
height and restored heading coordinates across editing and decoration changes.
The redraw provider distinguishes occlusion from lower-multicell write hazards.
Before native drawing, `erase_redraw_hazards` also removes glyphs whose lower
rows share a screen row with another float, even when their horizontal bounds
do not overlap. Ordinary writes into Kitty multicell lower rows skip the glyph;
native leading blanks and a later popup border can therefore share one output
run and shift the border horizontally. Bounds-only occlusion cannot prevent
this. The redraw-end paint restores uncovered glyphs; it still suppresses
only actually covered placements. The reservations and window geometry remain
unchanged. `test_popup_border_beside_decorated_multicell_lower_row_does_not_shift`
reproduces the six-cell drift with a Japanese fractional heading, a changed
blank in its lower reservation and a scratch border on that row. It compares
the entire popup grid and heading presence at synchronized frame boundaries,
as well as restored heading text after each decoration update.
ATX titles expose a direct `inline` child; Setext titles expose it through a
`paragraph`. Both use the configured size for their heading level. Multiline
Setext content is styled per source row and reserves scaled virtual rows for
each title line. Only continuation rows and the underline are line-concealed;
the end row excludes the following block. The full title/underline source
range owns anti-conceal restoration. A thematic break never enters this path.
Once terminal support is confirmed, those extmarks reserve whitespace rather
than a normal-size copy of the text. The literal runs remain in the OSC 66
placement. Otherwise a native repaint can expose plain heading text without
`##`, or draw a second copy over the enlarged text, while the source is still
concealed correctly. Native reservations preserve display widths and styles;
unsupported/disabled typography uses the normal renderer, and anti-conceal
still restores source. Whitespace reservation removes the duplicate copy; it
does not make the terminal overlay independent of native grid repaint timing.
Inline code containing those literal tags is not interpreted as markup.
Payloads contain sanitized text and grapheme-safe chunks within OSC 66's bounds.
Integer-scale ASCII uses OSC 66's automatic width (`w=0`), so Kitty lays out
individual characters on the scaled grid. Grouping seven ASCII characters in
one fixed-width multicell can leave font-metric padding at packet boundaries
even when cell advances are exact (the photographed "evi dence" case).
Non-ASCII clusters retain explicit widths. Fractional runs prefer whitespace
boundaries and keep words within the protocol's seven-cell width limit intact;
1.5x can fit all nine letters of "paragraph" or "Reproduce" in one packet.
When a word exceeds the limit, prefer denominator-aligned grapheme boundaries
to avoid adding integer-cell padding inside it. Highlight changes and
indivisible wide graphemes still constrain grouping. Rounded advances can
remain at natural spaces or an unrepresentable boundary; this is not arbitrary
subcell positioning or a promise about every font's pixel metrics.
Fractional ASCII spaces are separated from glyph packets. `space_runs` deducts
the preceding word's unused reservation from the next space's advance, rather
than rounding both independently. Remaining blank cells use height-one explicit
width packets; sufficiently large padding can instead contain a literal space
appended to the preceding same-highlight packet. Never append when the text
would no longer fit, or merge away independently highlighted whitespace.
This preserves source text/space counts and avoids shrinking word glyphs.
Consecutive spaces carry the rounding balance forward. At 1.5x, the tested
single-space gaps range from 1.5 to 2 native cells instead of ballooning to
2.5 or 3. Fractional positioning and font metrics still prevent a general
pixel-identical-space guarantee; integer-scale ASCII is unchanged.
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
native and tmux-adjusted bounds, and output payload. The painter compares
placement ownership independently, so a redraw in one place does not erase
every heading. Clearing an unrelated buffer is
a no-op for placements. Changed content retires only entries whose IDs vanished
or whose display data changed; viewport collection of a distant heading does
not erase unchanged headings. Origin/width changes erase owned extents before
native redraw. On a pure scroll, native scrolling moves/replaces the cells;
old screen coordinates are forgotten without sending an erase into newly
exposed body text, and current placements are replayed at the new positions.
The viewport snapshot includes topline, topfill and skipcol, so scrolling within
one wrapped source row or virtual filler follows the same ownership rule.
Command-line height changes preserve still-visible
lines when their origin and width are unchanged. Pre-draw erases target actually
occluded lines and lower-row float hazards while retaining unrelated placements.
Floating window positions are zero-based outer corners; convert them to the
one-based screen coordinates used by placements before testing intersections.
Their bounds include only nonempty border sides returned by the window config.
Otherwise a popup's bottom/right border can be repainted by enlarged glyphs,
while borderless floats can incorrectly suppress adjacent headings.
Every Neovim redraw replays visible, uncovered placements in the provider's
`on_end`. Owned-window redraws, changed placement payloads and redraws with no
identified foreign window also schedule one coalesced repair after the native
grid flush. A routine foreign-buffer/split redraw with unchanged placements
needs the in-frame replay but skips that duplicate repair. Decoration-provider
`on_buf`/`on_win` callbacks classify only this second pass; they never suppress
the global in-frame replay. tmux can repaint a complete terminal row and erase
an unchanged heading even when its window received no native redraw callback.
For tmux, the in-frame replay first sends a native (unwrapped) `CSI ? 2026 l`.
This flushes the pane's collected native rows before the OSC 66 passthrough;
tmux's own terminal synchronized update then commits both together. Sending
passthrough first lets later native rows erase the glyph or recreate the
multicell cursor skip. No tmux options or terminal sync nesting are used.
Full TUI invalidations can still print cells after the provider callback, so
the scheduled repair remains necessary, especially outside tmux. This is not
a universal atomic-rendering API or a guarantee about every GPU frame.
Native output can overwrite
multicells with identical blank cells, including composed/virtual rows without
an owned source-row callback. Equal screenstring/screenattr snapshots therefore
cannot prove the terminal overlay survived. Production painting keeps neither
cell snapshots nor per-source-row damage keys: both add work without allowing
the in-frame redraw repair to be skipped. Tests read the native grid directly when
verifying blank reservations. Explicit recovery uses `schedule(true)`.
Idle typography does not replay text by default, including fractional
H2/H3 sizes. Periodic replays are observable output even without explicit erases;
final multicell metadata alone does not establish that intermediate GPU frames
are stable.

`tests/terminal_compat.py` covers 40 rapid foreign-split updates, unchanged
heading content across viewport entry-set changes, clipped/page-scroll cleanup
and ASCII body cells outside placements. The driver pumps PTY output while RPC
is pending and feeds the terminal parser at synchronized-frame boundaries,
avoiding output backpressure and per-byte parsing overhead. A simultaneous
Normal-color/full-screen invalidation in a streaming split exposed an
intermediate empty frame with both the former unconditional repair and the
current painter; final recovery is verified separately for that case. These
tests establish terminal cell state, not universal GPU flicker elimination.

Passthrough permission alone is not visibility: `allow-passthrough=all` also
forwards output from hidden panes into the attached client's current view.
`check_visibility` suspends output immediately on focus transitions and reads
window/pane/zoom visibility over the tmux socket before resuming. Hidden owners
are forgotten without sending glyph erases into the destination view. An
unfocused pane can later become hidden without another FocusLost, so
`background_visible` validates visibility before background paint/erase output;
it also guards configurations without focus notifications. Focused panes with
focus notifications use the cached fast path. A redraw checks visibility once
before its pre-erases and reuses that result within the provider callbacks.
The bounded subprocess poll pumps only libuv: `SystemObj:wait()` calls
`vim.wait()`, which flushes the native UI even with `fast_only=true`. Such a
flush inside a provider commits the cleared heading before its replacement;
even a check in `on_start` can prematurely flush changed default colors.
Timeouts still fail closed and terminate the query process.
A queued paint can also see a newly created float before its first native
redraw. Covered old placements stay tracked until the provider's pre-erase;
dropping them early loses the multicells that must be removed before the popup
draws. Late paint never clears over the popup itself.
Queued geometry callbacks wait for
a fresh snapshot if focus changes during an in-flight query. Hidden recovery
timers stop, and FocusGained restores visible placements without changing tmux
options. If a native redraw starts while the asynchronous focus query is still
pending, `on_start` checks visibility with the non-flushing bounded query and
allows the same frame's overlay repair. Waiting for the asynchronous reply
would commit blank reservations during focus-time highlights or animations.
The delayed-query terminal regression checks this ordering; hidden-pane tests
retain the no-output guarantee. Without focus notifications, the next native
redraw restores placements.

With updated auto-cursorline.nvim, `sync_cursorline` temporarily owns
`w:auto_cursorline_disabled` while the cursor is on a shown typography range.
It restores the previous value on ordinary rows, buffer/window changes or
typography clear, and does not claim an already true flag owned elsewhere.
The optional loaded auto_cursorline module is notified immediately, so both
active highlights and queued enable timers honor suppression. Source restored
by anti-conceal retains normal cursorline behavior. No plugin is loaded just
for this integration and no global cursorline setting is changed.

Windows with typography also temporarily own `w:auto_cursorline_extmark`.
Updated auto-cursorline uses a window-scoped current-row mark for the delayed
CursorLine/CursorLineNr highlight, keeping the native `cursorline` option off.
Changing that native option can commit a fallback-text frame before scheduled
overlay repair; dirty-line tracking alone cannot remove that gap. The row mark
changes only the affected source row. Leaving typography restores the previous
flag and auto-cursorline's native behavior. Explicit `screenline` cursorlineopt
retains native behavior, since a whole-source-row mark has different wrap semantics.

Retire placements on BufWinLeave, TabLeave and WinClosed before another view
draws. The provider also prunes invalid owners before native drawing starts.
Erasing an obsolete placement only in a scheduled paint is too late: its old
coordinates can already contain another buffer's text. Ordinary focus changes
between still-visible windows retain the source window's owned placement.
Outside tmux, FocusGained forces an in-place replay without erasing placements
or invalidating terminal capability/geometry. Only VimResized retires those
coordinates and refreshes geometry. Under tmux, focus still requires the
visibility check above to protect the destination pane.
Focus handlers that change the global Normal background can invalidate the
entire native TUI, including after the provider replay. These full-screen
invalidations retain the same intermediate-frame limitation as other default
color changes; removing the direct-terminal erase does not eliminate that case.
Configurations can reduce this damage by keeping the global Normal background
unchanged and suppressing focus animations while sized text is active in any
window of the current tab. Inspect only already-loaded typography state so
focus events do not initialize a Markdown renderer. Inactive tabs, stale window
owners and disabled typography should retain ordinary focus behavior.

Redraw replays reissue multicells without a preceding glyph erase;
only obsolete extents and trailing reserved cells need explicit clearing.
An external tmux refresh can overwrite passthrough text without a Neovim event.
`:Inkstone refresh` explicitly rebuilds the current view and forces overlay replay.
`typography.recovery=true` opts a buffer into the former 250ms foreign-repaint
recovery loop. Its unchanged replays target only opted-in
buffers. The timer runs only while at least one such buffer is visible, and
stops when the last one is hidden/cleared. It is off by default to avoid periodic
output and fractional-text flicker. Size-only changes still clear
the previous extent even when grid extmarks were reused. Float/popup bounds and active tabs are checked
before drawing; cursor source restoration follows anti-conceal. Terminal geometry
refreshes retain request waiters until the fallback frame is rebuilt. Setup,
disable and wipe release owned placement timers and request waiters; a pending
probe retains its bounded timer and input guard until reply or timeout.

`lib/terminal_colors.lua` resolves highlight stacks for each window/paint.
Normal/NormalNC supply the base; configured heading foreground/background
groups supply defaults, and inline groups retain their ordered overrides.
Background groups contribute background and style attributes rather than
replacing the foreground. Window highlight namespaces and winhighlight links
resolve with global fallbacks, including namespace links to globally defined
groups. RGB foreground/background/special colors, bold, italic, reverse,
strikethrough and underline variants become SGR attributes before OSC 66 text.
Named definitions and completed SGR sequences are cached only within that
paint, so direct highlight edits and theme changes take effect on the next
redraw without stale global caches. This reproduces named renderer highlights;
arbitrary third-party per-cell decorations are not sampled from the grid.

The source bytes and normal grid remain authoritative. This is a scoped
terminal overlay, not a replacement Neovim TUI, and brief fallback/flicker during
unrelated redraws is possible. `doc/rendering-features.md` owns configuration,
eligibility and user-facing limits; `demo/rich.md` is the interactive sample.

## Experimental image typography

The opt-in `typography.backend='image'` reuses heading collection, source
restoration and shared-buffer fallback. `typography_image.layout` wraps native
display units with the existing Japanese/word-boundary layout, using the scaled
width budget. It retains whole style spans with fractional advances and rounds
only the final placeholder extent. OSC 66's seven-cell packet splitting and
per-packet cell quantization must not be reused: those produced gaps inside
`inkstone.nvim` and `必要なもの` in the photographed prototype. `core/typography_image.lua`
owns per-buffer heading slots and refcounted content assets. The Rust helper in
`native/` reads bounded JSON and returns PNG pixels using Pango/Cairo; it has no
terminal output or source-file access. At most two conversion jobs run at once.
Text/styles, font, raster cell dimensions, command and executable metadata key
the disk cache. Obsolete slots cancel unshared work; late completions cannot
upload or trigger a render after their owner is disposed. Errors retain the
normal heading renderer, and PNG publication uses private temporary files.

The Rust helper shapes each complete line with Pango attributes indexed by
UTF-8 bytes, merging equivalent adjacent attributes. Subpixel font metrics and
unrounded glyph positions set the base size. A single horizontal transform fits
the terminal cell proportions; fallback-font width correction applies to the
whole line. Native row reservations use ceil(ratio), while the font uses the
actual ratio, so 1.25x/1.5x/2x remain visually distinct within two-row layouts.
Rust pixel tests compare split versus unsplit words and actual ink bounds across
ratios; image-presence tests alone do not establish spacing or size correctness.

`lib/graphics.lua` is independent of Snacks and heading layout. It uploads PNGs
as quiet Kitty graphics virtual placements and encodes full image IDs plus
row/column indices into ordinary placeholder cells. Ready headings emit those
cells in their overlay and virtual-line extmarks. The first image row overlays
the concealed source line rather than adding inline width: it clips at the
window edge just like the remaining virtual rows. Otherwise a pending resize
or a full-width row followed by a `listchars` EOL marker can wrap that first
row and separate the glyphs' upper and lower halves. Normal redraw, scrolling,
popup occlusion and tmux window switching move/clip the same cells. No OSC 66
provider, idle repair, or image retransmission participates in their redraw.
Per-image highlight IDs are restored if a colorscheme cleared them. Release
deletes only exact owned image IDs; hidden uploads cannot place pixels on the
destination pane because prototypes have no physical screen location.

`typography.visible()` reports shown typography in valid windows of the current
tab for either backend. Image ownership alone is insufficient: pending, failed
and anti-concealed assets do not count. `typography_image.update` records the
shown placeholder extmarks during reconciliation. Focus integrations can use
this query to retain the existing Normal background and avoid focus animations.
An OSC-only check misses image headings: changing Normal between transparent
and opaque changes their resolved raster colors, invalidating the cache key and
replacing/retransmitting the image on each focus transition.

Image generation/display is optional and the default remains `backend='text'`.
The capability gate conservatively retains Kitty 0.40+ and existing passthrough
permission checks. Inline small spans keep ordinary rendering in this backend.
Raster cell proportions are configurable; theme/style changes need a render.
Image pixels do not expose terminal text selection or per-character search
highlights. `native/README.md` owns setup, protocol limits and the isolated
`demo/image-typography.lua` preview. `tests/image_typography.lua` checks pending/
failed native fallback, cache reuse, cleanup and cancelled jobs. Image tests in
`tests/terminal_compat.py` decode actual PNGs and resolve Kitty render layers at
synchronized frame boundaries; these do not prove every GPU/compositor frame.

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
- Extend native paragraph wrapping to nested lists/quotes, inline replacements
  and independently scoped shared-window layouts.
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
