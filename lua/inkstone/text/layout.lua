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
local function ranges(units, width, options, continuation, trim)
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
        local content = first
        while units[content] and str.whitespace(units[content].text) do content = content + 1 end
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
                    if preferred[index] and (trim or index >= content) then safe = index; break end
                end
            end
            last = safe or last
        end
        local finish = last
        if trim then
            while finish >= first and str.whitespace(units[finish].text) do finish = finish - 1 end
        end
        used = 0
        for index = first, last do used = used + units[index].width end
        result[#result + 1] = { first = first, last = finish, width = used, available = width }
        first = last + 1
        if trim then
            while first <= #units and str.whitespace(units[first].text) do first = first + 1 end
        end
        width = continuation or width
    end
    return result
end

-- Source-backed wrapping must retain whitespace and byte positions. The first
-- screen row can have a different budget from rows with breakindent/showbreak.
function M.softwrap(units, first_width, continuation_width, options)
    return ranges(units, first_width, options, continuation_width, false)
end

function M.wrap(units, width, options)
    local result = {}
    for _, range in ipairs(ranges(units, width, options, nil, true)) do
        local line = {}
        for index = range.first, range.last do append(line, units[index]) end
        result[#result + 1] = line
    end
    return #result > 0 and result or { {} }
end
return M
