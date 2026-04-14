local continuity = require('legate.session')
local status_message = require('legate.status_message')

---@class legate.HoverStatusRow
---@field message_id integer

---@class legate.HoverModule
local M = {}

---@type table<integer, table<integer, legate.HoverStatusRow>>
local status_rows = {}

---@param current_session legate.Session
---@param message_id integer
---@return legate.Message?
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
---@return legate.Message?
local function status_message_at_row(bufnr, row)
    local current_session = continuity.current()
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
---@param rows legate.RenderStatusRow[]
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
    local current_session = continuity.current()
    local message = status_message_at_row(bufnr, row + 1)

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
