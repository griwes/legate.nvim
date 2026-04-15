local buffer = require('legate.ui.buffer')
local config = require('legate.config')
local config_option = require('legate.config.option')
local prompt_pipeline = require('legate.core.prompt_pipeline')
local context = require('legate.transport.context')
local fs = require('legate.core.fs')
local handlers = require('legate.handlers')
local input = require('legate.ui.input')
local mcp_runtime = require('legate.mcp.runtime')
local methods = require('legate.core.methods')
local permission = require('legate.handlers.permission')
local render = require('legate.ui.render')
local router = require('legate.transport.router')
local runtime_api = require('legate.transport.runtime')
local session_api = require('legate.transport.session')
local rpc = require('legate.core.rpc')
local continuity = require('legate.session')
local terminal = require('legate.terminal')

---@class legate.TransportModule
local M = {}

---@type legate.RpcClient?
local client = nil
local client_generation = 0
local client_router = nil
local runtime_helper = nil
local session_helper = nil
local rpc_factory = function(opts)
    return rpc.new(opts)
end

---@class legate.TransportState
---@field initialized boolean
---@field authenticated boolean
---@field protocol_version integer?
---@field agent_info legate.AgentInfo?
---@field agent_capabilities legate.AgentCapabilities?
---@field auth_methods legate.AuthMethod[]
---@field bound_adapter_name string?
---@field bound_local_session_id string?
---@field bound_remote_session_id string?
---@field active_session legate.Session?
---@field loaded_existing_session boolean
---@field loading_existing_session boolean
---@field creating_new_session boolean
---@field pending_session_updates table<string, table[]>
---@field pending_permission legate.PendingPermissionState[]
local state = {
    initialized = false,
    authenticated = false,
    protocol_version = nil,
    agent_info = nil,
    agent_capabilities = nil,
    auth_methods = {},
    bound_adapter_name = nil,
    bound_local_session_id = nil,
    bound_remote_session_id = nil,
    active_session = nil,
    loaded_existing_session = false,
    loading_existing_session = false,
    creating_new_session = false,
    pending_session_updates = {},
    pending_permissions = {},
}

---@param current_session legate.Session
---@return boolean
local function should_rebind_connection(current_session)
    return (client ~= nil and state.bound_adapter_name ~= config.session_adapter_name(current_session))
        or (
            client ~= nil
            and continuity.transport_remote_id(current_session) ~= nil
            and continuity.transport_remote_id(current_session) ~= state.bound_remote_session_id
        )
end

---@param generation integer
---@return boolean
local function is_live_generation(generation)
    return client ~= nil and client_generation == generation
end

local function reset_connection()
    if client ~= nil then
        client:close()
    end

    client = nil
    client_router = nil
    state.initialized = false
    state.authenticated = false
    state.protocol_version = nil
    state.agent_info = nil
    state.agent_capabilities = nil
    state.auth_methods = {}
    state.bound_adapter_name = nil
    state.bound_local_session_id = nil
    state.bound_remote_session_id = nil
    state.active_session = nil
    state.loaded_existing_session = false
    state.loading_existing_session = false
    state.creating_new_session = false
    state.pending_session_updates = {}
    state.pending_permissions = {}
end

---@param raw_path string?
---@return string
local function resolve_cwd(raw_path)
    local path = raw_path or vim.fn.getcwd()
    return vim.fn.fnamemodify(path, ':p')
end

---@param current_session legate.Session
---@param cwd_override string?
---@param session_id string?
---@return table
local function session_request_params(current_session, cwd_override, session_id)
    local adapter = config.adapter_for_session(current_session)
    local cwd = resolve_cwd(cwd_override or adapter.cwd)
    local params = {
        cwd = cwd,
        mcpServers = mcp_runtime.effective_servers(current_session),
    }

    if session_id ~= nil then
        params.sessionId = session_id
    end

    return params, cwd
end

---@param role legate.MessageRole
---@param text string
---@return string[]
local function format_history_message(role, text)
    local title = role:sub(1, 1):upper() .. role:sub(2)
    local lines = {
        string.format('### %s', title),
    }

    for _, line in
        ipairs(vim.split(text, '\n', {
            plain = true,
        }))
    do
        table.insert(lines, line)
    end

    return lines
