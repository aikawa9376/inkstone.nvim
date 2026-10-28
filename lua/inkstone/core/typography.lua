-- Kitty OSC 66 text is outside Neovim's grid. Reserve its cells, erase it
-- before native redraws and replay it after the grid flush. Never change tmux.
local M = { active = {}, drawn = {}, tmux = nil, pending = false }
local ns = vim.api.nvim_create_namespace('inkstone.typography')
local probe_timeout = 1200
local cursorline_windows = {}
local cursorline_extmark_windows = {}
local function kitty()
    return vim.env.KITTY_WINDOW_ID ~= nil or vim.env.TERM_PROGRAM == 'kitty'
end

function M.wrap(data)
    if vim.env.TMUX then return '\27Ptmux;' .. data:gsub('\27', '\27\27') .. '\27\\' end
    return data
end

local function send(data)
    if data ~= '' and vim.api.nvim_ui_send then vim.api.nvim_ui_send(M.wrap(data)) end
end

local function refresh_waiters()
    local waiters = M.waiters or {}
    M.waiters = {}
    for buf, win in pairs(waiters) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            require('inkstone.core.ui').update(buf, win, 'TypographyReady', true)
        end
    end
end

function M.probe()
    if M.probing or M.capability ~= nil then return end
    if vim.env.TMUX then
        -- tmux consumes its first XTVERSION reply, but can translate later
        -- replies into extended keys before Neovim sees them. A TUI timeout
        -- guard cannot undo that. Read tmux's cached identity over its socket.
        if not M.tmux then
            M.refresh_tmux(function() if M.tmux.allowed then M.probe() end end)
        else
            M.capability = M.version_supported(M.tmux.terminal)
            refresh_waiters()
        end
        return
    end
    M.probing = true
    -- A fragmented DCS reply becomes mapped keys if the TUI's key-code timer
    -- expires (notably with ttimeoutlen=1). Protect only the query's lifetime.
    local input = { ttimeout = vim.o.ttimeout, ttimeoutlen = vim.o.ttimeoutlen }
    local guarded = math.max(probe_timeout, input.ttimeoutlen)
    vim.o.ttimeoutlen, vim.o.ttimeout = guarded, true
    local autocmd, timer
    local function done(supported)
        if not M.probing then return end
        M.probing, M.capability = false, supported
        -- Preserve any option changes the user made while the query was pending.
        if vim.o.ttimeoutlen == guarded then vim.o.ttimeoutlen = input.ttimeoutlen end
        if vim.o.ttimeout then vim.o.ttimeout = input.ttimeout end
        if timer and not timer:is_closing() then timer:stop(); timer:close() end
        if autocmd then pcall(vim.api.nvim_del_autocmd, autocmd) end
        M.probe_timer, M.probe_autocmd = nil, nil
        refresh_waiters()
    end
    autocmd = vim.api.nvim_create_autocmd('TermResponse', { callback = function(event)
        local sequence = type(event.data) == 'table' and event.data.sequence or event.data
        if type(sequence) ~= 'string' then return end
        local major, minor = sequence:match('kitty%((%d+)%.(%d+)')
        if major then done(tonumber(major) > 0 or tonumber(minor) >= 40)
        elseif sequence:match('^\27P>|') then done(false) end
    end })
    timer = vim.defer_fn(function() done(false) end, probe_timeout)
    M.probe_timer, M.probe_autocmd = timer, autocmd
    send('\27[>0q')
end

function M.version_supported(identity)
    local major, minor = (identity or ''):match('^kitty%((%d+)%.(%d+)')
    return major ~= nil and (tonumber(major) > 0 or tonumber(minor) >= 40)
end

function M.retry()
    if M.capability == true and M.tmux and M.tmux.allowed then return end
    -- Reuse an in-flight query: its reply cannot be recalled or safely ignored.
    M.capability, M.tmux = nil, nil
end

