local Base = require('inkstone.render.base')
local display = require('inkstone.lib.display')
local str = require('inkstone.lib.str')

---@class render.md.paragraph.Data
---@field margin number
---@field indent number

---@class render.md.render.Paragraph: render.md.Render
---@field private config render.md.paragraph.Config
---@field private data render.md.paragraph.Data
local Render = setmetatable({}, Base)
Render.__index = Render

---@protected
---@return boolean
function Render:setup()
    self.config = self.context.config.paragraph
    if not self.config.enabled then
        return false
    end
    local margin = self:get_number(self.config.left_margin)
    local indent = self:get_number(self.config.indent)
    if margin <= 0 and indent <= 0 and not self.config.wrap and not self.config.join then
        return false
    end
    self.data = { margin = margin, indent = indent }
    return true
end

---@private
---@param value render.md.paragraph.Number
---@return number
function Render:get_number(value)
    if type(value) == 'function' then
        return value({ text = self.node.text })
    else
        return value
    end
end

---@protected
function Render:run()
    local margin, indent = 0, 0
    if self.data.margin > 0 or self.data.indent > 0 then
        local width = math.max(vim.fn.max(self.node:widths()), self.config.min_width)
        margin = self.context:percent(self.data.margin, width)
        indent = self.context:percent(self.data.indent, width)
    end
    if self.config.wrap and not self.config.join then
        self:softwrap(margin, indent)
        self:padding(self.node.start_row, self.node.end_row - 1, margin)
        self:padding(self.node.start_row, self.node.start_row, indent)
        return
    end
    if self:reflow(margin, indent) then return end
    self:padding(self.node.start_row, self.node.end_row - 1, margin)
    self:padding(self.node.start_row, self.node.start_row, indent)
end

