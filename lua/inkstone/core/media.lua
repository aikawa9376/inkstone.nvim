local M = { cache = {}, pending = {} }

-- Graphics are delegated to Snacks so tmux passthrough, terminal detection,
-- image conversion and placement stay owned by one graphics implementation.
function M.backend()
    local ok, snacks = pcall(require, 'snacks')
    if not ok then return nil, 'snacks.nvim is required for media rendering' end
    local image = snacks.image
    if not image or not image.supports_terminal() then
        return nil, 'The terminal does not support Snacks image rendering (:checkhealth snacks)'
    end
    return image
end

function M.resolve(buf, destination)
    destination = destination:gsub('^<(.*)>$', '%1'):gsub('\\([%p ])', '%1')
    if destination:match('^https?://') then return destination end
    destination = destination:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
    if destination:find('%z') or destination:find('[\r\n]') then return nil end
    if destination:match('^file://') then destination = destination:sub(8) end
    if destination:match('^%a[%w+.-]*:') then return nil end
    if vim.startswith(destination, '/') then return vim.fs.normalize(destination) end
    local source = require('inkstone.core.preview').get(buf) or buf
    local file = vim.api.nvim_buf_get_name(source)
    local base = vim.b[source].inkstone_root
        or (file ~= '' and not file:find('://', 1, true) and vim.fs.dirname(file))
        or vim.fn.getcwd()
    return vim.fs.normalize(base .. '/' .. destination)
end

