local Context = require('inkstone.request.context')
local Marks = require('inkstone.lib.marks')
local ts = require('inkstone.core.ts')

---@class render.md.handler.MarkdownInline: render.md.Handler
local M = {}

---@param ctx render.md.handler.Context
---@return render.md.Mark[]
function M.parse(ctx)
    -- stylua: ignore
    local query = ts.parse('markdown_inline', [[
        (code_span) @code

        ((inline) @highlight
            (#lua-match? @highlight "==[^=]+=="))

        [
            (email_autolink)
            (full_reference_link)
            (image)
            (inline_link)
            (uri_autolink)
        ] @link

        (shortcut_link) @shortcut
    ]])
    ---@type table<string, render.md.Render>
    local renders = {
        code = require('inkstone.render.inline.code'),
        highlight = require('inkstone.render.inline.highlight'),
        link = require('inkstone.render.inline.link'),
        shortcut = require('inkstone.render.inline.shortcut'),
    }
    local context = Context.get(ctx.buf)
    local marks = Marks.new(context, true)
    local seen = ctx.seen or {}
    context.view:nodes(ctx.root, query, function(capture, node)
        -- Different injected trees can capture the same source link. Claim it
        -- before rendering updates inline widths/highlights, not after adding
        -- duplicate extmarks. Distinct links on one row have distinct ranges.
        local key = table.concat({ capture, node.type, node.start_row, node.start_col, node.end_row, node.end_col }, ':')
        if seen[key] then return end
        seen[key] = true
        local render = renders[capture]
        assert(render, ('unhandled inline capture: %s'):format(capture))
        render:execute(context, marks, node)
    end)
    return marks:get()
end

return M
