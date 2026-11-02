return function(test, equal, buffer)
    local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
    local binary = vim.env.INKSTONE_RASTER or root .. '/native/target/release/inkstone-raster'
    local typography = require('inkstone.core.typography')
    local images = require('inkstone.core.typography_image')
    local graphics = require('inkstone.lib.graphics')
    local ui = require('inkstone.core.ui')
    local function setup(command)
        require('inkstone').setup({ anti_conceal = { enabled = false }, media = { enabled = false },
            typography = { enabled = true, backend = 'image', image = { command = command,
                cache_dir = vim.fn.tempname() } } })
        local lines = { 'BEFORE', '', '# 日本語 **Heading**', '', 'AFTER' }
        local buf = buffer(lines)
        vim.bo[buf].filetype = 'markdown'
        vim.wo.conceallevel = 3
        vim.treesitter.start(buf, 'markdown')
        local parser = vim.treesitter.get_parser(buf, 'markdown')
        local function render()
            parser:parse(true)
            local context = require('inkstone.request.context').new(buf, vim.api.nvim_get_current_win(), require('inkstone.state').get(buf))
            return require('inkstone.core.handlers').run(context, parser), context
        end
        return buf, render, lines
    end

    if vim.fn.executable(binary) == 1 then
        test('Rust image headings keep native fallback until ready and reuse immutable assets', function()
            local supports, send, update = typography.supports, graphics.send, ui.update
            typography.supports, ui.update = function() return true end, function() end
            local packets = {}
            graphics.send = function(data) packets[#packets + 1] = data end
            local buf, render, source = setup({ binary })
            local first = render()
            for _, mark in ipairs(first) do assert(not mark.font_id, 'pending image must retain the normal renderer') end
            local function asset()
                local state = images.buffers[buf]
                return state and state.entries['heading:2'] and state.entries['heading:2'].asset
            end
            assert(vim.wait(3000, function() return asset() and asset().status == 'ready' end, 5), vim.inspect(images.assets))
            local ready = asset()
            local marks, context = render()
            assert(context.typography[1].image)
            local found = false
            for _, mark in ipairs(marks) do
                if mark.font_id then
                    for _, chunk in ipairs(mark.opts.virt_text or {}) do
                        found = found or chunk[1]:find(vim.fn.nr2char(0x10EEEE), 1, true) ~= nil
                    end
                end
            end
            assert(found, 'ready heading must use native placeholder extmarks')
            local sent = #packets
            render()
            equal(asset(), ready)
            equal(#packets, sent)
            typography.clear(buf, true)
            equal(asset(), ready, 'refreshing clear must not cancel the asset being reapplied')
            vim.api.nvim_set_hl(0, ready.highlight, {})
            render()
            equal(vim.api.nvim_get_hl(0, { name = ready.highlight }).fg, ready.id % 16777216)
            equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source)
            images.clear(buf)
            assert(images.buffers[buf] == nil and images.assets[ready.key] == nil)
            assert(packets[#packets]:find('d=I', 1, true), 'cleanup must delete only the owned image')
            typography.supports, graphics.send, ui.update = supports, send, update
            vim.api.nvim_buf_delete(buf, { force = true })
        end)
    else print('SKIP: Rust image headings (run make raster)') end

    test('failed raster jobs retain normal headings and do not retry each frame', function()
        local supports, update = typography.supports, ui.update
        typography.supports, ui.update = function() return true end, function() end
        local buf, render, source = setup({ 'false' })
        render()
        local function asset() return images.buffers[buf].entries['heading:2'].asset end
        assert(vim.wait(1000, function() return asset().status == 'failed' end, 5))
        local failed = asset()
        local marks = render()
        for _, mark in ipairs(marks) do assert(not mark.font_id) end
        equal(asset(), failed)
        equal(images.running, 0)
        equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source)
        images.clear(buf)
        typography.supports, ui.update = supports, update
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    test('cancelled raster jobs cannot publish images or revive disposed buffers', function()
        local supports, system, send, update = typography.supports, vim.system, graphics.send, ui.update
        typography.supports, ui.update = function() return true end, function() error('disposed request revived its buffer') end
        local completion, killed, packets = nil, 0, 0
        vim.system = function(_, _, callback)
            completion = callback
            return { kill = function() killed = killed + 1 end }
        end
        graphics.send = function() packets = packets + 1 end
        local buf, render = setup({ 'inkstone-cancel-test' })
        render()
        assert(completion)
        images.clear(buf)
        equal(killed, 1)
        completion({ code = 0, stdout = '\137PNG\r\n\26\nlate completion' })
        assert(vim.wait(1000, function() return images.running == 0 end, 5))
        equal(packets, 0)
        assert(images.buffers[buf] == nil and next(images.assets) == nil)
        typography.supports, vim.system, graphics.send, ui.update = supports, system, send, update
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end
