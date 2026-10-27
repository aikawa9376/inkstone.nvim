-- Cache immutable width summaries, never TSNodes. A changed tick or display
-- option drops the buffer's summaries. Bound both entry count and retained rows.
local M = { cache = {} }
local group = vim.api.nvim_create_augroup('InkstoneWidthCache', { clear = true })
vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args) M.cache[args.buf] = nil end,
})

function M.get(buf, first, last)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local signature = table.concat({
        tick, vim.bo[buf].tabstop, vim.bo[buf].vartabstop, vim.o.ambiwidth, vim.o.display,
    }, ':')
    local cache = M.cache[buf]
    if not cache or cache.signature ~= signature then
        cache = { signature = signature, entries = {}, rows = 0, count = 0 }
        M.cache[buf] = cache
    end
    local key = first .. ':' .. last
    if cache.entries[key] then return cache.entries[key] end
    local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
    local widths = {}
    local function measure()
        for i, line in ipairs(lines) do widths[i] = vim.fn.strdisplaywidth(line) end
    end
    if vim.api.nvim_get_current_buf() == buf then measure()
    else vim.api.nvim_buf_call(buf, measure) end
    if #widths <= 32768 then
        if cache.count >= 64 or cache.rows + #widths > 32768 then
            cache.entries, cache.count, cache.rows = {}, 0, 0
        end
        cache.entries[key] = widths
        cache.count, cache.rows = cache.count + 1, cache.rows + #widths
    end
    return widths
end

return M
