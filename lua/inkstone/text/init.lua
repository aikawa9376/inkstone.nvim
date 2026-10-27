-- Reusable Japanese layout for scratch views and other plugin consumers.
local M = {}
M.segment = require('inkstone.text.layout').segment
function M.wrap(text, width, options)
    local Parser = require('inkstone.parser.table')
    local wrapped = require('inkstone.text.layout').wrap(Parser.units({ { text, 'Normal' } }), width, options)
    local result = {}
    for _, line in ipairs(wrapped) do
        local pieces = {}
        for _, piece in ipairs(line) do pieces[#pieces + 1] = piece[1] end
        result[#result + 1] = table.concat(pieces)
    end
    return result
end
return M
