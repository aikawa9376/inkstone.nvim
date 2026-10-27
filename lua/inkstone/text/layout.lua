local str = require('inkstone.lib.str')
local grapheme = require('inkstone.text.grapheme')
local M = {}
local no_start, no_end = {}, {}
-- Adapted from md-render.nvim's MIT-licensed JIS-inspired character sets.
for _, char in ipairs(grapheme.split('）〕］｝〉》」』】｠〙〗»‐〜！？‼⁇⁈⁉・：；。．、，ゝゞヽヾ々〻ーぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ｡､｣ｧｨｩｪｫｯｬｭｮｰ)]}!?.,;:')) do no_start[char] = true end
for _, char in ipairs(grapheme.split('（〔［｛〈《「『【｟〘〖«｢([{')) do no_end[char] = true end
local parser
local function japanese_parser()
    if not parser then parser = require('inkstone.vendor.budoux').load_default_japanese_parser() end
    return parser
end
function M.segment(text)
    return japanese_parser():parse(text)
end
local function preferences(units, options)
    local preferred, offsets, pieces, offset = {}, {}, {}, 0
    for i, unit in ipairs(units) do
        pieces[#pieces + 1] = unit.text
        offset = offset + #unit.text
        offsets[offset] = i
        if str.whitespace(unit.text) or (units[i + 1] and str.whitespace(units[i + 1].text)) then
            preferred[i] = true
        end
    end
    local text = table.concat(pieces)
    if options.enabled ~= false and options.budoux ~= false and text:find('[\227-\233]') then
        local position = 0
        for _, phrase in ipairs(M.segment(text)) do
            position = position + #phrase
            local index = offsets[position]
            if index then preferred[index] = true end
        end
    end
    return preferred
end
local function append(line, unit)
    local last = line[#line]
    if last and vim.deep_equal(last[2], unit.highlight) then last[1] = last[1] .. unit.text
    else line[#line + 1] = { unit.text, unit.highlight } end
end
-- Width always wins when an extremely narrow column makes kinsoku impossible.
-- Otherwise prefer a phrase/word boundary, then a legal character boundary.
function M.wrap(units, width, options)
    options = options or {}
    assert(type(width) == 'number' and width >= 1, 'wrap width must be positive')
    local preferred = preferences(units, options)
    local result, first = {}, 1
    local function legal(index)
        if options.enabled == false then return true end
        return not no_end[units[index].text]
            and (not units[index + 1] or not no_start[units[index + 1].text])
    end
    while first <= #units do
        local last, used = first - 1, 0
        while last < #units and used + units[last + 1].width <= width do
            last = last + 1
            used = used + units[last].width
        end
        assert(last >= first, 'table unit exceeds column width')
        if last < #units then
            local safe
            for index = last, first, -1 do
                if legal(index) then
                    safe = safe or index
                    if preferred[index] then safe = index; break end
                end
            end
            last = safe or last
        end
        local finish = last
        while finish >= first and str.whitespace(units[finish].text) do finish = finish - 1 end
        local line = {}
        for index = first, finish do append(line, units[index]) end
        result[#result + 1] = line
        first = last + 1
        while first <= #units and str.whitespace(units[first].text) do first = first + 1 end
    end
    return #result > 0 and result or { {} }
end
return M
