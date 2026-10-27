-- Cache pure layout results by their complete display inputs, never TSNodes.
-- Exact input comparison also permits reuse after unrelated source edits.
local M = { cache = {} }
local max_entries, max_bytes = 64, 4 * 1024 * 1024
local group = vim.api.nvim_create_augroup('InkstoneLayoutCache', { clear = true })
vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args) M.cache[args.buf] = nil end,
})

function M.get(buf, key, input)
    local cache = M.cache[buf]
    local entry = cache and cache.entries[key]
    if entry and vim.deep_equal(entry.input, input) then
        -- Display compatibility and border assembly can mutate emitted lines.
        return vim.deepcopy(entry.value)
    end
end

function M.put(buf, key, input, value, bytes)
    if bytes > max_bytes then return end
    local cache = M.cache[buf]
    if not cache then
        cache = { entries = {}, count = 0, bytes = 0 }
        M.cache[buf] = cache
    end
    local previous = cache.entries[key]
    if previous then cache.bytes = cache.bytes - previous.bytes end
    if cache.bytes + bytes > max_bytes or (not previous and cache.count >= max_entries) then
        cache.entries, cache.count, cache.bytes = {}, 0, 0
        previous = nil
    end
    cache.entries[key] = { input = vim.deepcopy(input), value = vim.deepcopy(value), bytes = bytes }
    cache.bytes = cache.bytes + bytes
    if not previous then cache.count = cache.count + 1 end
end

return M
