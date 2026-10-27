-- A bounded pixel viewport. Conversion/cropping is async; Snacks owns Kitty
-- graphics transport, placeholders and tmux placement integration.
local M = { sessions = {}, remote = {} }

local function valid(session)
    return not session.closed and vim.api.nvim_buf_is_valid(session.buf) and vim.api.nvim_win_is_valid(session.win)
end

function M.close(session)
    if not session or session.closed then return end
    session.closed = true
    M.sessions[session.buf] = nil
    if session.timer then session.timer:stop(); session.timer:close(); session.timer = nil end
    if session.process then session.process:kill(15); session.process = nil end
    if session.placement then pcall(session.placement.close, session.placement); session.placement = nil end
    -- A killed child may still be finishing. Its callback performs final removal.
    if not session.running or session.running == 0 then vim.fn.delete(session.dir, 'rf') end
    if session.group then pcall(vim.api.nvim_del_augroup_by_id, session.group) end
end

function M.clear(origin)
    for owner, token in pairs(M.remote) do
        if not origin or owner == origin then
            M.remote[owner] = nil
            if token.convert and token.convert.abort then token.convert:abort() end
        end
    end
    for _, session in pairs(M.sessions) do
        if not origin or session.origin == origin then
            M.close(session)
            if vim.api.nvim_buf_is_valid(session.buf) then vim.api.nvim_buf_delete(session.buf, { force = true }) end
        end
    end
end

local function title(session, loading)
    if not valid(session) then return end
    local label = vim.fs.basename(session.source) .. (' · %d%%'):format(math.floor(session.zoom * 100 + .5))
    if session.pdf then label = label .. (' · page %d'):format(session.page) end
    vim.api.nvim_win_set_config(session.win, { title = ' ' .. label .. (loading and ' … ' or ' '), title_pos = 'center' })
end

function M.command(session, output)
    local size = session.backend.terminal and session.backend.terminal.size() or {}
    local cw, ch = size.cell_width or 9, size.cell_height or 18
    if cw <= 0 then cw = 9 end
    if ch <= 0 then ch = 18 end
    local width = math.max(1, math.floor(vim.api.nvim_win_get_width(session.win) * cw))
    local height = math.max(1, math.floor(vim.api.nvim_win_get_height(session.win) * ch))
    local zoom = math.max(.25, math.min(8, session.zoom))
    local max_x = math.max(0, math.floor((session.base_width or width) * zoom - width))
    local max_y = math.max(0, math.floor((session.base_height or height) * zoom - height))
    session.x, session.y = math.min(max_x, math.max(0, session.x)), math.min(max_y, math.max(0, session.y))
    local args = vim.deepcopy(session.command)
    if session.pdf then vim.list_extend(args, { '-density', '144' }) end
    vim.list_extend(args, {
        session.source .. '[' .. (session.pdf and session.page - 1 or 0) .. ']', '-auto-orient',
        '-resize', ('%dx%d'):format(width, height), '-resize', ('%.4f%%'):format(zoom * 100),
        '-format', '%w %h', '-write', 'info:',
        '-gravity', 'NorthWest', '-crop', ('%dx%d+%d+%d'):format(width, height, session.x, session.y),
        '+repage', '-background', 'none', '-extent', ('%dx%d'):format(width, height), output,
    })
    return args
end

function M.render(session)
    if not valid(session) then return end
    session.generation = session.generation + 1
    local generation = session.generation
    if session.process then session.process:kill(15); session.process = nil end
    local output = session.dir .. '/' .. generation .. '.png'
    local zoom, page = session.zoom, session.page
    local args = M.command(session, output)
    title(session, true)
    session.running = (session.running or 0) + 1
    local ok, process = pcall(vim.system, args, { text = true, timeout = session.timeout }, function(result)
        vim.schedule(function()
            session.running = session.running - 1
            if session.closed then
                if session.running == 0 then vim.fn.delete(session.dir, 'rf') end
                return
            end
            if not valid(session) or session.generation ~= generation then vim.fn.delete(output); return end
            session.process = nil
            if result.code ~= 0 or vim.fn.filereadable(output) ~= 1 then
                vim.fn.delete(output)
                session.page = session.displayed_page or 1
                title(session)
                local message = session.pdf and session.displayed_page
                    and ('Page %d is unavailable; keeping page %d'):format(page, session.displayed_page)
                    or vim.trim(result.stderr or 'image conversion failed'):match('[^\n]+')
                vim.notify('Inkstone viewer: ' .. (message or 'image conversion failed'), vim.log.levels.WARN)
                return
            end
            local w, h = (result.stdout or ''):match('(%d+)%s+(%d+)')
            if w and h then session.base_width, session.base_height = tonumber(w) / zoom, tonumber(h) / zoom end
            if session.placement then session.placement:close() end
            session.placement = session.backend.placement.new(session.buf, output, {
                inline = false, width = vim.api.nvim_win_get_width(session.win), height = vim.api.nvim_win_get_height(session.win),
            })
            if session.output then vim.fn.delete(session.output) end
            session.output, session.displayed_page = output, page
            title(session)
        end)
    end)
    if ok then session.process = process
    else
        session.running = session.running - 1
        vim.notify('Inkstone viewer: ' .. tostring(process), vim.log.levels.WARN)
    end
