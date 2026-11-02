-- Experimental image typography. Rust only rasterizes; this module owns async
-- requests, cache references and ordinary Neovim placeholder decorations.
local M = { buffers = {}, assets = {}, queue = {}, running = 0 }
local graphics = require('inkstone.lib.graphics')
local dispatch
local function read(path)
    local file = io.open(path, 'rb')
    if not file then return end
    local data = file:read(16 * 1024 * 1024 + 1)
    file:close()
    if data and #data <= 16 * 1024 * 1024 and data:sub(1, 8) == '\137PNG\r\n\26\n' then return data end
end

function M.available(config)
    return #config.command > 0 and vim.fn.executable(config.command[1]) == 1
end

local function notify(asset)
    for slot, owner in pairs(asset.users) do
        local state = M.buffers[owner.buf]
        if state and state.entries[owner.id] == slot and vim.api.nvim_buf_is_valid(owner.buf)
            and vim.api.nvim_buf_get_changedtick(owner.buf) == slot.tick
            and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_buf(state.win) == owner.buf then
            require('inkstone.core.ui').update(owner.buf, state.win, 'TypographyImageReady', true)
        end
    end
end

local function ready(asset, data)
    asset.id = graphics.id()
    graphics.upload(asset.id, data, asset.columns, asset.rows)
    asset.grid, asset.highlight = graphics.grid(asset.id, asset.columns, asset.rows)
    asset.status = 'ready'
end

local function release(slot)
    local asset = slot.asset
    asset.users[slot] = nil
    if next(asset.users) then return end
    M.assets[asset.key] = nil
    if asset.process then pcall(asset.process.kill, asset.process, 15) end
    if asset.id then graphics.delete(asset.id, asset.highlight) end
end

function M.clear(buf)
    if not buf then
        for owner in pairs(M.buffers) do M.clear(owner) end
        return
    end
    local state = M.buffers[buf]
    if not state then return end
    M.buffers[buf] = nil
    for _, slot in pairs(state.entries) do release(slot) end
end

dispatch = function()
    while M.running < 2 and #M.queue > 0 do
        local asset = table.remove(M.queue, 1)
        if M.assets[asset.key] == asset and next(asset.users) then
            M.running = M.running + 1
            asset.status = 'rendering'
            local function done(result)
                vim.schedule(function()
                    M.running = M.running - 1
                    asset.process = nil
                    if M.assets[asset.key] == asset and next(asset.users) then
                        local data = result.stdout or ''
                        if result.code == 0 and #data <= 16 * 1024 * 1024 and data:sub(1, 8) == '\137PNG\r\n\26\n' then
                            local temporary = asset.path .. '.' .. vim.uv.hrtime()
                            local file = io.open(temporary, 'wb')
                            if file then
                                local ok = file:write(data)
                                local closed = file:close()
                                if ok and closed then vim.uv.fs_rename(temporary, asset.path) end
                                vim.fn.delete(temporary)
                            end
                            ready(asset, data)
                        else
                            asset.status, asset.error = 'failed', (result.stderr or 'rasterization failed'):sub(1, 2048)
                        end
                        notify(asset)
                    end
                    dispatch()
                end)
            end
            local ok, process = pcall(vim.system, asset.command, { stdin = asset.input, timeout = asset.timeout }, done)
            if ok then asset.process = process else done({ code = 1, stderr = tostring(process) }) end
        end
    end
end

function M.request(context, entry)
    local config = context.config.typography.image
    local columns, lines = 0, {}
    local colors = require('inkstone.lib.terminal_colors').new(context.win, true)
    for _, line in ipairs(entry.lines) do
        columns = math.max(columns, line.width)
        local runs = {}
        for _, run in ipairs(line.runs) do
            local value = colors(run.highlight, entry.highlight, entry.background)
            local fg, bg = value.fg or 0xffffff, value.bg
            if value.reverse then fg, bg = bg or 0, fg end
            runs[#runs + 1] = { text = run.text, cells = run.width, fg = fg, bg = bg,
                bold = value.bold == true, italic = value.italic == true,
                underline = value.underline == true or value.undercurl == true or value.underdouble == true,
                strikethrough = value.strikethrough == true }
        end
        lines[#lines + 1] = runs
    end
    local rows = #lines * entry.spec.scale
    if columns < 1 or columns > 256 or rows > 256 then return end
    local input = vim.json.encode({ font = config.font, cell_width = config.cell_width, cell_height = config.cell_height,
        columns = columns, scale = entry.spec.scale, ratio = entry.spec.ratio, lines = lines })
    local executable = vim.fn.exepath(config.command[1])
    local stat = vim.uv.fs_stat(executable)
    local key = vim.fn.sha256('image-font-v1\0' .. input .. vim.json.encode(config.command) .. vim.inspect(stat and { stat.size, stat.mtime }))
    context.typography_image_requests = context.typography_image_requests or {}
    context.typography_image_requests[entry.id] = key
    local state = M.buffers[context.buf]
    if state and state.win ~= context.win then M.clear(context.buf); state = nil end
    if not state then state = { win = context.win, entries = {} }; M.buffers[context.buf] = state end
    local slot = state.entries[entry.id]
    if slot and slot.asset.key ~= key then release(slot); state.entries[entry.id] = nil; slot = nil end
    if not slot then
        local asset = M.assets[key]
        if not asset then
            if not pcall(vim.fn.mkdir, config.cache_dir, 'p') then return end
            asset = { key = key, path = config.cache_dir .. '/' .. key .. '.png', input = input,
                command = vim.deepcopy(config.command), timeout = config.timeout, columns = columns, rows = rows, users = {}, status = 'queued' }
            M.assets[key] = asset
            local cached = read(asset.path)
            if cached then ready(asset, cached) else M.queue[#M.queue + 1] = asset end
        end
        slot = { asset = asset }
        state.entries[entry.id] = slot
        asset.users[slot] = { buf = context.buf, id = entry.id }
    end
    slot.tick = vim.api.nvim_buf_get_changedtick(context.buf)
    dispatch()
    if slot.asset.status == 'ready' then
        graphics.highlight(slot.asset.id) -- ColorScheme may have cleared it.
        return slot.asset.grid
    end
end

function M.update(context)
    local state = M.buffers[context.buf]
    if not state then return end
    local requested = context.config.typography.backend == 'image' and context.typography_image_requests or {}
    for id, slot in pairs(state.entries) do
        if not requested or requested[id] ~= slot.asset.key then release(slot); state.entries[id] = nil end
    end
    if not next(state.entries) then M.buffers[context.buf] = nil end
end

return M
