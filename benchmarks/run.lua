-- Compare in separate processes: INKSTONE_BASELINE=1 selects the installed upstream.
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
local baseline = vim.env.INKSTONE_BASELINE == '1'
local name = baseline and 'render-markdown' or 'inkstone'
local dependency = vim.env.INKSTONE_UPSTREAM_RTP or (vim.fn.stdpath('data') .. '/lazy/render-markdown.nvim')
vim.opt.rtp:prepend(baseline and dependency or (vim.env.INKSTONE_BENCH_RTP or root))
vim.opt.rtp:append(vim.env.INKSTONE_PARSER_RTP or (vim.fn.stdpath('data') .. '/site'))
vim.o.columns, vim.o.lines = 140, 45
vim.o.redrawtime = 5000
require(name).setup({ file_types = { 'markdown' }, anti_conceal = { enabled = false },
    code = { sign = false, language = false, width = 'block', left_pad = 1, right_pad = 1 },
    pipe_table = { cell = 'trimmed' },
})
local function clock() return vim.uv.hrtime() / 1e6 end
local function median(values) local sorted = vim.deepcopy(values); table.sort(sorted); return sorted[math.ceil(#sorted / 2)] end
local result = { renderer = name, neovim = vim.version(), scenarios = {} }
for _, scenario in ipairs({ 'code', 'inline', 'table' }) do
    local lines = {}
    if scenario == 'code' then
        lines = { '```lua' }
        for i = 1, 7000 do lines[#lines + 1] = 'local value_' .. i .. ' = { id = ' .. i .. ', label = "hello world" }' end
        lines[#lines + 1] = '```'
    elseif scenario == 'inline' then
        lines = { '# Heading', '', string.rep('[x](https://x.example) **bold** `code` ', 500) }
    else
        lines = { '| 項目 | 説明 |', '| --- | --- |' }
        for i = 1, 1000 do lines[#lines + 1] = '| 項目' .. i .. ' | 「日本語」の文章と **強調**、[リンク](https://example.org)を読みやすく表示します。 |' end
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    vim.wo.conceallevel = 2
    vim.treesitter.start(buf, 'markdown')
    local parser = vim.treesitter.get_parser(buf, 'markdown')
    local started = clock(); parser:parse(true); local parse_ms = clock() - started
    local first = math.floor(#lines / 2)
    local times, marks = {}, nil
    local function render()
        local context = require(name .. '.request.context').new(buf, vim.api.nvim_get_current_win(), require(name .. '.state').get(buf))
        context.view.ranges = { { first, first + 40 } }
        return require(name .. '.core.handlers').run(context, parser)
    end
    started = clock(); render(); local cold_render_ms = clock() - started
    for sample = 1, 5 do
        collectgarbage('collect'); started = clock(); marks = render(); times[sample] = clock() - started
    end
    local decorator = require(name .. '.lib.decorator').new(buf)
    local ns = vim.api.nvim_create_namespace('InkstoneBenchmark')
    local applied = {}
    for sample = 1, 3 do
        decorator:clear(ns)
        local extmarks = {}
        for _, mark in ipairs(marks) do extmarks[#extmarks + 1] = require(name .. '.lib.extmark').new(mark) end
        decorator:set(extmarks)
        started = clock(); decorator:display(ns, function() return false end); applied[sample] = clock() - started
    end
    local previous = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do previous[mark[1]] = true end
    local refreshed = {}
    for sample = 1, 3 do
        started = clock()
        local extmarks = {}
        for _, mark in ipairs(marks) do extmarks[#extmarks + 1] = require(name .. '.lib.extmark').new(mark) end
        if decorator.replace then decorator:replace(ns, extmarks)
        else decorator:clear(ns); decorator:set(extmarks) end
        decorator:display(ns, function() return false end)
        refreshed[sample] = clock() - started
    end
    local retained = 0
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
        if previous[mark[1]] then retained = retained + 1 end
    end
    if vim.env.INKSTONE_BENCH_MARKS then
        vim.fn.writefile({ vim.json.encode(marks) }, vim.env.INKSTONE_BENCH_MARKS .. '-' .. scenario .. '.json')
    end
    result.scenarios[#result.scenarios + 1] = { name = scenario, rows = #lines, marks = #marks,
        full_parse_ms = parse_ms, cold_render_ms = cold_render_ms, render_ms = median(times),
        apply_ms = median(applied), refresh_ms = median(refreshed), retained_marks = retained, samples_ms = times }
    if decorator.dispose then decorator:dispose() else decorator.timer:stop(); decorator.timer:close() end
    vim.api.nvim_buf_delete(buf, { force = true })
end
if vim.env.INKSTONE_BENCH_OUT then vim.fn.writefile({ vim.json.encode(result) }, vim.env.INKSTONE_BENCH_OUT) end
print(vim.json.encode(result))
