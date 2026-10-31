local str = require('inkstone.lib.str')
local M = { windows = {} }

-- Persistent inline marks participate in native motions. They are buffer-wide,
-- so use ordinary source wrapping while another window displays this buffer.
function M.window_supported(buf, win)
    if #vim.fn.win_findbuf(buf) > 1 or not vim.wo[win].wrap
        or vim.wo[win].list or (vim.o.cpoptions:find('n', 1, true)
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

function M.layout(source, first_width, continuation_width, options)
    if str.width(source) <= first_width then return {} end
    local units = require('inkstone.parser.table').units({ { source, 'Normal' } })
    for _, unit in ipairs(units) do
        if unit.width > math.min(first_width, continuation_width) then return false end
    end
    local ranges = require('inkstone.text.layout').softwrap(units, first_width, continuation_width, options)
    local result, offset = {}, 0
    for i, range in ipairs(ranges) do
        for index = range.first, range.last do offset = offset + #units[index].text end
        if i < #ranges then result[#result + 1] = { col = offset, padding = range.available - range.width } end
    end
    return result
end

return M
