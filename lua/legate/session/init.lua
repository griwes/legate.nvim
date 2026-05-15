---@class legate.SessionModule
local M = {}
local session_activity = require('legate.session.activity')
local config = require('legate.config')
local events = require('legate.events')
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
local unpack = table.unpack or unpack

local function pack(...)
    return {
        n = select('#', ...),
        ...,
    }
end

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

M.create = registry_helper.create
M.ensure = registry_helper.ensure
M.current = registry_helper.current
M.get = registry_helper.get
M.select = registry_helper.select
M.list = registry_helper.list
M.close = registry_helper.close
M.waiting = registry_helper.waiting
M.pending_approval_session = registry_helper.pending_approval_session

M.append_message = state_helper.append_message
M.append_chunk = state_helper.append_chunk
M.set_draft_prompt = state_helper.set_draft_prompt
M.begin_prompt = state_helper.begin_prompt
M.enqueue_prompt = state_helper.enqueue_prompt
M.pop_queued_prompt = state_helper.pop_queued_prompt
M.queued_prompt_count = state_helper.queued_prompt_count
M.clear_queued_prompts = state_helper.clear_queued_prompts
M.current_turn_id = state_helper.current_turn_id
M.matches_turn = state_helper.matches_turn
M.finish_prompt = state_helper.finish_prompt
M.set_remote_id = state_helper.set_remote_id
M.set_transport_remote_id = state_helper.set_transport_remote_id
M.clear_remote_id = state_helper.clear_remote_id
M.transport_remote_id = state_helper.transport_remote_id
M.set_cwd = state_helper.set_cwd
M.set_remote_sync_state = state_helper.set_remote_sync_state
M.set_agent_info = state_helper.set_agent_info
M.set_config_options = state_helper.set_config_options
M.set_plan = state_helper.set_plan
M.set_available_commands = state_helper.set_available_commands

M.add_tool_call = activity_helper.add_tool_call
M.update_tool_call = activity_helper.update_tool_call
M.tool_call_by_id = activity_helper.tool_call_by_id
M.record_approval = activity_helper.record_approval
M.wait_for_approval = activity_helper.wait_for_approval
M.apply_update = activity_helper.apply_update
M.cancel = activity_helper.cancel
M.pending_approval = activity_helper.pending_approval
M.pending_approvals = activity_helper.pending_approvals
M.pending_approval_by_tool_call_id = activity_helper.pending_approval_by_tool_call_id
M.clear_pending_approval_by_request_id = activity_helper.clear_pending_approval_by_request_id
M.promote_pending_approval_by_request_id = activity_helper.promote_pending_approval_by_request_id
M.clear_pending_approval = activity_helper.clear_pending_approval

reconcile_status_messages = function(current_session)
    return activity_helper.reconcile_status_messages(current_session)
end

---@param value any
---@return boolean
local function is_session(value)
    return type(value) == 'table' and type(value.id) == 'string' and type(value.status) == 'string'
end

---@param values table
---@return legate.Session?
local function first_session(values)
    for index = 1, values.n or #values do
        local value = values[index]
        if is_session(value) then
            return value
        end
    end

    return nil
end

---@param name string
---@param reason? string
---@param resolve? fun(args: table, results: table): legate.Session?
local function publish_mutation(name, reason, resolve)
    local original = M[name]

    M[name] = function(...)
        local args = pack(...)
        local results = pack(original(unpack(args, 1, args.n)))
        local changed_session = resolve and resolve(args, results) or first_session(results) or first_session(args)

        events.session_changed(reason or name, changed_session)

        return unpack(results, 1, results.n)
    end
end

publish_mutation('set_adapter')
publish_mutation('reset_adapter_runtime_state')
publish_mutation('create')
publish_mutation('ensure')
publish_mutation('select')
publish_mutation('close', nil, function(_, results)
    return results[2]
end)
publish_mutation('append_message')
publish_mutation('append_chunk')
publish_mutation('set_draft_prompt')
publish_mutation('begin_prompt')
publish_mutation('enqueue_prompt')
publish_mutation('pop_queued_prompt')
publish_mutation('clear_queued_prompts')
publish_mutation('finish_prompt')
publish_mutation('set_remote_id')
publish_mutation('set_transport_remote_id')
publish_mutation('clear_remote_id')
publish_mutation('set_cwd')
publish_mutation('set_remote_sync_state')
publish_mutation('set_agent_info')
publish_mutation('set_config_options')
publish_mutation('set_plan')
publish_mutation('set_available_commands')
publish_mutation('add_tool_call')
publish_mutation('update_tool_call')
publish_mutation('record_approval')
publish_mutation('wait_for_approval')
publish_mutation('apply_update')
publish_mutation('clear_pending_approval_by_request_id')
publish_mutation('promote_pending_approval_by_request_id')
publish_mutation('clear_pending_approval')
publish_mutation('cancel')

---Clear all in-memory ACP session state.
function M.clear()
    registry_helper.clear()
    next_message_id = 1
    next_pending_approval_ordinal = 1
    events.session_changed('clear', nil)
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

    events.session_changed('restore', M.current())
    return ordered
end

return M
