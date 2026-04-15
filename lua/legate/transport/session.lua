local M = {}

---@param deps { config: legate.ConfigModule, config_option: legate.ConfigOptionModule, continuity: legate.SessionModule, ensure_client: fun(current_session: legate.Session): legate.RpcClient, methods: table, mcp_runtime: table, reset_connection: fun(), session_request_params: fun(current_session: legate.Session, cwd_override?: string, session_id?: string): table, string, should_rebind_connection: fun(current_session: legate.Session): boolean, state: legate.TransportState }
---@return table
function M.new(deps)
    local helper = {}

    ---@param current_session legate.Session
    function helper.initialize(current_session)
        if deps.state.initialized then
            return
        end

        local adapter = deps.config.adapter_for_session(current_session)

        local result, rpc_error = deps.ensure_client(current_session):request_sync(deps.methods.INITIALIZE, {
            protocolVersion = adapter.protocol_version,
            clientCapabilities = adapter.client_capabilities,
            clientInfo = adapter.client_info,
        })

        if rpc_error ~= nil then
            error(rpc_error.message)
        end

        ---@cast result legate.InitializeResult
        if result.protocolVersion ~= adapter.protocol_version then
            deps.reset_connection()
            error(string.format('Unsupported ACP protocol version: %s', result.protocolVersion))
        end

        deps.state.protocol_version = result.protocolVersion
        deps.state.agent_info = result.agentInfo
        deps.state.agent_capabilities = result.agentCapabilities
        deps.state.auth_methods = result.authMethods or {}
        deps.state.initialized = true

        deps.continuity.set_agent_info(current_session, result.agentInfo)
    end

    ---@param current_session legate.Session
    function helper.authenticate(current_session)
        if deps.state.authenticated then
            return
        end

        if #deps.state.auth_methods == 0 then
            deps.state.authenticated = true
            return
        end

        local adapter = deps.config.adapter_for_session(current_session)
        local method_id = adapter.auth_method or deps.state.auth_methods[1].id
        local _, rpc_error = deps.ensure_client(current_session):request_sync(deps.methods.AUTHENTICATE, {
            methodId = method_id,
        })

        if rpc_error ~= nil then
            error(rpc_error.message)
        end

        deps.state.authenticated = true
    end

    ---@param current_session legate.Session
    function helper.prepare_connection(current_session)
        if deps.should_rebind_connection(current_session) then
            deps.reset_connection()
        end

        helper.initialize(current_session)
        helper.authenticate(current_session)
    end

    ---@param current_session legate.Session
    function helper.apply_adapter_config_option_overrides(current_session)
        local adapter = deps.config.adapter_for_session(current_session)
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

            for _, choice in ipairs(deps.config_option.choices(option)) do
                allowed[choice.value.value] = true
            end

            if not allowed[value] then
                error(string.format('ACP adapter override uses invalid value for %s: %s', config_id, tostring(value)))
            end

            if option.currentValue ~= value then
                local result, rpc_error = deps.ensure_client(current_session)
                    :request_sync(deps.methods.SESSION_SET_CONFIG_OPTION, {
                        sessionId = current_session.remote_id,
                        configId = config_id,
                        value = value,
                    })

                if rpc_error ~= nil then
                    error(rpc_error.message)
                end

                deps.continuity.set_config_options(current_session, result.configOptions or {})
            end
        end
    end

    ---@param current_session legate.Session
    ---@param drain_session_updates fun(current_session: legate.Session, session_id: string)
    ---@param opts? { force_load?: boolean, force_new?: boolean }
    function helper.establish_session(current_session, drain_session_updates, opts)
        local force_load = opts ~= nil and opts.force_load or false
        local force_new = opts ~= nil and opts.force_new or false
        local previous_remote_id = current_session.remote_id
        local previous_remote_sync_state = current_session.remote_sync_state
        local previous_remote_sync_error = current_session.remote_sync_error
        local previous_transport_remote_id = deps.continuity.transport_remote_id(current_session)

        if force_load and previous_transport_remote_id == nil then
            previous_transport_remote_id = previous_remote_id

            if previous_transport_remote_id ~= nil then
                deps.continuity.set_transport_remote_id(
                    current_session,
                    previous_transport_remote_id,
                    previous_remote_sync_state,
                    previous_remote_sync_error
                )
            end
        end

        if force_new then
            deps.continuity.clear_remote_id(current_session)
            deps.state.bound_local_session_id = nil
            deps.state.bound_remote_session_id = nil
            deps.state.active_session = nil
            deps.state.loaded_existing_session = false
        end

        if
            not force_new
            and not force_load
            and previous_transport_remote_id ~= nil
            and deps.state.bound_local_session_id == current_session.id
            and deps.state.bound_remote_session_id == previous_transport_remote_id
        then
            deps.state.active_session = current_session
            return
        end

        if not force_new and previous_transport_remote_id ~= nil then
            if deps.state.agent_capabilities ~= nil and deps.state.agent_capabilities.loadSession then
                deps.state.active_session = current_session
                deps.state.loading_existing_session = true
                local params, cwd =
                    deps.session_request_params(current_session, current_session.cwd, previous_transport_remote_id)
                local result, rpc_error = deps.ensure_client(current_session)
                    :request_sync(deps.methods.SESSION_LOAD, params)
                deps.state.loading_existing_session = false

                if rpc_error == nil then
                    ---@cast result legate.SessionLoadResult
                    deps.state.bound_local_session_id = current_session.id
                    deps.state.bound_remote_session_id = previous_transport_remote_id
                    deps.state.active_session = current_session
                    deps.state.loaded_existing_session = true
                    deps.continuity.set_remote_sync_state(current_session, 'loaded')
                    deps.continuity.set_cwd(current_session, cwd)
                    deps.continuity.set_available_commands(current_session, {})
                    deps.continuity.set_config_options(current_session, result.configOptions or {})
                    helper.apply_adapter_config_option_overrides(current_session)
                    drain_session_updates(current_session, previous_transport_remote_id)
                    return
                end

                deps.state.pending_session_updates[previous_transport_remote_id] = nil
                deps.state.bound_local_session_id = nil
                deps.state.bound_remote_session_id = nil
                deps.state.active_session = nil
                deps.state.loaded_existing_session = false
                deps.continuity.set_transport_remote_id(current_session, nil, 'load_failed', rpc_error.message)

                if previous_remote_id ~= nil then
                    error(rpc_error.message)
                end

                if force_load then
                    error(rpc_error.message)
                end
            elseif force_load then
                local message = string.format(
                    'ACP agent does not advertise session/load support for session %s',
                    current_session.id
                )
                deps.state.bound_local_session_id = nil
                deps.state.bound_remote_session_id = nil
                deps.state.active_session = nil
                deps.state.loaded_existing_session = false
                deps.continuity.set_transport_remote_id(current_session, nil, 'load_failed', message)
                error(message)
            end
        end

        deps.state.active_session = current_session
        deps.state.creating_new_session = true
        local params, cwd = deps.session_request_params(current_session)
        local result, rpc_error = deps.ensure_client(current_session):request_sync(deps.methods.SESSION_NEW, params)
        deps.state.creating_new_session = false

        if rpc_error ~= nil then
            if previous_remote_id ~= nil then
                deps.continuity.set_transport_remote_id(
                    current_session,
                    previous_transport_remote_id,
                    previous_remote_sync_state,
                    previous_remote_sync_error
                )
            elseif force_new then
                deps.continuity.clear_remote_id(current_session, previous_remote_sync_state, previous_remote_sync_error)
            end

            error(rpc_error.message)
        end

        ---@cast result legate.SessionNewResult
        if result.sessionId == nil or result.sessionId == '' then
            deps.reset_connection()
            error('ACP session/new did not return a sessionId')
        end

        deps.state.bound_local_session_id = current_session.id
        deps.state.bound_remote_session_id = result.sessionId
        deps.state.active_session = current_session
        deps.state.loaded_existing_session = false

        deps.continuity.set_remote_id(current_session, result.sessionId, 'created')
        deps.continuity.set_cwd(current_session, cwd)
        deps.continuity.set_config_options(current_session, result.configOptions or {})
        helper.apply_adapter_config_option_overrides(current_session)
        deps.continuity.set_available_commands(current_session, {})
        drain_session_updates(current_session, result.sessionId)
    end

    return helper
end

return M
