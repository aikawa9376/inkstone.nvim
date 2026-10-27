local Context = require('inkstone.request.context')
local Marks = require('inkstone.lib.marks')
local ts = require('inkstone.core.ts')

---@class render.md.handler.Markdown: render.md.Handler
local M = {}

---@param ctx render.md.handler.Context
---@return render.md.Mark[]
function M.parse(ctx)
    -- stylua: ignore
    local query = ts.parse('markdown', [[
        (fenced_code_block) @code

        [
            (thematic_break)
            (minus_metadata)
            (plus_metadata)
        ] @dash

        (document) @document

        (link_reference_definition (link_label) @footnote)

        [
            (atx_heading)
            (setext_heading)
        ] @heading

        (list_item) @list

        (section (paragraph) @paragraph)

        (block_quote) @quote

        (section) @section

        (pipe_table) @table
    ]])
    ---@type table<string, render.md.Render>
    local renders = {
        code = require('inkstone.render.markdown.code'),
        dash = require('inkstone.render.markdown.dash'),
        document = require('inkstone.render.markdown.document'),
        footnote = require('inkstone.render.common.footnote'),
        heading = require('inkstone.render.markdown.heading'),
        list = require('inkstone.render.markdown.list'),
        paragraph = require('inkstone.render.markdown.paragraph'),
        quote = require('inkstone.render.markdown.quote'),
        section = require('inkstone.render.markdown.section'),
        table = require('inkstone.render.markdown.table'),
    }
    local context = Context.get(ctx.buf)
    local marks = Marks.new(context, false)
    context.view:nodes(ctx.root, query, function(capture, node)
        local render = renders[capture]
        assert(render, ('unhandled markdown capture: %s'):format(capture))
        render:execute(context, marks, node)
    end)
    return marks:get()
end

return M
