-- Tables own the text grid; Snacks owns image loading, fitting and transport.
local M = {}

function M.owns(buf, row)
    local context = require('inkstone.request.context').cache[buf]
    if not context then return false end
    local config = require('inkstone.state').get(buf)
    if not config.enabled or not config.media.enabled or not config.media.images then return false end
    for _, range in ipairs(context.table_image_ranges or {}) do
        if row >= range[1] and row <= range[2] then return true end
    end
    return false
end

local function integrate(image)
    local doc = image.doc
    if not doc or type(doc.find) ~= 'function' or M.doc == doc then return end
    M.doc = doc
    local find = doc.find
    -- Filter discovery rather than disabling Snacks globally. Its next visible
    -- update retires native table placements; other document images stay native.
    doc.find = function(buf, callback, opts)
        return find(buf, function(items)
            local visible = {}
            for _, item in ipairs(items) do
                if item.type ~= 'image' or not M.owns(buf, item.pos[1] - 1) then visible[#visible + 1] = item end
            end
            callback(visible)
        end, opts)
    end
end

function M.prepare(context, parser)
    context.cell_images, context.table_media, context.table_image_ranges = {}, {}, {}
    local config, table_config = context.config.media, context.config.pipe_table
    if not config.enabled or not config.images or not table_config.enabled
        or not table_config.wrap or context.conceal.level < 2
        or not vim.tbl_contains({ 'trimmed', 'padded' }, table_config.cell)
        or #vim.fn.win_findbuf(context.buf) ~= 1 then return end
    local candidates = {}
    context.view:each_tree(parser, function(tree, language)
        if language:lang() ~= 'markdown_inline' or not context.view:overlaps(tree:root()) then return end
        context.view:nodes(tree:root(), require('inkstone.core.ts').parse('markdown_inline', '(image) @image'), function(_, node)
            local destination = node:child('link_destination')
            local source = destination and require('inkstone.core.media').resolve(context.buf, destination.text)
            if source then
                candidates[#candidates + 1] = { kind = 'image', row = node.start_row, col = node.start_col,
                    end_col = node.end_col, source = source }
            end
        end)
    end)
    if #candidates == 0 then return end
    local image = require('inkstone.core.media').backend()
    if not image or not image.terminal or not image.terminal.env().placeholders
        or type(image.placement.render_grid) ~= 'function' then return end
    integrate(image)
    for _, item in ipairs(candidates) do
        local row = context.cell_images[item.row] or {}
        context.cell_images[item.row] = row
        row[#row + 1] = item
    end
end

function M.cell(context, node)
    local items = {}
    for _, item in ipairs((context.cell_images or {})[node.start_row] or {}) do
        if item.col >= node.start_col and item.end_col <= node.end_col then items[#items + 1] = item end
    end
    return #items > 0 and items or nil
end

function M.register(context, range)
    for row in pairs(context.cell_images or {}) do
        if row >= range[1] and row <= range[2] then
            context.table_image_ranges[#context.table_image_ranges + 1] = range
            return
        end
    end
end

function M.key(item)
    return item.kind .. ':' .. item.row .. ':' .. (item.col or 0) .. ':' .. vim.fn.sha256(item.source)
end

function M.request(context, item, width, range)
    local request = vim.tbl_extend('force', item, {
        key = M.key(item), table_range = range,
        cell = { width = math.max(1, math.min(width, context.config.media.max_width)), height = context.config.media.max_height },
    })
    context.table_media[#context.table_media + 1] = request
    local entry = (require('inkstone.core.media').cache[context.buf] or {})[request.key]
    if entry and entry.tick == vim.api.nvim_buf_get_changedtick(context.buf) and vim.deep_equal(entry.cell, request.cell) then
        return entry.grid
    end
end

-- Existing native images may predate Inkstone's first render. Public placement
-- cleanup removes their grids immediately, without changing native doc config.
function M.suppress(context, image)
    if not image.placement.clean or not image.placement.ns then return end
    local ids = {}
    local function chunks(line)
        for _, chunk in ipairs(line or {}) do
            local id = type(chunk[2]) == 'string' and chunk[2]:match('^SnacksImage(%d+)$')
            if id then ids[tonumber(id)] = true end
        end
    end
    for _, range in ipairs(context.table_image_ranges or {}) do
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(context.buf, image.placement.ns,
            { range[1], 0 }, { range[2], -1 }, { details = true })) do
            for _, item in ipairs((context.cell_images or {})[mark[2]] or {}) do
                if mark[3] >= item.col and mark[3] < item.end_col then
                    chunks(mark[4].virt_text)
                    for _, line in ipairs(mark[4].virt_lines or {}) do chunks(line) end
                    break
                end
            end
        end
    end
    for id in pairs(ids) do image.placement.clean(context.buf, id) end
end

function M.attach(context, entry, placement, valid)
    local state, render_grid = placement.state, placement.render_grid
    placement.state = function(self)
        local result = state(self)
        -- Snacks can add two columns when fitting a very short inline image.
        result.loc.width = math.min(entry.cell.width, result.loc.width)
        result.loc.height = math.min(entry.cell.height, result.loc.height)
        return result
    end
    placement.render_grid = function(self, loc)
        if not valid() then return end
        local grid = {}
        local function line(chunks)
            local row = {}
            for _, chunk in ipairs(chunks or {}) do
                if chunk[1]:find(vim.fn.nr2char(0x10EEEE), 1, true) then row[#row + 1] = chunk end
            end
            if #row > 0 then grid[#grid + 1] = row end
        end
        -- Reuse the backend's placeholder encoding and highlight IDs. Capture
        -- its grid on a proxy so only the table renderer emits virtual rows.
        local proxy = setmetatable({
            opts = vim.tbl_extend('force', self.opts, { range = { entry.row + 1, 0, entry.row + 1, 0 } }),
            _render = function(_, marks)
                for _, mark in ipairs(marks) do
                    line(mark.virt_text)
                    for _, row in ipairs(mark.virt_lines or {}) do line(row) end
                end
            end,
        }, { __index = self })
        render_grid(proxy, loc)
        if vim.deep_equal(entry.grid, grid) then return end
        entry.grid = grid
        vim.schedule(function()
            if valid() and vim.api.nvim_win_is_valid(context.win)
                and vim.api.nvim_win_get_buf(context.win) == context.buf then
                require('inkstone.core.ui').update(context.buf, context.win, 'TableImage', true)
            end
        end)
    end
end

return M
