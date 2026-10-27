if vim.g.loaded_inkstone then
    return
end
vim.g.loaded_inkstone = true

require('inkstone').setup(vim.g.inkstone_config)
require('inkstone.core.colors').init()
require('inkstone.core.command').init()
require('inkstone.core.log').init()
require('inkstone.core.manager').init()
