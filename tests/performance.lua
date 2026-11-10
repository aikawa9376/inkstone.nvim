return function(test, equal, buffer)
    local inkstone = require('inkstone')
    local Context = require('inkstone.request.context')
    local handlers = require('inkstone.core.handlers')
    local function setup(lines, options)
        inkstone.setup(vim.tbl_deep_extend('force', {
            anti_conceal = { enabled = false }, media = { enabled = false },
        }, options or {}))
        local buf = buffer(lines)
        vim.bo[buf].filetype = 'markdown'
        vim.wo.conceallevel = 3
        vim.treesitter.start(buf, 'markdown')
        local parser = vim.treesitter.get_parser(buf, 'markdown')
        local function render()
            parser:parse(true)
            local ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
            return handlers.run(ctx, parser), ctx
        end
        return buf, render, parser
    end

    test('native viewport accounts for wrap, conceal and fold gaps with an older-API fallback', function()
        local env = require('inkstone.lib.env')
        local api = vim.api.nvim_win_text_height
        local lines = {}
        for i = 1, 300 do lines[i] = 'row ' .. i end
        local buf = buffer(lines)
        local win = vim.api.nvim_get_current_win()
        local height, width = vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win)
        vim.wo.wrap, vim.wo.conceallevel, vim.wo.concealcursor = true, 3, 'nvic'
        lines[1] = 'a' .. string.rep('x', width * (height + 5)) .. 'b'
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { lines[1] })
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        local ok, result = pcall(api, win, { start_row = 0, max_height = 1 })
        if ok and result.end_row then
            env.text_height_supported = nil
            equal(env.range(buf, win, 0), { 0, 1 })
            assert(env.range(buf, win, 0, nil, false)[2] >= height)
            local ns = vim.api.nvim_create_namespace('inkstone-native-viewport-test')
            vim.api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = #lines[1] - 1, conceal = '' })
            if api(win, { start_row = 0, end_row = 0 }).all == 1 then
                equal(env.range(buf, win, 0), { 0, height })
            end
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            lines[1] = 'visible'
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, { lines[1] })
            vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_row = 150, end_col = 0, conceal_lines = '' })
            local calls = 0
            vim.api.nvim_win_text_height = function(w, opts)
                calls = calls + 1
                assert(opts.end_row < 1 or opts.start_row >= 151, 'native measurement walked a hidden fold body')
                return api(w, opts)
            end
            equal(env.range(buf, win, 0, { { 1, 151 } }), { 0, height + 150 })
            equal(calls, 2)
            vim.api.nvim_win_text_height = api
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            vim.cmd('2,151fold')
            equal(env.range(buf, win, 0, { { 10, 20 } }), { 0, height + 149 })
            vim.cmd('normal! zE')
        end
        local attempts = 0
        env.text_height_supported = nil
        vim.api.nvim_win_text_height = function() attempts = attempts + 1; error('Invalid key: max_height') end
        equal(env.range(buf, win, 5), env.range(buf, win, 5, nil, false))
        equal(env.range(buf, win, 5), env.range(buf, win, 5, nil, false))
        equal(attempts, 1)
        vim.api.nvim_win_text_height = api
        env.text_height_supported = nil
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('native paragraph layout is viewport bounded and caches source boundaries', function()
        local lines = {}
        for i = 1, 1000 do lines[i] = ('日本語の文章を文節で折り返します。'):rep(6) end
        local buf, _, parser = setup(lines)
        local softwrap = require('inkstone.lib.softwrap')
        local original, calls = softwrap.layout, 0
        softwrap.layout = function(...) calls = calls + 1; return original(...) end
        local function render()
            parser:parse(true)
            local ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
            ctx.view.ranges = { { 100, 101 }, { 800, 801 } }
            return handlers.run(ctx, parser)
        end
        local marks = render()
        equal(calls, 4)
        for _, mark in ipairs(marks) do
            assert(not mark.replace)
            assert((mark.start_row >= 100 and mark.start_row <= 101)
                or (mark.start_row >= 800 and mark.start_row <= 801))
        end
        calls = 0
        equal(render(), marks)
        equal(calls, 0)
        local config = require('inkstone.state').get(buf)
        config.paragraph.japanese.budoux = false
        render()
        equal(calls, 4)
        calls = 0
        config.padding.highlight = 'String'
        render()
        equal(calls, 0)
        vim.api.nvim_buf_set_text(buf, 100, 0, 100, 0, { '追加。' })
        render()
        equal(calls, 1)
        softwrap.layout = original
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('joined paragraph cache preserves marks and invalidates display inputs', function()
        local source = string.rep('日本語の **強調** と [リンク](https://example.org) を折り返します。', 10)
        local buf, render = setup({ 'BEFORE', '', source, '', 'AFTER' }, { paragraph = { join = true } })
        local first = render()
        local display = require('inkstone.lib.display')
        local original, calls = display.line, 0
        display.line = function(...) calls = calls + 1; return original(...) end
        equal(render(), first)
        equal(calls, 0)
        -- Emitted lines may be rewritten by display compatibility or a caller.
        for _, mark in ipairs(first) do if mark.replace then mark.replace[1][1][1] = 'modified' end end
        local clean = render()
        for _, mark in ipairs(clean) do if mark.replace then assert(mark.replace[1][1][1] ~= 'modified') end end
        local config = require('inkstone.state').get(buf)
        config.paragraph.japanese.budoux = false
        render()
        assert(calls > 0)
        calls = 0
        config.padding.highlight = 'String'
        render()
        assert(calls > 0)
        calls = 0
        vim.api.nvim_buf_set_text(buf, 2, 0, 2, 0, { '追加の文章。' })
        render()
        assert(calls > 0)
        display.line = original
        vim.api.nvim_buf_delete(buf, { force = true })
        equal(require('inkstone.lib.layout_cache').cache[buf], nil)
    end)

    test('width summaries survive unrelated edits and move with source rows', function()
        local cache = require('inkstone.lib.width_cache')
        local buf = buffer({ 'before', 'aa', '日本', 'after' })
        local widths = cache.get(buf, 1, 3)
        equal(widths, { 2, 4 })
        vim.api.nvim_buf_set_lines(buf, 3, 4, false, { 'changed after' })
        assert(cache.get(buf, 1, 3) == widths)
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted before' })
        assert(cache.get(buf, 2, 4) == widths)
        vim.api.nvim_buf_set_lines(buf, 4, 4, false, { 'inserted at end' })
        assert(cache.get(buf, 2, 4) == widths)
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
        assert(cache.get(buf, 1, 3) == widths)
        vim.api.nvim_buf_set_lines(buf, 1, 1, false, { 'x' })
        assert(cache.get(buf, 2, 4) == widths)
        vim.api.nvim_buf_set_lines(buf, 3, 3, false, { 'z' })
        equal(cache.get(buf, 2, 5), { 2, 1, 4 })
        vim.api.nvim_buf_set_text(buf, 2, 0, 2, 1, { 'long' })
        equal(cache.get(buf, 2, 5), { 5, 1, 4 })
        vim.api.nvim_buf_delete(buf, { force = true })
        equal(cache.cache[buf], nil)
        equal(cache.attached[buf], nil)
    end)

    test('unchanged extmarks retain IDs and edited native positions are checked', function()
        local buf = buffer({ 'abcd', 'efgh' })
        local decorator = require('inkstone.lib.decorator').new(buf)
        local Extmark = require('inkstone.lib.extmark')
        local ns = vim.api.nvim_create_namespace('inkstone-reuse-test')
        local mark = { conceal = true, start_row = 0, start_col = 1, opts = { end_col = 2, hl_group = 'String' } }
        local function next_marks() return { Extmark.new(vim.deepcopy(mark)) } end
        decorator:replace(ns, next_marks())
        decorator:display(ns, function() return false end)
        local id = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})[1][1]
        decorator:replace(ns, next_marks())
        decorator:display(ns, function() return false end)
        equal(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})[1][1], id)
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'unrelated edit' })
        decorator:replace(ns, next_marks())
        decorator:display(ns, function() return false end)
        equal(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})[1][1], id)
        vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { 'x' })
        decorator:replace(ns, next_marks())
        decorator:display(ns, function() return false end)
        local actual = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        equal(#actual, 1)
        assert(actual[1][1] ~= id)
        equal({ actual[1][2], actual[1][3], actual[1][4].end_col }, { 0, 1, 2 })
        decorator:replace(ns, {})
        equal(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)
        decorator:dispose()
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('wrap invalidation tracks rows across edits before the next render and keeps other marks', function()
        local buf = buffer({ 'first paragraph', '', 'second paragraph' })
        local decorator = require('inkstone.lib.decorator').new(buf)
        local Extmark = require('inkstone.lib.extmark')
        local ns = vim.api.nvim_create_namespace('inkstone-padding-invalidation-test')
        local function padding(row)
            return Extmark.new({ conceal = false, paragraph_padding = true, start_row = row, start_col = 5,
                opts = { virt_text = { { '    ', 'Normal' } }, virt_text_pos = 'inline', right_gravity = false } })
        end
        local first, second = padding(0), padding(2)
        local highlight = Extmark.new({ conceal = false, start_row = 0, start_col = 0,
            opts = { end_col = 5, hl_group = 'String' } })
        decorator:set({ first, second, highlight })
        decorator:display(ns, function() return false end)
        local original = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted' })
        assert(first:shown() and second:shown() and highlight:shown())
        -- Descriptions still have the old source rows; the watcher must track
        -- native movement even when several changes precede parsing.
        vim.api.nvim_buf_set_text(buf, 1, 0, 1, 1, { 'F' })
        assert(not first:shown() and second:shown() and highlight:shown())
        local remaining = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
        equal(#remaining, 2)
        equal(remaining[2], { original[3][1], 3, 5 })
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
        assert(second:shown())
        vim.api.nvim_buf_set_lines(buf, 2, 3, false, { 'replaced second paragraph' })
        assert(not second:shown() and highlight:shown())
        decorator:clear(ns)
        decorator:dispose()
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('custom clear callbacks still see an empty render namespace', function()
        local ui, calls = require('inkstone.core.ui'), 0
        local buf = setup({ '# Heading', '', 'text' }, { on = { clear = function(args)
            calls = calls + 1
            equal(#vim.api.nvim_buf_get_extmarks(args.buf, ui.ns, 0, -1, {}), 0)
        end } })
        for n = 1, 2 do
            ui.update(buf, vim.api.nvim_get_current_win(), 'Test', true)
            assert(vim.wait(1000, function() return ui.cache[buf] and ui.cache[buf].n >= n end, 5))
        end
        assert(calls >= 2)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('table child seeking matches full traversal for disjoint views', function()
        local lines = { '| A | B |', '| - | - |' }
        for _ = 1, 5000 do lines[#lines + 1] = '| x | y |' end
        local buf = buffer(lines)
        local tree = vim.treesitter.get_parser(buf, 'markdown'):parse(true)[1]
        local root = tree:root():named_child(0):named_child(0)
        equal(root:type(), 'pipe_table')
        local ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
        ctx.view.ranges = { { 2000, 2010 }, { 4000, 4003 } }
        local expected, actual, seeks = {}, {}, 0
        for node in root:iter_children() do
            if ctx.view:overlaps(node) then expected[#expected + 1] = node:id() end
        end
        local proxy = {
            child_count = function() return root:child_count() end,
            child = function(_, i) seeks = seeks + 1; return root:child(i) end,
        }
        ctx.view:children(proxy, function(node) actual[#actual + 1] = node:id() end)
        equal(actual, expected)
        assert(seeks < 40, 'off-screen children were enumerated')
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('handler pass shares tree enumeration without retaining tree snapshots', function()
        local buf, _, parser = setup({ 'BEFORE', '', '[link](https://example.org) **bold**', '', 'AFTER' },
            { media = { enabled = true } })
        parser:parse(true)
        local original, calls = parser.for_each_tree, 0
        local env = require('inkstone.lib.env')
        local width = env.win.width
        -- Isolate plugin traversals from getwininfo's native redraw callbacks.
        env.win.width = function(win) return vim.api.nvim_win_get_width(win) end
        parser.for_each_tree = function(...) calls = calls + 1; return original(...) end
        local ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
        handlers.run(ctx, parser)
        equal(calls, 1)
        equal(ctx.view.trees, nil)
        parser.for_each_tree = original
        env.win.width = width
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('cursor restores all wrapped table decorations and re-renders on exit', function()
        local lines = { 'BEFORE', '', '| A | B |', '| - | - |',
            '| [label](https://example.org/' .. string.rep('long/', 100) .. ') | ' .. string.rep('日本語。', 30) .. ' |',
            '| short | cell |', '', 'AFTER' }
        local buf, render = setup(lines, { pipe_table = { wrap = true, border_virtual = true } })
        local marks, ctx = render()
        equal(ctx.tables, { { 2, 5 } })
        local ui = require('inkstone.core.ui')
        local decorator = ui.get(buf)
        local extmarks = {}
        for _, mark in ipairs(marks) do extmarks[#extmarks + 1] = require('inkstone.lib.extmark').new(mark) end
        decorator:set(extmarks)
        local updater = ui.updater.new(buf, vim.api.nvim_get_current_win(), false)
        updater.mode = 'n'
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        updater:display()
        local before = vim.api.nvim_buf_get_extmarks(buf, ui.ns, 0, -1, {})
        assert(#before > 0)
        -- Header, delimiter, long row and a short row share the edit state.
        for row = 3, 6 do
            vim.api.nvim_win_set_cursor(0, { row, 0 })
            ctx.config.anti_conceal.enabled = false
            updater:display()
            equal(#vim.api.nvim_buf_get_extmarks(buf, ui.ns, 0, -1, {}), #before)
            ctx.config.anti_conceal = { enabled = true, above = 0, below = 0, disabled_modes = {} }
            updater:display()
            equal(#vim.api.nvim_buf_get_extmarks(buf, ui.ns, 0, -1, {}), 0)
        end
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        updater:display()
        equal(#vim.api.nvim_buf_get_extmarks(buf, ui.ns, 0, -1, {}), #before)
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end
