---@class acp.SessionModule
local M = {}
local status_message = require('acp.status_message')

---@type table<string, acp.Session>
local sessions = {}
local current_id = nil
local next_ordinal = 1
local next_message_id = 1
local next_pending_approval_ordinal = 1
local reconcile_status_messages

---@return integer
local function now()
    return os.time()
end

---@param tool_call acp.ToolCallState
---@return string
local function tool_stream_key(tool_call)
    return tool_call.stream_key
end

---@param ordinal integer
---@return string
local function approval_stream_key(ordinal)
    return string.format('approval:%d', ordinal)
end

---@return acp.Session
local function make_session()
    local ordinal = next_ordinal
    next_ordinal = next_ordinal + 1

    local timestamp = now()

    return {
        id = string.format('acp:%d', ordinal),
        ordinal = ordinal,
        status = 'idle',
        messages = {},
        draft_prompt = '',
        pending_approvals = {},
        plan_entries = {},
        available_commands = {},
        tool_calls = {},
        approval_entries = {},
        config_options = {},
        remote_sync_error = nil,
        remote_sync_state = 'unbound',
        turn_id = 0,
        created_at = timestamp,
        updated_at = timestamp,
        transport_remote_id = nil,
    }
end

---@param current_session acp.Session
---@param tool_call_id string
---@return integer?, acp.ToolCallState?
local function find_tool_call(current_session, tool_call_id)
    for index, tool_call in ipairs(current_session.tool_calls) do
        if tool_call.tool_call_id == tool_call_id then
            return index, tool_call
        end
    end

    return nil, nil
end

---@param status acp.ToolCallStatus
---@return boolean
local function is_finished_tool_status(status)
    return status == 'completed' or status == 'failed' or status == 'cancelled'
end

---@param status any
---@return acp.SessionStatus
local function normalize_status(status)
    if status == 'idle' or status == 'waiting' or status == 'cancelled' then
        return status
    end

    return 'idle'
end

---@param sync_state any
---@param remote_id string?
---@return acp.RemoteSyncState
local function normalize_remote_sync_state(sync_state, remote_id)
    if sync_state == 'unbound' or sync_state == 'created' or sync_state == 'loaded' or sync_state == 'load_failed' then
        return sync_state
    end

    if remote_id ~= nil then
        return 'created'
    end

    return 'unbound'
end

---@param input any
---@return table?
local function normalize_command_input(input)
    if type(input) ~= 'table' then
        return nil
    end

    return vim.deepcopy(input)
end

---@param available_commands any
---@return acp.AvailableCommand[]
local function normalize_available_commands(available_commands)
    if type(available_commands) ~= 'table' then
        return {}
    end

    local normalized = {}

    for _, command in ipairs(available_commands) do
        if type(command) == 'table' then
            local next_command = vim.deepcopy(command)

            next_command.input = normalize_command_input(next_command.input)
            table.insert(normalized, next_command)
        end
    end

    return normalized
end

---@param current_session acp.Session
---@return acp.Session
local function persisted_session(current_session)
    local snapshot = vim.deepcopy(current_session)

    if snapshot.pending_prompt ~= nil and snapshot.pending_prompt ~= '' and snapshot.draft_prompt == '' then
        snapshot.draft_prompt = snapshot.pending_prompt
    end

    snapshot.transport_remote_id = nil

    snapshot.pending_prompt = nil
    snapshot.pending_approvals = type(snapshot.pending_approvals) == 'table' and snapshot.pending_approvals or {}

    if snapshot.status == 'waiting' then
        snapshot.status = 'cancelled'
        snapshot.stop_reason = 'cancelled'

        for _, tool_call in ipairs(snapshot.tool_calls) do
            if not is_finished_tool_status(tool_call.status) then
                tool_call.status = 'cancelled'
            end
        end
    end

    return snapshot
end

