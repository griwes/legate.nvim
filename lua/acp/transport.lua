local buffer = require('acp.buffer')
local config = require('acp.config')
local fs = require('acp.fs')
local input = require('acp.input')
local methods = require('acp.methods')
local render = require('acp.render')
local rpc = require('acp.rpc')
local session = require('acp.session')
local terminal = require('acp.terminal')

---@class acp.TransportModule
local M = {}

---@type acp.RpcClient?
local client = nil
local client_generation = 0
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
---@field bound_local_session_id string?
---@field bound_remote_session_id string?
---@field active_session acp.Session?
---@field loaded_existing_session boolean
---@field loading_existing_session boolean
---@field creating_new_session boolean
---@field pending_session_updates table<string, table[]>
local state = {
    initialized = false,
    authenticated = false,
    protocol_version = nil,
    agent_info = nil,
    agent_capabilities = nil,
    auth_methods = {},
    bound_local_session_id = nil,
    bound_remote_session_id = nil,
    active_session = nil,
    loaded_existing_session = false,
    loading_existing_session = false,
    creating_new_session = false,
    pending_session_updates = {},
}

---@param current_session acp.Session
---@return boolean
local function should_rebind_connection(current_session)
    return current_session.remote_id ~= nil and current_session.turn_id > 0 and current_session.status ~= 'waiting'
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
    local current_session = state.active_session

    if
        current_session == nil
        or current_session.remote_id ~= params.sessionId
        or state.loading_existing_session
        or current_session.status ~= 'waiting'
    then
        return nil
    end

    return current_session
end

local function reset_connection()
    if client ~= nil then
        client:close()
    end

    client = nil
    state.initialized = false
    state.authenticated = false
    state.protocol_version = nil
    state.agent_info = nil
    state.agent_capabilities = nil
    state.auth_methods = {}
    state.bound_local_session_id = nil
    state.bound_remote_session_id = nil
    state.active_session = nil
    state.loaded_existing_session = false
    state.loading_existing_session = false
    state.creating_new_session = false
    state.pending_session_updates = {}
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

---@param raw_path string?
---@return string
local function resolve_cwd(raw_path)
    local path = raw_path or vim.fn.getcwd()
    return vim.fn.fnamemodify(path, ':p')
end

---@param session_id string?
---@return table
local function session_request_params(session_id)
    local params = {
        cwd = resolve_cwd(config.get().cwd),
        mcpServers = config.get().mcp_servers,
    }

    if session_id ~= nil then
        params.sessionId = session_id
    end

    return params
end

---@param option_kind acp.PermissionOptionKind
---@param options acp.PermissionOption[]
---@return acp.PermissionOption?
local function pick_permission_option(option_kind, options)
    for _, option in ipairs(options) do
        if option.kind == option_kind then
            return option
        end
    end

    return nil
end

---@param permission acp.PermissionRequest
---@return acp.PermissionOutcome
local function default_permission_outcome(permission)
    local selected = pick_permission_option(config.get().permission_default, permission.options)

    if selected == nil then
        selected = pick_permission_option('reject_once', permission.options)
            or pick_permission_option('reject_always', permission.options)
    end

    if selected == nil then
        return {
            outcome = 'cancelled',
        }
    end

    return {
        outcome = 'selected',
        optionId = selected.optionId,
    }
end

---@param permission acp.PermissionRequest
---@return string
local function permission_prompt(permission)
    local title = permission.toolCall.title or permission.toolCall.toolCallId or 'Approval'
    return string.format('ACP approval: %s', title)
end

---@param option acp.PermissionOption
---@return string
local function format_permission_option(option)
    return string.format('%s  [%s]', option.name, option.kind)
end

---@param selected_option acp.PermissionOption?
---@return acp.PermissionOutcome
local function selected_permission_outcome(selected_option)
    if selected_option == nil then
        return {
            outcome = 'cancelled',
        }
    end

    return {
        outcome = 'selected',
        optionId = selected_option.optionId,
    }
end

