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
