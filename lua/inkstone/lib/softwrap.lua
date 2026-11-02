local str = require('inkstone.lib.str')
local M = { windows = {} }

-- Detect displayed-width wrapping rather than assuming that every 0.13 dev
-- build has it. The scratch window never enters the user's window layout.
function M.conceal_aware()
    if M.conceal_aware_supported ~= nil then return M.conceal_aware_supported end
    local buf, win
    local ok, supported = pcall(function()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'axxxxxxxxxxxxb' })
        vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace('inkstone.conceal-probe'), 0, 1,
            { end_col = 13, conceal = '' })
        win = vim.api.nvim_open_win(buf, false, {
            relative = 'editor', row = 0, col = 0, width = 4, height = 1,
            style = 'minimal', hide = true, noautocmd = true,
        })
        vim.wo[win].wrap, vim.wo[win].conceallevel, vim.wo[win].concealcursor = true, 3, 'nvic'
        return vim.api.nvim_win_text_height(win, { start_row = 0, end_row = 0 }).all == 1
    end)
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    M.conceal_aware_supported = ok and supported or false
    return M.conceal_aware_supported
end

-- Tree-sitter conceal follows concealcursor independently of anti-conceal.
-- Select between precomputed source/display padding without reparsing on moves.
function M.concealed(win, row, mode)
    if vim.wo[win].conceallevel == 0 then return false end
    mode = mode:sub(1, 1)
    if mode == 'V' or mode == '\22' then mode = 'v' end
    if mode == 'v' and not vim.wo[win].concealcursor:find('v', 1, true)
        and vim.api.nvim_win_get_buf(win) == vim.api.nvim_get_current_buf() then
        local first, last = vim.fn.getpos('v')[2] - 1, vim.api.nvim_win_get_cursor(0)[1] - 1
        if row >= math.min(first, last) and row <= math.max(first, last) then return false end
    end
    if win ~= vim.api.nvim_get_current_win() or vim.api.nvim_win_get_cursor(win)[1] - 1 ~= row then return true end
    return vim.wo[win].concealcursor:find(mode, 1, true) ~= nil
end

-- Persistent inline marks participate in native motions. They are buffer-wide,
-- so use ordinary source wrapping while another window displays this buffer.
function M.window_supported(buf, win)
    if #vim.fn.win_findbuf(buf) > 1 or not vim.wo[win].wrap
        or (vim.o.cpoptions:find('n', 1, true)
            and (vim.wo[win].number or vim.wo[win].relativenumber)) then return false end
    return true
end

function M.supports(context)
    return M.window_supported(context.buf, context.win) and not vim.wo[context.win].linebreak
end

-- Do not make a permanent window-option change, or disable English linebreak
-- when native paragraph layout is off. An explicit win_options.linebreak wins.
function M.linebreak(win, active)
    local saved = M.windows[win]
    if active then
        if not saved then
            M.windows[win] = { buf = vim.api.nvim_win_get_buf(win), value = vim.wo[win].linebreak }
        end
        if vim.wo[win].linebreak then vim.wo[win].linebreak = false end
    elseif saved then
        M.windows[win] = nil
        if vim.api.nvim_win_is_valid(win) and not vim.wo[win].linebreak then
            vim.wo[win].linebreak = saved.value
        end
    end
end

function M.clear(buf)
    for win, saved in pairs(M.windows) do
        if not buf or saved.buf == buf then M.linebreak(win, false) end
    end
end

local group = vim.api.nvim_create_augroup('InkstoneSoftwrap', { clear = true })
vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group, callback = function(args) M.clear(args.buf) end,
})
vim.api.nvim_create_autocmd('BufWipeout', {
    group = group, callback = function(args) M.clear(args.buf) end,
})
vim.api.nvim_create_autocmd('WinClosed', {
    group = group, callback = function(args) M.windows[tonumber(args.match)] = nil end,
})

-- Match Neovim's continuation budget for ordinary paragraph indentation.
-- List/quote paragraphs are handled by their existing renderers. Unsupported
-- options/characters retain native source wrapping instead of virtual rows.
function M.head(context, source, width)
    if source:find('[%z\1-\31\127]') then return nil end
    local win = context.win
    local showbreak = vim.wo[win].showbreak
    if showbreak == '' then showbreak = vim.o.showbreak end
    local sbr, indent = str.width(showbreak), 0
    if vim.wo[win].breakindent then
        indent = #(source:match('^ *'))
        local shift, minimum, column, subtract = 0, 20, nil, false
        for option in vim.wo[win].breakindentopt:gmatch('[^,]+') do
            local key, value = option:match('^(%a+):([%-]?%d+)$')
            if key == 'shift' then shift = tonumber(value)
            elseif key == 'min' then minimum = tonumber(value)
            elseif key == 'column' then column = tonumber(value)
            elseif key == 'list' then
                if vim.fn.match(source, vim.bo[context.buf].formatlistpat) >= 0 then return nil end
            elseif option == 'sbr' then subtract = true
            else return nil end
        end
        indent = column and column ~= 0 and column or (indent + shift)
        if subtract then indent = indent - sbr end
        indent = math.max(0, math.min(indent, math.max(0, width - minimum)))
    end
    return indent + sbr
end

function M.layout(source, first_width, continuation_width, options, conceals)
    if str.width(source) <= first_width then return {} end
    local Parser = require('inkstone.parser.table')
    local units = {}
    local function append(text, col, replacement)
        for _, unit in ipairs(Parser.units({ { text, 'Normal' } })) do
            col = replacement or (col + #unit.text)
            unit.col = col
            units[#units + 1] = unit
        end
    end
    local col = 0
    for _, range in ipairs(conceals or {}) do
        append(source:sub(col + 1, range[1]), col)
        append(range.replacement or '', range[1], range[2])
        -- Anchor after hidden closing delimiters, never inside a concealed span.
        if units[#units] then units[#units].col = range[2] end
        col = range[2]
    end
    append(source:sub(col + 1), col)
    if #units == 0 then return {} end
    for _, unit in ipairs(units) do
        if unit.width > math.min(first_width, continuation_width) then return false end
    end
    local ranges = require('inkstone.text.layout').softwrap(units, first_width, continuation_width, options)
    local result = {}
    for i, range in ipairs(ranges) do
        if i < #ranges then result[#result + 1] = {
            col = units[range.last].col, padding = range.available - range.width,
        } end
    end
    return result
end

return M
