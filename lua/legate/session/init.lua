---@class legate.SessionModule
local M = {}
local session_activity = require('legate.session.activity')
local config = require('legate.config')
local session_persist = require('legate.session.persist')
local session_registry = require('legate.session.registry')
local session_state = require('legate.session.state')
local status_message = require('legate.status_message')

---@type table<string, legate.Session>
local sessions = {}
local current_id = nil
local next_ordinal = 1
local next_message_id = 1
local next_pending_approval_ordinal = 1
local reconcile_status_messages
local activity_helper
local persistence_helper
local registry_helper
local state_helper

---@param adapter_name? string
---@return string
local function resolved_adapter_name(adapter_name)
    if type(adapter_name) == 'string' and adapter_name ~= '' then
        local ok = pcall(config.adapter, adapter_name)

        if ok then
            return adapter_name
        end
    end

    return config.default_adapter_name()
end

---@return integer
local function now()
    return os.time()
end

---@param ordinal integer
---@return string
local function approval_stream_key(ordinal)
    return string.format('approval:%d', ordinal)
end

---@param status legate.ToolCallStatus
---@return boolean
local function is_finished_tool_status(status)
    return status == 'completed' or status == 'failed' or status == 'cancelled'
end

persistence_helper = session_persist.new({
    resolved_adapter_name = resolved_adapter_name,
    now = now,
    approval_stream_key = approval_stream_key,
    is_finished_tool_status = is_finished_tool_status,
})

---Set the configured adapter for a local ACP continuity.---@param current_session legate.Session
---@param adapter_name string
---@return legate.Session
function M.set_adapter(current_session, adapter_name)
    current_session.adapter_name = adapter_name
    current_session.updated_at = now()
    return current_session
end

---Clear adapter-owned remote/session metadata before rebinding under a new adapter.
---@param current_session legate.Session
---@return legate.Session
function M.reset_adapter_runtime_state(current_session)
    current_session.agent_info = nil
    current_session.remote_id = nil
    current_session.transport_remote_id = nil
    current_session.remote_sync_state = 'unbound'
    current_session.remote_sync_error = nil
    current_session.config_options = {}
    current_session.available_commands = {}
    current_session.cwd = nil
    current_session.updated_at = now()
    return current_session
end

registry_helper = session_registry.new({
    get_current_id = function()
        return current_id
    end,
    set_current_id = function(session_id)
        current_id = session_id
    end,
    get_next_ordinal = function()
        return next_ordinal
    end,
    set_next_ordinal = function(value)
        next_ordinal = value
    end,
    now = now,
    resolved_adapter_name = resolved_adapter_name,
    sessions = sessions,
})

---@param adapter_name? string
---@return legate.Session
function M.create(adapter_name)
    return registry_helper.create(adapter_name)
end

---@param adapter_name? string
---@return legate.Session
function M.ensure(adapter_name)
    return registry_helper.ensure(adapter_name)
end

---@return legate.Session?
function M.current()
    return registry_helper.current()
end

---@param session_id string
---@return legate.Session?
function M.get(session_id)
    return registry_helper.get(session_id)
end

---@param session_id string
---@return legate.Session
function M.select(session_id)
    return registry_helper.select(session_id)
end

---@return legate.Session[]
function M.list()
    return registry_helper.list()
end

---@param session_id string
---@return legate.Session, legate.Session?
function M.close(session_id)
    return registry_helper.close(session_id)
end

---@return legate.Session?
function M.waiting()
    return registry_helper.waiting()
end

---@return legate.Session?
function M.pending_approval_session()
    return registry_helper.pending_approval_session()
end

state_helper = session_state.new({
    now = now,
    normalize_available_commands = persistence_helper.normalize_available_commands,
    next_message_id = function()
        return next_message_id
    end,
    increment_message_id = function()
        next_message_id = next_message_id + 1
    end,
})

---@param session legate.Session
---@param role legate.MessageRole
---@param text string
---@param opts? { stream_kind?: 'tool_call'|'approval', stream_key?: string, status_state?: string, status_title?: string }
---@return legate.Message
function M.append_message(session, role, text, opts)
    return state_helper.append_message(session, role, text, opts)
end

---@param current_session legate.Session
---@param role legate.MessageRole
---@param text string
---@return legate.Message?
function M.append_chunk(current_session, role, text)
    return state_helper.append_chunk(current_session, role, text)
end

---@param current_session legate.Session
---@param prompt string
function M.set_draft_prompt(current_session, prompt)
    return state_helper.set_draft_prompt(current_session, prompt)
end

