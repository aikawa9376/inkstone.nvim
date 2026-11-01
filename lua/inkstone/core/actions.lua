local M = {}

-- Use the native jump-forward action when Ctrl+i has no contextual target.
function M.attach(buf)
    vim.keymap.set('n', '<C-i>', function()
        local count = vim.v.count1
        M.toggle(nil, nil, function()
            local key = vim.api.nvim_replace_termcodes('<C-i>', true, false, true)
            vim.cmd.normal({ args = { tostring(count) .. key }, bang = true })
        end)
    end, { buffer = buf, desc = 'Toggle Markdown view or jump forward' })
end

-- Closed ancestors, table views, open folds, then media at the cursor.
function M.toggle(buf, win, fallback)
    buf, win = buf or vim.api.nvim_get_current_buf(), win or vim.api.nvim_get_current_win()
    local function unmatched() if fallback then fallback() end end
    local config = require('inkstone.state').get(buf)
    if not config.enabled then unmatched(); return end
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not ok or not parser then unmatched(); return end
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local row = cursor[1] - 1
    parser:parse(nil, function(err)
        if err or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick
            or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf
            or (fallback and vim.api.nvim_get_current_win() ~= win)
            or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor) then return end
        local folds = require('inkstone.core.folds')
        local fold_at_cursor = false
        if config.folds.enabled then
            for _, block in ipairs(folds.blocks(buf, parser, config.folds)) do
                if row >= block.start_row and row < block.end_row then
                    if folds.closed(buf, block) then folds.toggle(buf, win); return end
                    fold_at_cursor = true
                end
            end
        end
        local table_at_cursor = false
        if config.pipe_table.enabled then
            local query = require('inkstone.core.ts').parse('markdown', '(pipe_table) @table')
            parser:for_each_tree(function(tree, language)
                if language:lang() ~= 'markdown' or not require('inkstone.core.ts').render(tree, language) then return end
                for _, node in query:iter_captures(tree:root(), buf, row, row + 1) do
                    local sr, _, er, ec = node:range()
                    if row >= sr and (row < er or (row == er and ec > 0)) then table_at_cursor = true end
                end
            end)
        end
        if table_at_cursor then require('inkstone.core.table_views').toggle(buf, win); return end
        if fold_at_cursor then folds.toggle(buf, win); return end
        if config.media.enabled then
            local context = require('inkstone.request.context').transient(buf, win, config)
            local media = require('inkstone.core.media')
            media.collect(context, parser, folds.apply(context, parser, {}))
            for _, item in ipairs(context.media) do
                if item.row == row then media.open(buf, win); return end
            end
        end
        unmatched()
    end)
end

return M