end

---@param current_session legate.Session
---@param prompt string
---@return legate.ContentBlock[]
local function prompt_blocks(current_session, prompt)
    local history = {}
    local limit = #current_session.messages
    local last = current_session.messages[limit]

    if
        current_session.status == 'waiting'
        and current_session.pending_prompt == prompt
        and last ~= nil
        and last.role == 'user'
        and last.text == prompt
    then
        limit = limit - 1
    end

    for index = 1, limit do
        local message = current_session.messages[index]

        if message.role ~= 'status' then
            local text = message.text

            if message.role == 'user' then
                text = prompt_pipeline.decorate(text, state.agent_capabilities, current_session)
            end

            vim.list_extend(history, format_history_message(message.role, text))
            table.insert(history, '')
        end
    end

    if #history == 0 then
        return {
            {
                type = 'text',
                text = prompt,
            },
        }
    end

    return {
        {
            type = 'text',
            text = 'Previous conversation transcript for context:\n\n' .. table.concat(history, '\n'),
        },
        {
            type = 'text',
            text = prompt,
        },
    }
end

---@param current_session legate.Session
---@param prompt string
---@return legate.ContentBlock[]
local function prompt_content(current_session, prompt)
    local guided_prompt = prompt_pipeline.decorate(prompt, state.agent_capabilities, current_session)

    if state.loaded_existing_session then
        return {
            {
                type = 'text',
                text = guided_prompt,
            },
        }
    end

    return prompt_blocks(current_session, guided_prompt)
end

---@return legate.TransportContext
local function build_context()
    return context.new({
        config = config,
        fs = fs,
        methods = methods,
        session = continuity,
        terminal = terminal,
        active_request_session = runtime_helper.active_request_session,
        active_session = function()
            return state.active_session
        end,
        apply_update = runtime_helper.apply_update,
        cancelled_response = runtime_helper.cancelled_response,
        cancel_pending_permission = runtime_helper.cancel_pending_permission,
        get_pending_permissions = function()
            return state.pending_permissions
        end,
        pending_permission_by_session = function(session_id)
            for _, pending in ipairs(state.pending_permissions) do
                if pending.local_session_id == session_id then
                    return pending
                end
            end
            return nil
        end,
        pending_permission_by_tool_call = function(session_id, tool_call_id)
            for _, pending in ipairs(state.pending_permissions) do
                if
                    pending.local_session_id == session_id
                    and pending.permission.toolCall.toolCallId == tool_call_id
                then
                    return pending
                end
            end
            return nil
        end,
        set_pending_permissions = function(pending_permissions)
            state.pending_permissions = pending_permissions
        end,
        inactive_request_error = runtime_helper.inactive_request_error,
        is_creating_new_session = function()
            return state.creating_new_session
        end,
        is_live_generation = is_live_generation,
        is_loading_existing_session = function()
            return state.loading_existing_session
        end,
        queue_session_update = runtime_helper.queue_session_update,
        reveal_inline_approval = runtime_helper.reveal_inline_approval,
        rerender = runtime_helper.rerender,
        should_apply_update = runtime_helper.should_apply_update,
    })
end

---@param current_session legate.Session
---@return legate.RpcClient
local function ensure_client(current_session)
    if client ~= nil then
        return client
    end

    local adapter = config.adapter_for_session(current_session)
    client_generation = client_generation + 1
    local generation = client_generation
    client_router = router.new(build_context())
    local generation_router = client_router
    state.bound_adapter_name = config.session_adapter_name(current_session)

    client = rpc_factory({
        command = adapter.command,
        cwd = resolve_cwd(adapter.cwd),
        env = adapter.env,
        timeout_ms = adapter.request_timeout_ms,
        on_notification = function(method, params)
            generation_router:dispatch_notification(generation, method, params)
        end,
        on_request = function(method, params, respond)
            generation_router:dispatch_request(generation, method, params, respond)
        end,
    })

    local ok, error_message = client:start()

    if not ok then
        error(string.format('Failed to start ACP agent: %s', error_message))
    end

    return client
