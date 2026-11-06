local M = {}

-- Read the displayed link marks and the current request's native conceal
-- snapshot. Hidden icons, revealed source and stale parse coordinates do not
-- participate in movement. No parsing is needed for individual key presses.
local function ranges(buf, row)
    local config = require('inkstone.state').get(buf)
    local decorator = require('inkstone.core.ui').cache[buf]
    local context = require('inkstone.request.context').cache[buf]
    if not config.enabled or not config.link.enabled or not decorator or decorator:changed()
        or vim.wo.conceallevel < 2
        or not require('inkstone.lib.softwrap').concealed(vim.api.nvim_get_current_win(), row, 'n') then return {} end
    local links, conceals = {}, {}
    for _, extmark in ipairs(decorator:get()) do
        if extmark:shown() then
            local mark = extmark:get()
            local range = mark.link_range
            if range and row >= range[1] and row <= range[3] then
                links[#links + 1] = { row == range[1] and range[2] or 0,
                    row == range[3] and range[4] or math.huge }
            end
            if mark.opts.conceal == '' and row == mark.start_row and (mark.opts.end_row or row) == row then
                conceals[#conceals + 1] = { mark.start_col, mark.opts.end_col }
            end
        end
    end
    if #links == 0 then return {} end
    if context and vim.treesitter.highlighter.active[buf] then
        vim.list_extend(conceals, context.highlights:line(row).native_conceals)
    end
    local result = {}
    for _, conceal in ipairs(conceals) do
        for _, link in ipairs(links) do
            local first, last = math.max(conceal[1], link[1]), math.min(conceal[2], link[2])
            if first < last then result[#result + 1] = { first, last } end
        end
    end
    require('inkstone.lib.interval').sort(result)
    local merged = {}
    for _, range in ipairs(result) do
        local last = merged[#merged]
        if last and range[1] <= last[2] then last[2] = math.max(last[2], range[2])
        else merged[#merged + 1] = range end
    end
    return merged
end

function M.attach(buf)
    for key, direction in pairs({ h = -1, l = 1 }) do
        vim.keymap.set('n', key, function() M.move(direction) end, {
            buffer = buf, desc = 'Move past hidden Markdown link syntax',
        })
    end
end

function M.move(direction, count)
    local buf = vim.api.nvim_get_current_buf()
    local motion = direction > 0 and 'l' or 'h'
    local cache = {}
    for _ = 1, count or vim.v.count1 do
        vim.cmd.normal({ args = { motion }, bang = true })
        while true do
            local cursor = vim.api.nvim_win_get_cursor(0)
            local row, col = cursor[1] - 1, cursor[2]
            if not cache[row] then cache[row] = ranges(buf, row) end
            local hidden
            for _, range in ipairs(cache[row]) do
                if col >= range[1] and col < range[2] then hidden = range; break end
            end
            if not hidden then break end
            local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
            local target = hidden[2]
            local next_row = row
            if direction > 0 and target >= #line and row + 1 < vim.api.nvim_buf_line_count(buf)
                and vim.o.whichwrap:find('l', 1, true) then
                next_row, target = row + 1, 0
            elseif direction < 0 or target >= #line then
                -- byteidx/charidx retain UTF-8 and combining-character bounds.
                target = math.max(0, vim.fn.byteidx(line, vim.fn.charidx(line, hidden[1]) - 1))
            end
            if next_row == row and target == col then break end
            vim.api.nvim_win_set_cursor(0, { next_row + 1, target })
        end
    end
end

return M
