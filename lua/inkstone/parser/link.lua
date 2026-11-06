local M = {}

---Browsers can copy text fragments containing an unmatched literal `(`.
---Markdown rejects the destination, leaving only a shortcut_link for the label.
---Recover that specific, single-line URL without rewriting the source.
---@param buf integer
---@param node render.md.Node
---@return string?, integer?
function M.text_fragment(buf, node)
    if node.type ~= 'shortcut_link' or node.start_row ~= node.end_row then return end
    local line = vim.api.nvim_buf_get_lines(buf, node.end_row, node.end_row + 1, false)[1] or ''
    if not line:sub(node.end_col + 1, node.end_col + 9):match('^%(https?://') then return end
    if node:parent('link_text') or node:parent('image_description') then return end
    local inline = node:parent('inline')
    local stop = inline and inline.end_row == node.end_row and inline.end_col or #line
    -- Stop at whitespace, another label, code, HTML or a table cell. The last
    -- closing parenthesis in this token terminates the Markdown destination.
    local destination = line:sub(node.end_col + 1, stop):match('^%((https?://[^%s<>%[%]`|]+)%)')
    if not destination or not destination:find('#.-:~:text=') then return end
    local _, opening = destination:gsub('%(', '')
    local _, closing = destination:gsub('%)', '')
    if opening <= closing then return end
    return destination, node.end_col + #destination + 2
end

return M
