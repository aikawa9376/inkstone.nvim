local Base = require('inkstone.render.base')
local env = require('inkstone.lib.env')
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
    if margin <= 0 and indent <= 0 and not self.config.wrap then
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
    local widths = self.node:widths()
    local width = math.max(vim.fn.max(widths), self.config.min_width)
    local margin = env.win.percent(self.context.win, self.data.margin, width)
    local indent = env.win.percent(self.context.win, self.data.indent, width)
    if self:reflow(margin, indent) then return end
    self:padding(self.node.start_row, self.node.end_row - 1, margin)
    self:padding(self.node.start_row, self.node.start_row, indent)
end

-- Source rows remain searchable/yankable. The UI restores the entire paragraph
-- when its source contains the cursor, including with anti_conceal disabled.
function Render:reflow(margin, indent)
    if not self.config.wrap or self.context.conceal.level < 2
        or not require('inkstone.lib.compat').has_11 then return false end
    local node = self.node
    -- Math rendering owns multiline virtual layout and source positioning.
    -- Reflowing the enclosing paragraph would hide its formula placements.
    for _, formula in ipairs(self.context.latex:get()) do
        if formula.start_row >= node.start_row and formula.start_row <= node.end_row then return false end
    end
    local prefix = self:indent():line(true):extend(display.prefix(self.context, self.marks:get(), node))
    local available = env.win.width(self.context.win) - prefix:width() - margin - indent
    if available < 2 then return false end
    local rows, maximum = {}, 0
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
            local line = display.line(self.context, {
                start_row = row, end_row = row, start_col = start, end_col = stop,
                text = text:sub(start + 1, stop),
            })
            local _, minimum = require('inkstone.parser.table').measure(require('inkstone.parser.table').units(line))
            if minimum > available then return false end
            maximum = math.max(maximum, str.line_width(line))
            rows[#rows + 1] = { line = line, hard = hard }
        end
    end
    if #rows == 0 or (#rows == 1 and maximum <= available) then return false end
    local wrapped = require('inkstone.text.paragraph').wrap(rows, available, self.config.japanese)
    for i, line in ipairs(wrapped) do
        wrapped[i] = prefix:copy():pad(margin + (i == 1 and indent or 0)):extend(line):get()
    end
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
