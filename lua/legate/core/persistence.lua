---@class legate.PersistenceModule
local M = {}
local CURRENT_VERSION = 1

---@param path string
---@param reason string
local function notify_restore_error(path, reason)
    vim.notify(string.format('Failed to restore ACP sessions from %s: %s', path, reason), vim.log.levels.ERROR)
end

---@param path? string
---@return string
local function state_file(path)
    return path or require('legate.config').get().session_state_file
end

---@param path? string
---@return string
local function state_dir(path)
    return string.format('%s.d', state_file(path))
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

---@param value string
---@return string
local function encode_path_component(value)
    return value:gsub('[^%w._-]', function(char)
        return string.format('%%%02X', char:byte())
    end)
end

---@param id string
---@return string
local function session_filename(id)
    return string.format('%s.json', encode_path_component(id))
end

---@param path string
---@return table?, string?
local function read_json(path)
    if vim.fn.filereadable(path) == 0 then
        return nil, nil
    end

    local read_ok, lines = pcall(vim.fn.readfile, path)
    if not read_ok then
        return nil, tostring(lines)
    end

    local ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
    if not ok or type(decoded) ~= 'table' then
        return nil, ok and 'invalid session state payload' or tostring(decoded)
    end

    return decoded, nil
end

---@param path string
---@param payload table
---@return boolean, string?
local function write_json(path, payload)
    local dir = vim.fn.fnamemodify(path, ':h')

    if dir ~= nil and dir ~= '' then
        local ok, result = pcall(vim.fn.mkdir, dir, 'p')

        if not ok then
            return false, tostring(result)
        end

        if result ~= 1 and result ~= 2 and result ~= 0 then
            return false, string.format('mkdir failed for %s', dir)
        end
    end

    local ok, result = pcall(vim.fn.writefile, { vim.json.encode(payload) }, path)

    if not ok then
        return false, tostring(result)
    end

    if result ~= 0 then
        return false, string.format('writefile failed for %s', path)
    end

    return true, nil
end

---@param session legate.Session
---@return table
local function index_entry(session)
    return {
        id = session.id,
        ordinal = session.ordinal,
        adapter_name = session.adapter_name,
        status = session.status,
        remote_id = session.remote_id,
        remote_sync_state = session.remote_sync_state,
        cwd = session.cwd,
        created_at = session.created_at,
        updated_at = session.updated_at,
        file = session_filename(session.id),
    }
end

---@param decoded table
---@return legate.SessionPersistencePayload
local function payload_from_index(decoded)
    local root = state_dir()
    local sessions = {}

    if vim.islist(decoded.sessions) then
        for _, entry in ipairs(decoded.sessions) do
            if type(entry) == 'table' and type(entry.id) == 'string' then
                local filename = type(entry.file) == 'string' and entry.file or session_filename(entry.id)
                local session, err = read_json(vim.fs.joinpath(root, 'sessions', filename))

                if session == nil and err ~= nil then
                    notify_restore_error(state_file(), err)
                elseif session ~= nil then
                    table.insert(sessions, session)
                end
            end
        end
    end

    return {
        current_id = type(decoded.current_id) == 'string' and decoded.current_id or nil,
        next_ordinal = tonumber(decoded.next_ordinal) or 1,
        next_message_id = tonumber(decoded.next_message_id) or 1,
        next_pending_approval_ordinal = tonumber(decoded.next_pending_approval_ordinal) or 1,
        sessions = sessions,
    }
end

---Load persisted ACP session state from disk.
---@return legate.SessionPersistencePayload|nil
function M.load()
    local path = state_file()
    local decoded, err = read_json(path)

    if decoded == nil then
        if err ~= nil then
            notify_restore_error(path, err)
            return nil
        end

        return empty_payload()
    end

    if decoded.version == CURRENT_VERSION then
        return payload_from_index(decoded)
    end

    return empty_payload()
end

---Persist ACP session state to disk.
---@param payload legate.SessionPersistencePayload
---@return boolean, string?
function M.save(payload)
    local path = state_file()
    local root = state_dir()
    local sessions = vim.islist(payload.sessions) and payload.sessions or {}

    for _, session in ipairs(sessions) do
        if type(session) == 'table' and type(session.id) == 'string' then
            local ok, err = write_json(vim.fs.joinpath(root, 'sessions', session_filename(session.id)), session)

            if not ok then
                return false, err
            end
        end
    end

    local ok, err = write_json(path, {
        version = CURRENT_VERSION,
        current_id = payload.current_id,
        next_ordinal = payload.next_ordinal,
        next_message_id = payload.next_message_id,
        next_pending_approval_ordinal = payload.next_pending_approval_ordinal,
        sessions = vim.tbl_map(index_entry, sessions),
    })

    if not ok then
        return false, err
    end

    return true
end

---Delete persisted ACP session state from disk.
function M.clear()
    local path = state_file()

    if vim.fn.filereadable(path) == 1 then
        vim.fn.delete(path)
    end

    local root = state_dir()
    if root ~= '' and root ~= '/' and vim.fn.isdirectory(root) == 1 then
        vim.fn.delete(root, 'rf')
    end
end

return M