---@param item table
---@return acp.Session?
local function restore_session(item)
    local session_id = type(item.id) == 'string' and item.id or nil

    if session_id == nil then
        return nil
    end

    local restored = vim.deepcopy(item)

    restored.id = session_id
    restored.ordinal = tonumber(restored.ordinal) or 1
    restored.status = normalize_status(restored.status)
    restored.messages = type(restored.messages) == 'table' and restored.messages or {}
    restored.draft_prompt = type(restored.draft_prompt) == 'string' and restored.draft_prompt or ''

    if type(restored.pending_prompt) == 'string' and restored.pending_prompt ~= '' and restored.draft_prompt == '' then
        restored.draft_prompt = restored.pending_prompt
    end

    restored.pending_prompt = nil
    restored.pending_approvals = type(restored.pending_approvals) == 'table' and restored.pending_approvals or {}
    restored.remote_id = type(restored.remote_id) == 'string' and restored.remote_id or nil
    restored.remote_sync_state = normalize_remote_sync_state(restored.remote_sync_state, restored.remote_id)
    restored.remote_sync_error = type(restored.remote_sync_error) == 'string'
            and restored.remote_sync_error ~= ''
            and restored.remote_sync_error
        or nil
    restored.plan_entries = type(restored.plan_entries) == 'table' and restored.plan_entries or {}
    restored.available_commands = normalize_available_commands(restored.available_commands)
    restored.tool_calls = type(restored.tool_calls) == 'table' and restored.tool_calls or {}
    restored.approval_entries = type(restored.approval_entries) == 'table' and restored.approval_entries or {}
    restored.config_options = type(restored.config_options) == 'table' and restored.config_options or {}
    restored.turn_id = math.max(tonumber(restored.turn_id) or 0, 0)
    restored.transport_remote_id = nil
    restored.created_at = tonumber(restored.created_at) or now()
    restored.updated_at = tonumber(restored.updated_at) or restored.created_at

    if restored.remote_sync_state ~= 'load_failed' then
        restored.remote_sync_error = nil
    end

    if restored.status == 'waiting' then
        restored.status = 'cancelled'
        restored.stop_reason = 'cancelled'
    end

    return restored
end

---@param session acp.Session
---@return acp.Session
local function store(session)
    sessions[session.id] = session
    current_id = session.id
    return session
end

---Create and select a new ACP session.
---@return acp.Session
function M.create()
    return store(make_session())
end

---Ensure there is a current ACP session.
---@return acp.Session
function M.ensure()
    local session = M.current()

    if session ~= nil then
        return session
    end

    return M.create()
end

---Return the current ACP session.
---@return acp.Session?
function M.current()
    if current_id == nil then
        return nil
    end

    return sessions[current_id]
end

---Return a session by its local identifier.
---@param session_id string
---@return acp.Session?
function M.get(session_id)
    return sessions[session_id]
end

---Select an existing ACP session as current.
---@param session_id string
---@return acp.Session
function M.select(session_id)
    local current_session = M.get(session_id)

    if current_session == nil then
        error(string.format('Unknown ACP session: %s', session_id))
    end

    current_id = session_id

    return current_session
end

---@param session_id string
---@return integer?, acp.Session[]
local function ordered_index(session_id)
    local ordered = M.list()

    for index, current_session in ipairs(ordered) do
        if current_session.id == session_id then
            return index, ordered
        end
    end

    return nil, ordered
end

---Return all sessions ordered by creation ordinal.
---@return acp.Session[]
function M.list()
    local ordered = {}

    for _, session in pairs(sessions) do
        table.insert(ordered, session)
    end

    table.sort(ordered, function(left, right)
        return left.ordinal < right.ordinal
    end)

    return ordered
end

