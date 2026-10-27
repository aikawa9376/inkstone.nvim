-- Declarative table charts: only numeric cell data is consumed, never code.
local M = {}

local function number(text)
    text = vim.trim(text)
    if text:find(',', 1, true) then
        local integer = text:match('^[+-]?([%d,]+)')
        if not integer then return end
        local groups = vim.split(integer, ',', { plain = true })
        if #groups[1] < 1 or #groups[1] > 3 then return end
        for i = 2, #groups do if not groups[i]:match('^%d%d%d$') then return end end
        text = text:gsub(',', '')
    end
    local value, unit = text:match('^([+-]?%d*%.?%d+[eE]?[+-]?%d*)%s*([^%d%s]*)$')
    value = tonumber(value)
    if value and value == value and math.abs(value) < math.huge then return value, unit end
end

function M.data(headers, rows)
    local series, unit = {}, nil
    for col, header in ipairs(headers) do
        local values, suffix, valid, count = {}, nil, true, 0
        for i, row in ipairs(rows) do
            local text = vim.trim(row[col] or '')
            if text == '' or text == '-' or text == '—' then values[i] = false
            else
                local value, u = number(text)
                if not value or (suffix and suffix ~= u) then valid = false; break end
                values[i], suffix, count = value, u, count + 1
            end
        end
        if valid and count > 0 then
            if unit and suffix ~= unit then return nil, 'Chart columns must use the same unit' end
            unit = suffix
            series[#series + 1] = { name = header ~= '' and header or ('Column ' .. col), values = values, col = col }
        end
    end
    if #series == 0 then return nil, 'This table has no numeric columns to chart' end
    local labels, numeric = {}, {}
    for _, s in ipairs(series) do numeric[s.col] = true end
    for i, row in ipairs(rows) do
        labels[i] = tostring(i)
        for col, value in ipairs(row) do if not numeric[col] and value ~= '' then labels[i] = value; break end end
    end
    return { labels = labels, series = series, unit = unit or '' }
end

local function escape(text)
    return tostring(text):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'):gsub("'", '&apos;')
end
M.escape = escape

function M.svg(data, opts)
    opts = opts or {}
    local width, height = opts.width or 960, opts.height or 480
    local fg, bg = opts.fg or '#d8dee9', opts.bg or '#20242c'
    local colors = opts.colors or { '#88c0d0', '#a3be8c', '#ebcb8b', '#b48ead', '#d08770' }
    local left, top, right, bottom = 85, 55, width - 25, height - 95
    local min, max = 0, 0
    for _, series in ipairs(data.series) do
        for _, value in ipairs(series.values) do if value then min, max = math.min(min, value), math.max(max, value) end end
    end
    if min == max then max = min + 1 end
    local function y(value) return bottom - (value - min) / (max - min) * (bottom - top) end
    local out = { ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">'):format(width, height, width, height),
        ('<rect width="100%%" height="100%%" fill="%s"/>'):format(bg),
        ('<g font-family="sans-serif" font-size="14" fill="%s">'):format(fg) }
    local function text(x, at_y, value, extra)
        out[#out + 1] = ('<text x="%.2f" y="%.2f" %s>%s</text>'):format(x, at_y, extra or '', escape(value))
    end
    for i = 0, 4 do
        local value = min + (max - min) * i / 4
        local at_y = y(value)
        out[#out + 1] = ('<path d="M%d %.2fH%d" stroke="%s" opacity=".2"/>'):format(left, at_y, right, fg)
        text(left - 8, at_y + 5, ('%.3g'):format(value), 'text-anchor="end"')
    end
    text(left, 25, data.unit ~= '' and ('Value (' .. data.unit .. ')') or 'Value')
    local step = (right - left) / math.max(#data.labels, 1)
    for i, label in ipairs(data.labels) do
        -- Keep all plotted values; sample axis labels only when crowded.
        if (i - 1) % math.max(1, math.ceil(#data.labels / 12)) == 0 then
            text(left + step * (i - .5), bottom + 25, label, 'text-anchor="middle"')
        end
    end
    for s, series in ipairs(data.series) do
        local color, points = colors[(s - 1) % #colors + 1], {}
        local function flush()
            if #points > 1 then
                out[#out + 1] = ('<polyline points="%s" fill="none" stroke="%s" stroke-width="3"/>'):format(table.concat(points, ' '), color)
            end
            points = {}
        end
        for i, value in ipairs(series.values) do
            if value then
                local x = left + step * (i - .5)
                if opts.kind == 'line' then
                    points[#points + 1] = ('%.2f,%.2f'):format(x, y(value))
                    out[#out + 1] = ('<circle cx="%.2f" cy="%.2f" r="3" fill="%s"/>'):format(x, y(value), color)
                else
                    local bar = step * .8 / #data.series
                    x = left + step * (i - 1) + step * .1 + (s - 1) * bar
                    out[#out + 1] = ('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s"/>')
                        :format(x, math.min(y(value), y(0)), math.max(bar - 1, .1), math.max(math.abs(y(value) - y(0)), 1), color)
                end
            elseif opts.kind == 'line' then flush() end
        end
        flush()
        local x = left + (s - 1) * math.max(150, (right - left) / #data.series)
        out[#out + 1] = ('<rect x="%.2f" y="%d" width="12" height="12" fill="%s"/>'):format(x, height - 32, color)
        text(x + 18, height - 21, series.name)
    end
    out[#out + 1] = '</g></svg>'
    return table.concat(out)
end

function M.lines(data, width)
    local lines, maximum = {}, 0
    for _, s in ipairs(data.series) do for _, v in ipairs(s.values) do if v then maximum = math.max(maximum, math.abs(v)) end end end
    for _, s in ipairs(data.series) do
        lines[#lines + 1] = { { s.name .. (data.unit ~= '' and (' (' .. data.unit .. ')') or ''), 'InkstoneTableHead' } }
        for i, value in ipairs(s.values) do
            local label = data.labels[i] .. ': '
            local bars = value and math.floor(math.abs(value) / math.max(maximum, 1e-10) * math.max(width - 24, 1)) or 0
            lines[#lines + 1] = { { label, 'InkstoneTableRow' }, { ('█'):rep(bars), 'InkstoneH2' },
                { value and (' ' .. tostring(value)) or ' —', 'InkstoneTableRow' } }
        end
    end
    return lines
end

return M
