-- Resolve source links on demand, independently of rendering and concealment.
-- Actions must see current text even while a streaming render is pending.
local M = {}

local function contains(range, row, col)
    return (row > range[1] or row == range[1] and col >= range[2])
        and (row < range[3] or row == range[3] and col < range[4])
end
M.contains = contains

local function child(node, kind)
    for n in node:iter_children() do if n:type() == kind then return n end end
end

local function text(buf, node)
    return node and vim.treesitter.get_node_text(node, buf)
end

local function label(value)
    return value:gsub('^%[', ''):gsub('%]$', ''):gsub('%s+', ' '):lower()
end

local function trim_token(value)
    local previous
    repeat
        previous = value
        value = value:gsub('[.,;!]+$', '')
        for _, suffix in ipairs({ '。', '、', '，', '；', '！', '」', '』' }) do
            if vim.endswith(value, suffix) then value = value:sub(1, -#suffix - 1) end
        end
    until value == previous
    for _, pair in ipairs({ { '(', ')' }, { '[', ']' }, { '{', '}' } }) do
        local function count(char) local _, n = value:gsub('%' .. char, ''); return n end
        while value:sub(-1) == pair[2] and count(pair[2]) > count(pair[1]) do value = value:sub(1, -2) end
    end
    return value
end

function M.collect(buf, only_row)
    local result, occupied, seen, references = {}, {}, {}, {}
    local function add(target, range, pos)
        if not target or target == '' or target:find('[%z\r\n]') then return end
        local key = table.concat(range, ':')
        if seen[key] then return end
        seen[key] = true
        result[#result + 1] = { target = target, range = range, pos = pos or { range[1] + 1, range[2] } }
        occupied[#occupied + 1] = range
    end
    local ok, parser = pcall(vim.treesitter.get_parser, buf)
    if ok then
        parser:parse(only_row and { only_row, only_row + 1 } or true)
        -- References may occur after their uses or in another injected tree.
        parser:for_each_tree(function(tree, language)
            if language:lang() ~= 'markdown' then return end
            local query = require('inkstone.core.ts').parse('markdown', '(link_reference_definition) @ref')
            for _, node in query:iter_captures(tree:root(), buf) do
                local name = text(buf, child(node, 'link_label'))
                if name and not references[label(name)] then
                    references[label(name)] = text(buf, child(node, 'link_destination'))
                end
                occupied[#occupied + 1] = { node:range() }
            end
        end)
        parser:for_each_tree(function(tree, language)
            if language:lang() ~= 'markdown_inline' then return end
            local query = require('inkstone.core.ts').parse('markdown_inline', [[
                [(inline_link) (image) (uri_autolink) (email_autolink)
                 (full_reference_link) (collapsed_reference_link) (shortcut_link)] @link
            ]])
            for _, node in query:iter_captures(tree:root(), buf, only_row, only_row and only_row + 1) do
                local kind, range = node:type(), { node:range() }
                local title = child(node, 'link_text') or child(node, 'image_description')
                local row, col = range[1], range[2]
                if title then row, col = title:range() end
                local target = text(buf, child(node, 'link_destination'))
                if kind == 'uri_autolink' or kind == 'email_autolink' then
                    target = text(buf, node):sub(2, -2)
                    col = col + 1
                    if kind == 'email_autolink' then target = 'mailto:' .. target end
                elseif kind == 'shortcut_link' then
                    local recovered, finish = require('inkstone.parser.link').text_fragment(buf,
                        require('inkstone.lib.node').new(buf, node))
                    target = recovered
                    if finish then range[4] = finish end
                    -- The inline grammar represents [[target|alias]] as a
                    -- shortcut inside the outer brackets.
                    local line = vim.api.nvim_buf_get_lines(buf, range[1], range[1] + 1, false)[1] or ''
                    if not target and range[1] == range[3] and range[2] > 0
                        and line:sub(range[2], range[2]) == '[' and line:sub(range[4] + 1, range[4] + 1) == ']' then
                        local body = text(buf, title) or ''
                        target = body:match('^([^|]+)')
                        range[2], range[4] = range[2] - 1, range[4] + 1
                        local alias = body:find('|', 1, true)
                        if alias then col = col + alias end
                    end
                end
                if not target and title then
                    local name = text(buf, child(node, 'link_label')) or text(buf, title)
                    target = references[label(name)]
                end
                if target then add(target:gsub('^<(.*)>$', '%1'), range, { row + 1, col }) end
            end
        end)
    end
    -- Bare URLs and paths also work in transcripts and inline code, and when
    -- a parser is unavailable. Structured links take precedence over tokens.
    table.sort(occupied, function(a, b)
        return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
    end)
    local occupied_count, occupied_index = #occupied, 1
    local start_row = only_row or 0
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, start_row, only_row and only_row + 1 or -1, false)) do
        local index = 1
        while true do
            local first, last = line:find("[^%s<>`\"'|]+", index)
            if not first then break end
            index = last + 1
            local value = line:sub(first, last)
            local prefix = value:match('^[%[%({]+') or ''
            first, value = first + #prefix, trim_token(value:sub(#prefix + 1))
            local row, col = start_row + i - 1, first - 1
            while occupied_index <= occupied_count do
                local range = occupied[occupied_index]
                if range[3] > row or range[3] == row and range[4] > col then break end
                occupied_index = occupied_index + 1
            end
            local covered = occupied_index <= occupied_count and contains(occupied[occupied_index], row, col)
            local uri = value:match('^%a[%w+.-]*://') or value:match('^mailto:')
            local path = value:find('/', 1, true) or value:match('^.+%.[%a%d]+[:#]?')
            if not covered and (uri or path) and value ~= '/' and not value:match('^%W+$') then
                add(value, { row, col, row, col + #value })
            end
        end
    end
    table.sort(result, function(a, b)
        return a.pos[1] < b.pos[1] or a.pos[1] == b.pos[1] and a.pos[2] < b.pos[2]
    end)
    return result
end

function M.current(buf, cursor)
    for _, item in ipairs(M.collect(buf, cursor[1] - 1)) do
        if contains(item.range, cursor[1] - 1, cursor[2]) then return item end
    end
end

return M
