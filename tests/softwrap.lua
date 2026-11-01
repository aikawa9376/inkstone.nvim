-- Exercise Neovim's actual grid and operators in an isolated attached UI.
-- Headless extmark descriptions alone cannot establish editable soft wrapping.
return function(test, equal)
    local child = vim.fn.jobstart({ vim.v.progpath, '--embed', '--headless', '--clean', '-u', 'NONE', '-i', 'NONE', '-n' }, { rpc = true })
    local function rpc(method, ...) return vim.rpcrequest(child, method, ...) end
    local function lua(code, ...) return rpc('nvim_exec_lua', code, { ... }) end
    rpc('nvim_ui_attach', 24, 20, { rgb = true })
    lua([=[
        local root, parser = ...
        vim.opt.rtp:prepend(root)
        vim.opt.rtp:append(parser or (vim.fn.stdpath('data') .. '/site'))
        vim.o.laststatus, vim.o.cmdheight, vim.o.ruler, vim.o.showcmd = 0, 0, false, false
        vim.o.linebreak = true
        vim.o.mouse = 'a'
        require('inkstone').setup({ anti_conceal = { enabled = false },
            media = { enabled = false }, typography = { enabled = false } })
        require('inkstone.core.manager').init()
        function refresh()
            local buf = vim.api.nvim_get_current_buf()
            local ui = require('inkstone.core.ui')
            local n = ui.cache[buf] and ui.cache[buf].n or 0
            require('inkstone.api').render({ buf = buf })
            assert(vim.wait(2000, function() return ui.cache[buf] and ui.cache[buf].n > n end, 5), 'render timeout')
            vim.cmd('redraw!')
        end
        function setup(lines, opts)
            vim.cmd('only!')
            vim.cmd('enew!')
            vim.wo.wrap, vim.wo.breakindent, vim.wo.showbreak = true, false, ''
            vim.wo.breakindentopt, vim.wo.number, vim.wo.relativenumber = '', false, false
            vim.wo.signcolumn, vim.wo.foldcolumn, vim.wo.list = 'no', '0', false
            require('inkstone').setup(vim.tbl_deep_extend('force', {
                anti_conceal = { enabled = false }, media = { enabled = false }, typography = { enabled = false },
            }, opts or {}))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
            vim.bo.filetype = 'markdown'
            vim.treesitter.start(0, 'markdown')
            vim.cmd('normal! gg0')
            refresh()
        end
        function rows(count)
            vim.cmd('redraw!')
            local result = {}
            for row = 1, count do
                local cells = {}
                for col = 1, vim.o.columns do cells[#cells + 1] = vim.fn.screenstring(row, col) end
                result[#result + 1] = table.concat(cells):gsub(' +$', '')
            end
            return result
        end
        function padding_count()
            local count = 0
            for _, mark in ipairs(require('inkstone.core.ui').cache[vim.api.nvim_get_current_buf()]:get()) do
                local description = mark:get()
                assert(not description.replace, 'paragraph source was replaced')
                assert(not description.opts.virt_lines, 'paragraph acquired virtual lines')
                if description.opts.virt_text_pos == 'inline' and mark:shown() then count = count + 1 end
            end
            return count
        end
    ]=], vim.fn.getcwd(), vim.env.INKSTONE_PARSER_RTP)

    test('ordinary Markdown buffers skip long details with default source and screen mappings', function()
        for _, anti in ipairs({ false, true }) do
            lua([=[
                local lines = { 'BEFORE', '', '<details>', '', '<summary>Long details</summary>', '', '```lua' }
                for i = 1, 800 do lines[#lines + 1] = 'print(' .. i .. ')' end
                vim.list_extend(lines, { '```', '', '</details>', '', 'AFTER' })
                setup(lines, { anti_conceal = { enabled = ... } })
            ]=], anti)
            for _, spec in ipairs({ { 3, 'j', 811 }, { 811, 'k', 3 }, { 2, '2j', 811 },
                { 812, '2k', 3 }, { 3, 'gj', 811 }, { 811, 'gk', 3 },
                { 3, '<Down>', 811 }, { 811, '<Up>', 3 } }) do
                lua('vim.api.nvim_win_set_cursor(0, { ..., 0 }); refresh()', spec[1])
                rpc('nvim_input', spec[2])
                lua([=[
                    local target = ...
                    assert(vim.wait(1000, function() return vim.api.nvim_win_get_cursor(0)[1] == target end, 5),
                        'default fold movement stopped inside concealed source at ' .. vim.api.nvim_win_get_cursor(0)[1])
                ]=], spec[3])
            end
        end
    end)

    test('default movement crosses the real upstream configuration details beyond the viewport', function()
        local range = lua([=[
            setup(vim.fn.readfile('doc/upstream-configuration.md'))
            local buf, folds = vim.api.nvim_get_current_buf(), require('inkstone.core.folds')
            local parser = vim.treesitter.get_parser(buf, 'markdown')
            parser:parse(true)
            for _, block in ipairs(folds.blocks(buf, parser, require('inkstone.state').get(buf).folds)) do
                if block.kind == 'details' and block.title == 'Default Configuration' then
                    assert(block.end_row - block.start_row > 800)
                    vim.api.nvim_win_set_cursor(0, { block.start_row + 1, 0 })
                    refresh()
                    return { block.start_row + 1, block.end_row + 1 }
                end
            end
            error('long upstream details fixture not found')
        ]=])
        for _, spec in ipairs({ { 'j', range[2] }, { 'k', range[1] } }) do
            rpc('nvim_input', spec[1])
            lua([=[
                local target = ...
                assert(vim.wait(1000, function() return vim.api.nvim_win_get_cursor(0)[1] == target end, 5),
                    'long upstream details trapped default movement')
            ]=], spec[2])
        end
    end)

    test('default screen mappings retain soft-wrap movement, raw fallback and native operators', function()
        lua([=[
            setup({ ('abcdefgh'):rep(10), '<details>', '<summary>Title</summary>', '', 'body', '</details>', 'AFTER' },
                { paragraph = { wrap = false } })
        ]=])
        for _, spec in ipairs({ { 'gj', 1, 24 }, { 'gk', 1, 0 }, { '2gj', 1, 48 } }) do
            rpc('nvim_input', spec[1])
            lua([=[
                local row, col = ...
                assert(vim.wait(1000, function() return vim.deep_equal(vim.api.nvim_win_get_cursor(0), { row, col }) end, 5))
            ]=], spec[2], spec[3])
        end
        lua('vim.api.nvim_win_set_cursor(0, { 2, 0 }); refresh()')
        rpc('nvim_input', 'yj')
        lua([=[
            assert(vim.wait(1000, function() return vim.fn.getreg('"') == '<details>\n<summary>Title</summary>\n' end, 5),
                'Normal-mode movement mapping changed an operator motion')
            require('inkstone').disable()
            assert(vim.wait(1000, function() return #vim.api.nvim_buf_get_extmarks(0, require('inkstone.core.ui').ns, 0, -1, {}) == 0 end, 5))
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
        ]=])
        rpc('nvim_input', 'j')
        lua('assert(vim.wait(1000, function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end, 5))')
    end)

    test('details tags become a styled control and body, including multiline summaries at the cursor', function()
        local result = lua([=[
            setup({ '<details open>', '', '<summary>', '<strong>Styled</strong>', 'Title', '</summary>', '',
                '# Content', '', '```lua', 'local answer = 42', '```', '', '</details>', '', 'AFTER' },
                { anti_conceal = { enabled = true, above = 1, below = 1 } })
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
            refresh()
            local result = { open = table.concat(rows(18), '\n') }
            local context = require('inkstone.request.context').get(vim.api.nvim_get_current_buf())
            local blocks = require('inkstone.core.folds').blocks(context.buf, vim.treesitter.get_parser(context.buf, 'markdown'), context.config.folds)
            result.title = blocks[1].title
            result.body = false
            for _, mark in ipairs(require('inkstone.core.ui').cache[context.buf]:get()) do
                if mark:get().details_body and mark:shown() then result.body = true end
            end
            require('inkstone.api').toggle_view()
            refresh()
            result.closed = table.concat(rows(18), '\n')
            require('inkstone.api').toggle_view()
            refresh()
            result.reopened = table.concat(rows(18), '\n')
            return result
        ]=])
        equal(result.title, 'Styled Title')
        assert(result.body)
        assert(result.open:find('▼ Styled Title', 1, true))
        for _, state in ipairs({ result.open, result.closed, result.reopened }) do
            assert(not state:find('<details', 1, true) and not state:find('<summary', 1, true) and not state:find('</summary', 1, true))
        end
        assert(not result.closed:find('answer', 1, true))
        assert(result.reopened:find('answer', 1, true))
    end)

    test('nested code folds have a visible summary across details close and reopen', function()
        local result = lua([=[
            setup({ 'BEFORE', '', '<details>', '', '<summary>Outer</summary>', '',
                '```lua', 'UNIQUE_CODE_A', 'UNIQUE_CODE_B', '```', '', 'DETAILS_TAIL', '', '</details>', '', 'AFTER' }, {
                code = { position = 'right', width = 'block', language_pad = 1, left_pad = 1, right_pad = 1, min_width = 40 },
            })
            local function toggle(row)
                vim.api.nvim_win_set_cursor(0, { row, 0 })
                require('inkstone.api').toggle_view()
                refresh()
                return table.concat(rows(18), '\n')
            end
            local result = { open = toggle(3), code_closed = toggle(8), parent_closed = toggle(3), parent_reopened = toggle(3) }
            result.code_opened = toggle(7)
            return result
        ]=])
        assert(result.open:find('UNIQUE_CODE_A', 1, true))
        assert(not result.code_closed:find('UNIQUE_CODE_A', 1, true))
        assert(result.code_closed:find('▶ 3 lines', 1, true), 'collapsed code must have a visible summary')
        assert(result.code_closed:find('· lua', 1, true))
        assert(result.parent_closed:find('▶ 11 lines · Outer', 1, true), 'details must show its hidden source-row count')
        assert(not result.parent_closed:find('DETAILS_TAIL', 1, true))
        assert(result.parent_reopened:find('▶ 3 lines', 1, true), 'nested collapsed state must be visibly identifiable')
        assert(result.parent_reopened:find('DETAILS_TAIL', 1, true))
        assert(result.code_opened:find('UNIQUE_CODE_A', 1, true))
    end)

    test('closed details and code stay closed when anti-conceal margins touch their body', function()
        local result = lua([=[
            setup({ 'BEFORE', '', '<details>', '', '<summary>Outer</summary>', '',
                '```lua', 'UNIQUE_CODE_A', 'UNIQUE_CODE_B', '```', '', 'DETAILS_TAIL', '', '</details>', '', 'AFTER' }, {
                anti_conceal = { enabled = true, above = 1, below = 1 },
            })
            local function toggle(row)
                vim.api.nvim_win_set_cursor(0, { row, 0 })
                require('inkstone.api').toggle_view()
                refresh()
                return table.concat(rows(18), '\n')
            end
            local result = { open = toggle(3), code_closed = toggle(8), parent_closed = toggle(3) }
            vim.api.nvim_win_set_cursor(0, { 8, 0 })
            refresh()
            result.source_entry = table.concat(rows(18), '\n')
            vim.api.nvim_win_set_cursor(0, { 3, 0 })
            refresh()
            result.source_exit = table.concat(rows(18), '\n')
            return result
        ]=])
        assert(result.open:find('UNIQUE_CODE_A', 1, true))
        assert(not result.code_closed:find('UNIQUE_CODE_A', 1, true), 'anti-conceal margin reopened a closed code body')
        assert(not result.parent_closed:find('UNIQUE_CODE_A', 1, true), 'anti-conceal margin reopened a closed parent body')
        assert(not result.parent_closed:find('DETAILS_TAIL', 1, true))
        assert(result.source_entry:find('UNIQUE_CODE_A', 1, true), 'deliberate source entry must still follow anti-conceal')
        assert(not result.source_exit:find('UNIQUE_CODE_A', 1, true))
    end)

    test('fold motions skip long hidden code and details, preserve counts and leave raw views native', function()
        local result = lua([=[
            local lines = { 'BEFORE', '', '<details>', '', '<summary>Heading Configuration</summary>', '', '```lua' }
            for i = 1, 800 do lines[#lines + 1] = 'print(' .. i .. ')' end
            vim.list_extend(lines, { '```', '', '</details>', '', 'AFTER' })
            setup(lines)
            local folds = require('inkstone.core.folds')
            local result = { positions = {}, foldmethod = vim.wo.foldmethod }
            local function move(row, keys)
                vim.api.nvim_win_set_cursor(0, { row, 0 })
                vim.cmd.normal({ args = { keys } })
                result.positions[#result.positions + 1] = vim.api.nvim_win_get_cursor(0)[1]
            end
            move(3, 'j')
            move(#lines - 1, 'k')
            move(2, '2j')
            move(#lines, '2k')
            result.closed = rows(8)
            vim.wo.conceallevel = 0
            move(3, 'j') -- visible source rows must remain addressable
            vim.wo.conceallevel = 3
            vim.api.nvim_win_set_cursor(0, { 3, 0 })
            folds.toggle()
            refresh()
            result.open = rows(10)
            move(3, 'j') -- skip the blank line and source summary tag
            move(#lines - 1, 'k') -- skip the closing details tag
            vim.api.nvim_win_set_cursor(0, { 7, 0 })
            folds.toggle()
            refresh()
            move(7, 'j')
            move(809, 'k')
            require('inkstone').disable()
            assert(vim.wait(1000, function() return #vim.api.nvim_buf_get_extmarks(0, require('inkstone.core.ui').ns, 0, -1, {}) == 0 end, 5))
            move(3, 'j')
            result.source = vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), lines)
            result.foldmethod_unchanged = vim.wo.foldmethod == result.foldmethod
            return result
        ]=])
        equal(result.positions, { 811, 3, 811, 3, 4, 6, 809, 809, 7, 4 })
        assert(table.concat(result.closed, '\n'):find('▶ 807 lines', 1, true))
        assert(table.concat(result.open, '\n'):find('print(1)', 1, true))
        assert(not table.concat(result.open, '\n'):find('<summary>', 1, true))
        assert(result.source and result.foldmethod_unchanged)
    end)

    test('fold motions preserve preferred columns, native folds and EOF anchors', function()
        local result = lua([=[
            setup({ 'abcdefghij', '<details>', '<summary>Title</summary>', '', 'body', '', '</details>', 'abcdefghij' })
            local folds = require('inkstone.core.folds')
            vim.wo.foldmethod, vim.wo.foldlevel = 'manual', 0
            vim.cmd('4,6fold')
            vim.api.nvim_win_set_cursor(0, { 1, 7 })
            vim.cmd('normal! j')
            folds.move(1)
            local result = { vim.api.nvim_win_get_cursor(0), vim.fn.foldclosed(4) }
            folds.move(-1)
            folds.move(-1)
            result[3] = vim.api.nvim_win_get_cursor(0)
            setup({ 'BEFORE', '```', 'body', '```' }, { code = { language = false } })
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            folds.toggle()
            refresh()
            folds.move(1, 3)
            result[4] = vim.api.nvim_win_get_cursor(0)
            result[5] = rows(3)
            return result
        ]=])
        equal(result[1], { 8, 7 })
        equal(result[2], 4)
        equal(result[3], { 1, 7 })
        equal(result[4], { 2, 0 })
        assert(table.concat(result[5], '\n'):find('▶ 2 lines', 1, true))
        assert(not table.concat(result[5], '\n'):find('`', 1, true), 'a bare fence must not become a language label')
    end)

    test('side preview maps fold movement without changing source keybindings', function()
        local result = lua([=[
            setup({ 'BEFORE', '<details>', '<summary>Title</summary>', '', 'body', '', '</details>', 'AFTER' })
            local src = vim.api.nvim_get_current_buf()
            local source_keys = vim.api.nvim_buf_get_keymap(src, 'n')
            local preview = require('inkstone.core.preview')
            preview.open(src)
            local dst = preview.buffers[src]
            assert(dst and not vim.bo[dst].modifiable)
            vim.api.nvim_set_current_win(vim.fn.win_findbuf(dst)[1])
            refresh()
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            vim.cmd.normal({ args = { 'j' } })
            local result = { vim.api.nvim_win_get_cursor(0)[1] }
            vim.cmd.normal({ args = { 'k' } })
            result[2] = vim.api.nvim_win_get_cursor(0)[1]
            result[3] = vim.deep_equal(source_keys, vim.api.nvim_buf_get_keymap(src, 'n'))
            preview.open(src)
            return result
        ]=])
        equal(result, { 8, 2, true })
    end)

    test('Ctrl+i cycles eligible table views and toggles folds using actual input', function()
        lua([=[
            setup({ 'BEFORE', '', '| Name | Value |', '| --- | --- |', '| A | 1 |', '',
                '```lua', 'print("body")', '```', '', '> [!NOTE]- Note', '> body', '',
                '<details>', '<summary>Title</summary>', '', 'body', '', '</details>', '', 'AFTER' })
            vim.api.nvim_win_set_cursor(0, { 5, 0 })
        ]=])
        for _, mode in ipairs({ 'list', 'chart', 'table' }) do
            rpc('nvim_input', '<C-i>')
            lua([=[
                local mode = ...
                assert(vim.wait(1000, function()
                    local entries = require('inkstone.core.table_views').cache[vim.api.nvim_get_current_buf()]
                    return entries and entries[1].mode == mode
                end, 5), 'Ctrl+i table cycle did not reach ' .. mode)
            ]=], mode)
        end
        for _, spec in ipairs({ { 7, true }, { 7, false }, { 11, false }, { 11, true }, { 14, false }, { 14, true } }) do
            lua('vim.api.nvim_win_set_cursor(0, { ..., 0 })', spec[1])
            rpc('nvim_input', '<C-i>')
            lua([=[
                local row, closed = ...
                local folds, buf = require('inkstone.core.folds'), vim.api.nvim_get_current_buf()
                local parser = vim.treesitter.get_parser(buf, 'markdown')
                assert(vim.wait(1000, function()
                    for _, block in ipairs(folds.blocks(buf, parser, require('inkstone.state').get(buf).folds)) do
                        if block.start_row == row - 1 then return folds.closed(buf, block) == closed end
                    end
                end, 5), 'Ctrl+i did not toggle the fold')
            ]=], spec[1], spec[2])
        end
        lua([=[
            setup({ '| Name | Value |', '| --- | --- |', '| A | word |' })
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
        ]=])
        for _, mode in ipairs({ 'list', 'table', 'list' }) do
            rpc('nvim_input', '<C-i>')
            lua([=[
                local mode = ...
                assert(vim.wait(1000, function()
                    local entries = require('inkstone.core.table_views').cache[vim.api.nvim_get_current_buf()]
                    return entries and entries[1].mode == mode
                end, 5))
            ]=], mode)
        end
    end)

    test('Ctrl+i keeps native jump-forward movement outside contextual targets and when disabled', function()
        for _, disabled in ipairs({ false, true }) do
            for _, count in ipairs({ 1, 2 }) do
                lua([=[
                    setup({ 'first', '', 'middle', '', 'last' })
                    if ... then require('inkstone').disable() end
                    vim.cmd('clearjumps')
                    vim.cmd('normal! gg3GG')
                    local key = vim.api.nvim_replace_termcodes('<C-o>', true, false, true)
                    vim.cmd.normal({ args = { '2' .. key }, bang = true })
                    assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
                ]=], disabled)
                rpc('nvim_input', tostring(count) .. '<C-i>')
                lua([=[
                    local target = ...
                    assert(vim.wait(1000, function() return vim.api.nvim_win_get_cursor(0)[1] == target end, 5),
                        'Ctrl+i did not retain native counted jump-forward movement')
                ]=], count == 1 and 3 or 5)
            end
        end
    end)

    test('native BudouX rows support screen motions, character selection, yank and mouse', function()
        local result = lua([=[
            local source = '今日は天気がいいから散歩しましょう。'
            setup({source})
            local result = { rows = rows(2), padding = padding_count(), yanks = {}, motions = {} }
            for _, command in ipairs({'gg0g$', 'gg0gj', 'gg0gjg0', 'gg0gjgk'}) do
                vim.cmd('normal! ' .. command)
                result.motions[#result.motions + 1] = vim.api.nvim_win_get_cursor(0)
            end
            for _, command in ipairs({'gg0yg$', 'gg0gjg0vg$y', 'gg0yy'}) do
                vim.cmd('normal! ' .. command)
                result.yanks[#result.yanks + 1] = vim.fn.getreg('"')
            end
            result.source = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            require('inkstone.state').get(vim.api.nvim_get_current_buf()).anti_conceal.enabled = true
            refresh()
            result.anti_conceal = { padding_count(), rows(2) }
            return result
        ]=])
        equal(result.rows, { '今日は天気がいいから', '散歩しましょう。' })
        equal(result.padding, 1)
        equal(result.motions, { { 1, 27 }, { 1, 30 }, { 1, 30 }, { 1, 0 } })
        equal(result.yanks, { '今日は天気がいいから', '散歩しましょう。', '今日は天気がいいから散歩しましょう。\n' })
        rpc('nvim_input_mouse', 'left', 'press', '', 0, 1, 0)
        rpc('nvim_input_mouse', 'left', 'release', '', 0, 1, 0)
        equal(lua('return vim.api.nvim_win_get_cursor(0)'), { 1, 30 })
        equal(result.source, { '今日は天気がいいから散歩しましょう。' })
        equal(result.anti_conceal, { 1, { '今日は天気がいいから', '散歩しましょう。' } })
    end)

    test('native wrapping keeps English words and restores the original linebreak option', function()
        equal(lua([=[
            setup({'English 今日は天気がいいから散歩しましょう。'})
            local result = { rows(2), vim.wo.linebreak }
            require('inkstone').disable()
            assert(vim.wait(1000, function() return vim.wo.linebreak end, 5))
            result[3] = vim.wo.linebreak
            return result
        ]=]), { { 'English 今日は天気が', 'いいから散歩しましょう。' }, false, true })
    end)

    test('Visual modes temporarily reveal source in Markdown and ACP buffers and restore on exit', function()
        for _, ft in ipairs({ 'markdown', 'lazyagent_acp' }) do
            lua([=[
                local ft = ...
                setup({'今日は天気がいいから散歩しましょう。'}, {
                    file_types = { 'markdown', 'lazyagent_acp' },
                    overrides = { filetype = { lazyagent_acp = { render_modes = { 'n', 't' }, typography = { enabled = false } } } },
                })
                if ft == 'lazyagent_acp' then
                    vim.treesitter.language.register('markdown', ft)
                    vim.bo.buftype, vim.bo.filetype = 'nofile', ft
                    require('inkstone.state').cache[vim.api.nvim_get_current_buf()] = nil
                    refresh()
                end
            ]=], ft)
            for _, visual in ipairs({ { 'v', 'v' }, { 'V', 'V' }, { '<C-v>', '\22' } }) do
                rpc('nvim_input', visual[1])
                equal(lua([=[
                    local mode = ...
                    assert(vim.wait(1000, function() return vim.fn.mode() == mode end, 5))
                    vim.wait(150)
                    return { padding_count(), rows(2), vim.wo.linebreak, vim.wo.conceallevel }
                ]=], visual[2]), { 0, { '今日は天気がいいから散歩', 'しましょう。' }, true, 0 })
                rpc('nvim_input', '<Esc>')
                equal(lua([=[
                    assert(vim.wait(1000, function() return vim.fn.mode() == 'n' end, 5))
                    vim.wait(150)
                    return { padding_count(), rows(2), vim.wo.linebreak, vim.wo.conceallevel }
                ]=]), { 1, { '今日は天気がいいから', '散歩しましょう。' }, false, 3 })
            end
            rpc('nvim_input', 'v')
            lua([=[
                assert(vim.wait(1000, function() return vim.fn.mode() == 'v' end, 5))
                vim.wait(150)
            ]=])
            rpc('nvim_input', 'g$')
            rpc('nvim_input', 'y')
            equal(lua([=[
                assert(vim.wait(1000, function() return vim.fn.mode() == 'n' end, 5))
                return vim.fn.getreg('"')
            ]=]), '今日は天気がいいから散歩')
        end
    end)

    test('Visual reveals Markdown delimiters and can explicitly opt into rendering', function()
        lua("setup({'# Title', '', '**bold** text'})")
        rpc('nvim_input', 'v')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'v' end, 5))
            vim.wait(150)
            return rows(3)
        ]=]), { '# Title', '', '**bold** text' })
        rpc('nvim_input', '<Esc>')
        lua("setup({'今日は天気がいいから散歩しましょう。'}, { render_modes = { 'n', 'v' } })")
        rpc('nvim_input', 'v')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'v' end, 5))
            vim.wait(150)
            return { padding_count(), rows(2), vim.wo.conceallevel }
        ]=]), { 1, { '今日は天気がいいから', '散歩しましょう。' }, 3 })
        rpc('nvim_input', '<Esc>')
    end)

    test('pending operators keep native rows across ModeChanged events', function()
        lua("setup({'今日は天気がいいから散歩しましょう。'})")
        rpc('nvim_input', 'y')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode(1):sub(1, 2) == 'no' end, 5))
            vim.wait(150)
            return { padding_count(), rows(2), vim.wo.linebreak }
        ]=]), { 1, { '今日は天気がいいから', '散歩しましょう。' }, false })
        rpc('nvim_input', 'g$')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'n' end, 5))
            return vim.fn.getreg('"')
        ]=]), '今日は天気がいいから')
    end)

    local function commandline_roundtrip(noice)
        lua([=[
            setup({'今日は天気がいいから散歩しましょう。'}, { render_modes = { 'n', 't' } })
            _G.commandline_clears = {}
            local updater = require('inkstone.core.ui').updater
            _G.original_clear = updater.clear
            updater.clear = function(self, ...)
                commandline_clears[#commandline_clears + 1] = self.mode
                return original_clear(self, ...)
            end
        ]=])
        for _, entry in ipairs({ ':let g:inkstone_cmdline_probe=1', '/散歩', '?天気' }) do
            for _, leave in ipairs({ '<Esc>', '<CR>' }) do
                rpc('nvim_input', entry)
                equal(lua([=[
                    assert(vim.wait(1000, function() return vim.fn.mode() == 'c' end, 5))
                    vim.wait(150)
                    return { padding_count(), rows(2), vim.wo.linebreak, vim.wo.conceallevel }
                ]=]), { 1, { '今日は天気がいいから', '散歩しましょう。' }, false, 3 })
                if noice then
                    equal(lua([=[
                        for _, win in ipairs(vim.api.nvim_list_wins()) do
                            if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'noice' then return true end
                        end
                        return false
                    ]=]), true)
                end
                rpc('nvim_input', leave)
                equal(lua([=[
                    assert(vim.wait(1000, function() return vim.fn.mode() == 'n' end, 5))
                    vim.wait(150)
                    return { padding_count(), rows(2), vim.wo.linebreak, vim.wo.conceallevel }
                ]=]), { 1, { '今日は天気がいいから', '散歩しましょう。' }, false, 3 })
            end
        end
        equal(lua([=[
            require('inkstone.core.ui').updater.clear = original_clear
            return commandline_clears
        ]=]), {})
    end

    test('command and search roundtrips preserve native decorations when c is omitted', commandline_roundtrip)

    test('native wrapping accounts for breakindent, showbreak, gutters and paragraph padding', function()
        equal(lua([=[
            setup({' 今日は天気がいいから散歩しましょう。'})
            vim.wo.breakindent = true
            refresh()
            local result = { rows(2) }
            vim.wo.showbreak = '> '
            refresh()
            result[2] = rows(2)
            vim.wo.number = true
            refresh()
            vim.cmd('normal! gg0gjg0yg$')
            result[3] = vim.fn.getreg('"')
            setup({'今日は天気がいいから散歩しましょう。'}, { paragraph = { left_margin = 2, indent = 2 } })
            result[4] = rows(2)
            return result
        ]=]), {
            { ' 今日は天気がいいから', ' 散歩しましょう。' },
            { ' 今日は天気がいいから', ' > 散歩しましょう。' },
            'いいから',
            { '    今日は天気がいいから', '  散歩しましょう。' },
        })
    end)

    test('native rows preserve whitespace, clusters, hard newlines and survive delete/undo', function()
        equal(lua([=[
            local source = 'abc   def ghijk   日本語の文章です。がｶﾞ👩‍💻👍🏽'
            setup({source, '次の行です。  ', '最後です。\\'})
            local joined, seen = {}, {}
            vim.cmd('normal! gg0')
            for _ = 1, 20 do
                vim.cmd('normal! g0')
                local cursor = vim.api.nvim_win_get_cursor(0)
                if cursor[1] ~= 1 or seen[cursor[2]] then break end
                seen[cursor[2]] = true
                vim.cmd('normal! yg$')
                joined[#joined + 1] = vim.fn.getreg('"')
                vim.cmd('normal! gj')
            end
            local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            vim.cmd('let &undolevels = &undolevels')
            vim.cmd('normal! gg0dg$')
            refresh()
            vim.cmd('normal! u')
            refresh()
            return { table.concat(joined), vim.deep_equal(before, vim.api.nvim_buf_get_lines(0, 0, -1, false)) }
        ]=]), { 'abc   def ghijk   日本語の文章です。がｶﾞ👩‍💻👍🏽', true })
    end)

    test('source wrapping remains stable through anti-conceal and Markdown decorations', function()
        local function decorated(wrap)
            return lua([=[
            local wrap = ...
            setup({'今日は**天気が**いいから散歩しましょう。'}, {
                anti_conceal = { enabled = false }, paragraph = { wrap = wrap },
                win_options = { linebreak = { default = true, rendered = false } },
            })
            local result = { rows(2) }
            vim.cmd('normal! gg0yg$')
            result[2] = vim.fn.getreg('"')
            local config = require('inkstone.state').get(vim.api.nvim_get_current_buf())
            config.anti_conceal.enabled = true
            refresh()
            result[3] = padding_count()
            vim.cmd('normal! gg0gjg0yg$')
            result[4] = vim.fn.getreg('"')
            local source = ('日本語の [リンク](https://example.org) を読みます。'):rep(4)
            setup({source})
            vim.cmd('normal! gg0yy')
            -- Four link icons survive, with no additional wrap padding.
            result[5] = padding_count() == 4 and vim.fn.getreg('"') == source .. '\n'
            return result
            ]=], wrap)
        end
        -- This source fills a native row, so it needs no padding. Neovim's
        -- conceal-aware wrap changes where that native row ends; compare with
        -- the installed editor's own behavior instead of pinning an old split.
        local expected, actual = decorated(false), decorated(true)
        equal(actual, expected)
        equal(table.concat(actual[1]), '今日は天気がいいから散歩しましょう。')
        equal(actual[2] .. actual[4], '今日は**天気が**いいから散歩しましょう。')
        equal(actual[3], 0)
        equal(actual[5], true)
    end)

    test('shared windows and nowrap use source wrapping and closing a split restores BudouX', function()
        equal(lua([=[
            setup({'今日は天気がいいから散歩しましょう。'})
            local buf = vim.api.nvim_get_current_buf()
            local result = { padding_count() > 0 }
            vim.cmd('vsplit')
            assert(vim.wait(1000, function() return padding_count() == 0 end, 5))
            result[2] = padding_count()
            vim.cmd('close')
            assert(vim.wait(1000, function() return padding_count() > 0 end, 5))
            result[3] = rows(2)
            vim.wo.wrap = false
            refresh()
            result[4] = padding_count()
            vim.wo.wrap = true
            refresh()
            result[5] = rows(2)
            return result
        ]=]), { true, 0, { '今日は天気がいいから', '散歩しましょう。' }, 0, { '今日は天気がいいから', '散歩しましょう。' } })
    end)

    test('resize and source edits recompute native BudouX boundaries', function()
        rpc('nvim_ui_try_resize', 30, 20)
        equal(lua([=[
            setup({'今日は天気がいいから散歩しましょう。'})
            local result = { rows(2) }
            vim.api.nvim_buf_set_text(0, 0, 0, 0, 0, {'日本語。'})
            refresh()
            vim.cmd('normal! gg0yg$')
            result[2] = vim.fn.getreg('"')
            return result
        ]=]), { { '今日は天気がいいから', '散歩しましょう。' }, '日本語。今日は天気がいいから' })
        rpc('nvim_ui_try_resize', 24, 20)
        equal(lua('refresh(); return rows(2)'), { '日本語。今日は天気が', 'いいから散歩しましょう。' })
    end)

    test('native layout settings and window lifetime restore owned options', function()
        equal(lua([=[
            setup({'今日は天気がいいから散歩しましょう。'})
            local config = require('inkstone.state').get(vim.api.nvim_get_current_buf())
            config.paragraph.japanese.budoux = false
            refresh()
            vim.cmd('normal! gg0yg$')
            local result = { vim.fn.getreg('"') }
            config.paragraph.wrap = false
            refresh()
            result[2] = vim.wo.linebreak
            config.paragraph.wrap = true
            refresh()
            result[3] = vim.wo.linebreak
            vim.cmd('enew!')
            result[4] = vim.wo.linebreak
            setup({' abcdefghijklmnopqrstuvwxyz'})
            result[5] = rows(2)
            setup({'今日は天気がいいから散歩しましょう。'}, {
                win_options = { linebreak = { default = true, rendered = true } },
            })
            result[6] = { vim.wo.linebreak, padding_count() }
            return result
        ]=]), {
            '今日は天気がいいから散歩', true, false, true,
            { ' abcdefghijklmnopqrstuvw', 'xyz' }, { true, 0 },
        })
    end)

    test('editing a decorated scratch keeps inactive buffer layout and window options', function()
        lua([=[
            setup({'今日は天気がいいから散歩しましょう。'})
            _G.background_win, _G.background_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
            _G.scratch_buf = vim.api.nvim_create_buf(false, true)
            _G.scratch_win = vim.api.nvim_open_win(scratch_buf, true, {
                relative = 'editor', row = 1, col = 4, width = 16, height = 6, style = 'minimal', border = 'single',
            })
            vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { 'scratch', '', '```lua', 'print(1)', '```' })
            require('inkstone.state').get(scratch_buf, {
                paragraph = { wrap = false, join = false }, typography = { enabled = false }, render_modes = { 'n', 't' },
            })
            vim.bo[scratch_buf].filetype = 'markdown'
            vim.treesitter.start(scratch_buf, 'markdown')
            require('inkstone.api').render({ buf = scratch_buf })
            vim.wait(150)
        ]=])
        rpc('nvim_input', 'i')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'i' end, 5))
            -- Scratch-local geometry/decoration changes schedule background
            -- refreshes through the ordinary OptionSet handler.
            vim.wo.number = true
            vim.wait(200)
            local shown = 0
            for _, mark in ipairs(require('inkstone.core.ui').cache[background_buf]:get()) do
                if mark:shown() and mark:get().opts.virt_text_pos == 'inline' then shown = shown + 1 end
            end
            return { shown, vim.wo[background_win].conceallevel, vim.wo[background_win].linebreak,
                vim.wo[scratch_win].conceallevel }
        ]=]), { 1, 3, false, 0 })
        rpc('nvim_input', '<Esc>')
        lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'n' end, 5))
            vim.api.nvim_win_close(scratch_win, true)
        ]=])
    end)

    local data = vim.fn.stdpath('data')
    local noice = vim.env.INKSTONE_NOICE_RTP or (data .. '/lazy/noice.nvim')
    local nui = vim.env.INKSTONE_NUI_RTP or (data .. '/lazy/nui.nvim')
    if vim.fn.filereadable(noice .. '/lua/noice/init.lua') == 1 and vim.fn.filereadable(nui .. '/lua/nui/popup/init.lua') == 1 then
        test('Noice command and search popups preserve native decorations on accept and cancel', function()
            lua([=[
                local noice, nui = ...
                vim.opt.rtp:append(noice)
                vim.opt.rtp:append(nui)
                require('noice').setup({
                    cmdline = { enabled = true, view = 'cmdline_popup' },
                    popupmenu = { enabled = false }, notify = { enabled = false },
                    messages = { view = 'mini', view_error = 'mini', view_warn = 'mini', view_search = false },
                    lsp = { progress = { enabled = false }, hover = { enabled = false }, signature = { enabled = false } },
                    health = { checker = false },
                    views = { cmdline_popup = { position = { row = 12, col = 0 }, size = { width = 20, height = 1 } } },
                })
                assert(vim.wait(2000, function() return require('noice.config').is_running() end, 5))
                assert(require('noice.ui')._attached, 'Noice did not attach its UI')
            ]=], noice, nui)
            commandline_roundtrip(true)
            lua("require('noice').disable()")
        end)
    else
        print('SKIP: Noice cmdline integration (set INKSTONE_NOICE_RTP and INKSTONE_NUI_RTP)')
    end

    pcall(rpc, 'nvim_command', 'qa!')
    vim.fn.jobstop(child)
end
