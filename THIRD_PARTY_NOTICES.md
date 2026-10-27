# Third-party notices

## render-markdown.nvim

Source: https://github.com/MeanderingProgrammer/render-markdown.nvim

MIT License, Copyright (c) 2024 Vlad. The license is retained in `LICENSE` and
`licenses/render-markdown.MIT`. The initial source revision is pinned in
`UPSTREAM.json`.

The runtime, upstream tests and reference documentation were adapted into an
independent `inkstone` namespace. Changes include viewport-bounded code marks,
lazy node text, bounded width summaries, grouped highlight sorting, stale-node
traversal protection, asynchronous rendering, latest-frame scheduling, resource
cleanup and Japanese table layout. Original notices remain applicable.

## budoux.lua / Google BudouX

Source: https://github.com/delphinus/budoux.lua
Original: https://github.com/google/budoux

Apache License 2.0; Copyright 2025 delphinus and Copyright 2021 Google LLC.
The complete license and notice are retained at `licenses/budoux.Apache-2.0`
and `licenses/budoux.NOTICE`.

The Lua implementation and models are vendored under `lua/inkstone/vendor/budoux/`.
Model module imports were changed to the private `inkstone.vendor.budoux`
namespace; the segmentation algorithm and model data were not otherwise changed.

## md-render.nvim

Source: https://github.com/delphinus/md-render.nvim

MIT License, Copyright (c) 2026 delphinus. The license is retained at
`licenses/md-render.MIT`. Its Japanese wrapping design was consulted, and its
JIS-inspired forbidden-start / forbidden-end character sets were adapted in
`lua/inkstone/text/layout.lua`. The wrapping algorithm in Inkstone is separate;
full JIS X 4051 conformance is not claimed.
