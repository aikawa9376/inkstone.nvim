-- Code colors remain native when a highlighter is attached. The renderer can
-- also use the already parsed injection trees without starting a highlighter.
local M = { generation = 0, seen = {} }

local aliases = {
    sh = 'bash', shell = 'bash', shellscript = 'bash', zsh = 'bash',
    js = 'javascript', jsx = 'javascript', ts = 'typescript', py = 'python',
    rb = 'ruby', rs = 'rust', yml = 'yaml', md = 'markdown', ps1 = 'powershell',
}

function M.register()
    for alias, language in pairs(aliases) do
        -- Explicit user registrations and actual alias-named parsers win.
        if vim.treesitter.language.get_lang(alias) == alias
            and #vim.api.nvim_get_runtime_file('parser/' .. alias .. '.*', false) == 0 then
            vim.treesitter.language.register(language, alias)
            M.generation = M.generation + 1
        end
    end
end

function M.prepare(buf, parser)
    if M.seen[buf] == M.generation then return end
    M.seen[buf] = M.generation
    -- An existing highlighter may have parsed before the aliases were added.
    if M.generation > 0 then parser:invalidate(true) end
end

function M.render(context, node, marks, config)
    if context.syntax_active or not config.syntax then return end
    local content = node:child('code_fence_content')
    if not content then return end
    context.code_syntax_seen = context.code_syntax_seen or {}
    local block_key = table.concat({ node.start_row, node.start_col, node.end_row, node.end_col }, ':')
    if context.code_syntax_seen[block_key] then return end
    context.code_syntax_seen[block_key] = true
    local seen, emitted, lines = {}, {}, {}
    for _, entry in ipairs(context.code_trees or {}) do
        local tree, language = entry[1], entry[2]
        local depth, parent = 0, language:parent()
        while parent do depth, parent = depth + 1, parent:parent() end
        local root = tree:root()
        local sr, sc, er, ec = root:range()
        if sr >= content.start_row and er <= content.end_row
            and (sr > content.start_row or sc >= content.start_col)
            and (er < content.end_row or ec <= content.end_col) then
            local lang = language:lang()
            local ok, query = pcall(vim.treesitter.query.get, lang, 'highlights')
            if ok and query then
                for _, range in ipairs(context.view.ranges) do
                    local first, last = math.max(sr, range[1]), math.min(er + 1, range[2])
                    if first < last then
                        for id, capture, metadata in query:iter_captures(root, context.buf, first, last) do
                            local name = query.captures[id]
                            local priority = (tonumber((metadata[id] or {}).priority or metadata.priority) or 100) + depth
                            local key = lang .. ':' .. capture:id() .. ':' .. name .. ':' .. priority
                            if not seen[key] and name:sub(1, 1) ~= '_' and name ~= 'spell' and name ~= 'nospell' then
                                seen[key] = true
                                local span = vim.treesitter.get_range(capture, context.buf, metadata[id])
                                local cr, cc, ce, cx = span[1], span[2], span[4], span[5]
                                local finish = ce - (cx == 0 and ce > cr and 1 or 0)
                                for _, visible in ipairs(context.view.ranges) do
                                    for row = math.max(cr, visible[1]), math.min(finish, visible[2] - 1) do
                                        lines[row] = lines[row] or vim.api.nvim_buf_get_lines(context.buf, row, row + 1, false)[1] or ''
                                        local left, right = row == cr and cc or 0, row == ce and cx or #lines[row]
                                        local mark_key = table.concat({ lang, name, row, left, right, priority }, ':')
                                        if right > left and not emitted[mark_key] then
                                            emitted[mark_key] = true
                                            marks:add(config, false, row, left, { end_col = right,
                                                hl_group = '@' .. name .. '.' .. lang,
                                                priority = priority })
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

return M
