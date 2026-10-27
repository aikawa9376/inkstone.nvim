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
3. `core/handlers.lua` evaluates inline handlers before block handlers.
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
TSNodes, have per-buffer entry/row limits, invalidate on changedtick and relevant
width options, and disappear on wipe. The first cold width scan still reads the
whole block. Unrelated edits currently invalidate that buffer's width summaries.

Highlight groups are appended cheaply and sorted only before a row is consumed.
Conceal coalescing retains the inherited behavior; batching that computation
requires separate compatibility work. Disabled trace logging does not materialize
node text. Guarded sibling traversal rejects empty nodes and nondecreasing starts
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

`core/folds.lua` discovers code fences, callouts and paired details blocks in
Markdown trees. It filters hidden child decorations and emits conceal/summary
marks; explicit toggle state follows source edits via a separate extmark
namespace. It does not set the user's foldmethod. `core/media.lua` collects
visible image/diagram requests after folding, uses async local conversion and
delegates graphics to Snacks. Pending placements reject edited/wiped buffers;
disable/setup/wipe close placements and cancel jobs. Native Snacks document
placements are not duplicated. See `doc/rendering-features.md` for configuration,
dependencies and remaining boundaries.

## Next work

- Incremental block summaries that survive unrelated edits, with bounded caches
  and source/version/width-option invalidation.
- Reduced tree enumeration, viewport-aware table row construction, and reusable
  unchanged extmarks.
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

`make terminal` starts isolated stock tmux and Neovim instances in pseudo
terminals, feeding real output to the installed Kitty native VT parser. It
checks table cells (including wrapped virtual rows), repaint, original buffer
bytes, yank and opt-out. This verifies terminal cell state, not GPU glyphs.
The compatibility pass stays within viewport ranges for source overlays and
does not change source offsets, measured widths or the terminal output layer.
