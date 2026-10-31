local Context = require('inkstone.request.context')
local compat = require('inkstone.lib.compat')
local env = require('inkstone.lib.env')
local iter = require('inkstone.lib.iter')
local log = require('inkstone.core.log')
local state = require('inkstone.state')

---@class render.md.Ui
local M = {}

M.ns = vim.api.nvim_create_namespace('inkstone.nvim')

---@private
---@type table<integer, render.md.Decorator>
M.cache = {}

---called from state on setup
function M.setup()
    require('inkstone.lib.softwrap').clear()
    require('inkstone.core.typography').clear()
    local table_views = require('inkstone.core.table_views')
    for buf in pairs(table_views.cache) do table_views.clear(buf) end
    require('inkstone.lib.layout_cache').cache = {}
    require('inkstone.core.media').reset()
    local folds = require('inkstone.core.folds')
    for buf in pairs(folds.trees) do folds.clear(buf) end
    for buf in pairs(folds.cache) do folds.clear(buf) end
    for _, decorator in pairs(M.cache) do decorator:dispose() end
    -- clear marks and reset cache
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    end
    M.cache = {}
    Context.cache = {}
end

---@param buf integer
---@return render.md.Decorator
function M.get(buf)
    local result = M.cache[buf]
    if not result then
        result = require('inkstone.lib.decorator').new(buf)
        M.cache[buf] = result
    end
    return result
end

---@param buf integer
---@param win integer
---@param event string
---@param force boolean
function M.update(buf, win, event, force)
    log.buf('info', 'Update', buf, event, ('force %s'):format(force))
    M.updater.new(buf, win, force):start()
end

---@class render.md.ui.Updater
---@field private buf integer
---@field private win integer
---@field private force boolean
---@field private decorator render.md.Decorator
---@field private config render.md.buf.Config
---@field private mode string
local Updater = {}
Updater.__index = Updater

---@param buf integer
---@param win integer
---@param force boolean
---@return render.md.ui.Updater
function Updater.new(buf, win, force)
    local self = setmetatable({}, Updater)
    self.buf = buf
    self.win = win
    self.force = force
    self.decorator = M.get(buf)
    self.config = state.get(buf)
    return self
end

function Updater:start()
    if not env.valid(self.buf, self.win) then
        return
    end
    self.decorator:schedule(
        self:changed() and not env.buf.empty(self.buf),
        self.config.debounce,
        log.runtime('update', function()
            self:run()
        end)
    )
end

---@private
---@return boolean
function Updater:changed()
    -- force or buffer has changed or we have not handled the visible range yet
    return self.force
        or self.decorator:changed()
        or not Context.contains(self.buf, self.win)
end

---@private
function Updater:run()
    if self.decorator ~= M.cache[self.buf] or not env.valid(self.buf, self.win) then
        return
    end
    self.mode = env.mode.get() -- mode is only available after this point
    local native = self.config.paragraph.enabled and self.config.paragraph.wrap and not self.config.paragraph.join
    local paragraph_modes = env.mode.join(self.config.render_modes, self.config.paragraph.render_modes)
    -- Native navigation must keep its starting geometry through selections,
    -- pending operators and command/search input. Anti-conceal still receives
    -- the actual mode/range. Joined layouts keep their policy.
    self.native_mode = native
        and (env.mode.is(self.mode, { 'v', 'V', '\22', 'c' }) or self.mode:sub(1, 2) == 'no')
        and env.mode.is('n', paragraph_modes)
    local render = self.config.enabled
        and (self.config.resolved:render(self.mode) or self.native_mode)
        and env.win.view(self.win).leftcol == 0
        and (self.config.render.diff or not env.win.get(self.win, 'diff'))
    log.buf('info', 'Render', self.buf, render)
    local next_state = render and 'rendered' or 'default'
    local softwrap = require('inkstone.lib.softwrap')
    for _, win in ipairs(env.buf.wins(self.buf)) do
        softwrap.linebreak(win, render and native
            and env.mode.is(self.native_mode and 'n' or self.mode, paragraph_modes)
            and self.config.win_options.linebreak == nil
            and softwrap.window_supported(self.buf, win))
        for name, value in pairs(self.config.win_options) do
            env.win.set(win, name, value[next_state])
        end
    end
    if not render then
        require('inkstone.core.media').clear(self.buf)
        self:clear()
    else
        self:render()
    end
end

