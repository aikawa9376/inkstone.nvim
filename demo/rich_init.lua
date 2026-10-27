-- Offline, isolated demo: nvim --clean -u demo/rich_init.lua demo/rich.md
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(vim.env.INKSTONE_PARSER_RTP or (vim.fn.stdpath('data') .. '/site'))
vim.o.termguicolors, vim.o.swapfile, vim.o.wrap = true, false, true
vim.g.mapleader = ' '

local snacks = vim.env.INKSTONE_SNACKS_RTP or (vim.fn.stdpath('data') .. '/lazy/snacks.nvim')
if vim.uv.fs_stat(snacks .. '/lua/snacks/init.lua') then
    vim.opt.rtp:prepend(snacks)
    require('snacks').setup({ image = { enabled = true, doc = { enabled = false }, math = { enabled = false } } })
end
require('inkstone').setup({ anti_conceal = { enabled = false }, paragraph = { wrap = false },
    pipe_table = { cell = 'trimmed' }, code = { sign = false } })
vim.cmd.runtime('plugin/inkstone.lua')
vim.api.nvim_create_autocmd('FileType', { pattern = 'markdown', callback = function(event)
    pcall(vim.treesitter.start, event.buf, 'markdown')
    vim.keymap.set('n', '<CR>', '<Plug>(InkstoneToggleView)', { buffer = event.buf })
end })
vim.keymap.set('n', '<leader>mv', '<Plug>(InkstoneToggleView)')
vim.keymap.set('n', '<leader>ml', '<Plug>(InkstoneToggleList)')
vim.keymap.set('n', '<leader>mg', '<Plug>(InkstoneToggleChart)')
