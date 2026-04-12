local buffer = require('acp.buffer')
local config = require('acp.config')
local config_option = require('acp.config_option')
local context = require('acp.transport.context')
local fs = require('acp.fs')
local handlers = require('acp.handlers')
local input = require('acp.input')
local mcp_guidance = require('acp.mcp_guidance')
local mcp_runtime = require('acp.mcp_runtime')
local methods = require('acp.methods')
local permission = require('acp.handlers.permission')
local render = require('acp.render')
local router = require('acp.transport.router')
local rpc = require('acp.rpc')
local session = require('acp.session')
local terminal = require('acp.terminal')

---@class acp.TransportModule
local M = {}

---@type acp.RpcClient?
local client = nil
local client_generation = 0
local client_router = nil
local rpc_factory = function(opts)
    return rpc.new(opts)
end

---@class acp.TransportState
---@field initialized boolean
---@field authenticated boolean
---@field protocol_version integer?
---@field agent_info acp.AgentInfo?
---@field agent_capabilities acp.AgentCapabilities?
---@field auth_methods acp.AuthMethod[]
---@field bound_adapter_name string?
---@field bound_local_session_id string?
---@field bound_remote_session_id string?
---@field active_session acp.Session?
---@field loaded_existing_session boolean
---@field loading_existing_session boolean
---@field creating_new_session boolean
---@field pending_session_updates table<string, table[]>
---@field pending_permission acp.PendingPermissionState[]
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

---@param current_session acp.Session
---@return boolean
local function should_rebind_connection(current_session)
    return (client ~= nil and state.bound_adapter_name ~= config.session_adapter_name(current_session))
        or (
            client ~= nil
            and session.transport_remote_id(current_session) ~= nil
            and session.transport_remote_id(current_session) ~= state.bound_remote_session_id
        )
end

---@param generation integer
---@return boolean
local function is_live_generation(generation)
    return client ~= nil and client_generation == generation
end

---@param current_session acp.Session
---@param update table
---@return boolean
local function should_apply_update(current_session, update)
    if current_session.status == 'idle' or current_session.status == 'waiting' then
        return true
    end

    return current_session.status == 'cancelled'
        and (
            update.sessionUpdate == 'tool_call'
            or update.sessionUpdate == 'tool_call_update'
            or update.sessionUpdate == 'config_option_update'
            or update.sessionUpdate == 'available_commands_update'
        )
end

---@return table
local function cancelled_response()
    return {
        outcome = {
            outcome = 'cancelled',
        },
    }
end

---@return table
local function inactive_request_error()
    return {
        code = -32000,
        message = 'ACP request is no longer active',
    }
end

---@param params { sessionId?: string }
---@return acp.Session?
local function active_request_session(params)
    if state.loading_existing_session then
        return nil
    end

    local session_id = params.sessionId
    local current_session = state.active_session

    local current_transport_remote_id = current_session ~= nil and session.transport_remote_id(current_session) or nil

    if
        current_session ~= nil
        and current_session.status == 'waiting'
        and ((session_id == nil) or (current_transport_remote_id ~= nil and current_transport_remote_id == session_id))
    then
        return current_session
    end

    local waiting_session = session.waiting()

    local waiting_transport_remote_id = waiting_session ~= nil and session.transport_remote_id(waiting_session) or nil

    if
        waiting_session ~= nil
        and waiting_session.status == 'waiting'
        and ((session_id == nil) or (waiting_transport_remote_id ~= nil and waiting_transport_remote_id == session_id))
    then
        return waiting_session
    end

    return nil
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

---@return string
local function prompt_snapshot()
    local bufnr = buffer.get()

    if bufnr == nil then
        return ''
    end

    return input.capture_prompt(bufnr) or ''
end

---@param current_session acp.Session
local function perform_rerender(current_session)
    local selected_session = session.current()

    if selected_session == nil or selected_session.id ~= current_session.id or buffer.get() == nil then
        return
    end

    render.render(current_session, prompt_snapshot())
end

---@param current_session acp.Session
local function rerender(current_session)
    if vim.in_fast_event() then
        vim.schedule(function()
            perform_rerender(current_session)
        end)
        return
    end

    perform_rerender(current_session)
end

---@param current_session acp.Session
local function reveal_inline_approval(current_session)
    if vim.in_fast_event() then
        vim.schedule(function()
            reveal_inline_approval(current_session)
        end)
        return
    end

    local bufnr = buffer.get()

    if bufnr == nil then
        vim.notify(string.format('ACP approval pending in %s', current_session.id))
        return
    end

    local selected_session = session.current()

    if selected_session ~= nil and selected_session.id ~= current_session.id then
        local prompt = input.capture_prompt(bufnr)

        if prompt ~= nil then
            session.set_draft_prompt(selected_session, prompt)
        end

        session.select(current_session.id)
        render.render(current_session, current_session.draft_prompt or '')
        return
    end

    rerender(current_session)
