local session = require('acp.session')
local status_message = require('acp.status_message')

---@class acp.HoverStatusRow
---@field message_id integer

---@class acp.HoverModule
local M = {}

---@type table<integer, table<integer, acp.HoverStatusRow>>
local status_rows = {}

---@param current_session acp.Session
---@param message_id integer
---@return acp.Message?
local function message_by_id(current_session, message_id)
    for _, message in ipairs(current_session.messages) do
        if message.id == message_id then
            return message
        end
    end

    return nil
end

---@param bufnr integer
---@param row integer
---@return acp.Message?
local function status_message_at_row(bufnr, row)
    local current_session = session.current()
    local row_state = status_rows[bufnr]

    if current_session == nil or row_state == nil then
        return nil
    end

    local entry = row_state[row]

    if entry == nil then
        return nil
    end

    return message_by_id(current_session, entry.message_id)
end

---@param bufnr integer
---@param rows acp.RenderStatusRow[]
function M.set_status_rows(bufnr, rows)
    status_rows[bufnr] = {}

    for _, entry in ipairs(rows) do
        status_rows[bufnr][entry.row] = {
            message_id = entry.message_id,
        }
    end
end

---@param bufnr integer
function M.clear(bufnr)
    status_rows[bufnr] = nil
end

---@param bufnr integer
---@param row integer
---@return lsp.Hover?
function M.hover_result(bufnr, row)
    local current_session = session.current()
    local message = status_message_at_row(bufnr, row)

    if current_session == nil or message == nil then
        return nil
    end

    local lines = status_message.hover_lines(current_session, message)

    if lines == nil or #lines == 0 then
        return nil
    end

    return {
        contents = {
            kind = 'markdown',
            value = table.concat(lines, '\n'),
        },
    }
end

return M
