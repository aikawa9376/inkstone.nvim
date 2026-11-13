return function(test, equal, buffer)
    local targets = require('inkstone.core.link_targets')
    local links = require('inkstone.core.links')
    local function setup(lines)
        local buf = buffer(lines)
        vim.bo[buf].filetype = 'markdown'
        return buf
    end
    local function at(buf, row, col)
        return assert(targets.current(buf, { row, col })).target
    end

    test('link labels resolve destinations, references and text fragments without rendered marks', function()
        local url = 'https://example.org/page#:~:text=first,last%20(new'
        local line = '[test](https://example.org/a_(b)?x=1#part "title")'
        local buf = setup({ line, '', '[表示][ref] [ref][] [ref]', '',
            '[ref]: <file name.md> "title"', '', '[設計](' .. url .. ')', '',
            '![画像](assets/image.png) <https://example.org> <a@example.org>', '', '[[note.md|別名]]' })
        for col = 0, #line - 1 do equal(at(buf, 1, col), 'https://example.org/a_(b)?x=1#part') end
        equal(at(buf, 3, 2), 'file name.md')
        equal(at(buf, 3, #'[表示][ref] ['), 'file name.md')
        equal(at(buf, 3, #'[表示][ref] [ref][] ['), 'file name.md')
        equal(at(buf, 7, 2), url)
        equal(at(buf, 9, 3), 'assets/image.png')
        equal(at(buf, 9, #'![画像](assets/image.png) <ht'), 'https://example.org')
        equal(at(buf, 9, #'![画像](assets/image.png) <https://example.org> <a'), 'mailto:a@example.org')
        equal(at(buf, 11, #'[[note.md|'), 'note.md')
        equal(targets.current(buf, { 2, 0 }), nil)
        -- Source lookup must track a streaming edit before any UI render.
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '[test](https://example.org/new)' })
        equal(at(buf, 1, 3), 'https://example.org/new')
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '[複数行の', 'ラベル](https://example.org/multiline)' })
        equal(at(buf, 2, 3), 'https://example.org/multiline')
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('bare paths and URLs preserve line numbers, balanced parentheses and UTF-8 byte positions', function()
        local buf = setup({ '日本語 `lua/inkstone/core/links.lua:12:3` と README.md。',
            'See https://example.org/a_(b). and (https://example.org/second).',
            '[linked](path/to/file.md) other/file.lua:5' })
        equal(at(buf, 1, #'日本語 `lua/'), 'lua/inkstone/core/links.lua:12:3')
        equal(at(buf, 1, #'日本語 `lua/inkstone/core/links.lua:12:3` と '), 'README.md')
        equal(at(buf, 2, #'See https://example'), 'https://example.org/a_(b)')
        equal(at(buf, 2, #'See https://example.org/a_(b). and (https://'), 'https://example.org/second')
        local found = targets.collect(buf)
        equal(#found, 6)
        equal(found[5].target, 'path/to/file.md')
        equal(found[6].target, 'other/file.lua:5')
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('link navigation lands on labels, supports counts and stops at document boundaries', function()
        local buf = setup({ '先頭 [一番](https://one) [二番](https://two)', '',
            '次 `src/file.lua:12` と [三番](https://three)' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        links.jump(1)
        equal(vim.api.nvim_win_get_cursor(0), { 1, #'先頭 [' })
        equal(links.target(), 'https://one')
        vim.api.nvim_win_set_cursor(0, { 1, #'先頭 [一' })
        links.jump(1, 2)
        equal(links.target(), 'src/file.lua:12')
        links.jump(-1)
        equal(links.target(), 'https://two')
        links.jump(-1, 10)
        equal(links.target(), 'https://one')
        local first = vim.api.nvim_win_get_cursor(0)
        links.jump(-1)
        equal(vim.api.nvim_win_get_cursor(0), first)
        links.jump(1, 10)
        equal(links.target(), 'https://three')
        local last = vim.api.nvim_win_get_cursor(0)
        links.jump(1)
        equal(vim.api.nvim_win_get_cursor(0), last)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('gf and gx open the label destination through the existing system handler', function()
        local buf = setup({ '[test](https://example.org/a?x=1#part)', '', 'plain words' })
        links.attach(buf)
        vim.api.nvim_win_set_cursor(0, { 1, 3 })
        local opened, open = {}, vim.ui.open
        vim.ui.open = function(target) opened[#opened + 1] = target end
        for _, key in ipairs({ 'gf', 'gx' }) do vim.fn.maparg(key, 'n', false, true).callback() end
        vim.ui.open = open
        equal(opened, { 'https://example.org/a?x=1#part', 'https://example.org/a?x=1#part' })
        equal(vim.api.nvim_win_get_cursor(0), { 1, 3 })
        vim.api.nvim_win_set_cursor(0, { 3, 3 })
        equal(links.open(false), false)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('file links resolve against the source document, decode escapes and honor line numbers', function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        local file = dir .. '/file name.md'
        vim.fn.writefile({ '# First', 'middle', '# 日本語見出し', 'last' }, file)
        for _, spec in ipairs({ { 'file%20name.md:2:3', { 2, 2 } },
            { 'file%20name.md#L4', { 4, 0 } }, { 'file%20name.md#日本語見出し', { 3, 0 } } }) do
            local buf = setup({ '[test](' .. spec[1] .. ')' })
            vim.api.nvim_buf_set_name(buf, dir .. '/source.md')
            vim.bo[buf].modified = false
            vim.api.nvim_win_set_cursor(0, { 1, 3 })
            assert(links.open(false))
            equal(vim.api.nvim_buf_get_name(0), file)
            equal(vim.api.nvim_win_get_cursor(0), spec[2])
            vim.api.nvim_buf_delete(buf, { force = true })
            vim.api.nvim_buf_delete(0, { force = true })
        end
        vim.fn.delete(dir, 'rf')
    end)

    test('link defaults preserve buffer integrations and fall back to existing global gx', function()
        local old_gx = vim.fn.maparg('gx', 'n', false, true)
        local calls = 0
        vim.keymap.set('n', 'gx', function() calls = calls + 1 end)
        local buf = setup({ 'plain words' })
        vim.keymap.set('n', 'gf', function() calls = calls + 10 end, { buffer = buf })
        vim.keymap.set('n', ']u', function() calls = calls + 100 end, { buffer = buf })
        links.attach(buf)
        for _, key in ipairs({ 'gf', 'gx', ']u' }) do vim.fn.maparg(key, 'n', false, true).callback() end
        equal(calls, 111)
        vim.api.nvim_buf_delete(buf, { force = true })
        if next(old_gx) then vim.fn.mapset('n', false, old_gx) else vim.keymap.del('n', 'gx') end
    end)
end
