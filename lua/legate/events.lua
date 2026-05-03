---@class legate.EventsModule
local M = {}

---@param current_session? legate.Session
---@return table
local function session_event_data(current_session)
    if current_session == nil then
        return {}
    end

    return {
        session_id = current_session.id,
        status = current_session.status,
        adapter_name = current_session.adapter_name,
        pending_approvals = #(current_session.pending_approvals or {}),
        remote_sync_state = current_session.remote_sync_state,
    }
end

---@param pattern string
---@param data table
local function emit_user_event(pattern, data)
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
        event = 'User',
        pattern = pattern,
    })

    if not ok or #autocmds == 0 then
        return
    end

    local function emit()
        pcall(vim.api.nvim_exec_autocmds, 'User', {
            pattern = pattern,
            data = data,
        })
    end

    if vim.in_fast_event() then
        vim.schedule(emit)
        return
    end

    emit()
end

---Notify integration consumers that session-backed Legate state changed.
---@param reason string
---@param current_session? legate.Session
function M.session_changed(reason, current_session)
    local data = session_event_data(current_session)
    data.reason = reason
    emit_user_event('LegateSessionChanged', data)
end

return M
