-- nvim --headless --clean -u NONE -l tests/run.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
vim.opt.rtp:prepend(root)
if vim.env.INKSTONE_PARSER_RTP then vim.opt.rtp:append(vim.env.INKSTONE_PARSER_RTP) end
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.o.columns, vim.o.lines, vim.o.redrawtime = 140, 45, 2000
vim.o.swapfile = false
local passed = 0
local function test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then io.stderr:write('FAIL: ' .. name .. '\n' .. err .. '\n'); vim.cmd('cquit 1') end
    passed = passed + 1
    print('PASS: ' .. name)
end
local function equal(actual, expected)
    if not vim.deep_equal(actual, expected) then error(vim.inspect({ actual = actual, expected = expected })) end
end
local function buffer(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
end
local inkstone = require('inkstone')
inkstone.setup({ anti_conceal = { enabled = false }, code = { sign = false, left_pad = 1, right_pad = 1, width = 'block' } })
local state = require('inkstone.state')
local Context = require('inkstone.request.context')
local Marks = require('inkstone.lib.marks')
local Node = require('inkstone.lib.node')
local Parser = require('inkstone.parser.table')
local text = require('inkstone.text')
local grapheme = require('inkstone.text.grapheme')

test('standalone namespace and valid Japanese configuration', function()
    equal(state.validate(), {})
    assert(package.loaded['render-markdown'] == nil)
    assert(inkstone.default.pipe_table.japanese.enabled)
    assert(inkstone.default.pipe_table.japanese.budoux)
end)
test('bundled BudouX Japanese model works offline', function()
    equal(text.segment('今日は天気がいいから散歩しましょう。'), { '今日は', '天気が', 'いいから', '散歩しましょう。' })
    assert(package.loaded.budoux == nil)
end)
test('display compatibility is gated, extensible and width-preserving', function()
    local display = require('inkstone.text.compat')
    local rules = display.compile({ kana = true, replacements = {} })
    local n = 0
    for source, replacement in pairs(rules.values) do
        n = n + 1
        equal(vim.fn.strdisplaywidth(source), vim.fn.strdisplaywidth(replacement))
    end
    equal(n, 112)
    equal(display.line({ { 'ｱﾞ / ｶﾟ', 'Normal' } }, rules), { { 'ア゙ / カ゚', 'Normal' } })
    equal(display.line({ { 'ｶ', 'String' }, { 'ﾞ / ﾊﾟ / ｳﾞ', 'Special' } }, rules),
        { { 'ガ', 'String' }, { ' / パ / ヴ', 'Special' } })
    local unchanged = { { 'が が ｶ ﾞ é 👩‍💻 ｶﾞﾞ', 'Normal' } }
    assert(display.line(unchanged, rules) == unchanged)
    local custom = display.compile({ kana = false, replacements = { ['é'] = 'é', ['日'] = 'x', [''] = 'x' } })
    equal(display.line({ { 'é日ｶﾞ', 'String' } }, custom), { { 'é日ｶﾞ', 'String' } })
    equal(display.enabled({ enabled = false }), false)
    equal(display.enabled({ enabled = true }), true)
    local kitty, program = vim.env.KITTY_WINDOW_ID, vim.env.TERM_PROGRAM
    vim.env.KITTY_WINDOW_ID, vim.env.TERM_PROGRAM = nil, 'unknown'
    equal(display.enabled({ enabled = 'auto' }), false)
    vim.env.KITTY_WINDOW_ID = '1'
    equal(display.enabled({ enabled = 'auto' }), true)
    vim.env.KITTY_WINDOW_ID, vim.env.TERM_PROGRAM = kitty, program
end)
test('compatibility overlays are viewport bounded and respect concealed regions', function()
    local buf = buffer({ 'ｶﾞ', 'ﾊﾟ', 'ｳﾞ', 'ｷﾞ' })
    local config = state.get(buf)
    config.display_compat.enabled = true
    local context = Context.new(buf, vim.api.nvim_get_current_win(), config)
    context.view.ranges = { { 0, 2 } }
    local marks = {
        { conceal = true, start_row = 1, start_col = 0, opts = { end_col = 6, conceal = '' } },
        { conceal = true, start_row = 2, start_col = 0, opts = { end_col = 6, conceal_lines = '' },
            replace = { { { 'ｳ', 'Normal' }, { 'ﾞ', 'String' } } } },
    }
    require('inkstone.render.compat').apply(context, marks)
    equal(#marks, 3)
    equal(marks[3].start_row, 0)
    equal(marks[3].opts.virt_text[1][1], 'ガ')
    equal(marks[2].replace, { { { 'ヴ', 'Normal' } } })
    equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'ｶﾞ', 'ﾊﾟ', 'ｳﾞ', 'ｷﾞ' })
    local extmark = require('inkstone.lib.extmark').new(marks[3])
    local ns = vim.api.nvim_create_namespace('inkstone-test-compat')
    extmark:show(ns, buf)
    equal(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 1)
    config.display_compat.enabled = false
    equal(#require('inkstone.render.compat').apply(context, {}), 0)
    vim.api.nvim_buf_delete(buf, { force = true })
end)
test('combining dakuten, halfwidth kana and emoji stay together', function()
    equal(grapheme.split('がｶﾞé👩‍💻🇯🇵👍🏽1️⃣'), { 'が', 'ｶﾞ', 'é', '👩‍💻', '🇯🇵', '👍🏽', '1️⃣' })
    local invalid = 'a' .. string.char(255) .. '日'
    equal(table.concat(grapheme.split(invalid)), invalid)
end)
test('Japanese wrapping obeys width and basic kinsoku', function()
    for _, sample in ipairs({ '日本語。日本語、文章です。', '「日本語」の表を、読みやすく。', 'これは（日本語）の説明です。' }) do
        local result = text.wrap(sample, 8, { budoux = false })
        equal(table.concat(result), sample)
        for _, line in ipairs(result) do
            assert(vim.fn.strdisplaywidth(line) <= 8)
            local chars = grapheme.split(line)
            assert(not vim.tbl_contains({ '。', '、', '）', '」' }, chars[1]), line)
            assert(not vim.tbl_contains({ '（', '「' }, chars[#chars]), line)
        end
    end
end)
test('BudouX prefers phrase boundaries and narrow columns terminate', function()
    equal(text.wrap('今日は天気がいいから散歩しましょう。', 12), { '今日は天気が', 'いいから', '散歩しましょ', 'う。' })
    equal(table.concat(text.wrap('「日」', 2)), '「日」')
    assert(not pcall(text.wrap, '日本語', 0))
end)
test('wrap preserves English words, cell colors and display clusters', function()
    equal(Parser.wrap(Parser.units({ { 'abc def ', 'Normal' }, { 'abcdefghij', 'String' } }), 7), {
        { { 'abc def', 'Normal' } }, { { 'abcdefg', 'String' } }, { { 'hij', 'String' } },
    })
    local sample = 'é行👩‍💻🇺🇸👍🏽'
    local units = Parser.units({ { sample, 'String' } })
    local _, minimum = Parser.measure(units)
    local joined = {}
    for _, line in ipairs(Parser.wrap(units, minimum)) do
        assert(require('inkstone.lib.str').line_width(line) <= minimum)
        for _, chunk in ipairs(line) do joined[#joined + 1] = chunk[1] end
    end
    equal(table.concat(joined), sample)
end)
test('highlight groups sort once on demand and include late insertions', function()
    local h = require('inkstone.request.highlights').new(0, {})
    h.computed = true
    local original, calls = table.sort, 0
    table.sort = function(...) calls = calls + 1; return original(...) end
    for i = 500, 1, -1 do h:add(0, { group = { 0, 1, priority = i, highlight = 'Normal' } }) end
    equal(calls, 0)
    local line = h:line(0)
    equal(calls, 1)
    equal(line.groups[1].priority, 1)
    h:line(0)
    equal(calls, 1)
    h:add(0, { group = { 0, 1, priority = 0, highlight = { 'Normal', 'String' } } })
    equal(h:line(0).groups[1].priority, 0)
    table.sort = original
end)
test('node text is lazy and disabled trace logging does not force it', function()
    local buf = buffer({ '# Heading', '', 'body' })
    local tree = vim.treesitter.get_parser(buf, 'markdown'):parse(true)[1]
    local original, calls = vim.treesitter.get_node_text, 0
    vim.treesitter.get_node_text = function(...) calls = calls + 1; return original(...) end
    local node = Node.new(buf, tree:root())
    equal(calls, 0)
    require('inkstone.core.log').node('document', node)
    equal(calls, 0)
    assert(node.text:find('Heading', 1, true))
    local _ = node.text
    equal(calls, 1)
    vim.treesitter.get_node_text = original
    vim.api.nvim_buf_delete(buf, { force = true })
end)
test('width summaries invalidate on edits, options and wipe', function()
    local buf = buffer({ '\tx', '日本語' })
    local cache = require('inkstone.lib.width_cache')
    vim.bo[buf].tabstop = 4
    equal(cache.get(buf, 0, 2), { 5, 6 })
    local first = cache.get(buf, 0, 2)
    assert(first == cache.get(buf, 0, 2))
    vim.bo[buf].tabstop = 8
    equal(cache.get(buf, 0, 2), { 9, 6 })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '日' })
    equal(cache.get(buf, 0, 2), { 9, 2 })
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(cache.cache[buf] == nil)
end)
test('real Markdown table parser and Japanese renderer produce marks', function()
    local buf = buffer({ '| 項目 | 説明 |', '| --- | --- |', '| 日本語 | 「日本語」の表を、読みやすく。 |', '| emoji | 👩‍💻🇯🇵👍🏽 |' })
    vim.wo.conceallevel = 2
    local tree = vim.treesitter.get_parser(buf, 'markdown'):parse(true)[1]
    local query = vim.treesitter.query.parse('markdown', '(pipe_table) @table')
    local context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
    context.view.ranges = { { 0, 5 } }
    for _, node in query:iter_captures(tree:root(), buf) do
        local marks = Marks.new(context, false)
        require('inkstone.render.markdown.table'):execute(context, marks, Node.new(buf, node))
        assert(#marks:get() > 0)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
end)
test('giant fences materialize only disjoint visible ranges and reuse widths', function()
    local lines = { '```lua' }
    for i = 1, 7000 do lines[#lines + 1] = i % 5 == 0 and '' or 'local value = "日本語"' end
    lines[#lines + 1] = '```'
    local buf = buffer(lines)
    local tree = vim.treesitter.get_parser(buf, 'markdown'):parse(true)[1]
    local query = vim.treesitter.query.parse('markdown', '(fenced_code_block) @code')
    local fence
    for _, node in query:iter_captures(tree:root(), buf) do fence = Node.new(buf, node); break end
    assert(fence)
    for _, ranges in ipairs({ { { 0, 10 }, { 6990, 7001 } }, { { 3500, 3510 } } }) do
        local context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
        context.view.ranges = ranges
        local marks = Marks.new(context, false)
        require('inkstone.render.markdown.code'):execute(context, marks, fence)
        assert(#marks:get() < 100)
        for _, mark in ipairs(marks:get()) do
            if mark.opts.hl_eol then
                local visible = false
                for _, range in ipairs(ranges) do visible = visible or (mark.start_row >= range[1] and mark.start_row <= range[2]) end
                assert(visible, 'offscreen code body mark')
            end
        end
    end
    vim.api.nvim_buf_delete(buf, { force = true })
end)
test('async completion rejects edits, superseded views and errors', function()
    local buf = buffer({ 'hello' })
    local callback
    local parser = { parse = function(_, _, cb) callback = cb end }
    local context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
    local completed = 0
    context.view:parse(parser, function() completed = completed + 1 end)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'changed' })
    callback(nil, {})
    equal(completed, 0)
    context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
    context.view:parse(parser, function() completed = completed + 1 end)
    Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
    callback(nil, {})
    equal(completed, 0)
    context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
    context.view:parse(parser, function() completed = completed + 1 end)
    callback('TIMEOUT', nil)
    equal(completed, 0)
    callback(nil, {})
    equal(completed, 1)
    vim.api.nvim_buf_delete(buf, { force = true })
end)
test('debounce renders the leading and latest frame, then disposes', function()
    local buf = buffer({ 'body' })
    local decorator = require('inkstone.lib.decorator').new(buf)
    local frames = {}
    decorator:schedule(true, 30, function() frames[#frames + 1] = 1 end)
    decorator:schedule(true, 30, function() frames[#frames + 1] = 2 end)
    decorator:schedule(true, 30, function() frames[#frames + 1] = 3 end)
    assert(vim.wait(1000, function() return #frames == 2 end, 5))
    equal(frames, { 1, 3 })
    decorator:dispose()
    assert(decorator.timer:is_closing())
    vim.api.nvim_buf_delete(buf, { force = true })
end)
test('public command, asynchronous UI and wipe cleanup', function()
    vim.fn.mkdir(vim.fn.stdpath('state'), 'p')
    vim.cmd.runtime('plugin/inkstone.lua')
    assert(vim.fn.exists(':Inkstone') == 2)
    local buf = buffer({ '# 日本語', '', '| 項目 | 説明 |', '| --- | --- |', '| 表 | 日本語の表示です。 |' })
    vim.bo[buf].filetype = 'markdown'
    local ui = require('inkstone.core.ui')
    ui.update(buf, vim.api.nvim_get_current_win(), 'Test', true)
    assert(vim.wait(3000, function() return ui.cache[buf] and ui.cache[buf].n > 0 end, 10))
    assert(#vim.api.nvim_buf_get_extmarks(buf, ui.ns, 0, -1, {}) > 0)
    local decorator = ui.cache[buf]
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(decorator.timer:is_closing())
    assert(ui.cache[buf] == nil and state.cache[buf] == nil and Context.cache[buf] == nil)
    assert(not require('inkstone.core.manager').attached(buf))
end)
print(('Inkstone: %d integration contracts passed'):format(passed))
