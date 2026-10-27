# Performance evidence

Initial measurements: 2026-10-27, Intel i7-6700K, Neovim
0.13.0-dev-1953+g3ee26cf91f, LuaJIT, installed Markdown/Markdown-inline/Lua
parsers. Baseline source revision is recorded in `UPSTREAM.json`.

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

## Reproduce

```sh
INKSTONE_BENCH_OUT=/tmp/inkstone-bench.json make bench

# Optional: provide an unmodified render-markdown checkout for comparison.
INKSTONE_BASELINE=1 \
INKSTONE_UPSTREAM_RTP=/path/to/render-markdown.nvim \
INKSTONE_BENCH_OUT=/tmp/render-markdown-bench.json make bench
```

Use `INKSTONE_PARSER_RTP` if parser binaries live outside Neovim's usual data
site. Compare runs on the same machine without other CPU-intensive work.

The first render may still parse and scan a whole large code block. Width
summaries are cached for unchanged buffer revisions and have size bounds.
Streaming edits invalidate the width summaries conservatively. Long logical
lines, table cell assembly and highlight/tree queries still have measurable
costs. The architecture document records the remaining work rather than
assuming that a Rust rewrite would remove all of it.
