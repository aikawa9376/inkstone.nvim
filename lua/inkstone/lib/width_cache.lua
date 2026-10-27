-- Cache immutable width summaries, never TSNodes. Buffer change ranges retain
-- unaffected entries and translate their source coordinates after insertions.
local M = { cache = {}, attached = {} }
local group = vim.api.nvim_create_augroup('InkstoneWidthCache', { clear = true })
vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args) M.cache[args.buf], M.attached[args.buf] = nil, nil end,
})

local function reset(cache)
    cache.entries, cache.rows, cache.count = {}, 0, 0
end

local function attach(buf)
    if M.attached[buf] then return end
    M.attached[buf] = vim.api.nvim_buf_attach(buf, false, {
        on_lines = function(_, changed_buf, tick, first, last, new_last)
            local cache = M.cache[changed_buf]
            if not cache then return end
            local entries, rows, count = {}, 0, 0
            local delta = new_last - last
            for _, entry in pairs(cache.entries) do
                if entry.last <= first or entry.first >= last then
                    if entry.first >= last and entry.last > first then
                        entry.first, entry.last = entry.first + delta, entry.last + delta
                    end
                    entries[entry.first .. ':' .. entry.last] = entry
                    rows, count = rows + #entry.widths, count + 1
                end
            end
            cache.entries, cache.rows, cache.count, cache.tick = entries, rows, count, tick
        end,
        on_changedtick = function(_, changed_buf, tick)
            local cache = M.cache[changed_buf]
            if cache then reset(cache); cache.tick = tick end
        end,
        on_reload = function(_, changed_buf) M.cache[changed_buf] = nil end,
        on_detach = function(_, changed_buf)
            M.cache[changed_buf], M.attached[changed_buf] = nil, nil
        end,
    })
end

function M.get(buf, first, last)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local signature = table.concat({
        vim.bo[buf].tabstop, vim.bo[buf].vartabstop, vim.o.ambiwidth, vim.o.display,
    }, ':')
    local cache = M.cache[buf]
    if not cache or cache.signature ~= signature or cache.tick ~= tick then
        cache = { signature = signature, tick = tick, entries = {}, rows = 0, count = 0 }
        M.cache[buf] = cache
    end
    attach(buf)
    local key = first .. ':' .. last
    if cache.entries[key] then return cache.entries[key].widths end
    local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
    local widths = {}
    local function measure()
        for i, line in ipairs(lines) do widths[i] = vim.fn.strdisplaywidth(line) end
    end
    if vim.api.nvim_get_current_buf() == buf then measure()
    else vim.api.nvim_buf_call(buf, measure) end
    if #widths <= 32768 then
        if cache.count >= 64 or cache.rows + #widths > 32768 then
            reset(cache)
        end
        cache.entries[key] = { first = first, last = last, widths = widths }
        cache.count, cache.rows = cache.count + 1, cache.rows + #widths
    end
    return widths
end

return M
