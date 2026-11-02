-- Compare viewport planning only, without parsing, handlers or terminal I/O.
local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p'))))
local env = require('inkstone.lib.env')
local result = { neovim = vim.version(), scenarios = {} }
local function median(values)
    table.sort(values)
    return values[math.ceil(#values / 2)]
end
for _, kind in ipairs({ 'plain', 'wrapped', 'character_conceal', 'concealed_lines', 'native_fold' }) do
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 10000 do lines[i] = 'row ' .. i end
    if kind == 'wrapped' or kind == 'character_conceal' then lines[1] = 'a' .. ('x'):rep(4000) .. 'b' end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor', row = 0, col = 0, width = 40, height = 20, style = 'minimal', hide = true,
    })
    vim.wo[win].wrap, vim.wo[win].conceallevel, vim.wo[win].concealcursor = true, 3, 'nvic'
    local ns, hidden = vim.api.nvim_create_namespace('inkstone-bench-native-geometry'), nil
    if kind == 'character_conceal' then
        vim.api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = #lines[1] - 1, conceal = '' })
    elseif kind == 'concealed_lines' then
        vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_row = 9000, end_col = 0, conceal_lines = '' })
        hidden = { { 1, 9001 } }
    elseif kind == 'native_fold' then
        vim.api.nvim_win_call(win, function() vim.cmd('2,9001fold') end)
    end
    local scenario = { name = kind }
    for _, native in ipairs({ false, true }) do
        env.range(buf, win, 10, hidden, native)
        local samples, range = {}, nil
        for i = 1, 9 do
            local started = vim.uv.hrtime()
            range = env.range(buf, win, 10, hidden, native)
            samples[i] = (vim.uv.hrtime() - started) / 1e6
        end
        scenario[native and 'native' or 'legacy'] = { median_ms = median(samples), range = range }
    end
    result.scenarios[#result.scenarios + 1] = scenario
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
end
result.native_supported = env.text_height_supported == true
local json = vim.json.encode(result)
if vim.env.INKSTONE_BENCH_OUT then vim.fn.writefile({ json }, vim.env.INKSTONE_BENCH_OUT) end
print(json)
