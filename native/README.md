# Experimental Rust image typography

`inkstone-raster` shapes Unicode text with Pango and rasterizes it with Cairo.
It reads one JSON request from stdin and writes one PNG to stdout. It never
writes terminal controls, reads source files or invokes an external command.
The Lua graphics transport can also display PNGs produced by other tools.

Build dependencies are Rust 1.92+/Cargo, pkg-config, and the Pango/Cairo development
libraries. No GTK windowing application or Snacks plugin is required.

```sh
make raster
make raster-test
nvim --clean -u NONE -i NONE -c 'luafile demo/image-typography.lua'
```

The preview uses your installed Markdown Tree-sitter parsers. Run it inside
Kitty and, for tmux, use your existing `allow-passthrough on` setting. The plugin
does not change tmux options. The current capability gate retains the existing
Kitty 0.40+ requirement, although Unicode image placeholders predate that release.

Selecting the Git branch alone keeps `backend='text'`. For an existing
configuration, opt in explicitly:

```lua
require('inkstone').setup({
    typography = {
        backend = 'image',
        image = {
            -- The default command finds a helper built inside this plugin checkout.
            font = 'monospace', -- Pango/fontconfig family; Japanese uses font fallback
            cell_width = 16,
            cell_height = 32,
        },
    },
})
```

For lazy.nvim, build when installing/updating the experiment:

```lua
{
    'aikawa9376/inkstone.nvim',
    branch = 'experiment/rust-image-typography',
    build = 'make raster',
    opts = { typography = { backend = 'image' } },
}
```

The default command searches PATH first, then the plugin's own
`native/target/release/inkstone-raster`. Custom command vectors remain exact;
an explicit absolute path can select another build.

`backend='text'` remains the default. The image prototype covers top-level ATX
and Setext headings with the existing wrapping and anti-conceal policy. Inline
`<small>` text keeps ordinary rendering. Shared-buffer windows use the existing
native fallback. Missing helpers, unsupported terminals, oversized requests and
conversion failures retain the complete normal-size heading renderer. Image
generation is asynchronous with at most two jobs; no worker starts per redraw.

The raster cell dimensions control resolution and aspect ratio, independently
of the actual terminal font size. Images fit their reserved terminal cells;
adjust these values to match your terminal's cell proportions if necessary.
No terminal response query is added, including under tmux extended keys.

Assets are keyed by text, styles, font, dimensions, command and executable file
metadata. PNGs are reused from `typography.image.cache_dir`. Terminal images
are retained only while requested by a buffer's viewport and are deleted by
their exact owned IDs. Native redraws, focus changes and floats move/clip the
placeholder cells without retransmitting or repainting the bitmap. Theme/style
changes are reflected on the next render; use `:Inkstone refresh` after direct
highlight or font-setting changes. Toggle typography off/on to retry a failed
job. There is no automatic dependency download at runtime.

Raster text is not terminal-selectable text. Native source editing, selection
and search still operate on the Markdown, but their highlights are not projected
inside image pixels. Font fallback and glyph metrics can differ from Kitty's.
Frame tests validate decoded PNGs and Kitty image render layers, not all GPU or
desktop-compositor frames.

Other buffers can trigger terminal redraws even when they are plain text.
The image backend does not repair an OSC 66 overlay in response: ACP streaming
and word-highlighter extmark changes in a scratch are covered by terminal frame
tests. This isolates image placement from those updates while leaving their
normal decorations enabled.
