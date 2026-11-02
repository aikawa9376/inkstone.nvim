local M = { cache = {}, trees = {}, ns = vim.api.nvim_create_namespace('inkstone.folds') }

local function text(buf, node)
    return vim.treesitter.get_node_text(node, buf)
end

local function summary(buf, opening, finish)
    local inline = opening.line:match('>[ \t]*(<[sS][uU][mM][mM][aA][rR][yY].*)')
    local row = opening.row
    local line = inline
    if not line then
        row = row + 1
        while row < finish do
            line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
            if not line:match('^%s*$') then break end
            row = row + 1
        end
    end
    local body = (line or ''):match('^%s*<[sS][uU][mM][mM][aA][rR][yY][^>]*>(.*)$')
    if not body then return end
    local first, parts = row, {}
    while row < finish do
        local last = body:match('^(.-)</[sS][uU][mM][mM][aA][rR][yY]>%s*$')
        parts[#parts + 1] = last or body
        if last then
            local title = vim.trim(table.concat(parts, ' '):gsub('<[^>]+>', ''):gsub('%s+', ' '))
            return title ~= '' and title or 'Details', row > opening.row and row or nil, math.max(opening.row + 1, first)
        end
        row = row + 1
        body = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    end
end

-- Return half-open source ranges, never treating fence contents as HTML.
function M.blocks(buf, parser, config, view)
    local roots, identities = {}, {}
    local function collect(tree, language)
        if language:lang() == 'markdown' and require('inkstone.core.ts').render(tree, language) then
            local root = tree:root()
            roots[#roots + 1] = root
            identities[#identities + 1] = root:id()
        end
    end
    if view then view:each_tree(parser, collect) else parser:for_each_tree(collect) end
    table.sort(identities)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local signature = table.concat(identities, ':') .. tostring(config.code) .. tostring(config.callout) .. tostring(config.details)
    local cached = M.trees[buf]
    if cached and cached.tick == tick and cached.signature == signature then return cached.blocks end
    local blocks, seen = {}, {}
    local query = require('inkstone.core.ts').parse('markdown', [[
        (fenced_code_block) @code
        (block_quote) @callout
        (html_block) @html
    ]])
    local tags = {}
    for _, root in ipairs(roots) do
        for id, node in query:iter_captures(root, buf) do
            local kind = query.captures[id]
            local sr, sc, er, ec = node:range()
            local finish = er + (ec > 0 and 1 or 0)
            local key = kind .. ':' .. sr .. ':' .. sc .. ':' .. finish
            if not seen[key] and (kind == 'html' or finish > sr + 1) then
                seen[key] = true
                if kind == 'html' and config.details then
                    local lines = vim.split(text(buf, node), '\n', { plain = true })
                    local fence, fence_size
                    for i, line in ipairs(lines) do
                        local lower = line:lower()
                        local marker, rest = line:match('^%s*([`~]+)(.*)$')
                        if marker and #marker >= 3 and not marker:find(marker:sub(1, 1) == '`' and '~' or '`', 1, true) then
                            if not fence then fence, fence_size = marker:sub(1, 1), #marker
                            elseif marker:sub(1, 1) == fence and #marker >= fence_size and rest:match('^%s*$') then fence = nil end
                        elseif not fence and lower:match('^%s*</?details[%s>]') then
                            tags[#tags + 1] = { row = sr + i - 1, line = line, close = lower:match('^%s*</') ~= nil }
                        end
                    end
                elseif kind == 'code' and config.code then
                    blocks[#blocks + 1] = { kind = kind, start_row = sr, start_col = sc, end_row = finish, closed = false }
                elseif kind == 'callout' and config.callout then
                    local first = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or ''
                    local suffix = first:match('^%s*>%s*%[![%w_-]+%]([+-]?)')
                    if suffix then
                        blocks[#blocks + 1] = { kind = kind, start_row = sr, start_col = sc, end_row = finish, closed = suffix == '-' }
                    end
                end
            end
        end
    end
    table.sort(tags, function(a, b) return a.row < b.row end)
    local stack, tag_rows = {}, {}
    for _, tag in ipairs(tags) do
        if not tag_rows[tag.row] then
            tag_rows[tag.row] = true
            if not tag.close then
                stack[#stack + 1] = tag
            elseif #stack > 0 then
                local opening = table.remove(stack)
                local title, summary_row, summary_start = summary(buf, opening, tag.row)
                blocks[#blocks + 1] = {
                    kind = 'details', start_row = opening.row, end_row = tag.row + 1,
                    closed = not opening.line:lower():match('%sopen[%s=>]'),
                    title = title or 'Details', summary_row = summary_row, summary_start = summary_start,
                }
            end
        end
    end
    table.sort(blocks, function(a, b)
        if a.start_row ~= b.start_row then return a.start_row < b.start_row end
        return a.end_row > b.end_row
    end)
    M.trees[buf] = { tick = tick, signature = signature, blocks = blocks }
    return blocks
end

local function entry(buf, block)
    for _, value in ipairs(M.cache[buf] or {}) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, value.id, {})
        if pos[1] == block.start_row and value.kind == block.kind then return value end
    end
end

function M.closed(buf, block)
    local value = entry(buf, block)
    if value then return value.closed end
    return block.closed
end

-- Half-open ranges of rows currently hidden by displayed fold controls.
-- After edits, descriptions can still refer to old source coordinates.
function M.hidden(buf)
    local decorator = require('inkstone.core.ui').cache[buf]
    if not decorator or decorator:changed() then return {} end
    local ranges = {}
    for _, extmark in ipairs(decorator:get()) do
        local mark = extmark:get()
        if mark.fold_hidden and extmark:shown() then
            ranges[#ranges + 1] = { mark.start_row, (mark.opts.end_row or mark.start_row) + 1 }
        end
    end
    table.sort(ranges, function(a, b) return a[1] < b[1] end)
    local merged = {}
    for _, range in ipairs(ranges) do
        local last = merged[#merged]
        if last and range[1] <= last[2] then last[2] = math.max(last[2], range[2])
        else merged[#merged + 1] = range end
    end
    return merged
end

function M.apply(context, parser, marks)
    local config = context.config.folds
    if not config.enabled then return marks end
    local blocks = M.blocks(context.buf, parser, config, context.view)
    local hidden, extra = {}, {}
    local anchors, code_anchors, open_code = {}, {}, {}
    local str = require('inkstone.lib.str')
    local icon_hl = require('inkstone.core.colors').fold_icon()
    local function add(row, opts, col)
        extra[#extra + 1] = { conceal = true, modes = config.render_modes, start_row = row, start_col = col or 0,
            fold_hidden = opts.conceal_lines ~= nil, opts = opts }
    end
    local function hide_tag(row, overlay_only)
        local line = vim.api.nvim_buf_get_lines(context.buf, row, row + 1, false)[1] or ''
        local opts = { end_col = #line, virt_text_pos = 'overlay',
            virt_text = { { string.rep(' ', vim.fn.strdisplaywidth(line)), 'InkstoneDetailsBody' } } }
        if not overlay_only then opts.conceal_lines = '' end
        add(row, opts)
        extra[#extra].conceal = false
    end
    local function count(block)
        return ('%d lines'):format(block.end_row - block.start_row - 1)
    end
    local function fold_info(block, closed)
        local value = count(block)
        local opts = { virt_text_pos = 'overlay',
            virt_text = { { (config.position == 'right' and ' ' or ' · ') .. value, 'Comment' } },
            -- Renderer virtual text uses Neovim's default priority (4096).
            -- Controls must remain above language borders and quote markers.
            priority = 5001, hl_mode = 'combine' }
        -- Use the displayed callout title rather than the raw marker's EOL.
        local first = vim.api.nvim_buf_get_lines(context.buf, block.start_row, block.start_row + 1, false)[1] or ''
        local function width(col)
            return context:width({ start_row = block.start_row, start_col = 0, end_col = col, text = first:sub(1, col) })
        end
        local column
        for _, mark in ipairs(marks) do
            if mark.start_row == block.start_row and mark.conceal == 'callout' and mark.opts.virt_text_pos == 'overlay' then
                column = math.max(column or 0, width(mark.start_col) + str.line_width(mark.opts.virt_text))
            end
        end
        opts.virt_text_win_col = column or width(#first)
        add(block.start_row, opts)
        extra[#extra].conceal = false
        extra[#extra].folded = closed
    end
    local function title(value, reserved, col)
        local width = math.max(0, context:window_width() - reserved - (col or 0) - 1)
        if str.width(value) <= width then return value end
        return width > 0 and str.sub(value, 1, width - 1) .. '…' or ''
    end
    for _, block in ipairs(blocks) do
        local inside = false
        for _, range in ipairs(hidden) do
            if block.start_row >= range[1] and block.start_row < range[2] then inside = true; break end
        end
        if not inside then
            local closed = M.closed(context.buf, block)
            if closed then
                anchors[block.start_row] = true
                hidden[#hidden + 1] = { block.start_row + 1, block.end_row }
                add(block.start_row + 1, { end_row = block.end_row - 1, end_col = 0, conceal_lines = '' })
                extra[#extra].fold_closed = true
            end
            if block.kind == 'details' then
                local first = vim.api.nvim_buf_get_lines(context.buf, block.start_row, block.start_row + 1, false)[1] or ''
                local icon = closed and '▶ ' or '▼ '
                local label = {
                    { icon, icon_hl }, { count(block), 'Comment' },
                    { ' · ' .. block.title, 'InkstoneDetailsHeader' },
                }
                if config.position == 'right' then
                    label = { { icon, icon_hl },
                        { title(block.title, str.width(count(block)) + str.width(icon)), 'InkstoneDetailsHeader' },
                        { ' ' .. count(block), 'Comment' } }
                end
                local width = str.line_width(label)
                local padding = math.max(0, vim.fn.strdisplaywidth(first) - width)
                if padding > 0 then label[#label + 1] = { string.rep(' ', padding), 'InkstoneDetailsBody' } end
                -- Overlay the HTML wrapper so concealcursor cannot expose the
                -- raw tag beside a retained interactive header.
                add(block.start_row, { end_row = block.start_row + 1, end_col = 0, virt_text_pos = 'overlay',
                    hl_group = 'InkstoneDetailsBody', hl_eol = true, priority = 150,
                    hl_mode = 'combine', virt_text = label })
                extra[#extra].conceal = false
                if not closed then
                    if block.summary_row then
                        add(block.start_row + 1, { end_row = block.summary_row, end_col = 0, conceal_lines = '' })
                        extra[#extra].conceal = false
                        for row = block.summary_start or block.summary_row, block.summary_row do hide_tag(row, true) end
                    end
                    hide_tag(block.end_row - 1)
                    local first_body = (block.summary_row or block.start_row) + 1
                    for _, visible in ipairs(context.view.ranges) do
                        local sr, er = math.max(first_body, visible[1]), math.min(block.end_row - 1, visible[2])
                        if sr < er then
                            add(sr, { end_row = er, end_col = 0, hl_group = 'InkstoneDetailsBody',
                                hl_eol = true, priority = 80 })
                            extra[#extra].conceal = false
                            extra[#extra].details_body = true
                        end
                    end
                end
            elseif closed and block.kind == 'code' then
                local first = vim.api.nvim_buf_get_lines(context.buf, block.start_row, block.start_row + 1, false)[1] or ''
                local info = first:match('[`~]+(.*)$') or ''
                local language = info:match('^%s*(%S+)')
                local label = { { '▶ ', icon_hl }, { count(block), 'Comment' } }
                if language then label[#label + 1] = { ' · ' .. language, context.config.code.highlight_fallback } end
                code_anchors[block.start_row] = block.start_col or 0
                if config.position == 'right' then
                    local prefix = str.width(first:sub(1, block.start_col or 0))
                    label = { { '▶ ', icon_hl },
                        { title(language or 'Code', str.width(count(block)) + 2, prefix), context.config.code.highlight_fallback },
                        { ' ' .. count(block), 'Comment' } }
                end
                local padding = math.max(0, str.width(first:sub((block.start_col or 0) + 1)) - str.line_width(label))
                if padding > 0 then label[#label + 1] = { string.rep(' ', padding), context.config.code.highlight } end
                add(block.start_row, { end_col = #first, virt_text_pos = 'overlay', virt_text = label,
                    priority = 150 }, block.start_col)
                -- This is an explicit fold control; keep its state visible at
                -- the cursor while Normal-mode rendering remains active.
                extra[#extra].conceal = false
                extra[#extra].folded = true
            elseif block.kind == 'code' then
                if entry(context.buf, block) then open_code[block.start_row] = block.start_col or 0 end
            elseif block.kind == 'callout' then
                fold_info(block, closed)
                add(block.start_row, { virt_text_pos = 'overlay', priority = 5001,
                    virt_text = { { closed and '▶' or '▼', icon_hl } } }, block.start_col)
                extra[#extra].conceal = false
            end
        end
    end
    local result = {}
    for _, mark in ipairs(marks) do
        local inside = false
        for _, range in ipairs(hidden) do
            if mark.start_row >= range[1] and mark.start_row < range[2] then inside = true; break end
        end
        -- A code fence without a language label normally hides its opening
        -- delimiter. Keep that line visible when it becomes the fold anchor.
        local code_col = code_anchors[mark.start_row]
        if not inside and not (anchors[mark.start_row] and mark.opts.conceal_lines)
            and not (code_col and mark.start_col >= code_col) then
            local open_col = open_code[mark.start_row]
            if open_col and mark.start_col >= open_col then
                -- Reopening code keeps its original language header decorated.
                mark.conceal = false
            end
            result[#result + 1] = mark
        end
    end
    vim.list_extend(result, extra)
    return result
end

function M.toggle(buf, win)
    buf, win = buf or vim.api.nvim_get_current_buf(), win or vim.api.nvim_get_current_win()
    local config = require('inkstone.state').get(buf).folds
    if not config.enabled then return false end
    local parser = vim.treesitter.get_parser(buf, 'markdown')
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    parser:parse(nil, function(err)
        if err or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick
            or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
        local selected
        for _, block in ipairs(M.blocks(buf, parser, config)) do
            if row >= block.start_row and row < block.end_row then
                if not selected or block.end_row - block.start_row < selected.end_row - selected.start_row then selected = block end
                -- Hidden children cannot be the interaction target, even when
                -- a source motion has placed the cursor inside the outer fold.
                if M.closed(buf, block) then break end
            end
        end
        if not selected then return end
        local value = entry(buf, selected)
        if not value then
            value = { kind = selected.kind, closed = selected.closed,
                id = vim.api.nvim_buf_set_extmark(buf, M.ns, selected.start_row, 0, { right_gravity = false }) }
            M.cache[buf] = M.cache[buf] or {}
            M.cache[buf][#M.cache[buf] + 1] = value
        end
        value.closed = not value.closed
        vim.api.nvim_win_set_cursor(win, { selected.start_row + 1, 0 })
        require('inkstone.core.ui').update(buf, win, 'ToggleFold', true)
    end)
    return true
end

function M.attach(buf)
    for key, direction in pairs({ j = 1, k = -1, gj = 1, gk = -1, ['<Down>'] = 1, ['<Up>'] = -1 }) do
        local screen = key == 'gj' or key == 'gk'
        vim.keymap.set('n', key, function() M.move(direction, nil, screen) end, {
            buffer = buf, desc = 'Move past hidden Markdown fold rows',
        })
    end
end

-- Normal-mode source/screen motions skip only displayed fold conceal marks.
-- Raw/editing views remain native; operators and Visual mappings are untouched.
---@param direction integer
---@param count? integer
---@param screen? boolean
function M.move(direction, count, screen)
    local buf = vim.api.nvim_get_current_buf()
    local config = require('inkstone.state').get(buf)
    local decorator = require('inkstone.core.ui').cache[buf]
    local ranges = {}
    if config.enabled and config.folds.enabled and decorator and vim.wo.conceallevel >= 2 then
        for _, extmark in ipairs(decorator:get()) do
            local mark = extmark:get()
            if mark.fold_hidden and extmark:shown() then
                ranges[#ranges + 1] = { mark.start_row + 1, (mark.opts.end_row or mark.start_row) + 1 }
            end
        end
    end
    local motion = (screen and 'g' or '') .. (direction > 0 and 'j' or 'k')
    if #ranges == 0 then
        vim.cmd.normal({ args = { tostring(count or vim.v.count1) .. motion }, bang = true })
        return
    end
    local last = vim.api.nvim_buf_line_count(buf)
    for _ = 1, count or vim.v.count1 do
        vim.cmd.normal({ args = { motion }, bang = true })
        while true do
            local row = vim.api.nvim_win_get_cursor(0)[1]
            local target
            for _, range in ipairs(ranges) do
                if row >= range[1] and row <= range[2] then
                    target = direction > 0 and range[2] + 1 or range[1] - 1
                    -- At EOF there is no following visible row; use the anchor.
                    if target > last then target = range[1] - 1 end
                    break
                end
            end
            if not target then break end
            target = math.max(1, target)
            if target == row then break end
            -- Jump by source position, since a native fold inside this range
            -- makes an equivalent count of j/k overshoot. Retain curswant so
            -- short hidden lines do not steal the preferred screen column.
            local view = vim.fn.winsaveview()
            local col = math.max(0, vim.fn.virtcol2col(0, target, view.curswant + 1) - 1)
            vim.api.nvim_win_set_cursor(0, { target, col })
            vim.fn.winrestview({ curswant = view.curswant })
            if vim.api.nvim_win_get_cursor(0)[1] == row then break end
        end
    end
end

function M.clear(buf)
    M.cache[buf] = nil
    M.trees[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1) end
end

return M
