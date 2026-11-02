-- Image data and virtual prototypes are uploaded once. Only ordinary extmark
-- text places them on screen, so redraws never need terminal overlay repair.
local M = {}
local escape = '\27'
local placeholder = vim.fn.nr2char(0x10EEEE)
local diacritics = require('inkstone.lib.image_diacritics')
local function position(value) return vim.fn.nr2char(diacritics[value + 1]) end

local counter = tonumber(vim.fn.sha256(tostring(vim.fn.getpid()) .. tostring(vim.uv.hrtime())):sub(1, 8), 16)
function M.id()
    counter = counter % 4294967295 + 1
    return counter
end

function M.highlight(id)
    local highlight = 'InkstoneImageFont' .. id
    local fg = id % 16777216
    local current = vim.api.nvim_get_hl(0, { name = highlight, link = false })
    if current.fg ~= fg or not current.nocombine then
        vim.api.nvim_set_hl(0, highlight, { fg = fg, nocombine = true })
    end
    return highlight
end

function M.grid(id, columns, rows)
    assert(columns >= 1 and columns <= 256 and rows >= 1 and rows <= 256)
    local highlight = M.highlight(id)
    local grid, high = {}, position(math.floor(id / 16777216))
    for row = 0, rows - 1 do
        local cells = {}
        for col = 0, columns - 1 do
            cells[#cells + 1] = placeholder .. position(row) .. position(col) .. high
        end
        grid[#grid + 1] = { { table.concat(cells), highlight } }
    end
    return grid, highlight
end

function M.send(data)
    if vim.env.TMUX then data = '\27Ptmux;' .. data:gsub('\27', '\27\27') .. '\27\\' end
    if vim.api.nvim_ui_send then vim.api.nvim_ui_send(data) end
end

function M.upload(id, png, columns, rows)
    local data = vim.base64.encode(png)
    for offset = 1, #data, 4096 do
        local chunk = data:sub(offset, offset + 4095)
        local more = offset + 4096 <= #data and 1 or 0
        local header = offset == 1 and ('a=T,f=100,q=2,U=1,C=1,i=%d,c=%d,r=%d,'):format(id, columns, rows) or 'q=2,'
        M.send(escape .. '_G' .. header .. 'm=' .. more .. ';' .. chunk .. escape .. '\\')
    end
end

function M.delete(id, highlight)
    -- Exact ownership: never delete other plugins' images or clear the screen.
    M.send(escape .. '_Ga=d,d=I,q=2,i=' .. id .. escape .. '\\')
    if highlight then vim.api.nvim_set_hl(0, highlight, {}) end
end

return M