---@param current_session legate.Session
---@param prompt string
---@return legate.Session
function M.begin_prompt(current_session, prompt)
    return state_helper.begin_prompt(current_session, prompt)
end

---@param current_session legate.Session
---@return integer
function M.current_turn_id(current_session)
    return state_helper.current_turn_id(current_session)
end

---@param current_session legate.Session
---@param turn_id integer
---@return boolean
function M.matches_turn(current_session, turn_id)
    return state_helper.matches_turn(current_session, turn_id)
end

---@param current_session legate.Session
---@param stop_reason legate.StopReason
function M.finish_prompt(current_session, stop_reason)
    return state_helper.finish_prompt(current_session, stop_reason)
end

---@param current_session legate.Session
---@param remote_id string?
---@param remote_sync_state? legate.RemoteSyncState
---@param remote_sync_error? string
function M.set_remote_id(current_session, remote_id, remote_sync_state, remote_sync_error)
    return state_helper.set_remote_id(current_session, remote_id, remote_sync_state, remote_sync_error)
end

---@param current_session legate.Session
---@param remote_id string?
---@param remote_sync_state? legate.RemoteSyncState
---@param remote_sync_error? string
function M.set_transport_remote_id(current_session, remote_id, remote_sync_state, remote_sync_error)
    return state_helper.set_transport_remote_id(current_session, remote_id, remote_sync_state, remote_sync_error)
end

---@param current_session legate.Session
---@param remote_sync_state? legate.RemoteSyncState
---@param remote_sync_error? string
function M.clear_remote_id(current_session, remote_sync_state, remote_sync_error)
    return state_helper.clear_remote_id(current_session, remote_sync_state, remote_sync_error)
end

---@param current_session legate.Session
---@return string?
function M.transport_remote_id(current_session)
    return state_helper.transport_remote_id(current_session)
end

---@param current_session legate.Session
---@param cwd string?
function M.set_cwd(current_session, cwd)
    return state_helper.set_cwd(current_session, cwd)
end

---@param current_session legate.Session
---@param remote_sync_state legate.RemoteSyncState
---@param remote_sync_error? string
function M.set_remote_sync_state(current_session, remote_sync_state, remote_sync_error)
    return state_helper.set_remote_sync_state(current_session, remote_sync_state, remote_sync_error)
end

---@param current_session legate.Session
---@param agent_info? legate.AgentInfo
function M.set_agent_info(current_session, agent_info)
    return state_helper.set_agent_info(current_session, agent_info)
end

---@param current_session legate.Session
---@param config_options legate.SessionConfigOption[]
function M.set_config_options(current_session, config_options)
    return state_helper.set_config_options(current_session, config_options)
end

---@param current_session legate.Session
---@param entries legate.PlanEntry[]
function M.set_plan(current_session, entries)
    return state_helper.set_plan(current_session, entries)
end

---@param current_session legate.Session
---@param available_commands legate.AvailableCommand[]
function M.set_available_commands(current_session, available_commands)
    return state_helper.set_available_commands(current_session, available_commands)
end

activity_helper = session_activity.new({
    now = now,
    approval_stream_key = approval_stream_key,
    append_message = state_helper.append_message,
    append_chunk = state_helper.append_chunk,
    set_plan = state_helper.set_plan,
    set_available_commands = state_helper.set_available_commands,
    set_config_options = state_helper.set_config_options,
    status_message = status_message,
    is_finished_tool_status = is_finished_tool_status,
    next_pending_approval_ordinal = function()
        return next_pending_approval_ordinal
    end,
    increment_pending_approval_ordinal = function()
        next_pending_approval_ordinal = next_pending_approval_ordinal + 1
    end,
})

---@param current_session legate.Session
---@param tool_call legate.ToolCall
---@return legate.ToolCallState
function M.add_tool_call(current_session, tool_call)
    return activity_helper.add_tool_call(current_session, tool_call)
end

---@param current_session legate.Session
---@param tool_call_update legate.ToolCallUpdate
---@return legate.ToolCallState
function M.update_tool_call(current_session, tool_call_update)
    return activity_helper.update_tool_call(current_session, tool_call_update)
end

---@param current_session legate.Session
---@param tool_call_id string?
---@return legate.ToolCallState?
function M.tool_call_by_id(current_session, tool_call_id)
    return activity_helper.tool_call_by_id(current_session, tool_call_id)
end

---@param current_session legate.Session
---@param permission legate.PermissionRequest
---@param outcome legate.PermissionOutcome
---@param source legate.PermissionStrategy
function M.record_approval(current_session, permission, outcome, source)
    return activity_helper.record_approval(current_session, permission, outcome, source)
end

