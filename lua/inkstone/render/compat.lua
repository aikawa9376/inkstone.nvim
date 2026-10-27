local text = require('inkstone.text.compat')
local M = {}

local function covers(mark, row, first, last)
    -- Replacements can be hidden when the cursor enters any source row. Keep
    -- equal-width source corrections available for that restored source view.
    if mark.replace then return false end
    local opts = mark.opts
    if not (mark.replace or opts.conceal_lines or opts.conceal
        or (opts.virt_text and opts.virt_text_pos == 'overlay')) then return false end
    local top, bottom = mark.start_row, opts.end_row or mark.start_row
    if row < top or row > bottom then return false end
    local start = row == top and mark.start_col or 0
    local stop = row == bottom and (opts.end_col or mark.start_col + 1) or math.huge
    return first < stop and last > start
end

-- Runs once after handlers, so source overlays never expose concealed content or
-- compete with a renderer-owned row. Virtual replacements are corrected in place.
function M.apply(context, marks)
    local config = context.config.display_compat
    if not text.enabled(config) then return marks end
    local rules = text.compile(config)
    for _, mark in ipairs(marks) do
        local opts = mark.opts
        if opts.virt_text then opts.virt_text = text.line(opts.virt_text, rules) end
        for _, lines in ipairs({ opts.virt_lines or {}, mark.replace or {} }) do
            for i, line in ipairs(lines) do lines[i] = text.line(line, rules) end
        end
    end
    local overlays, count = {}, vim.api.nvim_buf_line_count(context.buf)
    for _, range in ipairs(context.view.ranges) do
        local top, bottom = math.max(range[1], 0), math.min(range[2] + 1, count)
        local lines = vim.api.nvim_buf_get_lines(context.buf, top, bottom, false)
        for i, line in ipairs(lines) do
            local row = top + i - 1
            for _, span in ipairs(text.spans(line, rules)) do
                local covered = false
                for _, mark in ipairs(marks) do
                    if covers(mark, row, span[1], span[2]) then covered = true; break end
                end
                local highlights = context.highlights:line(row)
                for _, conceal in ipairs(highlights.conceals) do
                    if span[1] < conceal[2] and span[2] > conceal[1] then covered = true; break end
                end
                if not covered and not highlights.hidden then
                    overlays[#overlays + 1] = {
                        conceal = true,
                        start_row = row,
                        start_col = span[1],
                        opts = {
                            end_col = span[2],
                            virt_text = { { span[3], {} } },
                            virt_text_pos = 'overlay',
                            hl_mode = 'combine',
                            priority = 200,
                        },
                    }
                end
            end
        end
    end
    vim.list_extend(marks, overlays)
    return marks
end

return M