end

runtime_helper = runtime_api.new({
    buffer = buffer,
    continuity = continuity,
    input = input,
    render = render,
    state = state,
})

session_helper = session_api.new({
    config = config,
    config_option = config_option,
    continuity = continuity,
    ensure_client = ensure_client,
    methods = methods,
    mcp_runtime = mcp_runtime,
    reset_connection = reset_connection,
    session_request_params = session_request_params,
    should_rebind_connection = should_rebind_connection,
    state = state,
})

---@param current_session legate.Session
function M.ensure(current_session)
    session_helper.prepare_connection(current_session)
    session_helper.establish_session(current_session, runtime_helper.drain_session_updates)
end

---@param current_session legate.Session
function M.load(current_session)
    session_helper.prepare_connection(current_session)
    session_helper.establish_session(current_session, runtime_helper.drain_session_updates, {
        force_load = true,
    })
end

---@param current_session legate.Session
function M.rebind(current_session)
    session_helper.prepare_connection(current_session)
    session_helper.establish_session(current_session, runtime_helper.drain_session_updates, {
        force_new = true,
    })
end

---@param current_session legate.Session
---@param prompt string
function M.prompt(current_session, prompt)
    if current_session.remote_id ~= nil and current_session.turn_id > 1 then
        reset_connection()
    end

    M.ensure(current_session)
    state.active_session = current_session
    local generation = client_generation
    local turn_id = continuity.current_turn_id(current_session)

    ensure_client(current_session):request(methods.SESSION_PROMPT, {
        sessionId = current_session.remote_id,
        prompt = prompt_content(current_session, prompt),
    }, function(result, rpc_error)
        if not is_live_generation(generation) then
            return
        end

        if not continuity.matches_turn(current_session, turn_id) then
            return
        end

        if rpc_error ~= nil then
            continuity.append_message(current_session, 'status', rpc_error.message)
            runtime_helper.finish_turn(current_session, 'cancelled')
            return
        end

        ---@cast result legate.PromptResult
        runtime_helper.finish_turn(current_session, result.stopReason)
    end)
end

---@param current_session legate.Session
---@param config_id string
---@param value string
---@return legate.Session
function M.set_config_option(current_session, config_id, value)
    if
        client == nil
        or not state.initialized
        or current_session.remote_id == nil
        or state.bound_local_session_id ~= current_session.id
        or state.bound_remote_session_id ~= current_session.remote_id
    then
        M.ensure(current_session)
    end

    if current_session.remote_id == nil then
        error(string.format('ACP session is not bound: %s', current_session.id))
    end

    local result, rpc_error = ensure_client(current_session):request_sync(methods.SESSION_SET_CONFIG_OPTION, {
        sessionId = current_session.remote_id,
        configId = config_id,
        value = value,
    })

    if rpc_error ~= nil then
        error(rpc_error.message)
    end

    ---@cast result legate.SessionSetConfigOptionResult
    continuity.set_config_options(current_session, result.configOptions or {})

    return current_session
end

---@param current_session legate.Session
---@param selection string|integer
---@return legate.PermissionOutcome
function M.select_pending_approval(current_session, selection)
    return permission.select_pending_approval(build_context(), current_session, selection)
end

---@param current_session legate.Session
function M.cancel(current_session)
    if current_session.remote_id == nil or current_session.status ~= 'waiting' then
        return
    end

    runtime_helper.cancel_pending_permission(current_session)
    ensure_client(current_session):notify(methods.SESSION_CANCEL, {
        sessionId = current_session.remote_id,
    })
end

function M.clear()
    local current_session = continuity.current()
    runtime_helper.cancel_pending_permission(nil)

    if current_session ~= nil and buffer.get() ~= nil then
        runtime_helper.rerender(current_session)
    end

    reset_connection()
    rpc_factory = function(opts)
        return rpc.new(opts)
    end
    handlers.clear_extensions()
end

---@param factory fun(opts: table): legate.RpcClient
function M._set_rpc_factory(factory)
    rpc_factory = factory
    client = nil
    client_router = nil
end

return M
