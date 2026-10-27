---@class render.md.render.Context
---@field buf integer
---@field win? integer|integer[]
---@field event? string
---@field config? render.md.partial.UserConfig

---@class render.md.Api
local M = {}

---@param ctx render.md.render.Context
function M.render(ctx)
    local env = require('inkstone.lib.env')
    local list = require('inkstone.lib.list')
    local state = require('inkstone.state')
    local ui = require('inkstone.core.ui')

    local buf = ctx.buf
    local wins = list.ensure(ctx.win or env.buf.wins(buf))
    local event = ctx.event or 'Api'

    state.get(buf, ctx.config)
    state.attach()

    for _, win in ipairs(wins) do
        ui.update(buf, win, event, true)
    end
end

---@return boolean
function M.get()
    return require('inkstone.state').enabled
end

---@param enable? boolean
function M.set(enable)
    require('inkstone.core.manager').set(enable)
end

---@param enable? boolean
function M.set_buf(enable)
    require('inkstone.core.manager').set_buf(nil, enable)
end

function M.enable()
    M.set(true)
end

function M.buf_enable()
    M.set_buf(true)
end

function M.disable()
    M.set(false)
end

function M.buf_disable()
    M.set_buf(false)
end

function M.toggle()
    M.set()
end

function M.buf_toggle()
    M.set_buf()
end

function M.preview()
    require('inkstone.core.preview').open()
end

function M.toggle_fold()
    require('inkstone.core.folds').toggle()
end

function M.toggle_table()
    require('inkstone.core.table_views').toggle()
end

function M.toggle_view()
    require('inkstone.core.actions').toggle()
end

function M.toggle_list()
    require('inkstone.core.table_views').toggle(nil, nil, 'list')
end

function M.toggle_chart()
    require('inkstone.core.table_views').toggle(nil, nil, 'chart')
end

function M.typography()
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local config = require('inkstone.state').get(buf).typography
    config.enabled = config.enabled == false
    if config.enabled then require('inkstone.core.typography').retry() end
    require('inkstone.core.ui').update(buf, win, 'TypographyToggle', true)
end

function M.refresh()
    M.render({ buf = vim.api.nvim_get_current_buf(), event = 'Refresh' })
    require('inkstone.core.typography').schedule(true)
end

function M.media()
    require('inkstone.core.media').open()
end

function M.log()
    require('inkstone.core.log').open()
end

function M.expand()
    require('inkstone.state').modify_anti_conceal(1)
    M.enable()
end

function M.contract()
    require('inkstone.state').modify_anti_conceal(-1)
    M.enable()
end

function M.debug()
    require('inkstone.debug.marks').show()
end

function M.config()
    local difference = require('inkstone.state').difference()
    if not difference then
        -- selene: allow(deprecated)
        vim.print('default configuration')
    else
        -- selene: allow(deprecated)
        vim.print(difference)
    end
end

return M
