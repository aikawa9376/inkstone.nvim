-- Offline upstream-compatibility suite; install parsers and test deps explicitly.
vim.o.columns, vim.o.lines = 80, 40
vim.o.laststatus, vim.o.ruler, vim.o.tabstop, vim.o.wrap = 0, false, 4, false
local data = vim.fn.stdpath('data')
vim.opt.rtp:prepend('.')
if vim.env.INKSTONE_EXTRA_PARSER_RTP then vim.opt.rtp:prepend(vim.env.INKSTONE_EXTRA_PARSER_RTP) end
vim.opt.rtp:append(vim.env.INKSTONE_PARSER_RTP or (data .. '/site'))
vim.opt.rtp:append(vim.env.INKSTONE_PLENARY_RTP or (data .. '/lazy/plenary.nvim'))
vim.opt.rtp:append(vim.env.INKSTONE_MINI_ICONS_RTP or (data .. '/lazy/mini.icons'))
vim.cmd.runtime('plugin/plenary.vim')
vim.cmd.runtime('plugin/inkstone.lua')
require('mini.icons').setup({})
vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('InkstoneTestHighlighter', {}),
    pattern = 'markdown',
    callback = function(args) vim.treesitter.start(args.buf) end,
})