---@private
function Updater:clear(refreshing)
    require('inkstone.core.typography').clear(self.buf, refreshing)
    self.decorator:clear(M.ns)
    vim.api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
    state.on.clear({ buf = self.buf, win = self.win })
end

---@private
function Updater:render()
    if self:changed() then
        self:parse(function(extmarks)
            if not extmarks then
                return
            end
            local initial = self.decorator:initial()
            -- A custom clear callback may depend on seeing an empty namespace.
            if state.on.clear ~= require('inkstone.settings').on.default.clear then
                self:clear(true)
                self.decorator:set(extmarks)
            else
                self.decorator:replace(M.ns, extmarks)
            end
            if initial then
                compat.fix_lsp_window(self.buf, self.win, extmarks)
                state.on.initial({ buf = self.buf, win = self.win })
            end
            self:display()
        end)
    else
        self:display()
    end
end

---@private
---@param callback fun(extmarks: render.md.Extmark[]|nil)
function Updater:parse(callback)
    local ok, parser = pcall(vim.treesitter.get_parser, self.buf)
    if ok and parser then
        -- reset buffer context
        local context = Context.new(self.buf, self.win, self.config)
        if context then
            -- make sure injections are processed
            context.view:parse(parser, function()
                local Extmark = require('inkstone.lib.extmark')
                local handlers = require('inkstone.core.handlers')
                local marks = handlers.run(context, parser)
                callback(iter.list.map(marks, Extmark.new))
            end)
        else
            log.buf('debug', 'Skip', self.buf, 'in progress')
            callback(nil)
        end
    else
        log.buf('error', 'Fail', self.buf, 'no treesitter parser found')
        callback(nil)
    end
end

---@private
function Updater:display()
    local range = self:hidden()
    self.editing = range and self:editing_table(range) or nil
    self.decorator:display(M.ns, function(extmark)
        return self:hide(extmark, range)
    end)
    local context = Context.get(self.buf)
    require('inkstone.core.typography').update(context, self.decorator:get())
    require('inkstone.core.media').update(context, range, self.editing)
    state.on.render({ buf = self.buf, win = self.win })
end

-- A wrapped table is one display layout. Restore its source as a unit so raw
-- long URLs never mix with virtual rows and borders from the rendered layout.
function Updater:editing_table(range)
    local context = Context.get(self.buf)
    for _, ranges in ipairs({ context.tables or {}, context.table_views or {} }) do
        for _, owner in ipairs(ranges) do
            if range[1] <= owner[2] and range[2] >= owner[1] then return owner end
        end
    end
end

---@private
---@return render.md.Range?
function Updater:hidden()
    -- anti-conceal is not enabled -> hide nothing
    -- in disabled mode -> hide nothing
    local config = self.config.anti_conceal
    if not config.enabled or env.mode.is(self.mode, config.disabled_modes) then
        return nil
    end
    -- row is not known -> buffer is not active -> hide nothing
    local row = env.row.get(self.buf, self.win)
    if not row then
        return nil
    end
    if env.mode.is(self.mode, { 'v', 'V', '\22' }) then
        local start = vim.fn.getpos('v')[2] - 1
        ---@type render.md.Range
        return { math.min(row, start), math.max(row, start) }
    else
        ---@type render.md.Range
        return { row - config.above, row + config.below }
    end
end

---@private
---@param extmark render.md.Extmark
---@param range? render.md.Range
---@return boolean
function Updater:hide(extmark, range)
    local mark = extmark:get()

    if mark.typography then
        if range and range[1] <= mark.typography[2] and range[2] >= mark.typography[1] then return true end
    end

    local editing = self.editing
    local owner = mark.table_range or mark.table_view
    if editing and (extmark:overlaps(editing)
        or (owner and owner[1] == editing[1] and owner[2] == editing[2])) then
        return true
    end

    -- not in top level or mark level modes -> hide
    local show = env.mode.join(self.config.render_modes, mark.modes)
    if not env.mode.is(self.mode, show) and not (self.native_mode and env.mode.is('n', show)) then
        return true
    end

    -- does not overlap with hidden range -> show
    if not extmark:overlaps(range) then
        return false
    end

    local conceal = mark.conceal
    if type(conceal) == 'boolean' then
        -- mark has conceal value -> respect
        return conceal
    else
        -- mark has conceal element -> show if anti-conceal is ignored
        local ignore = self.config.anti_conceal.ignore[conceal]
        return not (ignore and env.mode.is(self.mode, ignore))
    end
end

---@private
M.updater = Updater

return M
