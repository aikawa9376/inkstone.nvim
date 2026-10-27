-- Optional oracle: INKSTONE_UPSTREAM_RTP=/path/to/render-markdown.nvim
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(assert(vim.env.INKSTONE_UPSTREAM_RTP, 'set INKSTONE_UPSTREAM_RTP'))
vim.opt.rtp:append(vim.env.INKSTONE_PARSER_RTP or (vim.fn.stdpath('data') .. '/site'))
require('inkstone').setup({ anti_conceal = { enabled = false }, code = { language = false, sign = false, left_pad = 1, right_pad = 1 } })
local Context = require('inkstone.request.context')
local Node = require('inkstone.lib.node')
local Marks = require('inkstone.lib.marks')
local Code = require('inkstone.render.markdown.code')
local Original = require('render-markdown.render.markdown.code')
local query = vim.treesitter.query.parse('markdown', '(fenced_code_block) @code')
local checked = 0
for _, rows in ipairs({ 30, 7000 }) do
    for _, indent in ipairs({ '', '  ' }) do
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        local lines = { indent .. '```lua' }
        for i = 1, rows do lines[#lines + 1] = i % 5 == 0 and '' or indent .. 'local text = "日本語"' end
        lines[#lines + 1] = indent .. '```'
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        local tree = vim.treesitter.get_parser(buf, 'markdown'):parse(true)[1]
        local fence
        for _, node in query:iter_captures(tree:root(), buf) do fence = Node.new(buf, node); break end
        assert(fence)
        local config = require('inkstone.state').get(buf)
        for _, options in ipairs({
            { width = 'block', left_pad = 1, left_margin = 0, disable_background = false },
            { width = 'full', left_pad = 2, left_margin = 2, disable_background = false },
            { width = 'block', left_pad = 0, left_margin = 0, disable_background = true },
        }) do
            for key, value in pairs(options) do config.code[key] = value end
            for _, ranges in ipairs({ { { 0, 10 }, { rows - 10, rows + 1 } }, { { math.floor(rows / 2), math.floor(rows / 2) + 10 } } }) do
                local context = Context.new(buf, vim.api.nvim_get_current_win(), config)
                context.view.ranges = ranges
                local function render(renderer)
                    local marks = Marks.new(context, false)
                    renderer:execute(context, marks, fence)
                    return vim.tbl_filter(function(mark)
                        for _, range in ipairs(ranges) do
                            if mark.start_row >= range[1] and mark.start_row <= range[2] then return true end
                        end
                        return false
                    end, marks:get())
                end
                assert(vim.deep_equal(render(Original), render(Code)), 'visible code marks differ from upstream')
                checked = checked + 1
            end
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end
print(('PASS: %d native-parser viewport cases match upstream mark fields'):format(checked))
