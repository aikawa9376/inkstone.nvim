return function(test, equal, buffer)
    local inkstone = require('inkstone')
    local Context = require('inkstone.request.context')
    local folds = require('inkstone.core.folds')
    local media = require('inkstone.core.media')
    local function parse(lines, opts)
        inkstone.setup(vim.tbl_deep_extend('force', { anti_conceal = { enabled = false }, media = { enabled = false } }, opts or {}))
        local buf = buffer(lines)
        vim.bo[buf].filetype = 'markdown'
        vim.wo.conceallevel = 3
        local parser = vim.treesitter.get_parser(buf, 'markdown')
        parser:parse(true)
        local ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
        ctx.view.ranges = { { 0, #lines } }
        return buf, parser, ctx, require('inkstone.core.handlers').run(ctx, parser)
    end

    test('overlapping inline trees render each source link once without inflating widths', function()
        local line = '[本体](https://github.com/one)・[設定](https://github.com/two)'
        local buf, parser = parse({ '', line, '' })
        local child = assert(parser:children().markdown_inline)
        local range = { 1, 0, 1, #line }
        child:set_included_regions({ { range }, { range } })
        child:parse(true)
        local roots = 0
        parser:for_each_tree(function(_, lt) if lt:lang() == 'markdown_inline' then roots = roots + 1 end end)
        equal(roots, 2, 'the real parser must expose overlapping source captures')
        for _ = 1, 2 do
            local ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
            local marks = require('inkstone.core.handlers').run(ctx, parser)
            local icons = {}
            for _, mark in ipairs(marks) do
                if mark.opts.virt_text_pos == 'inline' and mark.opts.priority == 9000 then
                    icons[#icons + 1] = mark.start_col
                end
            end
            equal(icons, { 0, #('[本体](https://github.com/one)・') })
            local body = { start_row = 1, start_col = 0, end_row = 1, end_col = #line, text = line }
            equal(#ctx.inline:get(body), 2)
            equal(ctx.inline:width(body), 2 * vim.fn.strdisplaywidth(ctx.config.link.custom.github.icon))
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('text fragment recovery is limited to rejected URLs and keeps neighboring source intact', function()
        local url = 'https://example.org/page#:~:text=first,last%20(new'
        local link = '[設計](' .. url .. ')'
        local source = link .. '[別](' .. url .. ') 終わり'
        local lines = { source, '', '[普通](https://example.org/(new)', '',
            '`' .. link .. '`', '', '```markdown', link, '```' }
        local buf, _, ctx, marks = parse(lines, { code = { enabled = false }, folds = { enabled = false } })
        local icons = {}
        for _, mark in ipairs(marks) do
            if mark.link_range then
                equal(mark.start_row, 0)
                icons[#icons + 1] = { mark.start_col, mark.link_range[4] }
            end
        end
        equal(icons, { { 0, #link }, { #link, #source - #' 終わり' } })
        local body = { start_row = 0, end_row = 0, start_col = 0, end_col = #source, text = source }
        equal(ctx:width(body), vim.fn.strdisplaywidth('󰖟 設計󰖟 別 終わり'))
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
        vim.api.nvim_buf_delete(buf, { force = true })
        buf, _, _, marks = parse({ link }, { link = { enabled = false } })
        equal(marks, {})
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('table heading borders preserve color with opt-in RGB and cterm bold', function()
        local colors = require('inkstone.core.colors')
        local source = 'InkstoneTestTableHead'
        vim.api.nvim_set_hl(0, source, { fg = 0x89abcd, bg = 0x102030, bold = true,
            italic = true, ctermfg = 12, cterm = { bold = true, italic = true } })
        local groups = {}
        for _, bold in ipairs({ false, true }) do
            for _, virtual in ipairs({ false, true }) do
                local delim = virtual and string.rep('-', 200) or '---'
                local buf, _, ctx, marks = parse({ '', '| Name | Value |',
                    '| ' .. delim .. ' | --- |', '| A | 1 |', '' }, {
                    pipe_table = { head = source, head_bold = bold },
                })
                equal(ctx.config.pipe_table.head_bold, bold)
                equal(require('inkstone.state').validate(), {})
                local found = {}
                local function check(line)
                    for _, chunk in ipairs(line) do
                        for _, glyph in ipairs({ '┌', '├' }) do
                            if chunk[1]:find(glyph, 1, true) then
                                found[glyph] = true
                                local hl = vim.api.nvim_get_hl(0, { name = chunk[2], link = false })
                                equal({ hl.fg, hl.bg, hl.italic, hl.bold == true },
                                    { 0x89abcd, 0x102030, true, bold })
                                equal({ hl.ctermfg, hl.cterm.italic, hl.cterm.bold == true }, { 12, true, bold })
                                groups[bold and 'on' or 'off'] = chunk[2]
                            end
                        end
                    end
                end
                for _, mark in ipairs(marks) do
                    if mark.opts.virt_text then check(mark.opts.virt_text) end
                    for _, line in ipairs(mark.opts.virt_lines or {}) do check(line) end
                    for _, line in ipairs(mark.replace or {}) do check(line) end
                end
                assert(found['┌'] and found['├'], 'top border and delimiter must both be styled')
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        assert(groups.on ~= groups.off, 'buffer-specific bold must not mutate a shared group')
        assert(vim.api.nvim_get_hl(0, { name = source, link = false }).bold)
        assert(not vim.api.nvim_get_hl(0, { name = groups.off, link = false }).bold)
        vim.api.nvim_set_hl(0, source, { fg = 0x556677, bold = true })
        colors.reload()
        for name, group in pairs(groups) do
            local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
            equal({ hl.fg, hl.bold == true }, { 0x556677, name == 'on' })
        end
        equal(inkstone.default.pipe_table.head_bold, false)
    end)

    test('code examples exclude injected decorations, folds, media and table views by default', function()
        local typography = require('inkstone.core.typography')
        local supports = typography.supports
        typography.supports = function() return true end
        local lines = { '# Outside', '', '![outside](outside.png)', '' }
        local first = #lines
        vim.list_extend(lines, {
            '````markdown', '# Literal heading', '', '- [x] literal checkbox', '',
            '| Name | Value |', '| --- | --- |', '| A | 1 |', '',
            '> [!NOTE]- Literal callout', '> body', '',
            '<details>', '<summary>Literal details</summary>', '', 'body', '', '</details>', '',
            '![literal](inside.png)', '', '<small>literal small</small>', '',
            '```mermaid', 'graph LR', 'A-->B', '```', '````', '',
            '~~~md', '# Another literal heading', '[link](https://example.com)', '~~~', '',
            '```html', '<!-- literal comment -->', '<small>literal small</small>', '```', '',
            '```yaml', '- literal bullet', '```', '',
            '```latex', '\\alpha', '```', '',
            '    # Indented code', '    <!-- literal comment -->', '',
            '```markdown', '# Unclosed literal heading', '', '![literal](unclosed.png)',
        })
        local buf, parser, ctx, marks = parse(lines, {
            code = { enabled = false }, folds = { code = false },
            pipe_table = { view = 'list' }, media = { enabled = true },
            typography = { enabled = true }, display_compat = { enabled = false },
        })
        typography.supports = supports
        equal(require('inkstone.state').nested, false)
        assert(#marks > 0, 'normal Markdown must still render')
        for _, mark in ipairs(marks) do
            assert(mark.start_row < first, 'decoration inside code: ' .. vim.inspect(mark))
        end
        equal(vim.tbl_map(function(item) return item.row end, ctx.media), { 2 })
        equal(folds.blocks(buf, parser, ctx.config.folds), {})
        equal(next(ctx.table_views), nil)
        equal(#ctx.typography, 1)
        equal(ctx.typography[1].row, 0)
        ctx.view.ranges = { { first + 1, first + 8 } }
        equal(require('inkstone.core.handlers').run(ctx, parser), {})
        equal(ctx.view.ranges, { { first + 1, first + 8 } })
        vim.api.nvim_win_set_cursor(0, { 10, 0 })
        require('inkstone.core.table_views').toggle(buf, vim.api.nvim_get_current_win(), 'list')
        vim.wait(50, function() return require('inkstone.core.table_views').cache[buf] ~= nil end, 5)
        equal(require('inkstone.core.table_views').cache[buf], nil)
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('Markdown injected outside code remains renderable in a non-Markdown host', function()
        vim.treesitter.query.set('html', 'injections', [[
            (element (text) @injection.content (#set! injection.language "markdown"))
        ]])
        inkstone.setup({ anti_conceal = { enabled = false }, code = { enabled = false },
            media = { enabled = false }, typography = { enabled = false },
            folds = { code = false }, display_compat = { enabled = false } })
        local buf = buffer({ '<div>', '# Injected heading', '', '```markdown',
            '# Literal heading', '```', '</div>' })
        local parser = vim.treesitter.get_parser(buf, 'html')
        parser:parse(true)
        local ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
        local marks = require('inkstone.core.handlers').run(ctx, parser)
        vim.treesitter.query.set('html', 'injections', nil)
        assert(#marks > 0, 'the first Markdown injection must still render')
        for _, mark in ipairs(marks) do
            assert(mark.start_row < 3, 'nested code in an injected document must stay literal')
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('nested rendering remains an explicit opt-in and preserves outer code decoration', function()
        local lines = { '````markdown', '# Inner heading', '',
            '![inner](inside.png)', '', '> [!NOTE]- Inner', '> body', '````' }
        local buf, _, _, marks = parse(lines)
        assert(#marks > 0, 'the outer code block should retain its background and borders')
        for _, mark in ipairs(marks) do
            assert(not mark.replace and not mark.folded, 'code contents must remain literal')
        end
        vim.api.nvim_buf_delete(buf, { force = true })
        local enabled, parser, ctx, nested = parse(lines, { nested = true,
            code = { enabled = false }, folds = { code = false }, media = { enabled = true },
            typography = { enabled = false }, display_compat = { enabled = false } })
        assert(#nested > 0, 'nested=true should still decorate injected Markdown')
        equal(#ctx.media, 1)
        equal(#folds.blocks(enabled, parser, ctx.config.folds), 1)
        vim.api.nvim_buf_delete(enabled, { force = true })
    end)

    test('conceal summaries batch work and display slices preserve overlapping styles', function()
        local buf, _, ctx = parse({ 'abcdefgh' })
        vim.treesitter.stop(buf)
        local Highlights = require('inkstone.request.highlights')
        ctx.highlights = Highlights.new(buf, ctx.view)
        local original, calls = Highlights.coalesce_conceals, 0
        Highlights.coalesce_conceals = function(...) calls = calls + 1; return original(...) end
        for i = 1, 1000 do
            ctx.highlights:add(0, { conceal = { i * 2, i * 2 + 1, replacement = '', blocks = 1 } })
        end
        equal(calls, 0)
        ctx.highlights:line(0)
        ctx.highlights:line(0)
        equal(calls, 1)
        Highlights.coalesce_conceals = original
        ctx.highlights = Highlights.new(buf, ctx.view)
        ctx.highlights:add(0, { group = { 0, 4, highlight = 'String', priority = 100 } })
        ctx.highlights:add(0, { group = { 3, 7, highlight = 'Special', priority = 200 } })
        ctx.highlights:add(0, { conceal = { 2, 3, replacement = '', blocks = 1 } })
        ctx.inline:add(0, { col = 3, line = { { 'X', 'Comment' } } })
        ctx.inline:add(0, { col = 6, line = { { 'Z', 'Comment' } } })
        equal(require('inkstone.lib.display').line(ctx, { start_row = 0, end_row = 0, start_col = 2, end_col = 6, text = 'cdef' }), {
            { 'X', 'Comment' }, { 'd', { 'InkstonePadding', 'String', 'Special' } },
            { 'ef', { 'InkstonePadding', 'Special' } }, { 'Z', 'Comment' },
        })
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('multiline highlight ranges are clipped per row and bounded to disjoint views', function()
        local lines = { ('─'):rep(40) }
        for i = 2, 1000 do lines[i] = '行ごとのハイライトです。' end
        local buf = buffer(lines)
        local tree = vim.treesitter.get_parser(buf, 'markdown'):parse(true)[1]
        local view = require('inkstone.request.view').new(buf)
        view.ranges = { { 100, 102 }, { 800, 802 } }
        local highlights = require('inkstone.request.highlights').new(buf, view)
        local get_lines, read = vim.api.nvim_buf_get_lines, 0
        vim.api.nvim_buf_get_lines = function(...)
            local result = get_lines(...)
            read = read + #result
            return result
        end
        highlights:tree('markdown', tree:root())
        vim.api.nvim_buf_get_lines = get_lines
        equal(read, 6)
        local rows = vim.tbl_keys(highlights.lines)
        table.sort(rows)
        equal(rows, { 100, 101, 102, 800, 801, 802 })
        for _, row in ipairs(rows) do
            local spell = {}
            for _, group in ipairs(highlights.lines[row].groups) do
                if group.highlight == '@spell.markdown' then spell[#spell + 1] = { group[1], group[2] } end
            end
            equal(spell, { { 0, #lines[row + 1] } })
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('paragraph wrapping preserves source newlines by default and joining is independent', function()
        local wrap = require('inkstone.text.paragraph').wrap
        local function row(text, hard) return { line = { { text, 'String' } }, hard = hard } end
        equal(wrap({ row('日本語'), row('の段落'), row('English'), row('words') }, 40), {
            { { '日本語', 'String' } }, { { 'の段落', 'String' } },
            { { 'English', 'String' } }, { { 'words', 'String' } },
        })
        local first = ('今日は天気がいいから散歩しましょう。'):rep(12)
        local second = ('長い文章も意味のまとまりで折り返します。'):rep(12)
        local last = 'ここは次の行です。'
        local original = { 'BEFORE', '', first, second, last, '', 'AFTER' }
        local buf, parser, ctx, marks = parse(original)
        equal(ctx.config.paragraph.wrap, true)
        equal(ctx.config.paragraph.join, false)
        local function rows(marks)
            local result = {}
            for _, mark in ipairs(marks) do
                for _, line in ipairs(mark.replace or {}) do
                    local text = {}; for _, chunk in ipairs(line) do text[#text + 1] = chunk[1] end
                    result[#result + 1] = table.concat(text)
                end
            end
            return result
        end
        local width = ctx:window_width()
        equal(rows(marks), {})
        assert(vim.iter(marks):any(function(mark) return mark.opts.virt_text_pos == 'inline' end))
        local function render()
            local fresh = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
            fresh.view.ranges = { { 0, #original } }
            return require('inkstone.core.handlers').run(fresh, parser)
        end
        -- Change only display settings: cache results must follow both flags.
        ctx.config.paragraph.join = true
        equal(rows(render()), require('inkstone.text').wrap(first .. second .. last, width))
        ctx.config.paragraph.wrap = false
        equal(rows(render()), { first .. second .. last })
        ctx.config.paragraph.join = false
        equal(rows(render()), {})
        ctx.config.paragraph.wrap = true
        equal(rows(render()), {})
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('replacement rows retain foreign range highlights without importing old renderer marks', function()
        local original = { '─ Assistant ' .. ('─'):rep(12), ('日本語の本文です。'):rep(15), '', 'AFTER' }
        local buf, parser, ctx = parse(original, { paragraph = { join = true } })
        local foreign = vim.api.nvim_create_namespace('lazyagent-test-transcript')
        vim.api.nvim_buf_set_extmark(buf, foreign, 0, 0, {
            end_col = #original[1], hl_group = 'DiagnosticInfo', priority = 200,
        })
        vim.api.nvim_buf_set_extmark(buf, foreign, 0, 4, {
            end_row = 1, end_col = #'日本語', hl_group = 'Special', priority = 250,
        })
        vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace('inkstone.nvim'), 0, 0, {
            end_col = #original[1], hl_group = 'Error', priority = 300,
        })
        local function render()
            ctx = Context.new(buf, vim.api.nvim_get_current_win(), ctx.config)
            ctx._width = 30
            return require('inkstone.core.handlers').run(ctx, parser)
        end
        local function styled(marks, target)
            local result = {}
            for _, mark in ipairs(marks) do
                for _, line in ipairs(mark.replace or {}) do
                    for _, chunk in ipairs(line) do
                        local groups = type(chunk[2]) == 'table' and chunk[2] or { chunk[2] }
                        assert(not vim.tbl_contains(groups, 'Error'), 'previous renderer styles leaked')
                        if vim.tbl_contains(groups, target) then result[#result + 1] = chunk[1] end
                    end
                end
            end
            return table.concat(result)
        end
        equal(styled(render(), 'DiagnosticInfo'), original[1] .. ' ')
        assert(styled(render(), 'Special'):find('日本語', 1, true))
        -- External changes must invalidate the layout even without a text edit.
        vim.api.nvim_buf_clear_namespace(buf, foreign, 0, -1)
        equal(styled(render(), 'DiagnosticInfo'), '')
        -- A range starting outside the viewport must still contribute there.
        vim.api.nvim_buf_set_extmark(buf, foreign, 0, 0, {
            end_row = 3, end_col = 0, hl_group = 'DiagnosticWarn', priority = 200,
        })
        vim.treesitter.stop(buf)
        local view = { ranges = { { 1, 1 }, { 3, 3 } } }
        local highlights = require('inkstone.request.highlights').new(buf, view)
        equal(highlights:line(1).groups, { { 0, #original[2], priority = 200, highlight = 'DiagnosticWarn' } })
        equal(highlights:line(3).groups, {})
        vim.api.nvim_buf_clear_namespace(buf, foreign, 0, -1)
        vim.api.nvim_buf_set_extmark(buf, foreign, 1, 0, {
            end_col = #'日本語', hl_eol = true, hl_group = 'Special', priority = 200,
        })
        highlights = require('inkstone.request.highlights').new(buf, view)
        equal(highlights:line(1).groups, { { 0, #'日本語', priority = 200, highlight = 'Special' } })
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('paragraph reflow joins soft breaks and retains hard breaks and highlights', function()
        local wrap = require('inkstone.text.paragraph').wrap
        local function row(s, hard) return { line = { { s, 'String' } }, hard = hard } end
        equal(wrap({ row('日本語'), row('の段落'), row('です。', true), row('English'), row('words') }, 40, {}, true), {
            { { '日本語の段落です。', 'String' } }, { { 'English words', 'String' } },
        })
        local original = { 'BEFORE', '', ' 日本語の段落を', ' 文節で折り返します。  ', ' English words follow.', '', 'AFTER' }
        local buf, _, _, marks = parse(original, { paragraph = { join = true } })
        local replacement
        for _, mark in ipairs(marks) do if mark.replace then replacement = mark; break end end
        assert(replacement)
        local rows = {}
        for _, line in ipairs(replacement.replace) do
            local chunks = {}; for _, chunk in ipairs(line) do chunks[#chunks + 1] = chunk[1] end
            rows[#rows + 1] = table.concat(chunks)
        end
        equal(rows, { ' 日本語の段落を文節で折り返します。', ' English words follow.' })
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original)
        -- Cursor restoration follows anti_conceal, including wrapped layouts.
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        local updater = require('inkstone.core.ui').updater.new(buf, vim.api.nvim_get_current_win(), true)
        updater.mode = 'n'
        local extmark = require('inkstone.lib.extmark').new(replacement)
        assert(not updater:hide(extmark, updater:hidden()))
        require('inkstone.state').get(buf).anti_conceal = { enabled = true, above = 0, below = 0, disabled_modes = {} }
        assert(updater:hide(extmark, updater:hidden()))
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('details render Markdown and code colors with or without blank HTML separators', function()
        local body = { '# Inside', '| Name | Value |', '| --- | --- |', '| A | B |',
            '- [x] Task', '[link](https://example.com)', '```lua', 'local answer = 42', '```' }
        for _, spaced in ipairs({ false, true }) do
            local lines = { '<details open>', '<summary><strong>Title</strong></summary>' }
            if spaced then lines[#lines + 1] = '' end
            vim.list_extend(lines, body)
            if spaced then lines[#lines + 1] = '' end
            lines[#lines + 1] = '</details>'
            local buf, parser, ctx, marks = parse(lines)
            local found = {}
            for _, mark in ipairs(marks) do found[tostring(mark.conceal)] = true end
            assert(found.head_icon and found.table_border and found.check_icon and found.link and found.code_background,
                'details must retain every normal Markdown component: ' .. vim.inspect(found))
            local blocks = folds.blocks(buf, parser, ctx.config.folds)
            equal(#blocks, 2)
            equal(blocks[1].title, 'Title')
            local lua_tree = false
            parser:for_each_tree(function(_, language) lua_tree = lua_tree or language:lang() == 'lua' end)
            assert(lua_tree, 'details code must have its normal Lua injection')
            assert(vim.iter(marks):any(function(mark) return mark.details_body end))
            equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end)

    test('details injections leave standalone HTML and HTML code examples literal', function()
        local buf = buffer({ '<details open>', '<summary>Title</summary>', '# Literal HTML body', '</details>' })
        vim.bo[buf].filetype = 'html'
        local parser = vim.treesitter.get_parser(buf, 'html')
        parser:parse(true)
        parser:for_each_tree(function(_, language) assert(language:lang() ~= 'markdown') end)
        vim.api.nvim_buf_delete(buf, { force = true })
        buf, parser = parse({ '```html', '<details open>', '<summary>Title</summary>', '# Literal example', '</details>', '```' })
        equal(vim.tbl_map(function(block) return block.kind end, folds.blocks(buf, parser, require('inkstone.state').get(buf).folds)), { 'code' })
        vim.api.nvim_buf_delete(buf, { force = true })
        local ctx, marks
        buf, parser, ctx, marks = parse({ '<details open>', '<summary>Outer</summary>', '```html',
            '<details>', '<summary>Literal</summary>', '# Literal example', '</details>', '```', '</details>' })
        equal(vim.tbl_map(function(block) return block.kind end, folds.blocks(buf, parser, ctx.config.folds)), { 'details', 'code' })
        for _, mark in ipairs(marks) do assert(mark.conceal ~= 'head_icon', 'HTML example inside details must stay literal') end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('code syntax fallback covers aliases, details and viewport ranges without duplicating a native highlighter', function()
        local cases = { { 'lua', 'lua', 'local answer = 42' }, { 'sh', 'bash', 'echo "hello"' },
            { 'py', 'python', 'answer = 42' }, { 'js', 'javascript', 'const answer = 42;' },
            { 'ts', 'typescript', 'const answer: number = 42;' }, { 'yml', 'yaml', 'answer: 42' } }
        for _, case in ipairs(cases) do
            if pcall(vim.treesitter.language.add, case[2]) then
                local lines = { '<details open>', '<summary>Code</summary>', '', '```' .. case[1], case[3], '```', '', '</details>' }
                local buf, parser, ctx = parse(lines)
                local function colors(native, enabled)
                    if native then vim.treesitter.start(buf, 'markdown') else vim.treesitter.stop(buf) end
                    ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
                    ctx.config.code.syntax = enabled
                    ctx.view.ranges = { { 0, #lines } }
                    local found = {}
                    for _, mark in ipairs(require('inkstone.core.handlers').run(ctx, parser)) do
                        if type(mark.opts.hl_group) == 'string' and mark.opts.hl_group:sub(1, 1) == '@' then
                            assert(mark.start_row == 4, 'syntax highlights escaped the code content')
                            found[#found + 1] = mark
                        end
                    end
                    return found
                end
                assert(#colors(false, true) > 0, 'missing syntax fallback for ' .. case[1])
                equal(#colors(true, true), 0)
                equal(#colors(false, false), 0)
                equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        local lines = { '```lua', '--[[' }
        for _ = 1, 1000 do lines[#lines + 1] = 'comment text' end
        vim.list_extend(lines, { ']]', '```' })
        local buf, parser = parse(lines)
        vim.treesitter.stop(buf)
        local ctx = Context.new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
        ctx.view.ranges = { { 10, 12 }, { 700, 702 } }
        local rows = {}
        for _, mark in ipairs(require('inkstone.core.handlers').run(ctx, parser)) do
            if mark.opts.hl_group == '@comment.lua' then rows[#rows + 1] = mark.start_row end
        end
        table.sort(rows)
        equal(rows, { 10, 11, 700, 701 })
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('code decoration covers indented blocks, open fences and final rows without a newline', function()
        for _, lines in ipairs({ { '```lua', 'local answer = 42' },
            { '```lua', 'local answer = 42', '```' }, { '    local answer = 42' } }) do
            local buf, parser, ctx = parse(lines, { code = { width = 'block', left_pad = 1, right_pad = 1 } })
            vim.bo[buf].endofline = false
            parser:parse(true)
            local marks = require('inkstone.core.handlers').run(ctx, parser)
            local body = #lines == 1 and 0 or 1
            local background = false
            for _, mark in ipairs(marks) do
                background = background or (mark.start_row == body and mark.conceal == 'code_background')
            end
            assert(background, 'code body lost its background at EOF: ' .. vim.inspect(lines))
            equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end)

    test('code language aliases preserve user registrations', function()
        local before = vim.treesitter.language.get_lang('js')
        vim.treesitter.language.register('lua', 'js')
        require('inkstone.core.code_syntax').register()
        equal(vim.treesitter.language.get_lang('js'), 'lua')
        vim.treesitter.language.register(before, 'js')
    end)

    test('folds distinguish fences, callouts and nested details and follow source edits', function()
        local lines = { 'BEFORE', '', '```html', '<details>', 'not a fold', '</details>', '```', '',
            '> [!NOTE]- Collapsed', '> callout body', '', '<details>', '<summary>Outer</summary>', '',
            '<details open>', '<summary>Inner</summary>', '', 'inner body', '', '</details>', '', '</details>', '', 'AFTER' }
        local buf, parser, ctx, marks = parse(lines)
        local blocks = folds.blocks(buf, parser, ctx.config.folds)
        equal(#blocks, 4)
        equal(vim.tbl_map(function(b) return { b.kind, b.closed } end, blocks), {
            { 'code', false }, { 'callout', true }, { 'details', true }, { 'details', false },
        })
        local concealed = {}
        for _, mark in ipairs(marks) do if mark.opts.conceal_lines then concealed[mark.start_row] = true end end
        assert(concealed[9] and concealed[12])
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
        folds.toggle(buf, vim.api.nvim_get_current_win())
        assert(vim.wait(1000, function() return folds.closed(buf, blocks[1]) end, 5))
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted', '' })
        parser:parse(true)
        blocks = folds.blocks(buf, parser, ctx.config.folds)
        assert(folds.closed(buf, blocks[1]))
        folds.toggle(buf, vim.api.nvim_get_current_win())
        assert(vim.wait(1000, function() return not folds.closed(buf, blocks[1]) end, 5))
        equal(vim.api.nvim_buf_get_lines(buf, 2, -1, false), lines)
        vim.api.nvim_buf_delete(buf, { force = true })
        equal(folds.cache[buf], nil)
    end)

    test('details summaries allow blank lines and toggling hidden code opens the parent first', function()
        local lines = { 'BEFORE', '', '<details>', '', '<summary>Heading Configuration</summary>', '',
            '```lua', 'print("body")', '```', '', '</details>', '', 'AFTER' }
        local buf, parser, ctx, marks = parse(lines)
        local blocks = folds.blocks(buf, parser, ctx.config.folds)
        equal({ blocks[1].title, blocks[1].summary_row }, { 'Heading Configuration', 4 })
        vim.api.nvim_win_set_cursor(0, { 8, 0 })
        folds.toggle(buf, vim.api.nvim_get_current_win())
        assert(vim.wait(1000, function() return not folds.closed(buf, blocks[1]) end, 5))
        assert(not folds.closed(buf, blocks[2]), 'hidden code must not be toggled')
        marks = folds.apply(ctx, parser, {})
        local hidden = {}
        for _, mark in ipairs(marks) do
            if mark.fold_hidden then hidden[#hidden + 1] = { mark.start_row, mark.opts.end_row or mark.start_row } end
        end
        equal(hidden, { { 3, 4 }, { 10, 10 } })
        vim.api.nvim_win_set_cursor(0, { 8, 0 })
        folds.toggle(buf, vim.api.nvim_get_current_win())
        assert(vim.wait(1000, function() return folds.closed(buf, blocks[2]) end, 5))
        assert(not folds.closed(buf, blocks[1]), 'expanded parent must allow child toggling')
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('a collapsed code fence retains its anchor even without a language heading', function()
        local buf, parser, ctx = parse({ 'BEFORE', '', '```', 'body', '```', '', 'AFTER' }, {
            code = { language = false },
        })
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        folds.toggle(buf, vim.api.nvim_get_current_win())
        local block = folds.blocks(buf, parser, ctx.config.folds)[1]
        assert(vim.wait(1000, function() return folds.closed(buf, block) end, 5))
        local marks = require('inkstone.core.handlers').run(ctx, parser)
        local anchor
        for _, mark in ipairs(marks) do
            assert(not (mark.start_row == 2 and mark.opts.conceal_lines), 'fold anchor was concealed')
            if mark.folded then anchor = mark end
        end
        assert(anchor and anchor.start_row == 2)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('media finds real image and diagram nodes and excludes folded contents', function()
        local buf, _, ctx = parse({ 'BEFORE', '', '![caption](assets/example%20image.png)', '',
            '```mermaid', 'graph LR', 'A-->B', '```', '', '```plantuml', '@startuml', 'A -> B', '@enduml', '```', '',
            '> [!NOTE]- Hidden', '> ![hidden](hidden.png)', '', 'AFTER' }, { media = { enabled = true } })
        equal(#ctx.media, 3)
        local kinds = {}; for _, item in ipairs(ctx.media) do kinds[item.kind] = item end
        assert(kinds.image.source:match('/assets/example image.png$'))
        assert(kinds.mermaid.source:find('A%-%->B'))
        assert(kinds.plantuml.source:find('@startuml', 1, true))
        equal(media.resolve(buf, 'https://example.com/a.png'), 'https://example.com/a.png')
        equal(media.resolve(buf, 'javascript:bad'), nil)
        equal(media.resolve(buf, 'bad%00path.png'), nil)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('media conversion uses async argv, caches output and reports missing tools', function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        local script = dir .. '/renderer.py'
        vim.fn.writefile({
            'import pathlib, sys, time',
            'args = sys.argv[1:]',
            'src = pathlib.Path(args[args.index("-i") + 1])',
            'time.sleep(0.05)',
            'pathlib.Path(args[args.index("-o") + 1]).write_bytes(src.read_bytes())',
        }, script)
        local config = vim.deepcopy(inkstone.default.media)
        config.cache_dir, config.mermaid_command = dir, { 'python3', script }
        local malicious = 'graph LR\nA["$(touch /tmp/inkstone-should-not-exist) `literal`"]-->B'
        local item = { kind = 'mermaid', source = malicious }
        local done, path, error = false
        media.convert(item, config, function(p, e) done, path, error = true, p, e end)
        assert(item.process and not done, 'conversion must not block the editor')
        assert(vim.wait(3000, function() return done end, 5), 'conversion timeout')
        assert(path, error)
        equal(table.concat(vim.fn.readfile(path), '\n'), malicious)
        local cached
        media.convert({ kind = 'mermaid', source = malicious }, config, function(p) cached = p end)
        equal(cached, path)
        config.mermaid_command = { 'inkstone-missing-renderer' }
        media.convert({ kind = 'mermaid', source = 'x' }, config, function(p, e) assert(not p and e:find('unavailable')) end)
        vim.fn.delete(dir, 'rf')
    end)

    test('media cleanup cancels work, rejects stale callbacks and avoids duplicate Snacks placements', function()
        local buf, _, ctx = parse({ 'BEFORE', '', '![image](sample.png)', '', 'AFTER' }, { media = { enabled = true } })
        local backend, convert = media.backend, media.convert
        local created, closed, killed, callback = 0, 0, 0
        media.backend = function() return { config = { enabled = true, doc = { enabled = true } }, placement = { new = function()
            created = created + 1
            return { close = function() closed = closed + 1 end }
        end } } end
        media.convert = function(entry, done_config, done)
            callback = done
            entry.process = { kill = function() killed = killed + 1 end }
        end
        media.update(ctx)
        media.clear(buf)
        callback('late.png')
        equal({ created, killed }, { 0, 1 })
        media.update(ctx)
        callback('sample.png')
        equal(created, 1)
        media.update(ctx)
        equal(created, 1)
        media.update(ctx, { 2, 2 })
        equal(closed, 1)
        vim.b[buf].snacks_image_attached = true
        media.update(ctx)
        equal(next(media.cache[buf]), nil)
        media.backend, media.convert = backend, convert
        vim.api.nvim_buf_delete(buf, { force = true })
        equal(media.cache[buf], nil)
    end)
end