end

---@param raw_path string?
---@return string
local function resolve_cwd(raw_path)
    local path = raw_path or vim.fn.getcwd()
    return vim.fn.fnamemodify(path, ':p')
end

---@param current_session acp.Session
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

---@param current_session? acp.Session
local function cancel_pending_permission(current_session)
    local pending_permissions = state.pending_permissions or {}

    if #pending_permissions == 0 then
        return
    end

    local retained = {}

    for _, pending_permission in ipairs(pending_permissions) do
        if current_session ~= nil and pending_permission.local_session_id ~= current_session.id then
            table.insert(retained, pending_permission)
        else
            local pending_session = session.get(pending_permission.local_session_id)

            if pending_session ~= nil then
                local remaining = {}

                for _, pending in ipairs(pending_session.pending_approvals or {}) do
                    if pending.request_id ~= pending_permission.request_id then
                        table.insert(remaining, pending)
                    end
                end

                pending_session.pending_approvals = remaining
            end

            pending_permission.respond(cancelled_response())
        end
    end

    state.pending_permissions = retained
end

---@param current_session acp.Session
---@param update table
local function apply_update(current_session, update)
    session.apply_update(current_session, update)
    rerender(current_session)
end

---@param session_id string
---@param update table
local function queue_session_update(session_id, update)
    local pending_updates = state.pending_session_updates[session_id]

    if pending_updates == nil then
        pending_updates = {}
        state.pending_session_updates[session_id] = pending_updates
    end

    table.insert(pending_updates, vim.deepcopy(update))
end

---@param current_session acp.Session
---@param session_id string
local function drain_session_updates(current_session, session_id)
    local pending_updates = state.pending_session_updates[session_id]

    if pending_updates == nil then
        return
    end

    state.pending_session_updates[session_id] = nil

    for _, update in ipairs(pending_updates) do
        if should_apply_update(current_session, update) then
            apply_update(current_session, update)
        end
    end
end

---@param current_session acp.Session
---@param stop_reason acp.StopReason
local function finish_turn(current_session, stop_reason)
    session.finish_prompt(current_session, stop_reason)
    rerender(current_session)
end

---@param role acp.MessageRole
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

---@param current_session acp.Session
---@param prompt string
---@return acp.ContentBlock[]
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
                text = mcp_guidance.prepend(text, state.agent_capabilities, current_session)
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

---@param current_session acp.Session
---@param prompt string
---@return acp.ContentBlock[]
local function prompt_content(current_session, prompt)
    local guided_prompt = mcp_guidance.prepend(prompt, state.agent_capabilities, current_session)

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

---@return acp.TransportContext
local function build_context()
    return context.new({
        config = config,
        fs = fs,
        methods = methods,
        session = session,
        terminal = terminal,
        active_request_session = active_request_session,
        active_session = function()
            return state.active_session
        end,
        apply_update = apply_update,
        cancelled_response = cancelled_response,
        cancel_pending_permission = cancel_pending_permission,
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
        inactive_request_error = inactive_request_error,
        is_creating_new_session = function()
            return state.creating_new_session
        end,
        is_live_generation = is_live_generation,
        is_loading_existing_session = function()
            return state.loading_existing_session
        end,
        queue_session_update = queue_session_update,
        reveal_inline_approval = reveal_inline_approval,
        rerender = rerender,
        should_apply_update = should_apply_update,
    })
end

---@param current_session acp.Session
---@return acp.RpcClient
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

---@param current_session acp.Session
local function initialize(current_session)
    if state.initialized then
        return
    end

    local adapter = config.adapter_for_session(current_session)

    local result, rpc_error = ensure_client(current_session):request_sync(methods.INITIALIZE, {
        protocolVersion = adapter.protocol_version,
        clientCapabilities = adapter.client_capabilities,
        clientInfo = adapter.client_info,
    })

    if rpc_error ~= nil then
        error(rpc_error.message)
    end

    ---@cast result acp.InitializeResult
    if result.protocolVersion ~= adapter.protocol_version then
        reset_connection()
        error(string.format('Unsupported ACP protocol version: %s', result.protocolVersion))
    end

    state.protocol_version = result.protocolVersion
    state.agent_info = result.agentInfo
    state.agent_capabilities = result.agentCapabilities
    state.auth_methods = result.authMethods or {}
    state.initialized = true

    session.set_agent_info(current_session, result.agentInfo)