-- Keep real source rows under the cursor. Only the unused end of each screen
-- row is virtual; native motions, selections and operators own the text.
function Render:softwrap(margin, indent)
    local context, node = self.context, self.node
    local softwrap = require('inkstone.lib.softwrap')
    if not softwrap.supports(context) then return end
    local width = context:window_width()
    local section = self:indent():line(true)
    local repeat_prefix = section:copy():pad(margin):get()
    local repeat_width = str.line_width(repeat_prefix)
    local cache = require('inkstone.lib.layout_cache')
    local function layout(row, text)
        if text:find('!%[') or text:find('!%[%[') then return end
        for _, formula in ipairs(context.latex:get()) do
            if row >= formula.start_row and row <= formula.end_row then return end
        end
        local head = softwrap.head(context, text, width)
        local first = width - repeat_width - (row == node.start_row and indent or 0)
        local continuation = head and width - head - repeat_width or 0
        -- Inline replacements have their own widths/coordinates. Keep native
        -- wrapping rather than guessing where their source lands.
        local body = { start_row = row, end_row = row, start_col = 0, end_col = #text, text = text }
        if first < 2 or continuation < 2 or #context.inline:get(body, true) > 0 then return end
        local input = vim.mpack.encode({ text, first, continuation, self.config.japanese,
            vim.o.ambiwidth, vim.o.display })
        local key = 'softwrap:' .. row
        local breaks = cache.get(context.buf, key, input)
        if breaks == nil then
            breaks = softwrap.layout(text, first, continuation, self.config.japanese)
            cache.put(context.buf, key, input, breaks, #text * 64)
        end
        for _, boundary in ipairs(breaks or {}) do
            local line = self:line():pad(boundary.padding):extend(repeat_prefix):get()
            if #line > 0 then
                self.marks:add(self.config, false, row, boundary.col, {
                    priority = 100, virt_text = line, virt_text_pos = 'inline', right_gravity = false,
                })
            end
        end
    end
    -- Each source row is independent, so off-screen paragraph rows need no
    -- decomposition or BudouX work, including disjoint shared-buffer views.
    local last = node.end_row - (node.end_col == 0 and 1 or 0)
    for _, range in ipairs(context.view.ranges) do
        local first, stop = math.max(node.start_row, range[1]), math.min(last, range[2])
        if first <= stop then
            for i, text in ipairs(vim.api.nvim_buf_get_lines(context.buf, first, stop + 1, false)) do
                layout(first + i - 1, text)
            end
        end
    end
end

-- Source rows remain searchable/yankable. The UI restores the entire paragraph
-- when anti_conceal includes its source; disabled anti_conceal keeps the layout.
function Render:reflow(margin, indent)
    if (not self.config.wrap and not self.config.join) or self.context.conceal.level < 2
        or not require('inkstone.lib.compat').has_11 then return false end
    local node = self.node
    -- Math rendering owns multiline virtual layout and source positioning.
    -- Reflowing the enclosing paragraph would hide its formula placements.
    for _, formula in ipairs(self.context.latex:get()) do
        if formula.start_row >= node.start_row and formula.start_row <= node.end_row then return false end
    end
    local section_indent = self:indent():line(true)
    local prefix = section_indent:copy():extend(display.prefix(self.context, self.marks:get(), node))
    local window_width = self.context:window_width()
    local available = self.config.wrap
        and (window_width - prefix:width() - margin - indent) or math.huge
    if available < 2 then return false end
    local cache = require('inkstone.lib.layout_cache')
    local inputs = {}
    local input = {
        available, margin, indent, prefix:get(), self.config.wrap, self.config.join,
        { self.config.japanese.enabled, self.config.japanese.budoux }, self.context.config.padding.highlight,
        self.context.conceal.level, vim.bo[self.context.buf].tabstop,
        vim.bo[self.context.buf].vartabstop, vim.o.ambiwidth, vim.o.display, inputs,
    }
    local bodies, bytes = {}, 0
    local source = vim.api.nvim_buf_get_lines(self.context.buf, node.start_row, node.end_row + 1, false)
    for i, text in ipairs(source) do
        local row = node.start_row + i - 1
        if row < node.end_row or node.end_col > 0 then
            local start = i == 1 and node:col() or str.spaces('start', text)
            local stop = row == node.end_row and node.end_col or #text
            local raw = text:sub(start + 1, stop)
            -- Keep image anchors on real rows for optional image providers.
            if raw:find('!%[') or raw:find('!%[%[') then return false end
            local hard = raw:match('  $') ~= nil or raw:match('\\$') ~= nil
            if raw:match('\\$') then stop = stop - 1 end
            while stop > start and text:sub(stop, stop):match('%s') do stop = stop - 1 end
            local body = {
                start_row = row, end_row = row, start_col = start, end_col = stop,
                text = text:sub(start + 1, stop),
            }
            local highlights = self.context.highlights:line(row)
            local inline = self.context.inline:get(body, true)
            local row_prefix = self.config.join and prefix or section_indent:copy():extend(
                display.row_prefix(self.context, self.marks:get(), row, text:sub(1, start)))
            local row_indent = i == 1 and indent or 0
            local row_available = self.config.join and available or (self.config.wrap
                and (window_width - row_prefix:width() - margin - row_indent) or math.huge)
            if row_available < 2 then return false end
            bodies[#bodies + 1] = { body = body, hard = hard, prefix = row_prefix,
                indent = row_indent, available = row_available }
            -- Arrays keep the snapshot canonical: map iteration order is not a
            -- stable cache key. Include custom handler highlights/insertions.
            local groups, conceals, insertions = {}, {}, {}
            for _, group in ipairs(highlights.groups) do
                groups[#groups + 1] = { group[1], group[2], group.priority, group.highlight }
            end
            for _, conceal in ipairs(highlights.conceals) do
                conceals[#conceals + 1] = { conceal[1], conceal[2], conceal.replacement, conceal.blocks }
            end
            for _, value in ipairs(inline) do insertions[#insertions + 1] = { value.col, value.line } end
            inputs[#inputs + 1] = { row, start, stop, body.text, hard, groups, conceals, insertions,
                row_prefix:get(), row_available, row_indent }
            bytes = bytes + #body.text * 64 + #highlights.groups * 128 + #highlights.conceals * 128
        end
    end
    local key = 'paragraph:' .. node.start_row .. ':' .. node.start_col
    -- Native encoding gives an immutable exact snapshot without recursively
    -- copying/comparing thousands of highlight tables in Lua on every frame.
    input = vim.mpack.encode(input)
    local cached = cache.get(self.context.buf, key, input)
    if cached ~= nil then
        if cached == false then return false end
        self.marks:replace(self.config, node, cached)
        return true
    end
    local rows, needs_layout = {}, self.config.join and #bodies > 1
    local Parser = require('inkstone.parser.table')
    for _, value in ipairs(bodies) do
        local line = display.line(self.context, value.body)
        local units = Parser.units(line)
        local _, minimum = Parser.measure(units)
        if minimum > value.available then return false end
        needs_layout = needs_layout or str.line_width(line) > value.available
        rows[#rows + 1] = { line = line, units = units, hard = value.hard,
            prefix = value.prefix, indent = value.indent, available = value.available }
    end
    if #rows == 0 or not needs_layout then
        cache.put(self.context.buf, key, input, false, bytes)
        return false
    end
    local paragraph = require('inkstone.text.paragraph')
    local wrapped = {}
    if self.config.join then
        wrapped = paragraph.wrap(rows, available, self.config.japanese, true)
        for i, line in ipairs(wrapped) do
            wrapped[i] = prefix:copy():pad(margin + (i == 1 and indent or 0)):extend(line):get()
        end
    else
        for _, row in ipairs(rows) do
            for i, line in ipairs(paragraph.wrap({ row }, row.available, self.config.japanese)) do
                wrapped[#wrapped + 1] = row.prefix:copy():pad(margin + (i == 1 and row.indent or 0)):extend(line):get()
            end
        end
    end
    cache.put(self.context.buf, key, input, wrapped, bytes)
    self.marks:replace(self.config, node, wrapped)
    return true
end

---@private
---@param start_row integer
---@param end_row integer
---@param amount integer
function Render:padding(start_row, end_row, amount)
    local line = self:line():pad(amount):get()
    if #line == 0 then
        return
    end
    for row = start_row, end_row do
        self.marks:add(self.config, false, row, 0, {
            priority = 100,
            virt_text = line,
            virt_text_pos = 'inline',
        })
    end
end

return Render
