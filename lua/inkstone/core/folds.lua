local M = { cache = {}, trees = {}, ns = vim.api.nvim_create_namespace('inkstone.folds') }

local function text(buf, node)
    return vim.treesitter.get_node_text(node, buf)
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
                    for i, line in ipairs(lines) do
                        local lower = line:lower()
                        if lower:match('^%s*</?details[%s>]') then
                            tags[#tags + 1] = { row = sr + i - 1, line = line, close = lower:match('^%s*</') ~= nil }
                        end
                    end
                elseif kind == 'code' and config.code then
                    blocks[#blocks + 1] = { kind = kind, start_row = sr, end_row = finish, closed = false }
                elseif kind == 'callout' and config.callout then
                    local first = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or ''
                    local suffix = first:match('^%s*>%s*%[![%w_-]+%]([+-]?)')
                    if suffix then
                        blocks[#blocks + 1] = { kind = kind, start_row = sr, end_row = finish, closed = suffix == '-' }
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
                local inline_summary = opening.line:match('>[ \t]*(<[sS][uU][mM][mM][aA][rR][yY].*)')
                local summary_row = opening.row + 1
                local summary = inline_summary
                if not summary then
                    -- Markdown commonly separates the HTML tags with blank lines.
                    while summary_row < tag.row do
                        summary = vim.api.nvim_buf_get_lines(buf, summary_row, summary_row + 1, false)[1] or ''
                        if not summary:match('^%s*$') then break end
                        summary_row = summary_row + 1
                    end
                end
                summary = summary or ''
                local title = summary:match('^%s*<[sS][uU][mM][mM][aA][rR][yY][^>]*>(.-)</[sS][uU][mM][mM][aA][rR][yY]>%s*$')
                blocks[#blocks + 1] = {
                    kind = 'details', start_row = opening.row, end_row = tag.row + 1,
                    closed = not opening.line:lower():match('%sopen[%s=>]'),
                    title = title and title:gsub('<[^>]+>', '') or 'Details',
                    summary_row = title and not inline_summary and summary_row or nil,
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

function M.apply(context, parser, marks)
    local config = context.config.folds
    if not config.enabled then return marks end
    local blocks = M.blocks(context.buf, parser, config, context.view)
    local hidden, extra = {}, {}
    local anchors = {}
    local function add(row, opts)
        extra[#extra + 1] = { conceal = true, modes = config.render_modes, start_row = row, start_col = 0,
            fold_hidden = opts.conceal_lines ~= nil, opts = opts }
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
            end
            if block.kind == 'details' then
                local first = vim.api.nvim_buf_get_lines(context.buf, block.start_row, block.start_row + 1, false)[1] or ''
                add(block.start_row, { end_col = #first, conceal = '', virt_text_pos = 'inline',
                    virt_text = { { (closed and '▶ ' or '▼ ') .. block.title, 'InkstoneLink' } } })
                if not closed then
                    if block.summary_row then
                        add(block.start_row + 1, { end_row = block.summary_row, end_col = 0, conceal_lines = '' })
                    end
                    add(block.end_row - 1, { conceal_lines = '' })
                end
            elseif closed then
                add(block.start_row, { virt_text_pos = 'eol', virt_text = {
                    { (' ▶ %d lines'):format(block.end_row - block.start_row - 1), 'Comment' },
                } })
                extra[#extra].folded = true
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
        if not inside and not (anchors[mark.start_row] and mark.opts.conceal_lines) then
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
