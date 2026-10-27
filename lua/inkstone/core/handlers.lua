local iter = require('inkstone.lib.iter')
local log = require('inkstone.core.log')
local state = require('inkstone.state')

---@class render.md.Handlers
local M = {}

---@private
---@type table<string, render.md.Handler>
M.builtin = {
    html = require('inkstone.handler.html'),
    latex = require('inkstone.handler.latex'),
    markdown = require('inkstone.handler.markdown'),
    markdown_inline = require('inkstone.handler.markdown_inline'),
    yaml = require('inkstone.handler.yaml'),
}

---@param context render.md.request.Context
---@param parser vim.treesitter.LanguageTree
---@return render.md.Mark[]
function M.run(context, parser)
    local language_roots = {} ---@type table<string, TSNode[]>
    parser:for_each_tree(function(tree, language_tree)
        local root = tree:root()
        local language = language_tree:lang()
        if
            (state.custom_handlers[language] or M.builtin[language])
            and (state.nested or M.level(language_tree) == 1)
            and context.view:overlaps(root)
        then
            local roots = language_roots[language]
            if not roots then
                roots = {}
                language_roots[language] = roots
            end
            roots[#roots + 1] = root
        end
    end)

    -- languages that run later will have more complete state
    local languages = vim.tbl_keys(language_roots) ---@type string[]
    local order = { latex = 10, markdown = 100 } ---@type table<string, integer>
    iter.list.sort(languages, function(language)
        return order[language] or 0
    end)

    local marks = {} ---@type render.md.Mark[]
    for _, language in ipairs(languages) do
        local roots = language_roots[language]
        for i, root in ipairs(roots) do
            M.tree(marks, language, {
                buf = context.buf,
                root = root,
                last = i == #roots,
            })
        end
    end
    return require('inkstone.render.compat').apply(context, marks)
end

---@private
---@param tree? vim.treesitter.LanguageTree
---@return integer
function M.level(tree)
    local result = 0
    while tree do
        if tree:lang() == 'markdown' then
            result = result + 1
        end
        tree = tree:parent()
    end
    return result
end

---Run custom & builtin handlers when available. Custom handler is always
---executed, builtin handler is skipped if custom does not specify extends.
---@private
---@param marks render.md.Mark[]
---@param language string
---@param ctx render.md.handler.Context
function M.tree(marks, language, ctx)
    log.buf('trace', 'Language', ctx.buf, language)
    local custom = state.custom_handlers[language]
    if custom then
        log.buf('trace', 'Handler', ctx.buf, 'custom')
        vim.list_extend(marks, custom.parse(ctx))
        if not custom.extends then
            return
        end
    end
    local builtin = M.builtin[language]
    if builtin then
        log.buf('trace', 'Handler', ctx.buf, 'builtin')
        vim.list_extend(marks, builtin.parse(ctx))
    end
end

return M