function M.erase(matches)
    local out, retained = {}, {}
    for _, rect in ipairs(M.drawn) do
        if not matches or matches(rect) then
            out[#out + 1] = ('\27[%d;%dH\27[%dX'):format(rect.row, rect.col, rect.width)
        else retained[#retained + 1] = rect end
    end
    M.drawn = retained
    if #out > 0 then send('\27' .. '7' .. table.concat(out) .. '\27' .. '8') end
end

function M.refresh_tmux(callback)
    if not vim.env.TMUX then
        M.tmux = { top = 0, left = 0, allowed = true }
        if M.capability == true then refresh_waiters() end
        if callback then callback() end
        return
    end
    if M.querying then return end
    M.querying = true
    local args = { 'tmux', 'display-message', '-p' }
    if vim.env.TMUX_PANE then vim.list_extend(args, { '-t', vim.env.TMUX_PANE }) end
    args[#args + 1] = '#{pane_top},#{pane_left},#{allow-passthrough},#{status},#{status-position},#{client_termtype}'
    vim.system(args, { text = true, timeout = 1000 }, function(result)
        vim.schedule(function()
            M.querying = false
            local top, left, allowed, status, position, terminal = (result.stdout or ''):match(
                '^(%d+),(%d+),([^,]*),([^,]*),([^,]*),([^\r\n]*)')
            M.tmux = { top = tonumber(top) or 0, left = tonumber(left) or 0,
                allowed = result.code == 0 and (allowed == 'on' or allowed == 'all'), terminal = terminal }
            if position == 'top' and status ~= 'off' then M.tmux.top = M.tmux.top + (tonumber(status) or 1) end
            local previous = M.capability
            M.capability = M.version_supported(terminal)
            if previous ~= M.capability then
                M.waiters = M.waiters or {}
                for buf, active in pairs(M.active) do M.waiters[buf] = active.win end
            end
            refresh_waiters()
            if callback then callback() end
        end)
    end)
end

function M.supports(context)
    if context.config.typography.enabled == false
        or (context.config.typography.enabled ~= true and not kitty()) or not vim.api.nvim_ui_send
        or #vim.api.nvim_list_uis() == 0 or vim.env.ZELLIJ then return false end
    M.waiters = M.waiters or {}
    if not M.tmux or (M.capability == nil and M.tmux.allowed) then M.waiters[context.buf] = context.win end
    if not M.tmux then
        M.refresh_tmux(function()
            if M.tmux.allowed and next(M.waiters or {}) then M.probe()
            elseif not M.tmux.allowed then M.waiters = {} end
        end)
    elseif M.tmux.allowed then M.probe() end
    return M.tmux ~= nil and M.tmux.allowed and M.capability == true
end

function M.spec(ratio)
    if not ratio or ratio <= 0 or ratio == 1 then return end
    ratio = math.max(.25, math.min(7, ratio))
    local scale = math.ceil(ratio)
    local num, den, error = 1, 1, math.huge
    for d = 1, 15 do
        for n = 1, d do
            local e = math.abs(scale * n / d - ratio)
            if e < error then num, den, error = n, d, e end
        end
    end
    return { scale = scale, num = num, den = den, ratio = scale * num / den }
end

function M.runs(chunks, spec)
    local units = require('inkstone.parser.table').units(chunks)
    local result, text, width, highlight = {}, {}, 0, nil
    local limit = math.max(1, math.floor(7 * spec.den / spec.num))
    -- OSC 66 advances by whole scaled cells. A full fractional run must end
    -- on an exact denominator boundary; otherwise each chunk's rounded tail
    -- adds a gap in words (e.g. "Images an" + "d diagrams" at 1.5x).
    local exact = math.floor(limit / spec.den) * spec.den
    if exact > 0 then limit = exact end
    local function flush()
        if width == 0 then return end
        local cells = math.max(1, math.ceil(width * spec.num / spec.den - 1e-8))
        result[#result + 1] = { text = table.concat(text), width = cells * spec.scale, cells = cells, highlight = highlight }
        text, width = {}, 0
    end
    for _, unit in ipairs(units) do
        local clean = unit.text:gsub('[%c]', '')
        if clean ~= '' and unit.width > 0 then
            if width + unit.width > limit or (width > 0 and not vim.deep_equal(highlight, unit.highlight)) then flush() end
            text[#text + 1], width, highlight = clean, width + unit.width, unit.highlight
        end
    end
    flush()
    return result
end

local function tag(marks, first, entry)
    local list = marks:get()
    for i = first, #list do list[i].typography, list[i].font_id = entry.range, entry.id end
end

-- Once Kitty support is confirmed, only OSC 66 owns these glyphs. A second
-- normal-size copy in the native grid becomes visible during native redraws.
-- Reserve its original cells without putting duplicate text underneath.
local function reserve(chunks)
    local result = {}
    for _, chunk in ipairs(chunks) do
        result[#result + 1] = { (' '):rep(vim.fn.strdisplaywidth(chunk[1])), chunk[2] }
    end
    return result
end

function M.heading(context, marks, node, data)
    if not M.supports(context) then return false end
    local spec = M.spec(context.config.typography.headings[data.level])
    -- Keep native layout for nested/indented headings and impossible widths.
    if not spec or node.start_col ~= 0 or node:col() ~= 0 then return false end
    local inline = node:child('inline')
    if not inline then return false end
    local line = require('inkstone.lib.display').line(context, inline)
    if #line == 0 then return false end
    local runs, lines = M.runs(line, spec), {}
    local current, width, budget = {}, 0, context:window_width()
    for _, run in ipairs(runs) do
        if run.width > budget then return false end
        if width + run.width > budget then lines[#lines + 1] = { runs = current, width = width }; current, width = {}, 0 end
        current[#current + 1], width = run, width + run.width
    end
    if #current > 0 then lines[#lines + 1] = { runs = current, width = width } end
    if #lines == 0 then return false end
    local last = node.end_row - (node.end_col == 0 and 1 or 0)
    local entry = { id = 'heading:' .. node.start_row, range = { node.start_row, last },
        row = node.start_row, col = 0, spec = spec, lines = lines, highlight = data.fg, background = data.bg }
    context.typography[#context.typography + 1] = entry
    local first, virtual = #marks:get() + 1, {}
    local function chunks(at)
        local out = {}; for _, run in ipairs(at.runs) do out[#out + 1] = { run.text, run.highlight } end
        return reserve(out)
    end
    marks:over(context.config.heading, true, node, { conceal = '', virt_text = chunks(lines[1]), virt_text_pos = 'inline' })
    for i = 1, #lines do
        if i > 1 then virtual[#virtual + 1] = chunks(lines[i]) end
        for _ = 2, spec.scale do virtual[#virtual + 1] = {} end
    end
    if #virtual > 0 then marks:add(context.config.heading, true, node.start_row, 0, { virt_lines = virtual }) end
    if not data.atx then
        marks:over(context.config.heading, true, data.marker, { conceal_lines = '' })
    end
    tag(marks, first, entry)
    return true
end

function M.small(context, parser, marks)
    if not M.supports(context) then return end
    local spec = M.spec(context.config.typography.small)
    if not spec then return end
    local Marks = require('inkstone.lib.marks')
    local own = Marks.new(context, false)
    local seen = {}
    context.view:each_tree(parser, function(tree, language)
        if language:lang() ~= 'markdown_inline' or not context.view:overlaps(tree:root()) then return end
        local sr, sc = tree:root():range()
        local text = vim.treesitter.get_node_text(tree:root(), context.buf)
        for i, source in ipairs(vim.split(text, '\n', { plain = true })) do
            local row, base = sr + i - 1, i == 1 and sc or 0
            for start, body, finish in source:gmatch('()<small>(.-)</small>()') do
                local col, stop = base + start - 1, base + finish - 1
                local key = row .. ':' .. col
                local replaced = false
                for _, mark in ipairs(marks) do
                    if (mark.replace or mark.table_view or mark.typography) and row >= mark.start_row
                        and row <= (mark.opts.end_row or mark.start_row) then replaced = true; break end
                end
                local opening = tree:root():named_descendant_for_range(row, col, row, col + 7)
                if opening and opening:type() == 'html_tag' and not seen[key] and not replaced and body ~= '' then
                    seen[key] = true
                    local line = require('inkstone.lib.display').line(context, { start_row = row, end_row = row,
                        start_col = col + 7, end_col = stop - 8, text = body })
                    local runs = M.runs(line, spec)
                    local width = 0; for _, run in ipairs(runs) do width = width + run.width end
                    local entry = { id = 'small:' .. key, range = { row, row }, row = row, col = col,
                        last_col = stop, spec = spec, lines = { { runs = runs, width = width } },
                        erase_width = require('inkstone.lib.str').line_width(line) }
                    context.typography[#context.typography + 1] = entry
                    local first = #own:get() + 1
                    own:add(context.config.paragraph, true, row, col, { end_col = stop, conceal = '',
                        virt_text = reserve(line), virt_text_pos = 'inline' })
                    tag(own, first, entry)
                end
            end
        end
    end)
    vim.list_extend(marks, own:get())
end

function M.filter(context, marks)
    if #context.typography == 0 then return marks end
    local result = {}
    for _, mark in ipairs(marks) do
        local inside = false
        if not mark.font_id then
            for _, entry in ipairs(context.typography) do
                if mark.start_row >= entry.range[1] and mark.start_row <= entry.range[2]
                    and (not entry.last_col or (mark.start_col >= entry.col and mark.start_col < entry.last_col)) then inside = true; break end
            end
        end
        if not inside then result[#result + 1] = mark end
    end
    return result
end

local function colors(highlight, fallback)
    local result = {}
    local names = type(highlight) == 'table' and highlight or { highlight or fallback or 'Normal' }
    for _, name in ipairs(names) do
        local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        if ok then for k, v in pairs(value) do result[k] = v end end
    end
    local out = { '\27[0m' }
    if result.fg then out[#out + 1] = ('\27[38;2;%d;%d;%dm'):format(math.floor(result.fg / 65536), math.floor(result.fg / 256) % 256, result.fg % 256) end
    if result.bg then out[#out + 1] = ('\27[48;2;%d;%d;%dm'):format(math.floor(result.bg / 65536), math.floor(result.bg / 256) % 256, result.bg % 256) end
    if result.bold then out[#out + 1] = '\27[1m' end
    return table.concat(out)
end

local function overlaps(a, b)
    return a.row < b.row + b.height and a.row + a.height > b.row
        and a.col < b.col + b.width and a.col + a.width > b.col
end

local function float_rect(win)
    local pos = vim.api.nvim_win_get_position(win)
    return { win = win, row = pos[1], col = pos[2],
        height = vim.api.nvim_win_get_height(win) + 2, width = vim.api.nvim_win_get_width(win) + 2 }
end

local function blockers()
    local result = {}
    if vim.fn.pumvisible() == 1 then
        local p = vim.fn.pum_getpos()
        if p.row then result[#result + 1] = { row = p.row, col = p.col, height = p.height + 2, width = p.width + 2 } end
    end
    for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local cfg = vim.api.nvim_win_get_config(other)
        if cfg.relative ~= '' and not cfg.hide then result[#result + 1] = float_rect(other) end
    end
    return result
end

local function covered(rect, covers)
    local screen = { row = rect.screen_row, col = rect.screen_col, height = rect.height, width = rect.width }
    for _, cover in ipairs(covers) do
        if cover.win ~= rect.win and overlaps(screen, cover) then return true end
    end
    return false
end

local function erase_matches(matches)
    for _, rect in ipairs(M.drawn) do
        if matches(rect) then M.erase(matches); return end
    end
end

local function erase_covered(covers)
    erase_matches(function(rect) return covered(rect, covers) end)
end

local function window_geometry(win, info, top)
    return { top or info.topline - 1, vim.api.nvim_win_get_position(win),
        vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win), info.textoff }
end

-- Decoration callbacks can revisit a whole window for an option change even
-- when the TUI's grid diff does not touch this placement. Only actual cells
-- and attributes under the overlay indicate damage (e.g. delayed cursorline
-- on an unrelated body row must not replay every heading).
local function native_cells(rect)
    local cells = {}
    for row = rect.screen_row, rect.screen_row + rect.height - 1 do
        for col = rect.screen_col, rect.screen_col + rect.width - 1 do
            cells[#cells + 1] = vim.fn.screenstring(row, col)
            cells[#cells + 1] = vim.fn.screenattr(row, col)
        end
    end
    return cells
end

function M.paint(force)
    if M.painting or not M.tmux or not M.tmux.allowed or M.capability ~= true then return end
    M.painting = true
    local out, regions, wanted, previous, covers = {}, {}, {}, {}, blockers()
    for _, rect in ipairs(M.drawn) do previous[rect.key] = rect end
    for buf, state in pairs(M.active) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_changedtick(buf) == state.tick
            and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_buf(state.win) == buf
            and vim.api.nvim_win_get_tabpage(state.win) == vim.api.nvim_get_current_tabpage() then
            local win = state.win
            local info = vim.fn.getwininfo(win)[1]
            -- Native sign/status columns can settle after on_win. Track the
            -- geometry actually used for the overlay, not an earlier grid pass.
            state.geometry = window_geometry(win, info)
            local top, bottom = info.winrow, info.winrow + info.height - 1
            local left, right = info.wincol + info.textoff, info.wincol + info.width - 1
            for _, entry in ipairs(state.entries) do
                local pos = vim.fn.screenpos(win, entry.row + 1, entry.col + 1)
                for i, line in ipairs(entry.lines) do
                    local row, col = pos.row + (i - 1) * entry.spec.scale, pos.col
                    local width = math.max(line.width, entry.erase_width or 0)
                    local rect = { key = buf .. ':' .. entry.id .. ':' .. i, buf = buf, win = win,
                        screen_row = row, screen_col = col, height = entry.spec.scale, width = width,
                        row = row + M.tmux.top, col = col + M.tmux.left }
                    if pos.row > 0 and row >= top and row + entry.spec.scale - 1 <= bottom
                        and col >= left and col + width - 1 <= right
                        and not covered(rect, covers) then
                        local at_row, at_col, payload = rect.row, rect.col, {}
                        for _, run in ipairs(line.runs) do
                            local spec = entry.spec
                            payload[#payload + 1] = ('\27[%d;%dH'):format(at_row, at_col)
                            payload[#payload + 1] = colors(run.highlight, entry.highlight)
                            local meta = ('s=%d:w=%d'):format(spec.scale, run.cells)
                            if spec.num < spec.den then meta = meta .. (':n=%d:d=%d:v=2'):format(spec.num, spec.den) end
                            payload[#payload + 1] = '\27]66;' .. meta .. ';' .. run.text .. '\27\\'
                            at_col = at_col + run.width
                        end
                        -- Clear only the native reservation's trailing cells.
                        -- Reissuing identical multicells replaces their glyphs
                        -- atomically; no blank frame or full-line erase is needed.
                        if width > line.width then
                            payload[#payload + 1] = ('\27[%d;%dH\27[%dX'):format(at_row, at_col, width - line.width)
                        end
                        rect.payload = table.concat(payload)
                        wanted[rect.key], regions[#regions + 1] = rect, rect
                    end
                end
            end
        end
    end
    for _, rect in ipairs(M.drawn) do
        local next_rect = wanted[rect.key]
        if not next_rect or next_rect.payload ~= rect.payload or next_rect.width ~= rect.width then
            -- Covered rectangles were already erased before the covering UI
            -- drew. Never clear over a popup after its native redraw.
            if not covered(rect, covers) then
                out[#out + 1] = ('\27[%d;%dH\27[%dX'):format(rect.row, rect.col, rect.width)
            end
        end
    end
    for _, rect in ipairs(regions) do
        local old = previous[rect.key]
        local changed = not old or old.payload ~= rect.payload or old.width ~= rect.width
        local revisit = changed or (M.damaged and M.damaged[rect.key])
        rect.native = revisit and native_cells(rect) or old.native
        local recover = force == 'recovery' and M.active[rect.buf].recovery
        if force == true or recover or changed or (revisit and not vim.deep_equal(old.native, rect.native)) then
            out[#out + 1] = rect.payload
        end
    end
    M.drawn = regions
    M.damaged = {}
    if #out > 0 then send('\27' .. '7' .. table.concat(out) .. '\27[0m\27' .. '8') end
    M.painting = false
end

function M.schedule(force)
    if force == true or not M.force then M.force = force end
    if M.pending or not next(M.active) then return end
    M.pending = true
    vim.schedule(function()
        local repaint = M.force
        M.pending, M.force = false, nil
        M.paint(repaint)
    end)
end

-- Avoid continually rewriting unchanged fractional multicells while idle.
-- Native damage is event-driven; periodic foreign-redraw recovery
-- is opt-in and must never repaint windows that did not request it.
local function sync_recovery()
    if not M.timer then return end
    for buf, state in pairs(M.active) do
        if state.recovery and vim.api.nvim_win_is_valid(state.win)
            and vim.api.nvim_win_get_buf(state.win) == buf
            and vim.api.nvim_win_get_tabpage(state.win) == vim.api.nvim_get_current_tabpage() then
            if not M.timer:is_active() then
                M.timer:start(250, 250, vim.schedule_wrap(function() M.schedule('recovery') end))
            end
            return
        end
    end
    M.timer:stop()
end

-- auto-cursorline can avoid writing a transient background over a multicell
-- in the first place. Own only flags we change, and leave other suppressors
-- intact. Normal body rows retain the user's delayed cursorline behavior.
function M.sync_cursorline()
    local blocked, rendered, changed = {}, {}, false
    local current = vim.api.nvim_get_current_win()
    for buf, state in pairs(M.active) do
        local win = state.win
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            rendered[win] = #state.entries > 0
            local row = vim.api.nvim_win_get_cursor(win)[1] - 1
            for _, entry in ipairs(state.entries) do
                if row >= entry.range[1] and row <= entry.range[2] then blocked[win] = true; break end
            end
        end
    end
    for win, saved in pairs(cursorline_windows) do
        if not vim.api.nvim_win_is_valid(win) then cursorline_windows[win] = nil
        elseif not blocked[win] then
            if vim.w[win].auto_cursorline_disabled == true then
                vim.w[win].auto_cursorline_disabled = saved.value
                changed = changed or win == current
            end
            cursorline_windows[win] = nil
        end
    end
    for win in pairs(blocked) do
        if not cursorline_windows[win] and vim.w[win].auto_cursorline_disabled ~= true then
            cursorline_windows[win] = { value = vim.w[win].auto_cursorline_disabled }
            vim.w[win].auto_cursorline_disabled = true
            changed = changed or win == current
        end
    end
    for win, saved in pairs(cursorline_extmark_windows) do
        if not vim.api.nvim_win_is_valid(win) then cursorline_extmark_windows[win] = nil
        elseif not rendered[win] then
            if vim.w[win].auto_cursorline_extmark == true then
                vim.w[win].auto_cursorline_extmark = saved.value
                changed = changed or win == current
            end
            cursorline_extmark_windows[win] = nil
        end
    end
    for win, enabled in pairs(rendered) do
        if enabled and not cursorline_extmark_windows[win] and vim.w[win].auto_cursorline_extmark ~= true then
            cursorline_extmark_windows[win] = { value = vim.w[win].auto_cursorline_extmark }
            vim.w[win].auto_cursorline_extmark = true
            changed = changed or win == current
        end
    end
    local auto = package.loaded.auto_cursorline
    if changed and type(auto) == 'table' and type(auto.cursor_moved) == 'function' then auto.cursor_moved() end
end

local function start()
    if M.timer then return end
    vim.api.nvim_set_decoration_provider(ns, {
        on_start = function()
            -- Retired placements must leave before the new window's native
            -- text is drawn; erasing them in a scheduled paint is too late.
            erase_matches(function(rect)
                return not vim.api.nvim_win_is_valid(rect.win)
                    or vim.api.nvim_win_get_buf(rect.win) ~= rect.buf
                    or vim.api.nvim_win_get_tabpage(rect.win) ~= vim.api.nvim_get_current_tabpage()
            end)
            erase_covered(blockers())
        end,
        on_win = function(_, win, buf, top)
            local state = M.active[buf]
            if not state or state.win ~= win then
                if #M.drawn > 0 and vim.api.nvim_win_get_config(win).relative ~= '' then erase_covered({ float_rect(win) }) end
                return false
            end
            local info = vim.fn.getwininfo(win)[1]
            local geometry = window_geometry(win, info, top)
            if not vim.deep_equal(state.geometry, geometry) or vim.api.nvim_buf_get_changedtick(buf) ~= state.tick then
                local old = state.geometry
                local same_origin = old and old[1] == geometry[1] and vim.deep_equal(old[2], geometry[2])
                    and old[3] == geometry[3] and old[5] == geometry[5]
                    and vim.api.nvim_buf_get_changedtick(buf) == state.tick
                erase_matches(function(rect)
                    return rect.win == win and (not same_origin or rect.screen_row < info.winrow
                        or rect.screen_row + rect.height > info.winrow + info.height)
                end)
                state.geometry = geometry
            end
            return true
        end,
        on_line = function(_, win, buf, row)
            local state = M.active[buf]
            if state and state.win == win then
                for _, entry in ipairs(state.entries) do
                    if row == entry.row then
                        M.damaged = M.damaged or {}
                        for i = 1, #entry.lines do M.damaged[buf .. ':' .. entry.id .. ':' .. i] = true end
                    end
                end
            end
        end,
        on_end = function() M.schedule() end,
    })
    M.timer = vim.uv.new_timer()
end

function M.clear(buf, keep_waiter)
    if buf and M.waiters and not keep_waiter then M.waiters[buf] = nil elseif not buf then M.waiters = {} end
    local painted = false
    for _, rect in ipairs(M.drawn) do if not buf or rect.buf == buf then painted = true; break end end
    if buf and not M.active[buf] and not painted then return end
    M.erase(function(rect) return not buf or rect.buf == buf end)
    if buf then M.active[buf] = nil else M.active = {} end
    M.sync_cursorline()
    -- A pending terminal reply must still drain with its input guard held.
    -- The probe's bounded timer releases it even when no buffers remain.
    if not next(M.active) then
        if M.timer then M.timer:stop(); M.timer:close(); M.timer = nil end
        vim.api.nvim_set_decoration_provider(ns, {})
    else sync_recovery(); M.schedule() end
    if painted then vim.schedule(function() if vim.v.dying == 0 then vim.cmd('redraw!') end end) end
end

function M.update(context, extmarks)
    local shown, entries = {}, {}
    for _, extmark in ipairs(extmarks) do
        local mark = extmark:get()
        if extmark:shown() and mark.font_id then shown[mark.font_id] = true end
    end
    for _, entry in ipairs(context.typography) do if shown[entry.id] then entries[#entries + 1] = entry end end
    if #entries == 0 then
        if M.active[context.buf] then M.clear(context.buf, context.config.typography.enabled ~= false) end
        return
    end
    local previous = M.active[context.buf]
    local tick = vim.api.nvim_buf_get_changedtick(context.buf)
    if previous and (previous.win ~= context.win or previous.tick ~= tick or not vim.deep_equal(previous.entries, entries)) then
        M.erase(function(rect) return rect.buf == context.buf end)
    end
    M.active[context.buf] = { win = context.win, tick = tick, entries = entries,
        recovery = context.config.typography.recovery,
        geometry = previous and previous.win == context.win and previous.geometry or nil }
    M.sync_cursorline()
    start()
    sync_recovery()
    M.schedule()
end

local group = vim.api.nvim_create_augroup('InkstoneTypography', { clear = true })
vim.api.nvim_create_autocmd('BufWinLeave', { group = group, callback = function(args)
    local win = vim.api.nvim_get_current_win()
    erase_matches(function(rect) return rect.buf == args.buf and rect.win == win end)
end })
vim.api.nvim_create_autocmd('TabLeave', { group = group, callback = function() M.erase() end })
vim.api.nvim_create_autocmd('WinClosed', { group = group, callback = function(args)
    local win = tonumber(args.match)
    erase_matches(function(rect) return rect.win == win end)
end })
vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'WinEnter', 'WinClosed' }, { group = group, callback = function()
    M.sync_cursorline()
    sync_recovery()
end })
vim.api.nvim_create_autocmd({ 'VimResized', 'FocusGained' }, { group = group, callback = function()
    if not next(M.active) and not M.probing and not next(M.waiters or {}) then return end
    M.erase(); M.tmux = nil
    M.refresh_tmux(function() M.schedule() end)
end })
vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function() M.clear() end })

return M
