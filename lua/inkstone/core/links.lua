local M = {}

-- Read the displayed link marks and the current request's native conceal
-- snapshot. Hidden icons, revealed source and stale parse coordinates do not
-- participate in movement. No parsing is needed for individual key presses.
local function ranges(buf, row)
    local config = require('inkstone.state').get(buf)
    local decorator = require('inkstone.core.ui').cache[buf]
    local context = require('inkstone.request.context').cache[buf]
    if not config.enabled or not config.link.enabled or not decorator or decorator:changed()
        or vim.wo.conceallevel < 2
        or not require('inkstone.lib.softwrap').concealed(vim.api.nvim_get_current_win(), row, 'n') then return {} end
    local links, conceals = {}, {}
    for _, extmark in ipairs(decorator:get()) do
        if extmark:shown() then
            local mark = extmark:get()
            local range = mark.link_range
            if range and row >= range[1] and row <= range[3] then
                links[#links + 1] = { row == range[1] and range[2] or 0,
                    row == range[3] and range[4] or math.huge }
            end
            if mark.opts.conceal == '' and row == mark.start_row and (mark.opts.end_row or row) == row then
                conceals[#conceals + 1] = { mark.start_col, mark.opts.end_col }
            end
        end
    end
    if #links == 0 then return {} end
    if context and vim.treesitter.highlighter.active[buf] then
        vim.list_extend(conceals, context.highlights:line(row).native_conceals)
    end
    local result = {}
    for _, conceal in ipairs(conceals) do
        for _, link in ipairs(links) do
            local first, last = math.max(conceal[1], link[1]), math.min(conceal[2], link[2])
            if first < last then result[#result + 1] = { first, last } end
        end
    end
    require('inkstone.lib.interval').sort(result)
    local merged = {}
    for _, range in ipairs(result) do
        local last = merged[#merged]
        if last and range[1] <= last[2] then last[2] = math.max(last[2], range[2])
        else merged[#merged + 1] = range end
    end
    return merged
end

function M.attach(buf)
    for key, direction in pairs({ h = -1, l = 1 }) do
        vim.keymap.set('n', key, function() M.move(direction) end, {
            buffer = buf, desc = 'Move past hidden Markdown link syntax',
        })
    end
    -- Respect integrations such as Obsidian's gf and Git's review navigation.
    -- User on.attach hooks still run after these defaults.
    local actions = {
        gf = { function() return M.open(false) end, 'Edit link destination' },
        gx = { function() return M.open(true) end, 'Open link destination with system handler' },
        [']u'] = { function() M.jump(1); return true end, 'Next URL or path' },
        ['[u'] = { function() M.jump(-1); return true end, 'Previous URL or path' },
    }
    vim.api.nvim_buf_call(buf, function()
        for key, action in pairs(actions) do
            local previous = vim.fn.maparg(key, 'n', false, true)
            if previous.buffer ~= 1 then
                vim.keymap.set('n', key, function()
                    if not action[1]() then M.fallback(key, previous) end
                end, { buffer = buf, desc = action[2] })
            end
        end
    end)
end

---@private
function M.fallback(key, mapping)
    local rhs
    if mapping.callback then
        rhs = mapping.callback()
        if mapping.expr ~= 1 then return end
    elseif mapping.rhs and mapping.rhs ~= '' then
        rhs = mapping.expr == 1 and vim.api.nvim_eval(mapping.rhs) or mapping.rhs
        rhs = rhs:gsub('<SID>', '<SNR>' .. (mapping.sid or 0) .. '_')
    else
        vim.cmd.normal({ args = { (vim.v.count > 0 and tostring(vim.v.count) or '') .. key }, bang = true })
        return
    end
    if rhs and rhs ~= '' then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(rhs, true, false, true),
            mapping.noremap == 1 and 'n' or 'm', false)
    end
end

function M.target()
    local item = require('inkstone.core.link_targets').current(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0))
    return item and item.target
end

local function heading(fragment)
    if not fragment or fragment == '' then return end
    local row, col = fragment:match('^L(%d+)C(%d+)')
    row = row or fragment:match('^L(%d+)')
    if row then
        row = math.min(tonumber(row), vim.api.nvim_buf_line_count(0))
        local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
        vim.api.nvim_win_set_cursor(0, { math.max(1, row), math.min(math.max(0, (tonumber(col) or 1) - 1), #line) })
        return
    end
    fragment = fragment:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        local title = line:match('^%s*#+%s+(.+)')
        if title then
            local slug = title:lower():gsub('%s+#+%s*$', ''):gsub('[%p]', function(c) return c == '-' and c or '' end):gsub('%s+', '-')
            if slug == fragment:lower() then vim.api.nvim_win_set_cursor(0, { i, 0 }); return end
        end
    end
end

-- gf edits local files and opens URLs; gx uses the user's vim.ui.open handler.
-- Neither action moves the cursor into concealed source to discover a target.
function M.open(system)
    local target = M.target()
    if not target then return false end
    target = target:gsub('\\([%p ])', '%1')
    if (target:match('^%a[%w+.-]*://') or target:match('^mailto:')) and not target:match('^file://') then
        local _, err = vim.ui.open(target)
        if err then vim.notify(err, vim.log.levels.ERROR) end
        return true
    end
    local path, fragment = target:match('^(.-)#(.*)$')
    path = path or target
    local row, col
    local filename, lnum, column = path:match('^(.-):(%d+):(%d+)$')
    if not filename then filename, lnum = path:match('^(.-):(%d+)$') end
    if filename then path, row, col = filename, tonumber(lnum), tonumber(column) or 1 end
    if path == '' then
        vim.cmd("normal! m'")
        heading(fragment)
        return true
    end
    local buf = vim.api.nvim_get_current_buf()
    if path:sub(1, 2) == '~/' then path = vim.fn.expand('~') .. path:sub(2) end
    local resolved = require('inkstone.core.media').resolve(buf, path)
    if not resolved then return true end
    if not vim.uv.fs_stat(resolved) then
        local found = vim.fn.findfile(path, vim.bo.path)
        if found ~= '' then resolved = vim.fn.fnamemodify(found, ':p') end
    end
    if system then
        local _, err = vim.ui.open(resolved)
        if err then vim.notify(err, vim.log.levels.ERROR) end
    elseif not vim.uv.fs_stat(resolved) then
        vim.notify('Inkstone: file not found: ' .. path, vim.log.levels.WARN)
    else
        vim.cmd("normal! m'")
        vim.api.nvim_cmd({ cmd = 'edit', args = { resolved }, magic = { file = false, bar = false } }, {})
        if row then heading(('L%dC%d'):format(row, col)) else heading(fragment) end
        vim.cmd('normal! zv')
    end
    return true
end

function M.jump(direction, count)
    local targets = require('inkstone.core.link_targets')
    local cursor, candidates = vim.api.nvim_win_get_cursor(0), {}
    for _, item in ipairs(targets.collect(vim.api.nvim_get_current_buf())) do
        local pos = item.pos
        local after = pos[1] > cursor[1] or pos[1] == cursor[1] and pos[2] > cursor[2]
        local before = pos[1] < cursor[1] or pos[1] == cursor[1] and pos[2] < cursor[2]
        if not targets.contains(item.range, cursor[1] - 1, cursor[2])
            and (direction > 0 and after or direction < 0 and before) then candidates[#candidates + 1] = item end
    end
    if #candidates == 0 then return end
    local index = math.min(count or vim.v.count1, #candidates)
    local item = candidates[direction > 0 and index or #candidates - index + 1]
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, item.pos)
    vim.cmd('normal! zv')
end

function M.move(direction, count)
    local buf = vim.api.nvim_get_current_buf()
    local motion = direction > 0 and 'l' or 'h'
    local cache = {}
    for _ = 1, count or vim.v.count1 do
        vim.cmd.normal({ args = { motion }, bang = true })
        while true do
            local cursor = vim.api.nvim_win_get_cursor(0)
            local row, col = cursor[1] - 1, cursor[2]
            if not cache[row] then cache[row] = ranges(buf, row) end
            local hidden
            for _, range in ipairs(cache[row]) do
                if col >= range[1] and col < range[2] then hidden = range; break end
            end
            if not hidden then break end
            local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
            local target = hidden[2]
            local next_row = row
            if direction > 0 and target >= #line and row + 1 < vim.api.nvim_buf_line_count(buf)
                and vim.o.whichwrap:find('l', 1, true) then
                next_row, target = row + 1, 0
            elseif direction < 0 or target >= #line then
                -- byteidx/charidx retain UTF-8 and combining-character bounds.
                target = math.max(0, vim.fn.byteidx(line, vim.fn.charidx(line, hidden[1]) - 1))
            end
            if next_row == row and target == col then break end
            vim.api.nvim_win_set_cursor(0, { next_row + 1, target })
        end
    end
end

return M
