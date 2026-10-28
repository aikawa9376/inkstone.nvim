-- Resolve named highlight stacks for one window/paint. Never retain this
-- cache across redraws: themes and window-local highlights can change live.
local M = {}

local function rgb(code, value)
    return ('\27[%d;2;%d;%d;%dm'):format(code, math.floor(value / 65536), math.floor(value / 256) % 256, value % 256)
end

local function sgr(value)
    local out = { '\27[0m' }
    if value.fg then out[#out + 1] = rgb(38, value.fg) end
    if value.bg then out[#out + 1] = rgb(48, value.bg) end
    if value.sp then out[#out + 1] = rgb(58, value.sp) end
    for _, style in ipairs({ { 'bold', '1' }, { 'italic', '3' }, { 'reverse', '7' }, { 'strikethrough', '9' } }) do
        if value[style[1]] then out[#out + 1] = '\27[' .. style[2] .. 'm' end
    end
    local underline = value.undercurl and '4:3' or value.underdouble and '4:2'
        or value.underdotted and '4:4' or value.underdashed and '4:5' or value.underline and '4'
    if underline then out[#out + 1] = '\27[' .. underline .. 'm' end
    return table.concat(out)
end

function M.new(win)
    local namespace = vim.api.nvim_get_hl_ns({ winid = win })
    if namespace < 0 then namespace = math.max(0, vim.api.nvim_get_hl_ns({})) end
    local aliases, groups, sequences = {}, {}, {}
    if namespace == 0 then
        for from, to in vim.wo[win].winhighlight:gmatch('([^,:]+):([^,]+)') do aliases[from] = to end
    end
    local function get(name)
        name = aliases[name] or name
        if not groups[name] then
            groups[name] = {} -- Bound malformed/cyclic namespace links.
            local value = vim.api.nvim_get_hl(namespace, { name = name, link = false, create = false })
            if namespace ~= 0 and not next(value) then
                value = vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
            end
            -- Namespace links can target a group defined only globally;
            -- get_hl(link=false) still returns a link in that case.
            if value.link then value = get(value.link) end
            groups[name] = value
        end
        return groups[name]
    end
    local normal = vim.tbl_extend('force', {}, get('Normal'))
    if win ~= vim.api.nvim_get_current_win() then normal = vim.tbl_extend('force', normal, get('NormalNC')) end
    return function(highlight, foreground, background)
        local names = type(highlight) == 'table' and highlight or { highlight }
        local key = (foreground or '') .. '\0' .. (background or '') .. '\0' .. table.concat(names, '\0')
        if sequences[key] then return sequences[key] end
        local result = vim.tbl_extend('force', {}, normal)
        if background then
            for k, v in pairs(get(background)) do
                if k ~= 'fg' and k ~= 'ctermfg' then result[k] = v end
            end
        end
        if foreground then result = vim.tbl_extend('force', result, get(foreground)) end
        for _, name in ipairs(names) do
            local value = get(name)
            if value.nocombine then result = vim.tbl_extend('force', {}, normal) end
            for k, v in pairs(value) do result[k] = v end
        end
        sequences[key] = sgr(result)
        return sequences[key]
    end
end

return M
