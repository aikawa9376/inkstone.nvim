local Base = require('inkstone.render.base')

---@class render.md.inline.link.Data
---@field icon render.md.mark.Text
---@field title? render.md.Node
---@field autolink boolean
---@field recovered_end? integer

---@class render.md.render.inline.Link: render.md.Render
---@field private config render.md.link.Config
---@field private data render.md.inline.link.Data
local Render = setmetatable({}, Base)
Render.__index = Render

---@protected
---@return boolean
function Render:setup()
    self.config = self.context.config.link
    if not self.config.enabled then
        return false
    end
    if self.node:descendant('shortcut_link') then
        return false
    end
    local icon = { self.config.hyperlink, self.config.highlight } ---@type render.md.mark.Text
    local title = nil ---@type render.md.Node?
    local autolink = false
    local recovered_end
    if self.node.type == 'shortcut_link' then
        local destination
        destination, recovered_end = require('inkstone.parser.link').text_fragment(self.context.buf, self.node)
        if not destination then return false end
        self.context.config:set_link_text(destination, icon)
    elseif self.node.type == 'email_autolink' then
        icon[1] = self.config.email
        autolink = true
    elseif self.node.type == 'image' then
        icon[1] = self.config.image
        local destination = self.node:child('link_destination')
        if destination and self.config.image_custom then
            self.context.config:set_link_text(destination.text, icon)
        end
        title = self.node:child('link_title')
    elseif self.node.type == 'inline_link' then
        local destination = self.node:child('link_destination')
        if destination then
            self.context.config:set_link_text(destination.text, icon)
        end
        title = self.node:child('link_title')
    elseif self.node.type == 'uri_autolink' then
        local destination = self.node.text:sub(2, -2)
        self.context.config:set_link_text(destination, icon)
        autolink = true
    end
    self.data = { icon = icon, title = title, autolink = autolink, recovered_end = recovered_end }
    return true
end

---@protected
function Render:run()
    if self.marks:start(self.config, 'link', self.node, {
        priority = 9000,
        hl_mode = 'combine',
        virt_text = { self.data.icon },
        virt_text_pos = 'inline',
    }) then
        local marks = self.marks:get()
        marks[#marks].link_range = { self.node.start_row, self.node.start_col,
            self.node.end_row, self.data.recovered_end or self.node.end_col }
    end
    self.marks:over(self.config, 'link', self.data.title, {
        priority = 1000,
        hl_group = self.config.highlight_title,
    })
    if self.data.autolink then
        self:hide(self.node.start_col, 1)
        self.marks:over(self.config, 'link', self.node, {
            priority = 1000,
            hl_group = self.data.icon[2],
        })
        self:hide(self.node.end_col - 1, 1)
    elseif self.data.recovered_end then
        self:hide(self.node.start_col, 1)
        self:hide(self.node.end_col - 1, self.data.recovered_end - self.node.end_col + 1)
    end
end

---@private
---@param col integer
---@param length integer
function Render:hide(col, length)
    self.marks:add(self.config, true, self.node.start_row, col, {
        end_col = col + length,
        conceal = '',
    })
end

return Render
