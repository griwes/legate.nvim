---@class acp.PersistenceModule
local M = {}

---@return string
local function state_file()
    return require('acp.config').get().session_state_file
end

---@return string
local function state_dir()
    return vim.fn.fnamemodify(state_file(), ':h')
end

---@return acp.SessionPersistencePayload
local function empty_payload()
    return {
        current_id = nil,
        next_ordinal = 1,
        next_message_id = 1,
        sessions = {},
    }
end

---Load persisted ACP session state from disk.
---@return acp.SessionPersistencePayload
function M.load()
    local path = state_file()

    if vim.fn.filereadable(path) == 0 then
        return empty_payload()
    end

    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))

    if not ok or type(decoded) ~= 'table' then
        return empty_payload()
    end

    return {
        current_id = type(decoded.current_id) == 'string' and decoded.current_id or nil,
        next_ordinal = tonumber(decoded.next_ordinal) or 1,
        next_message_id = tonumber(decoded.next_message_id) or 1,
        sessions = type(decoded.sessions) == 'table' and decoded.sessions or {},
    }
end

---Persist ACP session state to disk.
---@param payload acp.SessionPersistencePayload
function M.save(payload)
    local path = state_file()

    vim.fn.mkdir(state_dir(), 'p')
    vim.fn.writefile({
        vim.json.encode(payload),
    }, path)
end

---Delete persisted ACP session state from disk.
function M.clear()
    local path = state_file()

    if vim.fn.filereadable(path) == 1 then
        vim.fn.delete(path)
    end
end

return M