---@param generation integer
---@param permission acp.PermissionRequest
---@param respond fun(result?: any, error?: table)
local function handle_permission_request(generation, permission, respond)
    local current_session = active_request_session(permission)

    if current_session == nil then
        respond(cancelled_response())
        return
    end

    if config.get().permission_strategy == 'default' then
        local outcome = default_permission_outcome(permission)
        session.record_approval(current_session, permission, outcome, 'default')
        rerender(current_session)
        respond({
            outcome = outcome,
        })
        return
    end

    vim.ui.select(permission.options, {
        prompt = permission_prompt(permission),
        format_item = format_permission_option,
    }, function(selected_option)
        if not is_live_generation(generation) then
            return
        end

        local live_session = nil

        live_session = active_request_session(permission)

        if live_session == nil then
            respond(cancelled_response())
            return
        end

        local outcome = selected_permission_outcome(selected_option)
        session.record_approval(live_session, permission, outcome, 'select')
        rerender(live_session)
        respond({
            outcome = outcome,
        })
    end)
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
    reset_connection()
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
            vim.list_extend(history, format_history_message(message.role, message.text))
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
    if state.loaded_existing_session then
        return {
            {
                type = 'text',
                text = prompt,
            },
        }
    end

    return prompt_blocks(current_session, prompt)
end

---@param generation integer
---@param method string
---@param params table
local function on_notification(generation, method, params)
    if not is_live_generation(generation) then
        return
    end

    if method ~= methods.SESSION_UPDATE then
        return
    end

    local current_session = state.active_session

    if current_session == nil then
        return
    end

    if state.creating_new_session and current_session.remote_id == nil then
        if params.update.sessionUpdate == 'available_commands_update' then
            queue_session_update(params.sessionId, params.update)
        end
        return
    end

    if params.sessionId ~= current_session.remote_id then
        return
    end

    if state.loading_existing_session then
        if params.update.sessionUpdate == 'available_commands_update' then
            queue_session_update(params.sessionId, params.update)
        end
        return
    end

    if not should_apply_update(current_session, params.update) then
        return
    end

    apply_update(current_session, params.update)
end

---@param generation integer
---@param method string
---@param params table
---@param respond fun(result?: any, error?: table)
local function on_request(generation, method, params, respond)
    if not is_live_generation(generation) then
        if method == methods.SESSION_REQUEST_PERMISSION then
            respond(cancelled_response())
            return
        end

        respond(nil, inactive_request_error())
        return
    end

    if method == methods.SESSION_REQUEST_PERMISSION then
        handle_permission_request(generation, params, respond)
        return
    end

    local current_session = active_request_session(params)

    if current_session == nil then
        respond(nil, inactive_request_error())
        return
    end

    if method == methods.FS_READ_TEXT_FILE then
        local result, error = fs.read_text_file(params)
        respond(result, error)
        return
    end

    if method == methods.FS_WRITE_TEXT_FILE then
        local result, error = fs.write_text_file(params)

        if error == nil then
            rerender(current_session)
        end

        respond(result, error)
        return
    end

    if method == methods.TERMINAL_CREATE then
        local result, error = terminal.create(params)
        respond(result, error)
        return
    end

    if method == methods.TERMINAL_OUTPUT then
        local result, error = terminal.output(params)
        respond(result, error)
        return
    end

    if method == methods.TERMINAL_WAIT_FOR_EXIT then
        local result, error = terminal.wait_for_exit(params)
        respond(result, error)
        return
    end

    if method == methods.TERMINAL_KILL then
        local result, error = terminal.kill(params)
        respond(result, error)
        return
    end

    if method == methods.TERMINAL_RELEASE then
        local result, error = terminal.release(params)
        respond(result, error)
        return
    end

    respond(nil, {
        code = -32601,
        message = string.format('Unsupported ACP request: %s', method),
    })
end

