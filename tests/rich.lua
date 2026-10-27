return function(test, equal, buffer)
    local inkstone, state = require('inkstone'), require('inkstone.state')
    local Context = require('inkstone.request.context')
    local views = require('inkstone.core.table_views')
    local function setup(lines, options)
        inkstone.setup(vim.tbl_deep_extend('force', { anti_conceal = { enabled = false },
            media = { enabled = false }, typography = { enabled = false } }, options or {}))
        local buf = buffer(lines)
        vim.bo[buf].filetype = 'markdown'
        vim.wo.conceallevel = 3
        vim.treesitter.start(buf, 'markdown')
        local parser = vim.treesitter.get_parser(buf, 'markdown')
        local function render()
            parser:parse(true)
            local ctx = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
            ctx.view.ranges = { { 0, #lines + 10 } }
            return require('inkstone.core.handlers').run(ctx, parser), ctx
        end
        return buf, render, parser
    end
    local function content(marks)
        local result = {}
        for _, mark in ipairs(marks) do
            for _, line in ipairs(mark.replace or {}) do
                local texts = {}; for _, chunk in ipairs(line) do texts[#texts + 1] = chunk[1] end
                result[#result + 1] = table.concat(texts)
            end
        end
        return table.concat(result, '\n')
    end
    local function toggle(buf, mode)
        views.toggle(buf, vim.api.nvim_get_current_win(), mode)
        assert(vim.wait(1000, function() return views.cache[buf] ~= nil end, 5))
    end
    local function external_test(name, commands, callback)
        for _, command in ipairs(commands) do
            if vim.fn.executable(command) ~= 1 then print('SKIP: ' .. name .. ' (missing ' .. command .. ')'); return end
        end
        test(name, callback)
    end

    test('tables cycle through cards and charts while source and anchors survive edits', function()
        local lines = { 'BEFORE', '', '| 項目 | before | after |', '| --- | --- | --- |',
            '| 日本語 | 20ms | 10ms |', '| emoji 👩‍💻 | 40ms | 30ms |', '', 'AFTER' }
        local buf, render = setup(lines)
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
        toggle(buf, 'list')
        equal(views.cache[buf][1].mode, 'list')
        local marks = render()
        assert(content(marks):find('• 項目', 1, true))
        assert(content(marks):find('日本語', 1, true))
        equal(vim.api.nvim_win_get_cursor(0)[1], 3)
        toggle(buf, 'chart')
        equal(views.cache[buf][1].mode, 'chart')
        marks = render()
        assert(content(marks):find('█', 1, true))
        assert(content(marks):find('before (ms)', 1, true))
        toggle(buf, 'chart')
        equal(views.cache[buf][1].mode, 'table')
        toggle(buf, 'list')
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted' })
        marks = render()
        assert(content(marks):find('• 項目', 1, true))
        equal(vim.api.nvim_buf_get_lines(buf, 1, -1, false), lines)
        -- A new table at the same row must not inherit a deleted table's view.
        vim.api.nvim_buf_set_lines(buf, 3, 7, false, {})
        vim.api.nvim_buf_set_lines(buf, 3, 3, false, { '| New | Value |', '| - | - |', '| A | 1 |' })
        local _, context = render()
        equal(#context.table_views, 0)
        equal(views.cache[buf], nil)
        vim.api.nvim_buf_delete(buf, { force = true })
        equal(views.cache[buf], nil)
    end)

    test('card values retain inline rendering and escaped pipes', function()
        local buf, render = setup({ 'BEFORE', '', '| Name | Description |', '| - | - |',
            [[| a | **bold** [link](https://example.org) and a\|b |]], '', 'AFTER' })
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        toggle(buf, 'list')
        local text = content(render())
        assert(text:find('bold', 1, true))
        assert(not text:find('**', 1, true))
        assert(not text:find('https://example.org', 1, true))
        assert(text:find('a|b', 1, true))
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('chart data handles zero, negative and missing values and rejects incompatible units', function()
        local chart = require('inkstone.text.chart')
        local data = assert(chart.data({ 'Name', 'A', 'B' }, { { '<A&"', '0ms', '2ms' }, { 'B', '-1.5ms', '-' } }))
        equal(data.series[1].values, { 0, -1.5 })
        equal(data.series[2].values, { 2, false })
        local svg = chart.svg(data, { kind = 'line' })
        assert(svg:find('&lt;A&amp;&quot;', 1, true))
        assert(not svg:find('nan', 1, true))
        assert(svg:find('<circle', 1, true))
        assert(not chart.data({ 'A', 'B' }, { { '1ms', '2%' } }))
        assert(not chart.data({ 'Name', 'Value' }, { { 'A', 'word' } }))
        assert(not chart.data({ 'Value' }, { { '1,2' } }))
        equal(assert(chart.data({ 'Value' }, { { '1,200.5ms' } })).series[1].values, { 1200.5 })
        local zeros = assert(chart.data({ 'A' }, { { '0' }, { '0' } }))
        assert(not chart.svg(zeros):find('nan', 1, true))
    end)

    external_test('chart conversion produces real PNG and diagram collection owns its request', { 'rsvg-convert' }, function()
        local Chart, media = require('inkstone.text.chart'), require('inkstone.core.media')
        local data = assert(Chart.data({ 'Name', 'Value' }, { { '日本語', '1' }, { 'B', '2' } }))
        local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
        local config = vim.deepcopy(inkstone.default.media); config.cache_dir = dir
        local done, path = false, nil
        media.convert({ kind = 'chart', source = Chart.svg(data) }, config, function(result, err)
            assert(result, err); done, path = true, result
        end)
        assert(vim.wait(3000, function() return done end, 5))
        local file = assert(io.open(path, 'rb')); equal(file:read(8), '\137PNG\r\n\26\n'); file:close()
        vim.fn.delete(dir, 'rf')
    end)

    external_test('LaTeX converts through latex2text without an injected LaTeX parser', { 'latex2text' }, function()
        local original = { 'BEFORE', '', '$\\sqrt{3x-1}+(1+x)^2$', '', '$$',
            '\\lim_{n\\to\\infty} \\left(1 + \\frac{1}{n}\\right)^n', '$$', '',
            '`$\\sqrt{literal}$`', '', 'AFTER' }
        local buf, render, parser = setup(original, { latex = { converter = 'latex2text' } })
        local each_tree = parser.for_each_tree
        parser.for_each_tree = function(self, callback)
            each_tree(self, function(tree, language)
                if language:lang() ~= 'latex' then callback(tree, language) end
            end)
        end
        local marks, ctx = render()
        equal(#ctx.latex:get(), 2)
        local text = {}
        for _, mark in ipairs(marks) do
            for _, chunk in ipairs(mark.opts.virt_text or {}) do text[#text + 1] = chunk[1] end
            for _, line in ipairs(mark.opts.virt_lines or {}) do
                for _, chunk in ipairs(line) do text[#text + 1] = chunk[1] end
            end
            for _, line in ipairs(mark.replace or {}) do
                for _, chunk in ipairs(line) do text[#text + 1] = chunk[1] end
            end
        end
        local output = table.concat(text, '\n')
        assert(output:find('√(3x-1)+(1+x)^2', 1, true), output)
        assert(output:find('lim_n→∞ (1 + 1/n)^n', 1, true), output)
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original)
        parser.for_each_tree = each_tree
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    external_test('rich math replaces block source and refreshes when converters change', { 'latex2text', 'utftex' }, function()
        local original = { 'BEFORE', '', '$$', '\\lim_{n\\to\\infty} \\left(1 + \\frac{1}{n}\\right)^n', '$$', '', 'AFTER' }
        local buf, render = setup(original, { latex = { converter = 'latex2text' } })
        local function replacement(marks)
            for _, mark in ipairs(marks) do if mark.replace then return mark end end
        end
        equal(#assert(replacement(render())).replace, 1)
        local config = state.get(buf)
        config.latex.converter = 'utftex'
        local mark = assert(replacement(render()))
        assert(#mark.replace >= 3)
        local text = {}; for _, line in ipairs(mark.replace) do
            for _, chunk in ipairs(line) do text[#text + 1] = chunk[1] end
        end
        assert(table.concat(text):find('─', 1, true))
        equal({ mark.start_row, mark.opts.end_row }, { 2, 4 })
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        local updater = require('inkstone.core.ui').updater.new(buf, vim.api.nvim_get_current_win(), true)
        updater.mode = 'n'
        local extmark = require('inkstone.lib.extmark').new(mark)
        assert(not updater:hide(extmark, updater:hidden()))
        config.anti_conceal = { enabled = true, above = 0, below = 0, disabled_modes = {} }
        assert(updater:hide(extmark, updater:hidden()))
        config.latex.converter = 'false'
        local log_level = state.log_level
        state.log_level = 'off'
        local failed = render()
        state.log_level = log_level
        for _, item in ipairs(failed) do
            assert(not item.replace)
            for _, chunk in ipairs(item.opts.virt_text or {}) do assert(chunk[1] ~= 'error') end
        end
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('PDF links are collected for explicit viewing without inline duplication', function()
        local buf, render = setup({ 'BEFORE', '', '[Paper](assets/paper.pdf#page=3)', '', 'AFTER' }, { media = { enabled = true } })
        local _, ctx = render()
        equal(#ctx.media, 1)
        assert(ctx.media[1].document)
        assert(ctx.media[1].source:match('/assets/paper.pdf#page=3$'))
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('unified view action chooses the table before an enclosing details fold', function()
        local buf = setup({ 'BEFORE', '', '<details open>', '<summary>Outer</summary>', '',
            '| Name | Value |', '| - | - |', '| A | 1 |', '', '</details>', '', 'AFTER' })
        vim.api.nvim_win_set_cursor(0, { 8, 0 })
        require('inkstone.api').toggle_view()
        assert(vim.wait(1000, function() return views.cache[buf] ~= nil end, 5))
        equal(views.cache[buf][1].mode, 'list')
        equal(require('inkstone.core.folds').cache[buf], nil)
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        require('inkstone.api').toggle_view()
        assert(vim.wait(1000, function() return require('inkstone.core.folds').cache[buf] ~= nil end, 5))
        assert(require('inkstone.core.folds').cache[buf][1].closed)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    external_test('viewer fits, zooms and pans real images and cleans temporary output', { 'magick' }, function()
        local media, viewer = require('inkstone.core.media'), require('inkstone.core.viewer')
        local backend = media.backend
        local closed = 0
        media.backend = function() return {
            terminal = { size = function() return { cell_width = 9, cell_height = 18 } end },
            placement = { new = function() return { close = function() closed = closed + 1 end } end },
        } end
        local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
        local source = dir .. '/source.png'
        equal(vim.system({ 'magick', '-size', '1600x800', 'gradient:red-blue', '-rotate', '90', source }):wait().code, 0)
        local buf = buffer({ 'source' })
        local session = assert(viewer.open(source, { origin = buf, config = inkstone.default.media }))
        assert(vim.wait(3000, function() return session.output ~= nil end, 5))
        local first = session.output
        viewer.action(session, 'zoom_in')
        assert(vim.wait(3000, function() return session.output ~= first end, 5))
        equal(session.zoom, 1.25)
        viewer.action(session, 'right')
        local previous = session.output
        assert(vim.wait(3000, function() return session.output ~= previous end, 5))
        viewer.action(session, 'fit')
        assert(vim.wait(3000, function() return session.zoom == 1 and session.process == nil and session.timer == nil end, 5))
        equal({ session.x, session.y }, { 0, 0 })
        viewer.clear(buf)
        assert(session.closed and closed >= 1)
        equal(vim.fn.isdirectory(session.dir), 0)
        media.backend = backend
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.fn.delete(dir, 'rf')
    end)

    test('typography reserves real scaled cells, sanitizes controls and leaves source intact', function()
        local typography = require('inkstone.core.typography')
        local supports = typography.supports
        typography.supports = function() return true end
        local original = { 'BEFORE', '', '# 日本語 Heading', '', 'Normal <small>小さい補足</small> after', '',
            'Literal `<small>code</small>` stays code.', '', 'AFTER' }
        local buf, render = setup(original, { typography = { enabled = true }, paragraph = { wrap = false } })
        local marks, ctx = render()
        equal(#ctx.typography, 2)
        equal(ctx.typography[1].spec.scale, 2)
        equal(ctx.typography[2].spec.num / ctx.typography[2].spec.den, .8)
        for _, entry in ipairs(ctx.typography) do
            for _, line in ipairs(entry.lines) do
                for _, run in ipairs(line.runs) do assert(run.cells <= 7 and not run.text:find('[%c]')) end
            end
        end
        local dirty = typography.runs({ { 'x\27[31m\ny', 'Normal' } }, typography.spec(2))
        for _, run in ipairs(dirty) do assert(not run.text:find('[%c]')) end
        assert(#marks > 0)
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original)
        typography.supports = supports
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('fractional typography does not round space into the middle of words', function()
        local typography = require('inkstone.core.typography')
        local text = 'Images and diagrams and formatting'
        for _, ratio in ipairs({ .8, 1.25, 1.5, 2 }) do
            local spec = assert(typography.spec(ratio))
            local runs = typography.runs({ { text, 'Normal' } }, spec)
            local joined = {}
            for i, run in ipairs(runs) do
                joined[#joined + 1] = run.text
                assert(run.cells <= 7)
                if i < #runs then equal(run.width, vim.fn.strdisplaywidth(run.text) * spec.ratio) end
            end
            equal(table.concat(joined), text)
        end
    end)

    test('terminal probe guards fragmented replies and drains after disable or retry', function()
        local typography = require('inkstone.core.typography')
        local tmux = vim.env.TMUX; vim.env.TMUX = nil
        local send, capability = vim.api.nvim_ui_send, typography.capability
        local timeout, length = vim.o.ttimeout, vim.o.ttimeoutlen
        local queries = 0
        vim.api.nvim_ui_send = function() queries = queries + 1 end
        vim.o.ttimeout, vim.o.ttimeoutlen = true, 1
        typography.capability, typography.waiters = nil, {}
        typography.probe()
        assert(vim.o.ttimeout and vim.o.ttimeoutlen >= 1200)
        typography.clear()
        typography.retry()
        typography.probe()
        equal(queries, 1)
        assert(typography.probing and vim.o.ttimeoutlen >= 1200)
        vim.api.nvim_exec_autocmds('TermResponse', { data = { sequence = '\27P>|kitty(0.49.2)' } })
        equal(typography.capability, true)
        equal({ typography.probing, vim.o.ttimeout, vim.o.ttimeoutlen }, { false, true, 1 })
        equal(typography.probe_timer, nil)
        equal(typography.probe_autocmd, nil)
        vim.api.nvim_ui_send, typography.capability = send, capability
        vim.o.ttimeout, vim.o.ttimeoutlen = timeout, length
        vim.env.TMUX = tmux
    end)

    test('terminal probe preserves option changes made while waiting', function()
        local typography = require('inkstone.core.typography')
        local tmux = vim.env.TMUX; vim.env.TMUX = nil
        local send, capability = vim.api.nvim_ui_send, typography.capability
        local timeout, length = vim.o.ttimeout, vim.o.ttimeoutlen
        vim.api.nvim_ui_send = function() end
        vim.o.ttimeout, vim.o.ttimeoutlen = false, -1
        typography.capability, typography.waiters = nil, {}
        typography.probe()
        assert(vim.o.ttimeout and vim.o.ttimeoutlen >= 1200)
        vim.o.ttimeout, vim.o.ttimeoutlen = false, 2500
        vim.api.nvim_exec_autocmds('TermResponse', { data = { sequence = '\27P>|kitty(0.39.0)' } })
        equal(typography.capability, false)
        equal({ vim.o.ttimeout, vim.o.ttimeoutlen }, { false, 2500 })
        vim.api.nvim_ui_send, typography.capability = send, capability
        vim.o.ttimeout, vim.o.ttimeoutlen = timeout, length
        vim.env.TMUX = tmux
    end)

    test('unanswered terminal probes release their input guard on timeout', function()
        local typography = require('inkstone.core.typography')
        local tmux = vim.env.TMUX; vim.env.TMUX = nil
        local send, capability = vim.api.nvim_ui_send, typography.capability
        local timeout, length = vim.o.ttimeout, vim.o.ttimeoutlen
        vim.api.nvim_ui_send = function() end
        vim.o.ttimeout, vim.o.ttimeoutlen = false, -1
        typography.capability, typography.waiters = nil, {}
        typography.probe()
        assert(vim.wait(1600, function() return not typography.probing end, 5))
        equal(typography.capability, false)
        equal({ vim.o.ttimeout, vim.o.ttimeoutlen }, { false, -1 })
        equal(typography.probe_timer, nil)
        equal(typography.probe_autocmd, nil)
        vim.api.nvim_ui_send, typography.capability = send, capability
        vim.o.ttimeout, vim.o.ttimeoutlen = timeout, length
        vim.env.TMUX = tmux
    end)

    test('tmux uses cached terminal identity without sending input-stream queries', function()
        local typography = require('inkstone.core.typography')
        local tmux, cached, capability, send = vim.env.TMUX, typography.tmux, typography.capability, vim.api.nvim_ui_send
        local timeout, length = vim.o.ttimeout, vim.o.ttimeoutlen
        vim.env.TMUX = 'test'
        vim.api.nvim_ui_send = function() error('must not send a terminal query through tmux') end
        for _, case in ipairs({ { 'kitty(0.49.2)', true }, { 'kitty(0.40.0)', true },
            { 'kitty(0.39.0)', false }, { '', false }, { 'xterm(400)', false } }) do
            typography.tmux = { allowed = true, terminal = case[1] }
            typography.capability, typography.waiters = nil, {}
            typography.probe()
            equal(typography.capability, case[2])
            equal({ vim.o.ttimeout, vim.o.ttimeoutlen }, { timeout, length })
        end
        vim.env.TMUX, typography.tmux, typography.capability, vim.api.nvim_ui_send = tmux, cached, capability, send
    end)

    external_test('PDF viewer turns real pages and rejects the end of the document', { 'magick', 'gs' }, function()
        local media, viewer = require('inkstone.core.media'), require('inkstone.core.viewer')
        local backend, notify = media.backend, vim.notify
        local warnings = 0
        vim.notify = function() warnings = warnings + 1 end
        media.backend = function() return { placement = { new = function() return { close = function() end } end } } end
        local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
        local ps, pdf = dir .. '/pages.ps', dir .. '/pages.pdf'
        vim.fn.writefile({ '%!PS', '<< /PageSize [100 100] >> setpagedevice',
            '1 0 0 setrgbcolor 0 0 100 100 rectfill showpage',
            '0 0 1 setrgbcolor 0 0 100 100 rectfill showpage' }, ps)
        equal(vim.system({ 'gs', '-q', '-dBATCH', '-dNOPAUSE', '-sDEVICE=pdfwrite', '-o', pdf, ps }):wait().code, 0)
        local origin = buffer({ 'PDF source' })
        local session = assert(viewer.open(pdf, { origin = origin, config = inkstone.default.media }))
        assert(vim.wait(5000, function() return session.output ~= nil end, 5))
        local first = session.output
        viewer.action(session, 'next')
        assert(vim.wait(5000, function() return session.displayed_page == 2 end, 5))
        assert(session.output ~= first)
        viewer.action(session, 'next')
        assert(vim.wait(5000, function() return warnings > 0 end, 5))
        equal(session.page, 2)
        viewer.action(session, 'previous')
        assert(vim.wait(5000, function() return session.displayed_page == 1 end, 5))
        viewer.clear(origin)
        media.backend, vim.notify = backend, notify
        vim.api.nvim_buf_delete(origin, { force = true })
        vim.fn.delete(dir, 'rf')
    end)
end