function M.collect(context, parser, marks)
    context.media = {}
    local config = context.config.media
    if not config.enabled then return end
    local seen = {}
    local function add(item)
        for _, mark in ipairs(marks) do
            if mark.folded and item.row == mark.start_row then return end
            if mark.opts.conceal_lines then
                local finish = mark.opts.end_row or mark.start_row
                finish = finish + 1
                if item.row >= mark.start_row and item.row < finish then return end
            end
        end
        local key = item.kind .. ':' .. item.row .. ':' .. (item.col or 0)
        if seen[key] then return end
        seen[key] = true
        item.key = key .. ':' .. vim.fn.sha256(item.source)
        context.media[#context.media + 1] = item
    end
    context.view:each_tree(parser, function(tree, language)
        local lang = language:lang()
        if not context.view:overlaps(tree:root()) then return end
        if lang == 'markdown_inline' and config.images then
            local query = require('inkstone.core.ts').parse(lang, '(image) @image')
            context.view:nodes(tree:root(), query, function(_, node)
                local destination = node:child('link_destination')
                local path = destination and M.resolve(context.buf, destination.text)
                if path then add({ kind = 'image', row = node.start_row, col = node.start_col, source = path }) end
            end)
        elseif lang == 'markdown' and (config.mermaid or config.plantuml) then
            local query = require('inkstone.core.ts').parse(lang, '(fenced_code_block) @code')
            context.view:nodes(tree:root(), query, function(_, node)
                local info = node:child('info_string')
                local kind = info and info.text:match('^%s*(%S+)')
                if not (kind == 'mermaid' and config.mermaid or kind == 'plantuml' and config.plantuml) then return end
                local content = node:child('code_fence_content')
                if content then add({ kind = kind, row = node.start_row, col = node.start_col, source = content.text }) end
            end)
        end
    end)
end

local function close(entry)
    if entry.process then entry.process:kill(15); entry.process = nil end
    if entry.placement then pcall(entry.placement.close, entry.placement); entry.placement = nil end
end

function M.clear(buf)
    if M.pending[buf] then close(M.pending[buf]); M.pending[buf] = nil end
    for _, entry in pairs(M.cache[buf] or {}) do close(entry) end
    M.cache[buf] = nil
end

function M.reset()
    for buf in pairs(M.cache) do M.clear(buf) end
    for buf in pairs(M.pending) do M.clear(buf) end
end

-- Argument vectors only: document contents and filenames are never shell code.
-- No dependency downloads or implicit remote diagram server are used.
function M.convert(item, config, callback)
    if item.kind == 'image' then callback(item.source); return end
    local command = vim.deepcopy(config[item.kind .. '_command'])
    if not command or #command == 0 or vim.fn.executable(command[1]) ~= 1 then
        callback(nil, item.kind .. ' renderer is unavailable'); return
    end
    local cache = config.cache_dir
    local ok = pcall(vim.fn.mkdir, cache, 'p')
    if not ok or vim.fn.isdirectory(cache) ~= 1 then callback(nil, 'Cannot create media cache'); return end
    local hash = vim.fn.sha256(item.kind .. '\0' .. item.source .. '\0' .. vim.o.background .. vim.inspect(command))
    local base = cache .. '/' .. hash
    local output = base .. '.png'
    if vim.fn.filereadable(output) == 1 then callback(output); return end
    -- Each job writes private temporary files. Publish only successful output,
    -- so cancellation/failure cannot poison another buffer's content cache.
    local temporary = base .. '-' .. tostring(vim.uv.hrtime())
    local generated = temporary .. '.png'
    local input = temporary .. (item.kind == 'mermaid' and '.mmd' or '.puml')
    local written, err = pcall(vim.fn.writefile, vim.split(item.source, '\n', { plain = true }), input)
    if not written then callback(nil, tostring(err)); return end
    if item.kind == 'mermaid' then
        vim.list_extend(command, { '-i', input, '-o', generated, '-b', 'transparent', '-t', vim.o.background == 'light' and 'neutral' or 'dark' })
    else
        vim.list_extend(command, { '-tpng', input })
    end
    local started, process = pcall(vim.system, command, { text = true, timeout = config.timeout }, function(result)
        vim.schedule(function()
            item.process = nil
            vim.fn.delete(input)
            if result.code == 0 and vim.fn.filereadable(generated) == 1 then
                local renamed, rename_error = vim.uv.fs_rename(generated, output)
                if renamed then callback(output) else callback(nil, tostring(rename_error)) end
            else
                vim.fn.delete(generated)
                callback(nil, item.kind .. ': ' .. (result.stderr or 'conversion failed'))
            end
        end)
    end)
    if started then item.process = process else vim.fn.delete(input); callback(nil, tostring(process)) end
end

function M.update(context, hidden)
    local buf, config = context.buf, context.config.media
    if not config.enabled then M.clear(buf); return end
    local requested = {}
    for _, item in ipairs(context.media or {}) do
        if not hidden or item.row < hidden[1] or item.row > hidden[2] then requested[item.key] = item end
    end
    local entries = M.cache[buf] or {}
    M.cache[buf] = entries
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    for key, entry in pairs(entries) do
        if not requested[key] or entry.tick ~= tick then close(entry); entries[key] = nil end
    end
    if next(requested) == nil then return end
    local image = M.backend()
    if not image then return end
    for key, item in pairs(requested) do
        -- Snacks' own document renderer already handles images and Mermaid.
        -- Do not allocate a second placement when it owns this buffer.
        local native = vim.b[buf].snacks_image_attached and item.kind ~= 'plantuml'
            and image.config and image.config.enabled and image.config.doc.enabled
        if not native and not entries[key] then
            local entry = vim.deepcopy(item)
            entry.tick = tick
            entries[key] = entry
            M.convert(entry, config, function(path, err)
                if M.cache[buf] ~= entries or entries[key] ~= entry or not vim.api.nvim_buf_is_valid(buf)
                    or vim.api.nvim_buf_get_changedtick(buf) ~= tick then return end
                entry.path, entry.error = path, err
                if not path then return end
                local ok, placement = pcall(image.placement.new, buf, path, {
                    pos = { item.row + 1, item.col or 0 }, inline = true, conceal = false,
                    max_width = math.min(config.max_width, require('inkstone.lib.env').win.width(context.win)),
                    max_height = config.max_height, auto_resize = true,
                })
                if ok then entry.placement = placement else entry.error = tostring(placement) end
            end)
        end
    end
end

function M.open()
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local config = require('inkstone.state').get(buf)
    if not config.media.enabled then return end
    local image, reason = M.backend()
    if not image then vim.notify(reason, vim.log.levels.WARN); return end
    local tick, row = vim.api.nvim_buf_get_changedtick(buf), vim.api.nvim_win_get_cursor(win)[1] - 1
    local parser = vim.treesitter.get_parser(buf, 'markdown')
    parser:parse(nil, function(err)
        if err or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick
            or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
        local Context = require('inkstone.request.context')
        local exists, context = pcall(Context.get, buf)
        if not exists then context = Context.new(buf, win, config) end
        M.collect(context, parser, {})
        local selected
        for _, item in ipairs(context.media) do if item.row <= row and (not selected or item.row > selected.row) then selected = item end end
        if not selected then return end
        if M.pending[buf] then close(M.pending[buf]) end
        M.pending[buf] = selected
        M.convert(selected, config.media, function(path, error)
            if M.pending[buf] ~= selected then return end
            M.pending[buf] = nil
            if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then return end
            if not path then vim.notify(error, vim.log.levels.WARN); return end
            local target = vim.api.nvim_create_buf(false, true)
            local width = math.max(1, math.min(config.media.max_width, vim.o.columns - 4))
            local height = math.max(1, math.min(config.media.max_height, vim.o.lines - 4))
            vim.api.nvim_open_win(target, true, { relative = 'editor', style = 'minimal', border = 'rounded',
                width = width, height = height, row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2) })
            vim.bo[target].bufhidden = 'wipe'
            local placement = image.placement.new(target, path, { inline = false, width = width, height = height })
            vim.api.nvim_create_autocmd('BufWipeout', { buffer = target, once = true, callback = function() placement:close() end })
            vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = target })
        end)
    end)
end

return M
