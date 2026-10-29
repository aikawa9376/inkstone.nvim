local compat = require('inkstone.lib.compat')
local state = require('inkstone.state')

---@class render.md.Ts
local M = {}

---@private
---@type boolean
M.initialized = false

---@private
---@type table<string, vim.treesitter.Query>
M.queries = {}

---Keep code examples literal, including HTML/LaTeX and descendants of a
---Markdown injection. The outer fence still belongs to the host tree.
---@param tree TSTree
---@param language_tree vim.treesitter.LanguageTree
---@return boolean
function M.render(tree, language_tree)
    if state.nested then
        return true
    end
    local row, col = tree:root():range()
    local parent = language_tree:parent()
    while parent do
        if parent:lang() == 'markdown' then
            for _, host in pairs(parent:trees()) do
                local node = host:root():named_descendant_for_range(row, col, row, col)
                while node do
                    local kind = node:type()
                    if kind == 'fenced_code_block' or kind == 'indented_code_block' then
                        return false
                    end
                    node = node:parent()
                end
            end
        end
        parent = parent:parent()
    end
    return true
end

---called from state on setup
function M.setup()
    for _, language in ipairs(state.file_types) do
        M.inject(language)
    end
end

---called from state on attach
function M.init()
    if M.initialized then
        return
    end
    M.initialized = true
    for _, language in ipairs(state.file_types) do
        M.disable(language)
    end
    if state.restart_highlighter then
        vim.treesitter.stop()
        vim.treesitter.start()
    end
end

---@param language string
---@param query string
---@return vim.treesitter.Query
function M.parse(language, query)
    local result = M.queries[query]
    if not result then
        result = vim.treesitter.query.parse(language, query)
        M.queries[query] = result
    end
    return result
end

---@private
---@param language string
function M.inject(language)
    local injection = state.injections[language]
    if not injection or not injection.enabled then
        return
    end
    local query = ''
    if compat.has_11 then
        query = query .. ';; extends' .. '\n'
    else
        local files = vim.treesitter.query.get_files(language, 'injections')
        for _, file in ipairs(files) do
            local f = assert(io.open(file, 'r'))
            local body = f:read('*a') --[[@as string]]
            f:close()
            query = query .. body .. '\n'
        end
    end
    query = query .. injection.query
    pcall(vim.treesitter.query.set, language, 'injections', query)
end

---@private
---@param language string
function M.disable(language)
    local pattern = state.patterns[language]
    if not pattern or not pattern.disable then
        return
    end
    if not compat.has_11 then
        return
    end
    local query = vim.treesitter.query.get(language, 'highlights')
    if not query then
        return
    end
    if not query.query.disable_pattern then
        compat.release('TSQuery missing disable_pattern API')
        return
    end
    local query_directives = query.info.patterns
    for _, directive in ipairs(pattern.directives) do
        local query_directive = query_directives[directive.id]
        if M.has_directive(directive.name, query_directive) then
            query.query:disable_pattern(directive.id)
        end
    end
end

---@private
---@param name string
---@param directives? (string|integer)[][]
---@return boolean
function M.has_directive(name, directives)
    if not directives then
        return false
    end
    for _, directive in ipairs(directives) do
        if directive[1] == 'set!' and directive[2] == name then
            return true
        end
    end
    return false
end

return M