---Remove a local ACP session and choose the next current session when needed.
---@param session_id string
---@return acp.Session, acp.Session?
function M.close(session_id)
    local closing_session = M.get(session_id)

    if closing_session == nil then
        error(string.format('Unknown ACP session: %s', session_id))
    end

    local index, ordered = ordered_index(session_id)

    sessions[session_id] = nil

    if current_id ~= session_id then
        return closing_session, M.current()
    end

    local next_session = nil

    if index ~= nil then
        next_session = ordered[index - 1] or ordered[index + 1]
    end

    current_id = next_session and next_session.id or nil

    return closing_session, next_session
end

---Return the first session that currently has a live prompt turn.
---@return acp.Session?
function M.waiting()
    for _, current_session in ipairs(M.list()) do
        if current_session.status == 'waiting' then
            return current_session
        end
    end

    return nil
end

---Return the first session with a pending inline approval.
---@return acp.Session?
function M.pending_approval_session()
    for _, current_session in ipairs(M.list()) do
        if #(current_session.pending_approvals or {}) > 0 then
            return current_session
        end
    end

    return nil
end

---Append a transcript message to a session.
---@param session acp.Session
---@param role acp.MessageRole
---@param text string
---@param opts? { stream_kind?: 'tool_call'|'approval', stream_key?: string, status_state?: string, status_title?: string }
---@return acp.Message
function M.append_message(session, role, text, opts)
    local message = {
        id = next_message_id,
        role = role,
        text = text,
        created_at = now(),
        stream_kind = opts and opts.stream_kind or nil,
        stream_key = opts and opts.stream_key or nil,
        status_state = opts and opts.status_state or nil,
        status_title = opts and opts.status_title or nil,
    }

    next_message_id = next_message_id + 1
    table.insert(session.messages, message)
    session.updated_at = now()

    return message
end

---@param previous string
---@param next_chunk string
---@return boolean
local function needs_chunk_spacing(previous, next_chunk)
    if previous == '' or next_chunk == '' then
        return false
    end

    local previous_last = previous:sub(-1)
    local next_first = next_chunk:sub(1, 1)

    if next_first:match('%s') or next_first:match('^[%]%)}%.,;:!?]$') then
        return false
    end

    return previous_last:match('[%.!?]') ~= nil
end