end

---@param current_session acp.Session
local function authenticate(current_session)
    if state.authenticated then
        return
    end

    if #state.auth_methods == 0 then
        state.authenticated = true
        return
    end

    local adapter = config.adapter_for_session(current_session)
    local method_id = adapter.auth_method or state.auth_methods[1].id
    local result, rpc_error = ensure_client(current_session):request_sync(methods.AUTHENTICATE, {
        methodId = method_id,
    })

    if rpc_error ~= nil then
        error(rpc_error.message)
    end

    state.authenticated = true
    return result
end

---@param current_session acp.Session
local function prepare_connection(current_session)
    if should_rebind_connection(current_session) then
        reset_connection()
    end

    initialize(current_session)
    authenticate(current_session)
end

---@param current_session acp.Session
local function apply_adapter_config_option_overrides(current_session)
    local adapter = config.adapter_for_session(current_session)
    local overrides = adapter.config_option_overrides or {}

    if current_session.remote_id == nil or vim.tbl_isempty(overrides) then
        return
    end

    local override_ids = vim.tbl_keys(overrides)
    table.sort(override_ids)

    for _, config_id in ipairs(override_ids) do
        local option = nil

        for _, candidate in ipairs(current_session.config_options or {}) do
            if candidate.id == config_id then
                option = candidate
                break
            end
        end

        if option == nil then
            error(string.format('ACP adapter override references unknown config option: %s', config_id))
        end

        local value = overrides[config_id]
        local allowed = {}

        for _, choice in ipairs(config_option.choices(option)) do
            allowed[choice.value.value] = true
        end

        if not allowed[value] then
            error(string.format('ACP adapter override uses invalid value for %s: %s', config_id, tostring(value)))
        end

        if option.currentValue ~= value then
            local result, rpc_error = ensure_client(current_session):request_sync(methods.SESSION_SET_CONFIG_OPTION, {
                sessionId = current_session.remote_id,
                configId = config_id,
                value = value,
            })

            if rpc_error ~= nil then
                error(rpc_error.message)
            end

            session.set_config_options(current_session, result.configOptions or {})
        end
    end
end

---@param current_session acp.Session
---@param opts? { force_load?: boolean, force_new?: boolean }
local function establish_session(current_session, opts)
    local force_load = opts ~= nil and opts.force_load or false
    local force_new = opts ~= nil and opts.force_new or false
    local previous_remote_id = current_session.remote_id
    local previous_remote_sync_state = current_session.remote_sync_state
    local previous_remote_sync_error = current_session.remote_sync_error
    local previous_transport_remote_id = session.transport_remote_id(current_session)
    if force_load and previous_transport_remote_id == nil then
        previous_transport_remote_id = previous_remote_id
        if previous_transport_remote_id ~= nil then
            session.set_transport_remote_id(
                current_session,
                previous_transport_remote_id,
                previous_remote_sync_state,
                previous_remote_sync_error
            )
        end
    end

    if force_new then
        session.clear_remote_id(current_session)
        state.bound_local_session_id = nil
        state.bound_remote_session_id = nil
        state.active_session = nil
        state.loaded_existing_session = false
    end

    if
        not force_new
        and not force_load
        and previous_transport_remote_id ~= nil
        and state.bound_local_session_id == current_session.id
        and state.bound_remote_session_id == previous_transport_remote_id
    then
        state.active_session = current_session
        return
    end

    if not force_new and previous_transport_remote_id ~= nil then
        if state.agent_capabilities ~= nil and state.agent_capabilities.loadSession then
            state.active_session = current_session
            state.loading_existing_session = true
            local params, cwd =
                session_request_params(current_session, current_session.cwd, previous_transport_remote_id)
            local result, rpc_error = ensure_client(current_session):request_sync(methods.SESSION_LOAD, params)
            state.loading_existing_session = false

            if rpc_error == nil then
                ---@cast result acp.SessionLoadResult
                state.bound_local_session_id = current_session.id
                state.bound_remote_session_id = previous_transport_remote_id
                state.active_session = current_session
                state.loaded_existing_session = true
                session.set_remote_sync_state(current_session, 'loaded')
                session.set_cwd(current_session, cwd)
                session.set_available_commands(current_session, {})
                session.set_config_options(current_session, result.configOptions or {})
                apply_adapter_config_option_overrides(current_session)
                drain_session_updates(current_session, previous_transport_remote_id)
                return
            end

            state.pending_session_updates[previous_transport_remote_id] = nil
            state.bound_local_session_id = nil
            state.bound_remote_session_id = nil
            state.active_session = nil
            state.loaded_existing_session = false
            session.set_transport_remote_id(current_session, nil, 'load_failed', rpc_error.message)

            if previous_remote_id ~= nil then
                error(rpc_error.message)
            end

            if force_load then
                error(rpc_error.message)
            end
        elseif force_load then
            local message =
                string.format('ACP agent does not advertise session/load support for session %s', current_session.id)
            state.bound_local_session_id = nil
            state.bound_remote_session_id = nil
            state.active_session = nil
            state.loaded_existing_session = false
            session.set_transport_remote_id(current_session, nil, 'load_failed', message)
            error(message)
        end
    end

    state.active_session = current_session
    state.creating_new_session = true
    local params, cwd = session_request_params(current_session)
    local result, rpc_error = ensure_client(current_session):request_sync(methods.SESSION_NEW, params)
    state.creating_new_session = false

    if rpc_error ~= nil then
        if previous_remote_id ~= nil then
            session.set_transport_remote_id(
                current_session,
                previous_transport_remote_id,
                previous_remote_sync_state,
                previous_remote_sync_error
            )
        elseif force_new then
            session.clear_remote_id(current_session, previous_remote_sync_state, previous_remote_sync_error)
        end

        error(rpc_error.message)
    end

    ---@cast result acp.SessionNewResult
    if result.sessionId == nil or result.sessionId == '' then
        reset_connection()
        error('ACP session/new did not return a sessionId')
    end

    state.bound_local_session_id = current_session.id
    state.bound_remote_session_id = result.sessionId
    state.active_session = current_session
    state.loaded_existing_session = false

    session.set_remote_id(current_session, result.sessionId, 'created')
    session.set_cwd(current_session, cwd)
    session.set_config_options(current_session, result.configOptions or {})
    apply_adapter_config_option_overrides(current_session)
    session.set_available_commands(current_session, {})
    drain_session_updates(current_session, result.sessionId)
