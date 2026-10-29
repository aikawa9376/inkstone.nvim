local Node = require('inkstone.lib.node')
local env = require('inkstone.lib.env')
local interval = require('inkstone.lib.interval')
local log = require('inkstone.core.log')

---@class render.md.request.View
---@field private buf integer
---@field private ranges render.md.Range[]
local View = {}
View.__index = View

---@param buf integer
---@return render.md.request.View
function View.new(buf)
    local self = setmetatable({}, View)
    self.buf = buf
    local ranges = {} ---@type render.md.Range[]
    for _, win in ipairs(env.buf.wins(buf)) do
        ranges[#ranges + 1] = env.range(buf, win, 10)
    end
    self.ranges = interval.coalesce(ranges)
    return self
end

---@return string
function View:__tostring()
    local ranges = {} ---@type string[]
    for _, range in ipairs(self.ranges) do
        ranges[#ranges + 1] = ('%d->%d'):format(range[1], range[2])
    end
    return ('[%s]'):format(table.concat(ranges, ','))
end

---@param win integer
---@return boolean
function View:contains(win)
    local rows = env.range(self.buf, win, 0)
    for _, range in ipairs(self.ranges) do
        if interval.contains(range, rows) then
            return true
        end
    end
    return false
end

---@param node TSNode
---@return boolean
function View:overlaps(node)
    local start_row, _, end_row = node:range()
    for _, range in ipairs(self.ranges) do
        if interval.overlap(range, { start_row, end_row }) then
            return true
        end
    end
    return false
end

---Visit direct children in the view without wrapping every off-screen row.
---Children are ordered and non-overlapping, so seek by end row, then walk.
function View:children(root, callback)
    local seen = {}
    for _, range in ipairs(self.ranges) do
        local low, high = 0, root:child_count()
        while low < high do
            local middle = math.floor((low + high) / 2)
            local _, _, finish = root:child(middle):range()
            if finish < range[1] then low = middle + 1 else high = middle end
        end
        local node = root:child(low)
        while node do
            local first = node:range()
            if first > range[2] then break end
            local id = node:id()
            if not seen[id] then seen[id] = true; callback(node) end
            node = node:next_sibling()
        end
    end
end

-- Share native tree enumeration within one synchronous handler pass only.
function View:each_tree(parser, callback)
    if self.trees then
        for _, entry in ipairs(self.trees) do callback(entry[1], entry[2]) end
    else
        parser:for_each_tree(function(tree, language_tree)
            if require('inkstone.core.ts').render(tree, language_tree) then
                callback(tree, language_tree)
            end
        end)
    end
end

---@param parser vim.treesitter.LanguageTree
---@param callback fun()
function View:parse(parser, callback)
    local buf = self.buf
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local mode = vim.api.nvim_get_mode().mode
    parser:parse(self.ranges, function(err, trees)
        if err or not trees or not vim.api.nvim_buf_is_valid(buf)
            or vim.api.nvim_buf_get_changedtick(buf) ~= tick
            or vim.api.nvim_get_mode().mode ~= mode then return end
        local Context = require('inkstone.request.context')
        local ok, context = pcall(Context.get, buf)
        if ok and context.view == self and vim.api.nvim_win_is_valid(context.win)
            and vim.api.nvim_win_get_buf(context.win) == buf then callback() end
    end)
end

---@param root TSNode
---@param query vim.treesitter.Query
---@param callback fun(capture: string, node: render.md.Node)
function View:nodes(root, query, callback)
    self:query(root, query, function(id, ts_node)
        local sr, sc, er, ec = ts_node:range()
        if not ts_node:has_error() and (er > sr or (er == sr and ec > sc)) then
            local capture = query.captures[id]
            local node = Node.new(self.buf, ts_node)
            log.node(capture, node)
            callback(capture, node)
        end
    end)
end

---@param root TSNode
---@param query vim.treesitter.Query
---@param callback fun(id: integer, node: TSNode, data: vim.treesitter.query.TSMetadata)
function View:query(root, query, callback)
    for _, range in ipairs(self.ranges) do
        local start, stop = range[1], range[2]
        for id, node, data in query:iter_captures(root, self.buf, start, stop) do
            callback(id, node, data)
        end
    end
end

return View
