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
    context._width = nil
    local language_roots = {} ---@type table<string, TSNode[]>
    context.view.trees = {}
    parser:for_each_tree(function(tree, language_tree)
        if require('inkstone.core.ts').render(tree, language_tree) then
            context.view.trees[#context.view.trees + 1] = { tree, language_tree }
        end
    end)
    local table_views = require('inkstone.core.table_views')
    table_views.prepare(context, parser)
    context.view:each_tree(parser, function(tree, language_tree)
        local root = tree:root()
        local language = language_tree:lang()
        if
            (state.custom_handlers[language] or M.builtin[language])
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

    -- Unicode conversion only needs source ranges, not a LaTeX syntax tree.
    -- Markdown already identifies formulas; retain conversion when the optional
    -- LaTeX parser/injection is missing. Never duplicate actual injected roots
    -- or pass Markdown nodes to a user-supplied LaTeX handler.
    if context.config.latex.enabled and not language_roots.latex and not state.custom_handlers.latex
        and #require('inkstone.lib.env').commands(context.config.latex.converter) > 0 then
        local query = require('inkstone.core.ts').parse('markdown_inline', '(latex_block) @latex')
        local formulas = {}
        for _, root in ipairs(language_roots.markdown_inline or {}) do
            for _, node in query:iter_captures(root, context.buf) do
                if context.view:overlaps(node) then formulas[#formulas + 1] = node end
            end
        end
        if #formulas > 0 then language_roots.latex = formulas end
    end

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
    local typography = require('inkstone.core.typography')
    typography.small(context, parser, marks)
    marks = typography.filter(context, marks)
    marks = table_views.filter(context, marks)
    marks = require('inkstone.core.folds').apply(context, parser, marks)
    require('inkstone.core.media').collect(context, parser, marks)
    marks = require('inkstone.render.compat').apply(context, marks)
    context.view.trees = nil
    return marks
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