end

---@param current_session acp.Session
function M.ensure(current_session)
    prepare_connection(current_session)
    establish_session(current_session)
end

---@param current_session acp.Session
function M.load(current_session)
    prepare_connection(current_session)
    establish_session(current_session, {
        force_load = true,
    })
end

---@param current_session acp.Session
function M.rebind(current_session)
    prepare_connection(current_session)
    establish_session(current_session, {
        force_new = true,
    })
end

---@param current_session acp.Session
---@param prompt string
function M.prompt(current_session, prompt)
    if current_session.remote_id ~= nil and current_session.turn_id > 1 then
        reset_connection()
    end

    M.ensure(current_session)
    state.active_session = current_session
    local generation = client_generation
    local turn_id = session.current_turn_id(current_session)

    ensure_client(current_session):request(methods.SESSION_PROMPT, {
        sessionId = current_session.remote_id,
        prompt = prompt_content(current_session, prompt),
    }, function(result, rpc_error)
        if not is_live_generation(generation) then
            return
        end

        if not session.matches_turn(current_session, turn_id) then
            return
        end

        if rpc_error ~= nil then
            session.append_message(current_session, 'status', rpc_error.message)
            finish_turn(current_session, 'cancelled')
            return
        end

        ---@cast result acp.PromptResult
        finish_turn(current_session, result.stopReason)
    end)
end

---@param current_session acp.Session
---@param config_id string
---@param value string
---@return acp.Session
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

    ---@cast result acp.SessionSetConfigOptionResult
    session.set_config_options(current_session, result.configOptions or {})

    return current_session
end

---@param current_session acp.Session
---@param selection string|integer
---@return acp.PermissionOutcome
function M.select_pending_approval(current_session, selection)
    return permission.select_pending_approval(build_context(), current_session, selection)
end

---@param current_session acp.Session
function M.cancel(current_session)
    if current_session.remote_id == nil or current_session.status ~= 'waiting' then
        return
    end

    cancel_pending_permission(current_session)
    ensure_client(current_session):notify(methods.SESSION_CANCEL, {
        sessionId = current_session.remote_id,
    })
end

function M.clear()
    local current_session = session.current()
    cancel_pending_permission(nil)

    if current_session ~= nil and buffer.get() ~= nil then
        rerender(current_session)
    end

    reset_connection()
    rpc_factory = function(opts)
        return rpc.new(opts)
    end
    handlers.clear_extensions()
end

---@param factory fun(opts: table): acp.RpcClient
function M._set_rpc_factory(factory)
    rpc_factory = factory
    client = nil
    client_router = nil
end

return M