end

function M.action(session, action)
    if not valid(session) then return end
    if action == 'zoom_in' then session.zoom = math.min(8, session.zoom * 1.25)
    elseif action == 'zoom_out' then session.zoom = math.max(.25, session.zoom / 1.25)
    elseif action == 'fit' then session.zoom, session.x, session.y = 1, 0, 0
    elseif action == 'left' then session.x = session.x - 90
    elseif action == 'right' then session.x = session.x + 90
    elseif action == 'up' then session.y = session.y - 90
    elseif action == 'down' then session.y = session.y + 90
    elseif action == 'next' and session.pdf then session.page, session.x, session.y = session.page + 1, 0, 0
    elseif action == 'previous' and session.pdf then session.page, session.x, session.y = math.max(1, session.page - 1), 0, 0
    else return end
    -- An in-flight crop must not publish after a newer interaction is queued.
    session.generation = session.generation + 1
    if session.timer then session.timer:stop(); session.timer:close() end
    session.timer = vim.uv.new_timer()
    session.timer:start(40, 0, vim.schedule_wrap(function()
        session.timer:stop(); session.timer:close(); session.timer = nil
        M.render(session)
    end))
end

function M.open(source, options)
    options = options or {}
    local backend, reason = require('inkstone.core.media').backend()
    if not backend then vim.notify(reason, vim.log.levels.WARN); return end
    local config = options.config or require('inkstone.state').get(options.origin or vim.api.nvim_get_current_buf()).media
    local command = config.viewer_command
    if not command or vim.fn.executable(command[1] or '') ~= 1 then
        vim.notify('Inkstone viewer needs ImageMagick (media.viewer_command)', vim.log.levels.WARN); return
    end
    local page = tonumber(source:match('#page=(%d+)$')) or options.page or 1
    source = source:gsub('#page=%d+$', '')
    if source:match('^https?://') then
        local owner, token = options.origin or 0, {}
        local previous = M.remote[owner]
        M.remote[owner] = token
        if previous and previous.convert and previous.convert.abort then previous.convert:abort() end
        -- Use the backend's URL converter; no separate download implementation.
        local convert = backend.convert.convert({ src = source, on_done = function(result)
            if M.remote[owner] ~= token or (options.origin and not vim.api.nvim_buf_is_valid(options.origin)) then return end
            M.remote[owner] = nil
            if result:error() then vim.notify('Inkstone: image download failed', vim.log.levels.WARN)
            else
                local target = result.file
                if source:lower():match('%.pdf$') or source:lower():match('%.pdf[?]') then
                    for _, step in ipairs(result.steps or {}) do if step.name == 'url' then target = step.file; break end end
                    options = vim.tbl_extend('force', options, { pdf = true, page = page })
                end
                M.open(target, options)
            end
        end })
        token.convert = convert
        convert:run()
        return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local width = math.max(1, math.min(config.max_width, vim.o.columns - 4))
    local height = math.max(1, math.min(config.max_height, vim.o.lines - 5))
    local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', style = 'minimal', border = 'rounded',
        width = width, height = height, row = math.floor((vim.o.lines - height - 2) / 2), col = math.floor((vim.o.columns - width - 2) / 2),
        title = ' Image ', footer = ' +/− zoom · hjkl pan · [/] page · 0 fit · q close ', footer_pos = 'center' })
    local session = { buf = buf, win = win, origin = options.origin, backend = backend, source = source,
        pdf = options.pdf or source:lower():match('%.pdf$') ~= nil, page = math.max(1, page), zoom = 1, x = 0, y = 0,
        generation = 0, dir = vim.fn.tempname(), command = command, timeout = config.timeout }
    session.group = vim.api.nvim_create_augroup('InkstoneViewer' .. buf, { clear = true })
    vim.fn.mkdir(session.dir, 'p')
    M.sessions[buf] = session
    vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'wipe', false
    vim.api.nvim_create_autocmd('BufWipeout', { group = session.group, buffer = buf, once = true, callback = function() M.close(session) end })
    local keys = { ['+'] = 'zoom_in', ['='] = 'zoom_in', ['-'] = 'zoom_out', ['0'] = 'fit',
        h = 'left', j = 'down', k = 'up', l = 'right', [']'] = 'next', ['['] = 'previous',
        ['<ScrollWheelUp>'] = 'zoom_in', ['<ScrollWheelDown>'] = 'zoom_out' }
    for key, action in pairs(keys) do
        vim.keymap.set('n', key, function() M.action(session, action) end, { buffer = buf, desc = action })
    end
    vim.keymap.set('n', 'q', function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
    vim.keymap.set('n', '<Esc>', function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
    vim.api.nvim_create_autocmd('VimResized', { group = session.group, callback = function() M.action(session, 'fit') end })
    M.render(session)
    return session
end

return M
