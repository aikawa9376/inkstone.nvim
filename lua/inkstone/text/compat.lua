-- Width-preserving display substitutions. Source buffers are never rewritten.
local grapheme = require('inkstone.text.grapheme')
local str = require('inkstone.lib.str')
local M = {}

local voiced = {
    ['ｳﾞ'] = 'ヴ', ['ｶﾞ'] = 'ガ', ['ｷﾞ'] = 'ギ', ['ｸﾞ'] = 'グ', ['ｹﾞ'] = 'ゲ', ['ｺﾞ'] = 'ゴ',
    ['ｻﾞ'] = 'ザ', ['ｼﾞ'] = 'ジ', ['ｽﾞ'] = 'ズ', ['ｾﾞ'] = 'ゼ', ['ｿﾞ'] = 'ゾ',
    ['ﾀﾞ'] = 'ダ', ['ﾁﾞ'] = 'ヂ', ['ﾂﾞ'] = 'ヅ', ['ﾃﾞ'] = 'デ', ['ﾄﾞ'] = 'ド',
    ['ﾊﾞ'] = 'バ', ['ﾋﾞ'] = 'ビ', ['ﾌﾞ'] = 'ブ', ['ﾍﾞ'] = 'ベ', ['ﾎﾞ'] = 'ボ',
    ['ﾊﾟ'] = 'パ', ['ﾋﾟ'] = 'ピ', ['ﾌﾟ'] = 'プ', ['ﾍﾟ'] = 'ペ', ['ﾎﾟ'] = 'ポ',
    ['ﾜﾞ'] = 'ヷ', ['ｦﾞ'] = 'ヺ',
}

-- Also retain unusual pairs such as ｱﾞ and ｶﾟ: a fullwidth base plus a
-- combining mark occupies the same two cells without dropping either mark.
local half = grapheme.split('ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ')
local full = grapheme.split('ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン')
for i, base in ipairs(half) do
    for mark, combining in pairs({ ['ﾞ'] = '゙', ['ﾟ'] = '゚' }) do
        voiced[base .. mark] = voiced[base .. mark] or full[i] .. combining
    end
end

function M.enabled(config)
    return config.enabled == true or (config.enabled == 'auto'
        and (vim.env.KITTY_WINDOW_ID ~= nil or vim.env.TERM_PROGRAM == 'kitty'))
end

function M.compile(config)
    local rules = { values = {}, prefixes = {} }
    local values = vim.tbl_extend('force', config.kana and voiced or {}, config.replacements or {})
    for source, replacement in pairs(values) do
        -- A rule must replace a complete display cluster and keep its grid width.
        if source ~= '' and not source:find('[%c]') and not replacement:find('[%c]')
            and #grapheme.split(source) == 1 and str.width(source) > 0
            and str.width(source) == str.width(replacement) then
            rules.values[source] = replacement
            rules.prefixes[source:sub(1, 1)] = true
        end
    end
    return rules
end

function M.spans(text, rules)
    local candidate = false
    for prefix in pairs(rules.prefixes) do
        if text:find(prefix, 1, true) then candidate = true; break end
    end
    if not candidate then return {} end
    local spans, col = {}, 0
    for _, cluster in ipairs(grapheme.split(text)) do
        local replacement = rules.values[cluster]
        if replacement and replacement ~= cluster then
            spans[#spans + 1] = { col, col + #cluster, replacement }
        end
        col = col + #cluster
    end
    return spans
end

-- Resolve across highlight chunk boundaries, keeping the base character's color.
function M.line(line, rules)
    local pieces = {}
    for _, chunk in ipairs(line) do pieces[#pieces + 1] = chunk[1] end
    local text = table.concat(pieces)
    local spans = M.spans(text, rules)
    if #spans == 0 then return line end
    local result, index, offset, col = {}, 1, 1, 0
    local function append(value, hl)
        if value == '' then return end
        local last = result[#result]
        if last and last[2] == hl then last[1] = last[1] .. value
        else result[#result + 1] = { value, hl } end
    end
    local function consume(length, emit)
        while length > 0 do
            local chunk = line[index]
            local take = math.min(length, #chunk[1] - offset + 1)
            if emit then append(chunk[1]:sub(offset, offset + take - 1), chunk[2]) end
            length, offset = length - take, offset + take
            if offset > #chunk[1] then index, offset = index + 1, 1 end
        end
    end
    for _, span in ipairs(spans) do
        consume(span[1] - col, true)
        local hl = line[index][2]
        consume(span[2] - span[1], false)
        append(span[3], hl)
        col = span[2]
    end
    consume(#text - col, true)
    -- Never change layout already measured by a renderer's chunk-based widths.
    return str.line_width(result) == str.line_width(line) and result or line
end

return M
