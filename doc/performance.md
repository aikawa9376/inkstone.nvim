# Performance evidence

Initial measurements: 2026-10-27, Intel i7-6700K, Neovim
0.13.0-dev-1953+g3ee26cf91f, LuaJIT, installed Markdown/Markdown-inline/Lua
parsers. Baseline source revision is recorded in `UPSTREAM.json`.

## Initial fork measurements (before paragraph reflow)

Both renderers use the same 140-column window, 41-row synthetic view and
comparable code/table options. Each row below is a median after a warm-up:
five handler runs and three extmark application runs. Different renderers run
in separate processes. The measurements exclude terminal drawing, provider
activity and unrelated plugins. Full native parsing is reported separately by
the runner and is not included in the render/apply columns.

| Synthetic case | Baseline generation | Inkstone generation | Baseline apply | Inkstone apply | Marks baseline → Inkstone |
| --- | ---: | ---: | ---: | ---: | ---: |
| 7,000-row Lua fence | 21.48ms | 1.68ms | 71.70ms | 0.46ms | 21,005 → 128 |
| 500 inline link/bold/code groups on one source row | 91.04ms | 32.31ms | 1.51ms | 1.38ms | 1,000 → 1,000 |
| 1,000 Japanese table rows | 16.52ms | 15.06ms | 0.57ms | 0.56ms | 82 → 82 |

These are targeted workloads, not a universal editor speedup claim. The table
case performs Japanese phrase segmentation in Inkstone, so its behavior is not
identical to upstream character/word wrapping. Native full parsing of the Lua
fence remained about 0.74–0.75s for both: caching and clipping decoration do not
make Tree-sitter parsing itself faster. Async rendering is intended to improve
responsiveness; this benchmark does not measure input latency.

## Incremental rendering with paragraph reflow

Same machine and Neovim build, 2026-10-27. The before version is Inkstone
`8339d09`; the after version is the incremental-rendering working tree. Both
use default paragraph reflow and the same benchmark options. These numbers
are separate from the earlier upstream comparison, which predates paragraph
reflow. Handler medians use five samples after a warm-up. Refresh medians use
three samples and include Extmark object construction, reconciliation and
display of unchanged descriptions, excluding handler generation.

| Synthetic case | Generation before → after | Unchanged refresh before → after | Retained native marks after |
| --- | ---: | ---: | ---: |
| 7,000-row Lua fence | 2.40 → 2.32ms | 0.69 → 0.11ms | 128 |
| 500 inline link/bold/code groups on one source row | 150.74 → 120.00ms | 5.34 → 1.09ms | 1,002 |
| 1,000 Japanese table rows | 26.78 → 18.99ms | 0.59 → 0.19ms | 83 |

All mark descriptions in these three fixtures match before/after when ignoring
internal table-ownership metadata and the API's `strict` normalization. The
retained counts include generated virtual-line marks, so they can exceed the
handler's mark count. No native marks survived the before version's full-clear
refresh. Real cursor moves, edits and scrolling can retain fewer marks.

Fresh extmark application did not improve: code 0.46 → 0.56ms, inline
3.95 → 5.04ms, table 0.68 → 0.80ms. Reuse targets subsequent updates.
The first paragraph render remained about 214 → 211ms; warm layout caching
does not remove native highlight queries or inline-handler work. Cold full
Lua parsing remained about 0.75–0.77s. These are CPU/API measurements, not
terminal input-latency measurements or a claim of smooth rendering for every
large paragraph.

## Reproduce

```sh
INKSTONE_BENCH_OUT=/tmp/inkstone-bench.json make bench

# Optional: provide an unmodified render-markdown checkout for comparison.
INKSTONE_BASELINE=1 \
INKSTONE_UPSTREAM_RTP=/path/to/render-markdown.nvim \
INKSTONE_BENCH_OUT=/tmp/render-markdown-bench.json make bench

# Compare another Inkstone checkout with the current benchmark runner.
INKSTONE_BENCH_RTP=/path/to/older/inkstone.nvim \
INKSTONE_BENCH_OUT=/tmp/older-inkstone-bench.json make bench
```

Use `INKSTONE_PARSER_RTP` if parser binaries live outside Neovim's usual data
site. Compare runs on the same machine without other CPU-intensive work.

The runner reports native full parse, first handler render, warm generation,
fresh application, unchanged refresh and retained mark count separately.
`INKSTONE_BENCH_MARKS=/tmp/inkstone-marks` optionally saves full descriptions
for each scenario for output comparisons.

The first render may still parse and scan a whole large code block. Width
summaries have size bounds; unrelated edits retain them, and row insertions
translate their ranges. An edit inside a summary still invalidates that whole
summary. Long logical lines, table cell assembly and highlight/tree queries still have measurable
costs. The architecture document records the remaining work rather than
assuming that a Rust rewrite would remove all of it.