---@param current_session acp.Session
---@param role acp.MessageRole
---@param text string
---@return acp.Message?
function M.append_chunk(current_session, role, text)
    if text == '' then
        return nil
    end

    local last = current_session.messages[#current_session.messages]

    if last ~= nil and last.role == role then
        local separator = needs_chunk_spacing(last.text, text) and ' ' or ''

        last.text = last.text .. separator .. text
        current_session.updated_at = now()
        return last
    end

    return M.append_message(current_session, role, text)
end

---@param current_session acp.Session
---@param stream_kind 'tool_call'|'approval'
---@param stream_key string
---@return acp.Message?
local function stream_status_message(current_session, stream_kind, stream_key)
    for _, message in ipairs(current_session.messages) do
        if message.role == 'status' and message.stream_kind == stream_kind and message.stream_key == stream_key then
            return message
        end
    end

    return nil
end

---@param current_session acp.Session
---@param stream_kind 'tool_call'|'approval'
---@param stream_key string
---@param text string
---@param opts { status_state?: string, status_title?: string }
local function upsert_status_message(current_session, stream_kind, stream_key, text, opts)
    local message = stream_status_message(current_session, stream_kind, stream_key)

    if message ~= nil then
        message.text = text
        message.status_state = opts.status_state
        message.status_title = opts.status_title
        current_session.updated_at = now()
        return message
    end

    return M.append_message(current_session, 'status', text, {
        stream_kind = stream_kind,
        stream_key = stream_key,
        status_state = opts.status_state,
        status_title = opts.status_title,
    })
end

---Store the unsent draft prompt for a session.
---@param current_session acp.Session
---@param prompt string
function M.set_draft_prompt(current_session, prompt)
    current_session.draft_prompt = prompt
    current_session.updated_at = now()
end

---Record a submitted prompt on the given ACP session.
---@param current_session acp.Session
---@param prompt string
---@return acp.Session
function M.begin_prompt(current_session, prompt)
    current_session.turn_id = current_session.turn_id + 1
    current_session.pending_prompt = prompt
    current_session.draft_prompt = ''
    current_session.stop_reason = nil
    current_session.plan_entries = {}
    current_session.status = 'waiting'
    M.append_message(current_session, 'user', prompt)

    return current_session
end

---@param current_session acp.Session
---@return integer
function M.current_turn_id(current_session)
    return current_session.turn_id
end

---@param current_session acp.Session
---@param turn_id integer
---@return boolean
function M.matches_turn(current_session, turn_id)
    return current_session.turn_id == turn_id
end

---Mark a prompt turn as finished with the given stop reason.
---@param current_session acp.Session
---@param stop_reason acp.StopReason
function M.finish_prompt(current_session, stop_reason)
    current_session.pending_prompt = nil
    current_session.pending_approval = nil
    current_session.stop_reason = stop_reason
    current_session.status = stop_reason == 'cancelled' and 'cancelled' or 'idle'
    current_session.updated_at = now()
end

---Bind a remote ACP session id to the local session.
---@param current_session acp.Session
---@param remote_id string?
---@param remote_sync_state? acp.RemoteSyncState
---@param remote_sync_error? string
function M.set_remote_id(current_session, remote_id, remote_sync_state, remote_sync_error)
    current_session.remote_id = remote_id
    current_session.transport_remote_id = remote_id
    current_session.remote_sync_state = remote_sync_state or current_session.remote_sync_state
    current_session.remote_sync_error = remote_sync_error
    current_session.updated_at = now()
end

---@param current_session acp.Session
---@param remote_id string?
---@param remote_sync_state? acp.RemoteSyncState
---@param remote_sync_error? string
function M.set_transport_remote_id(current_session, remote_id, remote_sync_state, remote_sync_error)
    current_session.transport_remote_id = remote_id
    current_session.remote_sync_state = remote_sync_state or current_session.remote_sync_state
    current_session.remote_sync_error = remote_sync_error
    current_session.updated_at = now()
end

---Clear the remote ACP session binding from the local session.
---@param current_session acp.Session
---@param remote_sync_state? acp.RemoteSyncState
---@param remote_sync_error? string
function M.clear_remote_id(current_session, remote_sync_state, remote_sync_error)
    current_session.remote_id = nil
    current_session.transport_remote_id = nil
    current_session.remote_sync_state = remote_sync_state or 'unbound'
    current_session.remote_sync_error = remote_sync_error
    current_session.updated_at = now()
end

---@param current_session acp.Session
---@return string?
function M.transport_remote_id(current_session)
    return current_session.transport_remote_id
end

---Store the current remote sync state on the local session.
---@param current_session acp.Session
---@param remote_sync_state acp.RemoteSyncState
---@param remote_sync_error? string
function M.set_remote_sync_state(current_session, remote_sync_state, remote_sync_error)
    current_session.remote_sync_state = remote_sync_state
    current_session.remote_sync_error = remote_sync_error
    current_session.updated_at = now()
end

---Store agent metadata on the local session.
---@param current_session acp.Session
---@param agent_info? acp.AgentInfo
function M.set_agent_info(current_session, agent_info)
    current_session.agent_info = agent_info
    current_session.updated_at = now()
end

---Store session config options for the local session.
---@param current_session acp.Session
---@param config_options acp.SessionConfigOption[]
function M.set_config_options(current_session, config_options)
    current_session.config_options = config_options
    current_session.updated_at = now()
end

---Store the current ACP plan entries on the local session.
---@param current_session acp.Session
---@param entries acp.PlanEntry[]
function M.set_plan(current_session, entries)
    current_session.plan_entries = vim.deepcopy(entries)
    current_session.updated_at = now()
end

---Store the current ACP slash commands on the local session.
---@param current_session acp.Session
---@param available_commands acp.AvailableCommand[]
function M.set_available_commands(current_session, available_commands)
    current_session.available_commands = normalize_available_commands(available_commands)
    current_session.updated_at = now()
end

---@param current_session acp.Session
---@param tool_call acp.ToolCall
---@return acp.ToolCallState
function M.add_tool_call(current_session, tool_call)
    local _, existing = find_tool_call(current_session, tool_call.toolCallId)

    if existing ~= nil then
        return M.update_tool_call(current_session, tool_call)
    end

    local next_tool_call = {
        tool_call_id = tool_call.toolCallId,
        stream_key = string.format('tool:%d:%s', current_session.turn_id, tool_call.toolCallId),
        title = tool_call.title,
        status = tool_call.status or 'pending',
        kind = tool_call.kind,
        locations = vim.deepcopy(tool_call.locations or {}),
        content = vim.deepcopy(tool_call.content or {}),
        raw_input = vim.deepcopy(tool_call.rawInput),
        raw_output = vim.deepcopy(tool_call.rawOutput),
    }

    table.insert(current_session.tool_calls, next_tool_call)
    current_session.updated_at = now()
    upsert_status_message(
        current_session,
        'tool_call',
        tool_stream_key(next_tool_call),
        status_message.tool_call_status_text(next_tool_call),
        {
            status_state = next_tool_call.status,
            status_title = next_tool_call.title,
        }
    )

    return next_tool_call
end

---@param current_session acp.Session
---@param tool_call_update acp.ToolCallUpdate
---@return acp.ToolCallState
function M.update_tool_call(current_session, tool_call_update)
    local _, tool_call = find_tool_call(current_session, tool_call_update.toolCallId)

    if tool_call == nil then
        tool_call = {
            tool_call_id = tool_call_update.toolCallId,
            stream_key = string.format('tool:%d:%s', current_session.turn_id, tool_call_update.toolCallId),
            title = tool_call_update.title or tool_call_update.toolCallId,
            status = tool_call_update.status or 'pending',
            locations = {},
            content = {},
        }
        table.insert(current_session.tool_calls, tool_call)
    end

    if tool_call_update.title ~= nil then
        tool_call.title = tool_call_update.title
    end

    if tool_call_update.status ~= nil then
        tool_call.status = tool_call_update.status
    end

    if tool_call_update.kind ~= nil then
        tool_call.kind = tool_call_update.kind
    end

    if tool_call_update.locations ~= nil then
        tool_call.locations = vim.deepcopy(tool_call_update.locations)
    end

    if tool_call_update.content ~= nil then
        tool_call.content = vim.deepcopy(tool_call_update.content)
    end

    if tool_call_update.rawInput ~= nil then
        tool_call.raw_input = vim.deepcopy(tool_call_update.rawInput)
    end

    if tool_call_update.rawOutput ~= nil then
        tool_call.raw_output = vim.deepcopy(tool_call_update.rawOutput)
    end

    current_session.updated_at = now()
    upsert_status_message(
        current_session,
        'tool_call',
        tool_stream_key(tool_call),
        status_message.tool_call_status_text(tool_call),
        {
            status_state = tool_call.status,
            status_title = tool_call.title,
        }
    )

    return tool_call
end

---@param current_session acp.Session
---@param tool_call_id string?
---@return acp.ToolCallState?
function M.tool_call_by_id(current_session, tool_call_id)
    if tool_call_id == nil then
        return nil
    end

    local _, tool_call = find_tool_call(current_session, tool_call_id)
    return tool_call
end

---@param current_session acp.Session
---@param permission acp.PermissionRequest
---@param outcome acp.PermissionOutcome
---@param source acp.PermissionStrategy
function M.record_approval(current_session, permission, outcome, source)
    local matched_tool_call = M.tool_call_by_id(current_session, permission.toolCall.toolCallId)
    local selected_kind = nil
    local selected_option_name = nil

    if outcome.outcome == 'selected' and outcome.optionId ~= nil then
        for _, option in ipairs(permission.options) do
            if option.optionId == outcome.optionId then
                selected_kind = option.kind
                selected_option_name = option.name
                break
            end
        end
    end

    local approval = {
        ordinal = #current_session.approval_entries + 1,
        stream_key = approval_stream_key(#current_session.approval_entries + 1),
        tool_call_id = permission.toolCall.toolCallId,
        title = permission.toolCall.title
            or (matched_tool_call and matched_tool_call.title)
            or permission.toolCall.toolCallId
            or 'Approval',
        outcome = outcome.outcome,
        source = source,
        selected_kind = selected_kind,
        selected_option_name = selected_option_name,
        selected_option_id = outcome.optionId,
        options = vim.deepcopy(permission.options),
    }

    table.insert(current_session.approval_entries, approval)
    for index, pending in ipairs(current_session.pending_approvals) do
        if pending.request_id == permission.request_id then
            table.remove(current_session.pending_approvals, index)
            break
        end
    end
    upsert_status_message(
        current_session,
        'approval',
        approval.stream_key,
        status_message.approval_status_text(approval),
        {
            status_state = approval.selected_kind or approval.outcome,
            status_title = string.format('Approval [%d] %s', approval.ordinal, approval.title),
        }
    )
    current_session.updated_at = now()
end

---@param current_session acp.Session
---@param permission acp.PermissionRequest
function M.wait_for_approval(current_session, permission)
    local tool_call_id = permission.toolCall.toolCallId

    if tool_call_id ~= nil then
        M.update_tool_call(current_session, {
            toolCallId = tool_call_id,
            title = permission.toolCall.title,
            status = 'waiting_for_approval',
        })
    end

    table.insert(current_session.pending_approvals, {
        request_id = permission.request_id,
        ordinal = next_pending_approval_ordinal,
        tool_call_id = tool_call_id,
        title = permission.toolCall.title or tool_call_id or 'Approval',
        options = vim.deepcopy(permission.options),
        generation = permission.generation,
        created_at = now(),
    })
    next_pending_approval_ordinal = next_pending_approval_ordinal + 1
    current_session.updated_at = now()
end

---@param current_session acp.Session
---@param update table
function M.apply_update(current_session, update)
    local kind = update.sessionUpdate

    if kind == 'agent_message_chunk' and update.content ~= nil and update.content.type == 'text' then
        M.append_chunk(current_session, 'assistant', update.content.text)
        return
    end

    if kind == 'user_message_chunk' and update.content ~= nil and update.content.type == 'text' then
        M.append_chunk(current_session, 'user', update.content.text)
        return
    end

    if kind == 'plan' then
        M.set_plan(current_session, update.entries or {})
        return
    end

    if kind == 'available_commands_update' then
        M.set_available_commands(current_session, update.availableCommands or {})
        return
    end

    if kind == 'config_option_update' then
        M.set_config_options(current_session, update.configOptions or {})
        return
    end

    if kind == 'session_info_update' then
        current_session.updated_at = now()
        return
    end

    if kind == 'tool_call' then
        M.add_tool_call(current_session, update)
        return
    end

    if kind == 'tool_call_update' then
        M.update_tool_call(current_session, update)
    end
end

---Cancel an ACP session prompt state.
---@param current_session acp.Session
---@return acp.Session
function M.cancel(current_session)
    for _, tool_call in ipairs(current_session.tool_calls) do
        if not is_finished_tool_status(tool_call.status) then
            tool_call.status = 'cancelled'
            upsert_status_message(
                current_session,
                'tool_call',
                tool_stream_key(tool_call),
                status_message.tool_call_status_text(tool_call),
                {
                    status_state = tool_call.status,
                    status_title = tool_call.title,
                }
            )
        end
    end

    current_session.turn_id = current_session.turn_id + 1
    current_session.pending_prompt = nil
    current_session.pending_approvals = {}
    current_session.status = 'cancelled'
    current_session.updated_at = now()

    return current_session
end

---@param current_session acp.Session
---@return acp.PendingApproval?
function M.pending_approval(current_session)
    return current_session.pending_approvals[1]
end

---@param current_session acp.Session
---@return acp.PendingApproval[]
function M.pending_approvals(current_session)
    return current_session.pending_approvals
end

---@param current_session acp.Session
---@param tool_call_id string?
---@return acp.PendingApproval?
function M.pending_approval_by_tool_call_id(current_session, tool_call_id)
    if tool_call_id == nil then
        return nil
    end

    for _, pending in ipairs(current_session.pending_approvals) do
        if pending.tool_call_id == tool_call_id then
            return pending
        end
    end

    return nil
end

---@param current_session acp.Session
---@param request_id string
---@return acp.PendingApproval?
function M.clear_pending_approval_by_request_id(current_session, request_id)
    for index, pending in ipairs(current_session.pending_approvals or {}) do
        if pending.request_id == request_id then
            table.remove(current_session.pending_approvals, index)
            current_session.updated_at = now()
            return pending
        end
    end

    return nil
end

---@param current_session acp.Session
---@param tool_call_id string?
---@return acp.PendingApproval?
function M.clear_pending_approval(current_session, tool_call_id)
    local pending = M.pending_approval_by_tool_call_id(current_session, tool_call_id)

    if pending == nil then
        return nil
    end

    return M.clear_pending_approval_by_request_id(current_session, pending.request_id)
end

reconcile_status_messages = function(current_session)
    for _, tool_call in ipairs(current_session.tool_calls) do
        if tool_call.stream_key == nil or tool_call.stream_key == '' then
            tool_call.stream_key = string.format('tool:%d:%s', current_session.turn_id, tool_call.tool_call_id)
        end

        upsert_status_message(
            current_session,
            'tool_call',
            tool_stream_key(tool_call),
            status_message.tool_call_status_text(tool_call),
            {
                status_state = tool_call.status,
                status_title = tool_call.title,
            }
        )
    end

    for _, approval in ipairs(current_session.approval_entries) do
        if approval.stream_key == nil or approval.stream_key == '' then
            approval.stream_key = approval_stream_key(approval.ordinal)
        end

        upsert_status_message(
            current_session,
            'approval',
            approval.stream_key,
            status_message.approval_status_text(approval),
            {
                status_state = approval.selected_kind or approval.outcome,
                status_title = string.format('Approval [%d] %s', approval.ordinal, approval.title),
            }
        )
    end
end

---Clear all in-memory ACP session state.
function M.clear()
    sessions = {}
    current_id = nil
    next_ordinal = 1
    next_message_id = 1
    next_pending_approval_ordinal = 1
end

---Return a persisted snapshot of all local ACP sessions.
---@return acp.SessionPersistencePayload
function M.snapshot()
    local persisted = {}

    for _, current_session in ipairs(M.list()) do
        table.insert(persisted, persisted_session(current_session))
    end

    return {
        current_id = current_id,
        next_ordinal = next_ordinal,
        next_message_id = next_message_id,
        sessions = persisted,
    }
end

---Restore all local ACP sessions from a persisted snapshot.
---@param payload acp.SessionPersistencePayload
---@return acp.Session[]
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
            local restored = restore_session(item)

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
    next_pending_approval_ordinal = 1

    for _, current_session in ipairs(ordered) do
        for _, pending in ipairs(current_session.pending_approvals or {}) do
            next_pending_approval_ordinal =
                math.max(next_pending_approval_ordinal, (tonumber(pending.ordinal) or 0) + 1)
        end
    end

    return ordered
end

return M
