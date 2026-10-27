-- Display clusters needed by Japanese prose and emoji. This is intentionally
-- scoped, not a claim of complete Unicode UAX #29 conformance.
local M = {}
local function codepoint(s)
    local a, b, c, d = s:byte(1, 4)
    if #s == 1 or a < 128 then return a end
    if a < 224 then return (a - 192) * 64 + b - 128 end
    if a < 240 then return (a - 224) * 4096 + (b - 128) * 64 + c - 128 end
    return (a - 240) * 262144 + (b - 128) * 4096 + (c - 128) * 64 + d - 128
end
local function combining(cp)
    return (cp >= 0x0300 and cp <= 0x036F)
        or (cp >= 0x1AB0 and cp <= 0x1AFF)
        or (cp >= 0x1DC0 and cp <= 0x1DFF)
        or (cp >= 0x20D0 and cp <= 0x20FF)
        or (cp >= 0xFE00 and cp <= 0xFE0F)
        or (cp >= 0xFE20 and cp <= 0xFE2F)
        or (cp >= 0x1F3FB and cp <= 0x1F3FF)
        or (cp >= 0xE0100 and cp <= 0xE01EF)
        or (cp >= 0xE0020 and cp <= 0xE007F)
        or cp == 0x3099 or cp == 0x309A or cp == 0xFF9E or cp == 0xFF9F
end
function M.split(text)
    local result, previous, regional = {}, nil, 0
    local index = 1
    while index <= #text do
        local lead = text:byte(index)
        local size = lead >= 0xF0 and lead <= 0xF4 and 4
            or lead >= 0xE0 and lead <= 0xEF and 3
            or lead >= 0xC2 and lead <= 0xDF and 2 or 1
        for at = index + 1, index + size - 1 do
            local byte = text:byte(at)
            if not byte or byte < 0x80 or byte > 0xBF then size = 1; break end
        end
        local char = text:sub(index, index + size - 1)
        index = index + size
        local cp = codepoint(char)
        local ri = cp >= 0x1F1E6 and cp <= 0x1F1FF
        local join = #result > 0 and (combining(cp) or cp == 0x200D or previous == 0x200D
            or (ri and regional % 2 == 1) or (previous == 13 and cp == 10))
        if join then result[#result] = result[#result] .. char
        else result[#result + 1] = char end
        regional = ri and (regional + 1) or 0
        previous = cp
    end
    return result
end
return M