---@return acp.RpcClient
local function ensure_client()
    if client ~= nil then
        return client
    end

    client_generation = client_generation + 1
    local generation = client_generation

    client = rpc_factory({
        command = config.get().agent_command,
        cwd = resolve_cwd(config.get().cwd),
        env = config.get().agent_env,
        timeout_ms = config.get().request_timeout_ms,
        on_notification = function(method, params)
            on_notification(generation, method, params)
        end,
        on_request = function(method, params, respond)
            on_request(generation, method, params, respond)
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

    local result, rpc_error = ensure_client():request_sync(methods.INITIALIZE, {
        protocolVersion = config.get().protocol_version,
        clientCapabilities = config.get().client_capabilities,
        clientInfo = config.get().client_info,
    })

    if rpc_error ~= nil then
        error(rpc_error.message)
    end

    ---@cast result acp.InitializeResult
    if result.protocolVersion ~= config.get().protocol_version then
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

local function authenticate()
    if state.authenticated then
        return
    end

    if #state.auth_methods == 0 then
        state.authenticated = true
        return
    end

    local method_id = config.get().auth_method or state.auth_methods[1].id
    local result, rpc_error = ensure_client():request_sync(methods.AUTHENTICATE, {
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
    authenticate()
end

---@param current_session acp.Session
---@param opts? { force_load?: boolean, force_new?: boolean }
local function establish_session(current_session, opts)
    local force_load = opts ~= nil and opts.force_load or false
    local force_new = opts ~= nil and opts.force_new or false
    local previous_remote_id = current_session.remote_id
    local previous_remote_sync_state = current_session.remote_sync_state
    local previous_remote_sync_error = current_session.remote_sync_error

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
        and current_session.remote_id ~= nil
        and state.bound_local_session_id == current_session.id
        and state.bound_remote_session_id == current_session.remote_id
    then
        state.active_session = current_session
        return
    end

    if not force_new and current_session.remote_id ~= nil then
        if state.agent_capabilities ~= nil and state.agent_capabilities.loadSession then
            state.active_session = current_session
            state.loading_existing_session = true
            session.set_available_commands(current_session, {})
            local result, rpc_error =
                ensure_client():request_sync(methods.SESSION_LOAD, session_request_params(current_session.remote_id))
            state.loading_existing_session = false

            if rpc_error == nil then
                ---@cast result acp.SessionLoadResult
                state.bound_local_session_id = current_session.id
                state.bound_remote_session_id = current_session.remote_id
                state.active_session = current_session
                state.loaded_existing_session = true
                session.set_remote_sync_state(current_session, 'loaded')
                session.set_config_options(current_session, result.configOptions or {})
                drain_session_updates(current_session, current_session.remote_id)
                return
            end

            state.pending_session_updates[current_session.remote_id] = nil
            state.bound_local_session_id = nil
            state.bound_remote_session_id = nil
            state.active_session = nil
            state.loaded_existing_session = false
            session.set_remote_sync_state(current_session, 'load_failed', rpc_error.message)

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
            session.set_remote_sync_state(current_session, 'load_failed', message)
            error(message)
        end
    end

    state.active_session = current_session
    state.creating_new_session = true
    local result, rpc_error = ensure_client():request_sync(methods.SESSION_NEW, session_request_params())
    state.creating_new_session = false

    if rpc_error ~= nil then
        if previous_remote_id ~= nil then
            session.set_remote_id(
                current_session,
                previous_remote_id,
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
    session.set_config_options(current_session, result.configOptions or {})
    session.set_available_commands(current_session, {})
    drain_session_updates(current_session, result.sessionId)
end

---Ensure the ACP transport is initialized and bound to the given session.
---@param current_session acp.Session
function M.ensure(current_session)
    prepare_connection(current_session)
    establish_session(current_session)
end

---Explicitly bind or reload the given session against the ACP transport.
---@param current_session acp.Session
function M.load(current_session)
    prepare_connection(current_session)
    establish_session(current_session, {
        force_load = true,
    })
end

---Explicitly discard a failed remote binding and create a fresh remote ACP session.
---@param current_session acp.Session
function M.rebind(current_session)
    prepare_connection(current_session)
    establish_session(current_session, {
        force_new = true,
    })
end

---Send a prompt turn over ACP for the given session.
---@param current_session acp.Session
---@param prompt string
function M.prompt(current_session, prompt)
    M.ensure(current_session)
    state.active_session = current_session
    local generation = client_generation
    local turn_id = session.current_turn_id(current_session)

    ensure_client():request(methods.SESSION_PROMPT, {
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

---Set an ACP session config option and store the returned full configuration state.
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

    local result, rpc_error = ensure_client():request_sync(methods.SESSION_SET_CONFIG_OPTION, {
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

---Cancel the current ACP prompt turn if one is in progress.
---@param current_session acp.Session
function M.cancel(current_session)
    if current_session.remote_id == nil or current_session.status ~= 'waiting' then
        return
    end

    ensure_client():notify(methods.SESSION_CANCEL, {
        sessionId = current_session.remote_id,
    })
end

---Reset all ACP transport state.
function M.clear()
    reset_connection()
    rpc_factory = function(opts)
        return rpc.new(opts)
    end
end

---Inject a custom RPC client factory for tests.
---@param factory fun(opts: table): acp.RpcClient
function M._set_rpc_factory(factory)
    rpc_factory = factory
    client = nil
end

return M
