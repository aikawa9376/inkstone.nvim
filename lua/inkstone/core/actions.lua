local M = {}

-- One action for preview interaction: table views, folds, then media.
function M.toggle(buf, win)
    buf, win = buf or vim.api.nvim_get_current_buf(), win or vim.api.nvim_get_current_win()
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not ok or not parser then return end
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    parser:parse(nil, function(err)
        if err or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick
            or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
        local config = require('inkstone.state').get(buf)
        local table_at_cursor = false
        if config.pipe_table.enabled then
            local query = require('inkstone.core.ts').parse('markdown', '(pipe_table) @table')
            parser:for_each_tree(function(tree, language)
                if language:lang() ~= 'markdown' then return end
                for _, node in query:iter_captures(tree:root(), buf, row, row + 1) do
                    local sr, _, er, ec = node:range()
                    if row >= sr and (row < er or (row == er and ec > 0)) then table_at_cursor = true end
                end
            end)
        end
        if table_at_cursor then require('inkstone.core.table_views').toggle(buf, win); return end
        local folds = require('inkstone.core.folds')
        if config.folds.enabled then
            for _, block in ipairs(folds.blocks(buf, parser, config.folds)) do
                if row >= block.start_row and row < block.end_row then folds.toggle(buf, win); return end
            end
        end
        require('inkstone.core.media').open(buf, win)
    end)
end

return M
