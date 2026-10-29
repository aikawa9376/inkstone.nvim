local interval = require('inkstone.lib.interval')

---@class render.md.request.highlights.Line
---@field hidden boolean
---@field conceals render.md.request.highlights.Conceal[]
---@field groups render.md.request.highlights.Group[]

---@class render.md.request.highlights.Entry
---@field hidden? boolean
---@field conceal? render.md.request.highlights.Conceal
---@field group? render.md.request.highlights.Group

---@class render.md.request.highlights.Conceal: render.md.Range
---@field replacement string
---@field blocks integer

---@class render.md.request.highlights.Group: render.md.Range
---@field priority integer
---@field highlight render.md.mark.Hl

---@class render.md.request.Highlights
---@field private buf integer
---@field private view render.md.request.View
---@field private computed boolean
---@field private lines table<integer, render.md.request.highlights.Line>
local Highlights = {}
Highlights.__index = Highlights

---@param buf integer
---@param view render.md.request.View
---@return render.md.request.Highlights
function Highlights.new(buf, view)
    local self = setmetatable({}, Highlights)
    self.buf = buf
    self.view = view
    self.computed = false
    self.lines = {}
    return self
end

---@param row integer
---@param entry render.md.request.highlights.Entry
function Highlights:add(row, entry)
    if not self.lines[row] then
        self.lines[row] = { hidden = false, conceals = {}, groups = {} }
    end
    local line = self.lines[row]
    if entry.hidden then
        line.hidden = entry.hidden
    end
    if entry.conceal then
        if interval.valid(entry.conceal, true) then
            line.conceals[#line.conceals + 1] = entry.conceal
            line.conceals_dirty = true
        end
    end
    if entry.group then
        if interval.valid(entry.group, true) then
            line.groups[#line.groups + 1] = entry.group
            line.groups_dirty = true
        end
    end
end

---@private
---@param conceals render.md.request.highlights.Conceal[]
---@return render.md.request.highlights.Conceal[]
function Highlights.coalesce_conceals(conceals)
    interval.sort(conceals)
    local result = {} ---@type render.md.request.highlights.Conceal[]
    result[#result + 1] = conceals[1]
    for i = 2, #conceals do
        local conceal, last = conceals[i], result[#result]
        if conceal[1] <= last[2] then
            last[2] = math.max(last[2], conceal[2])
            last.replacement = last.replacement .. conceal.replacement
            last.blocks = last.blocks + conceal.blocks
        else
            result[#result + 1] = conceal
        end
    end
    return result
end

---@param row integer
---@return render.md.request.highlights.Line
function Highlights:line(row)
    if not self.computed then
        self.computed = true
        self:compute()
    end
    local line = self.lines[row]
    if not line then
        line = { hidden = false, conceals = {}, groups = {} }
    end
    if line.conceals_dirty then
        line.conceals = Highlights.coalesce_conceals(line.conceals)
        line.conceals_dirty = nil
    end
    if line.groups_dirty then
        table.sort(line.groups, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            local ah = type(a.highlight) == 'table' and table.concat(a.highlight, '\0') or a.highlight
            local bh = type(b.highlight) == 'table' and table.concat(b.highlight, '\0') or b.highlight
            return ah < bh
        end)
        line.groups_dirty = nil
    end
    return line
end

---Cached row level implementation of vim.treesitter.get_captures_at_pos
---@private
function Highlights:compute()
    self:extmarks()
    if not vim.treesitter.highlighter.active[self.buf] then
        return
    end
    local parser = vim.treesitter.get_parser(self.buf)
    if not parser then
        return
    end
    self.view:each_tree(parser, function(tree, language_tree)
        self:tree(language_tree:lang(), tree:root())
    end)
end

-- Replacement rows cannot inherit decorations from the concealed source.
-- Snapshot foreign range highlights alongside captures, excluding our previous
-- render so refreshing a layout never feeds its own styles back into it.
function Highlights:extmarks()
    local owned, seen = {}, {}
    for name, id in pairs(vim.api.nvim_get_namespaces()) do
        if name:match('^inkstone[%.:]') then owned[id] = true end
    end
    local sources = {}
    for _, range in ipairs(self.view.ranges) do
        local marks = vim.api.nvim_buf_get_extmarks(self.buf, -1, { range[1], 0 }, { range[2], -1 },
            { details = true, overlap = true, type = 'highlight' })
        for _, mark in ipairs(marks) do
            local sr, sc, opts = mark[2], mark[3], mark[4]
            local key = opts.ns_id .. ':' .. mark[1]
            if not owned[opts.ns_id] and not opts.invalid and opts.hl_group and not seen[key] then
                seen[key] = true
                local er, ec = opts.end_row or sr, opts.end_col or sc
                local last = er - (ec == 0 and er > sr and 1 or 0)
                for _, visible in ipairs(self.view.ranges) do
                    for row = math.max(sr, visible[1]), math.min(last, visible[2]) do
                        if not sources[row] then
                            sources[row] = vim.api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1] or ''
                        end
                        self:add(row, { group = { row == sr and sc or 0,
                            row == er and math.min(ec, #sources[row]) or #sources[row],
                            priority = opts.priority or 0, highlight = opts.hl_group } })
                    end
                end
            end
        end
    end
end

---@private
---@param language string
---@param root TSNode
function Highlights:tree(language, root)
    if not self.view:overlaps(root) then
        return
    end
    if not vim.tbl_contains({ 'markdown', 'markdown_inline' }, language) then
        return
    end
    local query = vim.treesitter.query.get(language, 'highlights')
    if not query then
        return
    end
    local sources, seen = {}, {}
    self.view:query(root, query, function(id, node, data)
        local sr, sc, er, ec = Highlights.range(id, data, node)
        local priority = Highlights.priority(id, data)
        local key = table.concat({ id, node:id(), sr, sc, er, ec, priority,
            tostring(data.conceal), tostring(data.conceal_lines) }, ':')
        if seen[key] then return end
        seen[key] = true
        -- Capture columns belong to different rows for multiline nodes. Using
        -- the final column on the first row can split a UTF-8 character and
        -- turn a virtual highlight chunk into visible <e2>/<94>/<80> bytes.
        local last = er - (ec == 0 and 1 or 0)
        for _, range in ipairs(self.view.ranges) do
            for row = math.max(sr, range[1]), math.min(last, range[2]) do
                if not sources[row] then
                    sources[row] = vim.api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1] or ''
                end
                local start_col = row == sr and sc or 0
                local end_col = row == er and ec or #sources[row]
                if data.conceal_lines then self:add(row, { hidden = true }) end
                if data.conceal then
                    self:add(row, { conceal = { start_col, end_col,
                        replacement = data.conceal, blocks = 1 } })
                end
                self:add(row, { group = { start_col, end_col, priority = priority,
                    highlight = '@' .. query.captures[id] .. '.' .. language } })
            end
        end
    end)
end

---@private
---@param id integer
---@param data vim.treesitter.query.TSMetadata
---@param node TSNode
---@return integer, integer, integer, integer
function Highlights.range(id, data, node)
    local range = (data[id] or {}).range or data.range or { node:range() }
    local offset = (data[id] or {}).offset or data.offset or { 0, 0, 0, 0 }
    return range[1] + tonumber(offset[1]),
        range[2] + tonumber(offset[2]),
        range[3] + tonumber(offset[3]),
        range[4] + tonumber(offset[4])
end

---@private
---@param id integer
---@param data vim.treesitter.query.TSMetadata
---@return integer
function Highlights.priority(id, data)
    return tonumber((data[id] or {}).priority or data.priority) or 100
end

return Highlights
