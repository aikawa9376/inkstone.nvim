local Extmark = require('inkstone.lib.extmark')
local compat = require('inkstone.lib.compat')
local replacements = require('inkstone.lib.replacements')

---@class render.md.Decorator
---@field private buf integer
---@field private timer uv.uv_timer_t
---@field private running boolean
---@field private marks render.md.Extmark[]
---@field private generated render.md.Extmark[]
---@field private tick integer?
---@field private padding { row: integer, mark: render.md.Extmark }[]
---@field private watching boolean?
---@field private disposed boolean?
---@field n integer
local Decorator = {}
Decorator.__index = Decorator

---@param buf integer
---@return render.md.Decorator
function Decorator.new(buf)
    local self = setmetatable({}, Decorator)
    self.buf = buf
    self.timer = assert(compat.uv.new_timer())
    self.running = false
    self.marks = {}
    self.generated = {}
    self.tick = nil
    self.padding = {}
    self.n = 0
    return self
end

---@return boolean
function Decorator:initial()
    return self.tick == nil
end

---@return boolean
function Decorator:changed()
    return self.tick ~= self:get_tick()
end

---@return render.md.Extmark[]
function Decorator:get()
    local result = {} ---@type render.md.Extmark[]
    vim.list_extend(result, self.marks)
    vim.list_extend(result, self.generated)
    return result
end

---@param marks render.md.Extmark[]
function Decorator:set(marks)
    self.marks = marks
    self.tick = self:get_tick()
    self.n = self.n + 1
end

---Keep equal decorations across viewport refreshes and partial edits.
function Decorator:replace(ns, marks)
    local buckets, retained = {}, {}
    local changed = self:changed()
    local same = #marks == #self.marks
    if same then
        for i, extmark in ipairs(self.marks) do
            if not vim.deep_equal(extmark:get(), marks[i]:get())
                or (changed and not extmark:valid(ns, self.buf)) then same = false; break end
        end
    end
    if same and not changed then
        self:set(self.marks)
        return
    end
    local function key(mark) return mark.start_row .. ':' .. mark.start_col end
    for _, extmark in ipairs(self.marks) do
        local k = key(extmark:get())
        buckets[k] = buckets[k] or {}
        buckets[k][#buckets[k] + 1] = extmark
    end
    for i, next_mark in ipairs(marks) do
        local bucket = buckets[key(next_mark:get())] or {}
        for index, old in ipairs(bucket) do
            if vim.deep_equal(old:get(), next_mark:get())
                and (not changed or old:valid(ns, self.buf)) then
                retained[old], marks[i] = true, old
                bucket[index] = bucket[#bucket]
                bucket[#bucket] = nil
                break
            end
        end
    end
    for _, extmark in ipairs(self.marks) do
        if not retained[extmark] then extmark:hide(ns, self.buf) end
    end
    if changed then
        for _, extmark in ipairs(self.generated) do extmark:hide(ns, self.buf) end
        self.generated = {}
        self.layout = nil
    end
    self:set(marks)
end

---@param ns integer
function Decorator:clear(ns)
    for _, extmark in ipairs(self:get()) do
        extmark:hide(ns, self.buf)
    end
    self.generated = {}
    self.layout = nil
    self.padding = {}
end

-- Whole-line streaming updates collapse inline extmarks to column zero. Remove
-- obsolete wrap padding synchronously, before a redraw can precede TextChanged,
-- the debounce timer or async parsing. Keep unaffected rows and decorations.
---@private
---@param ns integer
function Decorator:watch_padding(ns)
    if self.watching then return end
    self.watching = vim.api.nvim_buf_attach(self.buf, false, {
        on_lines = function(_, _, _, first, last, new_last)
            if self.disposed then return true end
            local retained = {}
            for _, entry in ipairs(self.padding) do
                if entry.row >= first and entry.row < last then
                    entry.mark:hide(ns, self.buf)
                else
                    if entry.row >= last then entry.row = entry.row + new_last - last end
                    retained[#retained + 1] = entry
                end
            end
            self.padding = retained
        end,
        on_reload = function()
            if self.disposed then return true end
            for _, entry in ipairs(self.padding) do entry.mark:hide(ns, self.buf) end
            self.padding = {}
        end,
        on_detach = function() self.padding, self.watching = {}, nil end,
    })
end

---@param ns integer
---@param hide fun(extmark: render.md.Extmark): boolean
function Decorator:display(ns, hide)
    local visible = {} ---@type render.md.Mark[]
    local layout = {}
    self.padding = {}
    for _, extmark in ipairs(self.marks) do
        if hide(extmark) then
            extmark:hide(ns, self.buf)
        else
            extmark:show(ns, self.buf)
            visible[#visible + 1] = extmark:get()
            if extmark:get().paragraph_padding and extmark:shown() then
                self.padding[#self.padding + 1] = { row = extmark:get().start_row, mark = extmark }
            end
            if extmark:get().replace or extmark:get().opts.conceal_lines then layout[#layout + 1] = extmark end
        end
    end
    if #self.padding > 0 then self:watch_padding(ns) end

    local line_count = vim.api.nvim_buf_line_count(self.buf)
    local tick = self:get_tick()
    local previous = self.layout
    local same = previous and previous.tick == tick and previous.lines == line_count and #previous.marks == #layout
    if same then
        for i, extmark in ipairs(layout) do
            if previous.marks[i] ~= extmark then same = false; break end
        end
    end
    -- Descriptions are immutable after construction. Reconciliation retains
    -- the same objects only after comparing the entire regenerated mark.
    if same then return end
    self.layout = { tick = tick, lines = line_count, marks = layout }
    local generated = replacements.resolve(visible, line_count)
    local current = {} ---@type render.md.Mark[]
    for _, extmark in ipairs(self.generated) do
        current[#current + 1] = extmark:get()
    end
    if vim.deep_equal(current, generated) then
        return
    end
    for _, extmark in ipairs(self.generated) do
        extmark:hide(ns, self.buf)
    end
    self.generated = {}
    for _, mark in ipairs(generated) do
        local extmark = Extmark.new(mark)
        extmark:show(ns, self.buf)
        self.generated[#self.generated + 1] = extmark
    end
end

---@param debounce boolean
---@param ms integer
---@param callback fun()
function Decorator:schedule(debounce, ms, callback)
    if debounce and ms > 0 then
        self.pending = callback
        self.timer:start(ms, 0, function()
            self.running = false
            local pending = self.pending
            self.pending = nil
            if pending then vim.schedule(pending) end
        end)
        if not self.running then
            self.running = true
            self.pending = nil
            vim.schedule(callback)
        end
    else
        vim.schedule(callback)
    end
end

function Decorator:dispose()
    self.disposed = true
    self.padding = {}
    self.pending = nil
    if self.timer and not self.timer:is_closing() then
        self.timer:stop()
        self.timer:close()
    end
end

---@private
---@return integer
function Decorator:get_tick()
    return vim.api.nvim_buf_get_changedtick(self.buf)
end

return Decorator
