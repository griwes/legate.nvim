---@class legate.PersistenceModule
local M = {}

---@param path string
---@param reason string
local function notify_restore_error(path, reason)
    vim.notify(string.format('Failed to restore ACP sessions from %s: %s', path, reason), vim.log.levels.ERROR)
end

---@return string
local function state_file()
    return require('legate.config').get().session_state_file
end

---@return string
local function state_dir()
    return vim.fn.fnamemodify(state_file(), ':h')
end

---@return legate.SessionPersistencePayload
local function empty_payload()
    return {
        current_id = nil,
        next_ordinal = 1,
        next_message_id = 1,
        next_pending_approval_ordinal = 1,
        sessions = {},
    }
end

---Load persisted ACP session state from disk.
---@return legate.SessionPersistencePayload|nil
function M.load()
    local path = state_file()

    if vim.fn.filereadable(path) == 0 then
        return empty_payload()
    end

    local read_ok, lines = pcall(vim.fn.readfile, path)

    if not read_ok then
        notify_restore_error(path, tostring(lines))
        return nil
    end

    local ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))

    if not ok or type(decoded) ~= 'table' then
        notify_restore_error(path, ok and 'invalid session state payload' or tostring(decoded))
        return nil
    end

    return {
        current_id = type(decoded.current_id) == 'string' and decoded.current_id or nil,
        next_ordinal = tonumber(decoded.next_ordinal) or 1,
        next_message_id = tonumber(decoded.next_message_id) or 1,
        next_pending_approval_ordinal = tonumber(decoded.next_pending_approval_ordinal) or 1,
        sessions = vim.islist(decoded.sessions) and decoded.sessions or {},
    }
end

---Persist ACP session state to disk.
---@param payload legate.SessionPersistencePayload
---@return boolean, string?
function M.save(payload)
    local path = state_file()
    local dir = state_dir()

    if dir ~= nil and dir ~= '' then
        local ok, result = pcall(vim.fn.mkdir, dir, 'p')

        if not ok then
            return false, tostring(result)
        end

        if result ~= 1 and result ~= 2 and result ~= 0 then
            return false, string.format('mkdir failed for %s', dir)
        end
    end

    local ok, result = pcall(vim.fn.writefile, {
        vim.json.encode(payload),
    }, path)

    if not ok then
        return false, tostring(result)
    end

    if result ~= 0 then
        return false, string.format('writefile failed for %s', path)
    end

    return true
end

---Delete persisted ACP session state from disk.
function M.clear()
    local path = state_file()

    if vim.fn.filereadable(path) == 1 then
        vim.fn.delete(path)
    end
end

return M
