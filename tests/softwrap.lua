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

    test('interactive selection and pending operators keep native rows across ModeChanged events', function()
        lua("setup({'今日は天気がいいから散歩しましょう。'})")
        rpc('nvim_input', 'v')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'v' end, 5))
            vim.wait(150)
            return { padding_count(), rows(2), vim.wo.linebreak }
        ]=]), { 1, { '今日は天気がいいから', '散歩しましょう。' }, false })
        rpc('nvim_input', 'g$')
        rpc('nvim_input', 'y')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'n' end, 5))
            return vim.fn.getreg('"')
        ]=]), '今日は天気がいいから')
        rpc('nvim_input', 'V')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'V' end, 5))
            vim.wait(150)
            return { padding_count(), rows(2) }
        ]=]), { 1, { '今日は天気がいいから', '散歩しましょう。' } })
        rpc('nvim_input', 'y')
        equal(lua([=[
            assert(vim.wait(1000, function() return vim.fn.mode() == 'n' end, 5))
            return vim.fn.getreg('"')
        ]=]), '今日は天気がいいから散歩しましょう。\n')
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
        equal(lua([=[
            setup({'今日は**天気が**いいから散歩しましょう。'}, { anti_conceal = { enabled = false } })
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
        ]=]), { { '今日は天気がいいから', '散歩しましょう。' }, '今日は**天気が**いいから', 0, '散歩しましょう。', true })
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
