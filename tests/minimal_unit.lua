vim.opt.rtp:prepend('.')
vim.opt.rtp:append(vim.env.INKSTONE_PARSER_RTP or (vim.fn.stdpath('data') .. '/site'))
vim.opt.rtp:append(vim.env.INKSTONE_PLENARY_RTP or (vim.fn.stdpath('data') .. '/lazy/plenary.nvim'))
vim.cmd.runtime('plugin/plenary.vim')
