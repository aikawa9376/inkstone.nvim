-- From the repository: nvim --clean -u NONE -i NONE -c 'luafile demo/image-typography.lua'
-- Build first: make raster
local source = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fs.dirname(vim.fs.dirname(source))
local binary = root .. '/native/target/release/inkstone-raster'
assert(vim.fn.executable(binary) == 1, 'Build the Rust helper first: make raster')
assert(not package.loaded['inkstone'], 'Use a clean Neovim instance for this isolated preview')
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.o.termguicolors, vim.o.wrap, vim.o.number = true, true, false
vim.o.swapfile, vim.o.conceallevel, vim.o.concealcursor = false, 3, 'nvic'
require('inkstone').setup({
    anti_conceal = { enabled = false },
    media = { enabled = false },
    overrides = { buftype = { nofile = { render_modes = { 'n', 'c' } } } },
    typography = { enabled = true, backend = 'image', image = {
        command = { binary }, font = vim.env.INKSTONE_FONT or 'monospace',
        cache_dir = vim.env.INKSTONE_IMAGE_CACHE,
    } },
})
vim.cmd('runtime plugin/inkstone.lua')
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    'Rust image typography — experimental', '',
    '# 日本語の見出し · Inkstone', '',
    '本文は通常のテキストです。見出しだけを Rust で画像にしています。', '',
    '## 画像として描く **強調** と `code`', '',
    'Snacks は読み込みません。画像の位置は Neovim の装飾で管理します。', '',
    '### Focus・スクロール・ポップアップ', '',
    'ほかのディスプレイへ移動して戻る、スクロール、:vnew などを試せます。', '',
    'ソースを編集する場合は i / v で表示を戻します。',
    ':Inkstone typography で通常の見出しへ切り替えられます。', '',
    '色やフォントの変更後は :Inkstone refresh で画像を更新します。', '',
    '# 長い見出しを折り返す · 日本語の組版と画像の配置を確認します', '',
    '選択・検索ハイライトは画像内の文字へは投影されません。元テキストは保持されます。', '',
    '## English, café, emoji 👩‍💻 and 日本語', '',
    'Lua owns placement and lifecycle; Rust generates PNG pixels with Pango/Cairo.', '',
    '---', '',
    'このウィンドウを閉じると実験表示を終了します。',
})
vim.bo.filetype = 'markdown'
vim.bo.buftype, vim.bo.bufhidden, vim.bo.modified = 'nofile', 'wipe', false
vim.treesitter.start(0, 'markdown')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
require('inkstone').render({ buf = vim.api.nvim_get_current_buf() })
