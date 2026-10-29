---@class render.md.Display
local M = {}

---@param context render.md.request.Context
---@param marks render.md.Mark[]
---@param node render.md.Node
---@return render.md.mark.Line
function M.prefix(context, marks, node)
    local _, source = node:line('first', 0)
    -- Markdown row nodes may include their leading whitespace (ACP indents
    -- every transcript line). Virtual rows must retain it just like overlays.
    source = source and source:sub(1, node:col()) or ''
    return M.row_prefix(context, marks, node.start_row, source)
end

---@param context render.md.request.Context
---@param marks render.md.Mark[]
---@param row integer
---@param source string source prefix before the row's content
---@return render.md.mark.Line
function M.row_prefix(context, marks, row, source)
    local overlays = {} ---@type render.md.Mark[]
    for _, mark in ipairs(marks) do
        local opts = mark.opts
        if
            mark.start_row == row
            and mark.start_col < #source
            and opts.end_col
            and opts.end_col <= #source
            and opts.virt_text
            and opts.virt_text_pos == 'overlay'
        then
            overlays[#overlays + 1] = mark
        end
    end
    table.sort(overlays, function(a, b)
        return a.start_col < b.start_col
    end)

    local line, col = context.config:line(), 0
    for _, mark in ipairs(overlays) do
        if mark.start_col >= col then
            line:text(source:sub(col + 1, mark.start_col))
                :extend(mark.opts.virt_text)
            col = mark.opts.end_col
        end
    end
    return line:text(source:sub(col + 1)):get()
end

---@param context render.md.request.Context
---@param body render.md.node.Body
---@return render.md.mark.Line
function M.line(context, body)
    ---@type table<integer, true>
    local boundaries = {
        [body.start_col] = true,
        [body.end_col] = true,
    }
    ---@param col integer
    local function boundary(col)
        if col > body.start_col and col < body.end_col then
            boundaries[col] = true
        end
    end

    local inline = context.inline:get(body, true)
    local highlights = context.highlights:line(body.start_row)
    local insertions, starts, ends = {}, {}, {}

    for _, value in ipairs(inline) do
        boundary(value.col)
        insertions[value.col] = insertions[value.col] or {}
        insertions[value.col][#insertions[value.col] + 1] = value.line
    end
    for index, range in ipairs(highlights.groups) do
        boundary(range[1])
        boundary(range[2])
        local first, last = math.max(range[1], body.start_col), math.min(range[2], body.end_col)
        if first < last then
            starts[first], ends[last] = starts[first] or {}, ends[last] or {}
            starts[first][#starts[first] + 1] = index
            ends[last][#ends[last] + 1] = index
        end
    end
    for _, range in ipairs(highlights.conceals) do
        boundary(range[1])
        boundary(range[2])
    end

    local columns = vim.tbl_keys(boundaries)
    table.sort(columns)

    local line = context.config:line()
    local active, conceal_index = {}, 1
    for i = 1, #columns - 1 do
        local col, stop = columns[i], columns[i + 1]
        for _, index in ipairs(ends[col] or {}) do active[index] = nil end
        for _, index in ipairs(starts[col] or {}) do active[index] = true end
        for _, value in ipairs(insertions[col] or {}) do line:extend(value) end
        local groups = { context.config.padding.highlight } ---@type render.md.mark.Hl[]
        -- Sweep interval endpoints instead of scanning every highlight and
        -- inline insertion at every byte boundary of a long paragraph.
        local indices = vim.tbl_keys(active)
        table.sort(indices)
        for _, index in ipairs(indices) do
            local group = highlights.groups[index].highlight
            if type(group) == 'table' then
                vim.list_extend(groups, group)
            else
                groups[#groups + 1] = group
            end
        end
        local hidden = false
        while highlights.conceals[conceal_index] and highlights.conceals[conceal_index][2] <= col do
            conceal_index = conceal_index + 1
        end
        local range = highlights.conceals[conceal_index]
        if range then
            if col >= range[1] and col < range[2] then
                hidden = true
                if col == math.max(range[1], body.start_col) then
                    line:text(
                        context.conceal:replacement(range.replacement),
                        groups
                    )
                end
            end
        end
        if not hidden then
            line:text(
                body.text:sub(col - body.start_col + 1, stop - body.start_col),
                groups
            )
        end
    end
    for _, value in ipairs(insertions[body.end_col] or {}) do line:extend(value) end
    return line:get()
end

return M
