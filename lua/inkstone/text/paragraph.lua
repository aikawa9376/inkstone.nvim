local Parser = require('inkstone.parser.table')
local layout = require('inkstone.text.layout')
local M = {}

-- Join CommonMark soft breaks. CJK neighbours do not gain an ASCII space.
-- A hard break starts a fresh wrapping group.
function M.wrap(rows, width, options)
    local result, units = {}, {}
    local function flush()
        vim.list_extend(result, layout.wrap(units, width, options))
        units = {}
    end
    for i, row in ipairs(rows) do
        local next_units = Parser.units(row.line)
        local previous, first = units[#units], next_units[1]
        if previous and first and not (previous.width > 1 and first.width > 1) then
            units[#units + 1] = { text = ' ', width = 1, highlight = previous.highlight }
        end
        vim.list_extend(units, next_units)
        if row.hard or i == #rows then flush() end
    end
    return result
end

return M