---@param current_session legate.Session
---@param permission legate.PermissionRequest
function M.wait_for_approval(current_session, permission)
    return activity_helper.wait_for_approval(current_session, permission)
end

---@param current_session legate.Session
---@param update table
function M.apply_update(current_session, update)
    return activity_helper.apply_update(current_session, update)
end

---@param current_session legate.Session
---@return legate.Session
function M.cancel(current_session)
    return activity_helper.cancel(current_session)
end

---@param current_session legate.Session
---@return legate.PendingApproval?
function M.pending_approval(current_session)
    return activity_helper.pending_approval(current_session)
end

---@param current_session legate.Session
---@return legate.PendingApproval[]
function M.pending_approvals(current_session)
    return activity_helper.pending_approvals(current_session)
end

---@param current_session legate.Session
---@param tool_call_id string?
---@return legate.PendingApproval?
function M.pending_approval_by_tool_call_id(current_session, tool_call_id)
    return activity_helper.pending_approval_by_tool_call_id(current_session, tool_call_id)
end

---@param current_session legate.Session
---@param request_id string
---@return legate.PendingApproval?
function M.clear_pending_approval_by_request_id(current_session, request_id)
    return activity_helper.clear_pending_approval_by_request_id(current_session, request_id)
end

---@param current_session legate.Session
---@param request_id string
---@return legate.PendingApproval?
function M.promote_pending_approval_by_request_id(current_session, request_id)
    return activity_helper.promote_pending_approval_by_request_id(current_session, request_id)
end

---@param current_session legate.Session
---@param tool_call_id string?
---@return legate.PendingApproval?
function M.clear_pending_approval(current_session, tool_call_id)
    return activity_helper.clear_pending_approval(current_session, tool_call_id)
end

reconcile_status_messages = function(current_session)
    return activity_helper.reconcile_status_messages(current_session)
end

---Clear all in-memory ACP session state.
function M.clear()
    registry_helper.clear()
    next_message_id = 1
    next_pending_approval_ordinal = 1
end

---Return a persisted snapshot of all local ACP sessions.
---@return legate.SessionPersistencePayload
function M.snapshot()
    local persisted = {}

    for _, current_session in ipairs(M.list()) do
        table.insert(persisted, persistence_helper.persisted_session(current_session))
    end

    return {
        current_id = current_id,
        next_ordinal = next_ordinal,
        next_message_id = next_message_id,
        next_pending_approval_ordinal = next_pending_approval_ordinal,
        sessions = persisted,
    }
end

---Restore all local ACP sessions from a persisted snapshot.
---@param payload legate.SessionPersistencePayload
---@return legate.Session[]
function M.restore(payload)
    M.clear()

    local payload_sessions = payload.sessions

    if payload_sessions ~= nil and not vim.islist(payload_sessions) then
        vim.notify('ACP saved session file is corrupted: sessions must be a list', vim.log.levels.ERROR)
        payload_sessions = {}
    end

    local max_ordinal = 0
    local max_message_id = 0

    for _, item in ipairs(payload_sessions or {}) do
        if type(item) == 'table' then
            local restored = persistence_helper.restore_session(item)

            if restored ~= nil then
                sessions[restored.id] = restored
                reconcile_status_messages(restored)
                max_ordinal = math.max(max_ordinal, restored.ordinal)

                for _, message in ipairs(restored.messages) do
                    if type(message) == 'table' then
                        max_message_id = math.max(max_message_id, tonumber(message.id) or 0)
                    end
                end
            end
        end
    end

    local ordered = M.list()
    local payload_current_id = type(payload.current_id) == 'string' and payload.current_id or nil

    if payload_current_id ~= nil and sessions[payload_current_id] ~= nil then
        current_id = payload_current_id
    elseif #ordered > 0 then
        current_id = ordered[1].id
    else
        current_id = nil
    end

    next_ordinal = math.max(tonumber(payload.next_ordinal) or 1, max_ordinal + 1)
    next_message_id = math.max(tonumber(payload.next_message_id) or 1, max_message_id + 1)
    next_pending_approval_ordinal = tonumber(payload.next_pending_approval_ordinal) or 1

    for _, current_session in ipairs(ordered) do
        for _, approval in ipairs(current_session.approval_entries or {}) do
            next_pending_approval_ordinal =
                math.max(next_pending_approval_ordinal, (tonumber(approval.ordinal) or 0) + 1)
        end

        for _, pending in ipairs(current_session.pending_approvals or {}) do
            next_pending_approval_ordinal =
                math.max(next_pending_approval_ordinal, (tonumber(pending.ordinal) or 0) + 1)
        end
    end

    return ordered
end

return M
