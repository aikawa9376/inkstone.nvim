-- Kitty OSC 66 text is outside Neovim's grid. Reserve its cells, erase it
-- before native redraws and replay it after the grid flush. Never change tmux.
local M = { active = {}, drawn = {}, tmux = nil, pending = false }
local ns = vim.api.nvim_create_namespace('inkstone.typography')
local probe_timeout = 1200
local cursorline_windows = {}
local cursorline_extmark_windows = {}
local sync_recovery
local function kitty()
    return vim.env.KITTY_WINDOW_ID ~= nil or vim.env.TERM_PROGRAM == 'kitty'
end

function M.wrap(data)
    if vim.env.TMUX then return '\27Ptmux;' .. data:gsub('\27', '\27\27') .. '\27\\' end
    return data
end

-- An unfocused pane may become hidden without another FocusLost (for example
-- after focusing its sibling, then changing tmux windows). Validate before
-- background output instead of trusting a cached visibility bit.
local function background_visible()
    local args = { 'tmux', 'display-message', '-p' }
    if vim.env.TMUX_PANE then vim.list_extend(args, { '-t', vim.env.TMUX_PANE }) end
    args[#args + 1] = '#{window_active},#{window_zoomed_flag},#{pane_active}'
    local result = vim.system(args, { text = true, timeout = 100 }):wait()
    local window, zoom, pane = (result.stdout or ''):match('^(%d),(%d),(%d)')
    local visible = result.code == 0 and window == '1' and (zoom ~= '1' or pane == '1')
    if M.tmux then M.tmux.visible = visible end
    M.suspended = not visible
    if not visible then
        M.drawn = {}
        if M.timer then M.timer:stop() end
    elseif sync_recovery then sync_recovery() end
    return visible
end

local function needs_visibility_check()
    return vim.env.TMUX and (M.focused == false or (M.tmux and M.tmux.focus_events == false))
end

local function send(data)
    if needs_visibility_check() and not M.painting and not background_visible() then return end
    if M.suspended or (M.tmux and M.tmux.visible == false) then return end
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
    M.tmux_callbacks = M.tmux_callbacks or {}
    if callback then M.tmux_callbacks[#M.tmux_callbacks + 1] = callback end
    if M.querying then M.query_again = true; return end
    M.querying = true
    local args = { 'tmux', 'display-message', '-p' }
    if vim.env.TMUX_PANE then vim.list_extend(args, { '-t', vim.env.TMUX_PANE }) end
    args[#args + 1] = '#{pane_top},#{pane_left},#{allow-passthrough},#{status},#{status-position},#{client_termtype},#{window_active},#{window_zoomed_flag},#{pane_active},#{focus-events}'
    vim.system(args, { text = true, timeout = 1000 }, function(result)
        vim.schedule(function()
            M.querying = false
            -- A focus change during an in-flight query needs fresh visibility;
            -- do not release its callbacks using the pre-switch snapshot.
            if M.query_again then M.query_again = nil; M.refresh_tmux(); return end
            local fields = vim.split((result.stdout or ''):gsub('[\r\n]+$', ''), ',', { plain = true })
            local top, left, allowed, status, position, terminal = unpack(fields, 1, 6)
            M.tmux = { top = tonumber(top) or 0, left = tonumber(left) or 0,
                allowed = result.code == 0 and (allowed == 'on' or allowed == 'all'), terminal = terminal,
                visible = result.code == 0 and fields[7] ~= '0' and (fields[8] ~= '1' or fields[9] == '1'),
                focus_events = fields[10] ~= '0' }
            if M.focused == nil then M.focused = M.tmux.visible and fields[9] ~= '0' and M.tmux.focus_events end
            if position == 'top' and status ~= 'off' then M.tmux.top = M.tmux.top + (tonumber(status) or 1) end
            local previous = M.capability
            M.capability = M.version_supported(terminal)
            if previous ~= M.capability then
                M.waiters = M.waiters or {}
                for buf, active in pairs(M.active) do M.waiters[buf] = active.win end
            end
            refresh_waiters()
            local callbacks = M.tmux_callbacks
            M.tmux_callbacks = {}
            for _, cb in ipairs(callbacks) do cb() end
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

-- Whitespace can consume the preceding word's unused cells rather than
-- adding another rounded fractional packet on top of that padding.
local function space_runs(runs, spec)
    if spec.num == spec.den then return runs end
    local result, slack = {}, 0
    for _, run in ipairs(runs) do
        if run.text:match('^ +$') then
            for _ = 1, #run.text do
                local previous = result[#result]
                local cells = math.max(0, math.floor(spec.ratio - slack + .5))
                if cells == 0 and previous and slack + 1e-8 >= spec.ratio
                    and vim.deep_equal(previous.highlight, run.highlight) then
                    -- Retain the literal space for terminal selection, too.
                    previous.text = previous.text .. ' '
                else
                    cells = math.max(1, cells)
                    result[#result + 1] = { text = ' ', width = cells, cells = cells,
                        highlight = run.highlight, space = true }
                end
                slack = slack + cells - spec.ratio
            end
        else
            result[#result + 1] = run
            slack = run.width - vim.fn.strdisplaywidth(run.text) * spec.ratio
        end
    end
    return result
end

function M.runs(chunks, spec)
    local units = {}
    for _, unit in ipairs(require('inkstone.parser.table').units(chunks)) do
        local clean = unit.text:gsub('[%c]', '')
        if clean ~= '' and unit.width > 0 then
            units[#units + 1] = { text = clean, width = unit.width, highlight = unit.highlight }
        end
    end
    local result, first = {}, 1
    local limit = math.max(1, math.floor(7 * spec.den / spec.num))
    while first <= #units do
        local highlight, width, stop = units[first].highlight, 0, first - 1
        local boundary, aligned_boundary, aligned
        local widths = {}
        for i = first, #units do
            local unit = units[i]
            if not vim.deep_equal(highlight, unit.highlight) or width + unit.width > limit
                or (spec.num < spec.den and (unit.text == ' ') ~= (units[first].text == ' ')) then break end
            width, stop = width + unit.width, i
            widths[i] = width
            if width % spec.den == 0 then aligned = i end
            local next_unit = units[i + 1]
            if unit.text:find('%s$') or (next_unit and next_unit.text:find('^%s')) then
                boundary = i
                if width % spec.den == 0 then aligned_boundary = i end
            end
        end
        -- Keep fitting words intact, including nine-letter 1.5x words such
        -- as "paragraph" and "Reproduce". For overlong words, retain exact
        -- fractional advances whenever a grapheme boundary allows one.
        if stop < #units and vim.deep_equal(highlight, units[stop + 1].highlight)
            and (spec.num == spec.den or (units[stop].text == ' ') == (units[stop + 1].text == ' ')) then
            stop = aligned_boundary or boundary or aligned or stop
        end
        local text = {}
        for i = first, stop do text[#text + 1] = units[i].text end
        local cells = math.max(1, math.ceil(widths[stop] * spec.num / spec.den - 1e-8))
        result[#result + 1] = { text = table.concat(text), width = cells * spec.scale, cells = cells, highlight = highlight }
        first = stop + 1
    end
    return space_runs(result, spec)
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
    -- Setext headings wrap their inline content in a paragraph node.
    local content = data.atx and node or node:child('paragraph')
    local inline = content and content:child('inline')
    if not inline then return false end
    local lines, budget = {}, context:window_width()
    -- Setext titles may contain multiple source lines. Resolve styles and
    -- inline replacements on each row, keeping their existing line breaks.
    for i, text in ipairs(vim.split(inline.text, '\n', { plain = true })) do
        local row, col = inline.start_row + i - 1, i == 1 and inline.start_col or 0
        local line = require('inkstone.lib.display').line(context, {
            start_row = row, end_row = row, start_col = col, end_col = col + #text, text = text,
        })
        local current, width = {}, 0
        for _, run in ipairs(M.runs(line, spec)) do
            if run.width > budget then return false end
            if width + run.width > budget then lines[#lines + 1] = { runs = current, width = width }; current, width = {}, 0 end
            current[#current + 1], width = run, width + run.width
        end
        if #current > 0 then lines[#lines + 1] = { runs = current, width = width } end
    end
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
        -- Continuation rows now live in virtual lines, alongside scaled-row
        -- padding. Hide them and the underline without hiding the next block.
        -- conceal_lines includes end_row even when end_col is zero.
        local marker = data.marker
        local last = marker.end_row - (marker.end_col == 0 and 1 or 0)
        local line = vim.api.nvim_buf_get_lines(context.buf, last, last + 1, false)[1] or ''
        marks:add(context.config.heading, true, node.start_row + 1, 0, {
            end_row = last, end_col = marker.end_col > 0 and marker.end_col or #line, conceal_lines = '',
        })
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

local function overlaps(a, b)
    return a.row < b.row + b.height and a.row + a.height > b.row
        and a.col < b.col + b.width and a.col + a.width > b.col
end

local function float_rect(win)
    local pos = vim.api.nvim_win_get_position(win)
    local cfg = vim.api.nvim_win_get_config(win)
    local border = cfg.border
    local function edge(index)
        if type(border) ~= 'table' or #border == 0 then return 0 end
        local char = border[(index - 1) % #border + 1]
        if type(char) == 'table' then char = char[1] end
        return char ~= '' and 1 or 0
    end
    -- Window positions include the border and are zero-based; screenpos and
    -- our overlay rectangles are one-based. Count only the actual border sides.
    return { win = win, row = pos[1] + 1, col = pos[2] + 1,
        height = vim.api.nvim_win_get_height(win) + edge(2) + edge(6),
        width = vim.api.nvim_win_get_width(win) + edge(4) + edge(8) }
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

function M.paint(force)
    if needs_visibility_check() and not M.painting and not background_visible() then return end
    if M.painting or M.suspended or not M.tmux or not M.tmux.allowed
        or M.tmux.visible == false or M.capability ~= true then return end
    M.painting = true
    local out, regions, wanted, previous, covers = {}, {}, {}, {}, blockers()
    for _, rect in ipairs(M.drawn) do previous[rect.key] = rect end
    for buf, state in pairs(M.active) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_changedtick(buf) == state.tick
            and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_buf(state.win) == buf
            and vim.api.nvim_win_get_tabpage(state.win) == vim.api.nvim_get_current_tabpage() then
            local win = state.win
            local colors = require('inkstone.lib.terminal_colors').new(win)
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
                            local spec = run.space and { scale = 1, num = 1, den = 1 } or entry.spec
                            payload[#payload + 1] = ('\27[%d;%dH'):format(at_row, at_col)
                            payload[#payload + 1] = colors(run.highlight, entry.highlight, entry.background)
                            -- Fixed-width groups can leave font-metric padding between ASCII
                            -- chunks even when their grid advances are exact. Kitty's normal
                            -- per-character sizing avoids that for integer-scale ASCII.
                            local automatic = not run.space and spec.num == spec.den and not run.text:find('[\128-\255]')
                            local meta = ('s=%d:w=%d'):format(spec.scale, automatic and 0 or run.cells)
                            if spec.num < spec.den then meta = meta .. (':n=%d:d=%d:v=2'):format(spec.num, spec.den) end
                            payload[#payload + 1] = '\27]66;' .. meta .. ';' .. run.text .. '\27\\'
                            at_col = at_col + run.width
                        end
                        -- Clear only the native reservation's trailing cells.
                        -- Reissue multicells directly, without an extra erase
                        -- of an intact glyph before its replacement.
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
        local recover = force == 'recovery' and M.active[rect.buf].recovery
        if force == true or recover or changed then
            out[#out + 1] = rect.payload
        end
    end
    M.drawn = regions
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
sync_recovery = function()
    if not M.timer then return end
    if M.suspended or (M.tmux and M.tmux.visible == false) then M.timer:stop(); return end
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

-- Own only flags we change; restore the previous value without taking over
-- flags already held by another suppressor.
local function sync_window_flag(name, owners, enabled)
    local changed, current = false, vim.api.nvim_get_current_win()
    for win, saved in pairs(owners) do
        if not vim.api.nvim_win_is_valid(win) then owners[win] = nil
        elseif not enabled[win] then
            if vim.w[win][name] == true then
                vim.w[win][name] = saved.value
                changed = changed or win == current
            end
            owners[win] = nil
        end
    end
    for win in pairs(enabled) do
        if not owners[win] and vim.w[win][name] ~= true then
            owners[win] = { value = vim.w[win][name] }
            vim.w[win][name] = true
            changed = changed or win == current
        end
    end
    return changed
end

-- Ordinary body rows retain the user's delayed cursorline behavior.
function M.sync_cursorline()
    local blocked, rendered = {}, {}
    for buf, state in pairs(M.active) do
        local win = state.win
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            if #state.entries > 0 then rendered[win] = true end
            local row = vim.api.nvim_win_get_cursor(win)[1] - 1
            for _, entry in ipairs(state.entries) do
                if row >= entry.range[1] and row <= entry.range[2] then blocked[win] = true; break end
            end
        end
    end
    local blocked_changed = sync_window_flag('auto_cursorline_disabled', cursorline_windows, blocked)
    local rendered_changed = sync_window_flag('auto_cursorline_extmark', cursorline_extmark_windows, rendered)
    local auto = package.loaded.auto_cursorline
    if (blocked_changed or rendered_changed) and type(auto) == 'table' and type(auto.cursor_moved) == 'function' then auto.cursor_moved() end
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
        -- TUI/compositor output can overwrite multicells even when no owned
        -- source row received on_line, or when its blank cells stayed equal.
        -- Repair after every completed redraw, coalesced into one callback.
        on_end = function() M.schedule(true) end,
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

function M.check_visibility()
    if not vim.env.TMUX then return end
    -- FocusLost arrives as tmux switches views. Block both paint and erase
    -- immediately: passthrough=all otherwise writes over the destination.
    M.suspended = true
    M.visibility_generation = (M.visibility_generation or 0) + 1
    local generation = M.visibility_generation
    M.refresh_tmux(function()
        if generation ~= M.visibility_generation then return end
        M.suspended = not M.tmux.visible
        if M.suspended then M.drawn = {} else M.schedule(true) end
        sync_recovery()
    end)
end

local group = vim.api.nvim_create_augroup('InkstoneTypography', { clear = true })
vim.api.nvim_create_autocmd({ 'FocusLost', 'FocusGained' }, { group = group, callback = function(args)
    M.focused = args.event == 'FocusGained'
    M.check_visibility()
end })
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
vim.api.nvim_create_autocmd({ 'VimResized', 'FocusGained' }, { group = group, callback = function(args)
    if args.event == 'FocusGained' and vim.env.TMUX then return end
    if not next(M.active) and not M.probing and not next(M.waiters or {}) then return end
    M.erase(); M.tmux = nil
    M.refresh_tmux(function() M.schedule() end)
end })
vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function() M.clear() end })

return M
