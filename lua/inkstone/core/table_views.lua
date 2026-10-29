local M = { cache = {}, ns = vim.api.nvim_create_namespace('inkstone.table_views') }
local Node = require('inkstone.lib.node')

local function range(node)
    local sr, _, er, ec = node:range()
    return { sr, er - (ec == 0 and 1 or 0) }
end

function M.clear(buf)
    M.cache[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1) end
end

function M.mode(buf, node, default)
    local row = node:range()
    for i = #(M.cache[buf] or {}), 1, -1 do
        local entry = M.cache[buf][i]
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, entry.id, { details = true })
        if not pos[1] or pos[3].invalid then
            vim.api.nvim_buf_del_extmark(buf, M.ns, entry.id)
            table.remove(M.cache[buf], i)
        elseif pos[1] == row then return entry.mode end
    end
    if M.cache[buf] and #M.cache[buf] == 0 then M.cache[buf] = nil end
    return default or 'table'
end

function M.read(context, root, styled)
    local headers, rows, first, last = {}, {}, nil, nil
    for node in root:iter_children() do
        local kind = node:type()
        if kind == 'pipe_table_header' or kind == 'pipe_table_row' then
            local values, chunks = {}, {}
            for cell in node:iter_children() do
                if cell:type() == 'pipe_table_cell' then
                    local wrapped = Node.new(context.buf, cell)
                    local value = vim.trim(wrapped.text)
                    local line = styled and require('inkstone.lib.display').line(context, wrapped) or { { value, context.config.pipe_table.row } }
                    values[#values + 1], chunks[#chunks + 1] = value, line
                end
            end
            if kind == 'pipe_table_header' then headers = values
            else
                rows[#rows + 1] = { values = values, chunks = chunks, node = Node.new(context.buf, node) }
                first, last = first or node, node
            end
        end
    end
    return { headers = headers, rows = rows, range = range(root), first = first, last = last }
end

function M.cards(context, data)
    local Parser = require('inkstone.parser.table')
    local result, width = {}, math.max(2, context:window_width() - 2)
    -- LazyAgent's table cards use a column heading followed by its value,
    -- separating records with a blank row. Here they are virtual display rows.
    for index, row in ipairs(data.rows) do
        if index > 1 then result[#result + 1] = {} end
        for col, header in ipairs(data.headers) do
            local title = header ~= '' and header or ('Column ' .. col)
            result[#result + 1] = { { '• ' .. title, col == 1 and 'InkstoneH2' or 'InkstoneTableHead' } }
            local units = Parser.units(row.chunks[col] or { { '', context.config.pipe_table.row } })
            local _, minimum = Parser.measure(units)
            for _, line in ipairs(Parser.wrap(units, math.max(width, minimum), context.config.pipe_table.japanese)) do
                result[#result + 1] = context.config:line():pad(2):extend(line):get()
            end
        end
    end
    return result
end

-- Expand queries only for explicitly selected, bounded alternate table views.
function M.prepare(context, parser)
    context.table_views, context.charts = {}, {}
    local config = context.config.pipe_table
    if not config.enabled or ((config.view or 'table') == 'table' and not M.cache[context.buf]) then return end
    local ranges = vim.deepcopy(context.view.ranges)
    context.view:each_tree(parser, function(tree, language)
        if language:lang() ~= 'markdown' or not context.view:overlaps(tree:root()) then return end
        local query = require('inkstone.core.ts').parse('markdown', '(pipe_table) @table')
        context.view:query(tree:root(), query, function(_, node)
            if M.mode(context.buf, node, config.view) ~= 'table' then
                local r = range(node)
                if r[2] - r[1] < config.view_max_rows then ranges[#ranges + 1] = { r[1], r[2] + 1 } end
            end
        end)
    end)
    context.view.ranges = require('inkstone.lib.interval').coalesce(ranges)
end

function M.filter(context, marks)
    if not next(context.table_views or {}) then return marks end
    local result = {}
    for _, mark in ipairs(marks) do
        local hidden = false
        for _, r in ipairs(context.table_views) do
            if mark.start_row >= r[1] and mark.start_row <= r[2] and not mark.table_view then hidden = true; break end
        end
        if not hidden then result[#result + 1] = mark end
    end
    return result
end

function M.toggle(buf, win, requested)
    buf, win = buf or vim.api.nvim_get_current_buf(), win or vim.api.nvim_get_current_win()
    local config = require('inkstone.state').get(buf).pipe_table
    if not config.enabled then return false end
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not ok or not parser then return false end
    local tick, row = vim.api.nvim_buf_get_changedtick(buf), vim.api.nvim_win_get_cursor(win)[1] - 1
    parser:parse(true, function(err)
        if err or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick
            or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
        local selected
        local query = require('inkstone.core.ts').parse('markdown', '(pipe_table) @table')
        parser:for_each_tree(function(tree, language)
            if language:lang() ~= 'markdown' or not require('inkstone.core.ts').render(tree, language) then return end
            for _, node in query:iter_captures(tree:root(), buf, row, row + 1) do
                local r = range(node)
                if row >= r[1] and row <= r[2] then selected = node; break end
            end
        end)
        if not selected then return end
        local r = range(selected)
        if r[2] - r[1] >= config.view_max_rows then
            vim.notify('Inkstone: table exceeds pipe_table.view_max_rows', vim.log.levels.WARN); return
        end
        local current = M.mode(buf, selected, config.view)
        local mode = requested
        if not mode then mode = ({ table = 'list', list = 'chart', chart = 'table' })[current] end
        if mode == current then mode = 'table' end
        if mode == 'chart' then
            local context = require('inkstone.request.context').transient(buf, win, require('inkstone.state').get(buf))
            local data = M.read(context, selected)
            local values = {}; for i, record in ipairs(data.rows) do values[i] = record.values end
            local chart, reason = require('inkstone.text.chart').data(data.headers, values)
            if not chart then
                if requested then vim.notify('Inkstone: ' .. reason, vim.log.levels.WARN); return end
                mode = 'table'
            end
        end
        local sr, sc, er, ec = selected:range()
        local id = vim.api.nvim_buf_set_extmark(buf, M.ns, sr, sc, {
            end_row = er, end_col = ec, right_gravity = false, invalidate = true,
        })
        -- Remove a previous anchor at the same table before keeping its new mode.
        local entries = M.cache[buf] or {}
        for i = #entries, 1, -1 do
            local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, entries[i].id, {})
            if pos[1] == sr then vim.api.nvim_buf_del_extmark(buf, M.ns, entries[i].id); table.remove(entries, i) end
        end
        entries[#entries + 1] = { id = id, mode = mode }
        M.cache[buf] = entries
        -- A visible header is the interaction anchor for the alternate layout.
        vim.api.nvim_win_set_cursor(win, { sr + 1, sc })
        require('inkstone.core.ui').update(buf, win, 'TableView', true)
    end)
    return true
end

return M
