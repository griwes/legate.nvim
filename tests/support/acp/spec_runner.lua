local M = {}

function M.run(description, body_path)
    describe(description, function()
        local plugin
        local api
        local transport
        local fake_client
        local fake_clients
        local fake_next_session
        local fake_available_commands
        local fake_on_new
        local fake_supports_load
        local fake_on_load
        local fake_load_error
        local terminalia_modules = {
            'terminalia.api',
            'terminalia.commands',
            'terminalia.config',
            'terminalia.context.providers',
            'terminalia.context.state',
            'terminalia.history',
            'terminalia.init',
            'terminalia.persistence',
            'terminalia.runtime.native',
            'terminalia.terminal.model',
            'terminalia.terminal.registry',
            'terminalia.view.float',
            'terminalia.view.history',
            'terminalia.view.split',
        }

        local function temp_path(name)
            local root = vim.fn.tempname()
            vim.fn.mkdir(root, 'p')
            return root .. '/' .. name
        end

        local function read_file(path)
            local handle = assert(io.open(path, 'rb'))
            local content = assert(handle:read('*a'))
            handle:close()
            return content
        end

        local function wait_until(predicate, timeout_ms)
            local ok = vim.wait(timeout_ms or 1000, predicate, 10)
            assert.is_true(ok)
        end

        local function chmod(path, mode)
            local ok = os.execute(string.format("chmod %s '%s'", mode, path:gsub("'", "'\\''")))
            assert.is_true(ok == true or ok == 0)
        end

        ---@param session_id? string
        ---@param available_commands? legate.AvailableCommand[]
        local function emit_available_commands_update(session_id, available_commands)
            fake_client:emit_notification('session/update', {
                sessionId = session_id or 'sess_123',
                update = {
                    sessionUpdate = 'available_commands_update',
                    availableCommands = vim.deepcopy(available_commands or fake_available_commands),
                },
            })
        end

        ---@param sessions legate.Session[]
        ---@return string[]
        local function session_ids(sessions)
            return vim.tbl_map(function(item)
                return item.id
            end, sessions)
        end

        ---@param selector fun(items: legate.Session[], opts: table, on_choice: fun(selected_session?: legate.Session))
        local function with_ui_select(selector)
            local original = vim.ui.select

            vim.ui.select = selector

            return function()
                vim.ui.select = original
            end
        end

        ---@param inputter fun(opts: table, on_confirm: fun(value?: string))
        local function with_ui_input(inputter)
            local original = vim.ui.input

            vim.ui.input = inputter

            return function()
                vim.ui.input = original
            end
        end

        local function with_fast_event_schedule()
            local original_in_fast_event = vim.in_fast_event
            local original_schedule = vim.schedule
            local scheduled = {}

            vim.in_fast_event = function()
                return true
            end
            vim.schedule = function(callback)
                table.insert(scheduled, callback)
            end

            return scheduled,
                function()
                    vim.in_fast_event = original_in_fast_event
                    vim.schedule = original_schedule
                end
        end

        local function clear_terminalia_modules()
            for _, module_name in ipairs(terminalia_modules) do
                package.loaded[module_name] = nil
            end
        end

        local function setup_terminalia()
            local history_dir = vim.fn.tempname()
            local state_file = vim.fn.tempname()
            local repo = vim.fn.fnamemodify(vim.fn.getcwd() .. '/../terminalia.nvim', ':p')

            vim.opt.runtimepath:prepend(repo)
            clear_terminalia_modules()

            local terminalia = require('terminalia')

            terminalia.setup({
                history_dir = history_dir,
                notify_on_exit = false,
                state_file = state_file,
            })
            terminalia.api.clear()

            return terminalia
        end

        local function clear_terminalia_state()
            if package.loaded['terminalia'] == nil then
                return
            end

            require('terminalia').api.clear()
        end

        local function install_fake_transport()
            fake_clients = {}
            transport._set_rpc_factory(function(opts)
                fake_client = {
                    opts = opts,
                    sync_calls = {},
                    async_calls = {},
                    notifications = {},
                    callback = nil,
                    started = false,
                    closed = false,
                }

                table.insert(fake_clients, fake_client)

                function fake_client:start()
                    self.started = true
                    return true
                end

                local fake_config_options = {
                    {
                        id = 'mode',
                        name = 'Mode',
                        description = 'Controls how the agent requests permission',
                        category = 'mode',
                        type = 'select',
                        currentValue = 'ask',
                        options = {
                            {
                                value = 'ask',
                                name = 'Ask',
                                description = 'Request permission before making changes',
                            },
                            {
                                value = 'code',
                                name = 'Code',
                                description = 'Write and modify code with full tool access',
                            },
                        },
                    },
                    {
                        id = 'model',
                        name = 'Model',
                        category = 'model',
                        type = 'select',
                        currentValue = 'gpt-5.4',
                        options = {
                            {
                                value = 'gpt-5.4',
                                name = 'GPT-5.4',
                            },
                            {
                                value = 'gpt-5.4-mini',
                                name = 'GPT-5.4 Mini',
                            },
                        },
                    },
                }

                function fake_client:request_sync(method, params)
                    table.insert(self.sync_calls, {
                        method = method,
                        params = vim.deepcopy(params),
                    })

                    if method == 'initialize' then
                        return {
                            protocolVersion = 1,
                            agentInfo = {
                                name = 'codex-acp',
                                title = 'Codex ACP',
                                version = '0.11.1',
                            },
                            agentCapabilities = {
                                loadSession = fake_supports_load,
                            },
                            authMethods = {
                                {
                                    id = 'chatgpt',
                                },
                            },
                        }
                    end

                    if method == 'authenticate' then
                        return {}
                    end

                    if method == 'session/new' then
                        local session_id = string.format('sess_%03d', fake_next_session)
                        fake_next_session = fake_next_session + 1

                        if fake_on_new ~= nil then
                            fake_on_new(self, session_id)
                        end

                        return {
                            sessionId = session_id,
                            configOptions = vim.deepcopy(fake_config_options),
                        }
                    end

                    if method == 'session/load' then
                        if fake_load_error ~= nil then
                            return nil,
                                {
                                    message = fake_load_error,
                                }
                        end

                        if fake_on_load ~= nil then
                            fake_on_load(self, params)
                        end

                        return {
                            configOptions = vim.deepcopy(fake_config_options),
                        }
                    end

                    if method == 'session/set_config_option' then
                        for _, option in ipairs(fake_config_options) do
                            if option.id == params.configId then
                                option.currentValue = params.value
                            end
                        end

                        return {
                            configOptions = vim.deepcopy(fake_config_options),
                        }
                    end

                    error('Unexpected sync method: ' .. method)
                end

                function fake_client:request(method, params, callback)
                    table.insert(self.async_calls, {
                        method = method,
                        params = vim.deepcopy(params),
                    })
                    self.callback = callback
                end

                function fake_client:notify(method, params)
                    table.insert(self.notifications, {
                        method = method,
                        params = vim.deepcopy(params),
                    })
                end

                function fake_client:close()
                    self.closed = true
                end

                function fake_client:emit_notification(method, params)
                    self.opts.on_notification(method, params)
                end

                function fake_client:emit_request(method, params)
                    local response
                    self.opts.on_request(method, params, function(result, error)
                        response = {
                            result = result,
                            error = error,
                        }
                    end)

                    return response
                end

                function fake_client:resolve(result, error)
                    assert.is_not_nil(self.callback)
                    self.callback(result, error)
                end

                return fake_client
            end)
        end

        before_each(function()
            for name, _ in pairs(package.loaded) do
                if name == 'legate' or vim.startswith(name, 'legate.') then
                    package.loaded[name] = nil
                end
            end
            clear_terminalia_modules()
            vim.g.loaded_acp = nil

            plugin = require('legate')
            api = plugin.api
            transport = require('legate.transport')
            fake_next_session = 123
            fake_available_commands = {
                {
                    name = 'web',
                    description = 'Search the web for information',
                    input = {
                        hint = 'query to search for',
                    },
                },
                {
                    name = 'test',
                    description = 'Run tests for the current project',
                },
            }
            fake_on_new = nil
            fake_supports_load = false
            fake_on_load = nil
            fake_load_error = nil
            api.clear()
            install_fake_transport()
        end)

        after_each(function()
            api.clear()
            clear_terminalia_state()
            clear_terminalia_modules()
        end)
        local function body_env()
            local readers = {
                plugin = function()
                    return plugin
                end,
                api = function()
                    return api
                end,
                transport = function()
                    return transport
                end,
                fake_client = function()
                    return fake_client
                end,
                fake_clients = function()
                    return fake_clients
                end,
                fake_next_session = function()
                    return fake_next_session
                end,
                fake_available_commands = function()
                    return fake_available_commands
                end,
                fake_on_new = function()
                    return fake_on_new
                end,
                fake_supports_load = function()
                    return fake_supports_load
                end,
                fake_on_load = function()
                    return fake_on_load
                end,
                fake_load_error = function()
                    return fake_load_error
                end,
                terminalia_modules = function()
                    return terminalia_modules
                end,
                temp_path = function()
                    return temp_path
                end,
                read_file = function()
                    return read_file
                end,
                wait_until = function()
                    return wait_until
                end,
                chmod = function()
                    return chmod
                end,
                emit_available_commands_update = function()
                    return emit_available_commands_update
                end,
                session_ids = function()
                    return session_ids
                end,
                with_ui_select = function()
                    return with_ui_select
                end,
                with_ui_input = function()
                    return with_ui_input
                end,
                with_fast_event_schedule = function()
                    return with_fast_event_schedule
                end,
                clear_terminalia_modules = function()
                    return clear_terminalia_modules
                end,
                setup_terminalia = function()
                    return setup_terminalia
                end,
                clear_terminalia_state = function()
                    return clear_terminalia_state
                end,
                install_fake_transport = function()
                    return install_fake_transport
                end,
            }
            local writers = {
                plugin = function(value)
                    plugin = value
                end,
                api = function(value)
                    api = value
                end,
                transport = function(value)
                    transport = value
                end,
                fake_client = function(value)
                    fake_client = value
                end,
                fake_clients = function(value)
                    fake_clients = value
                end,
                fake_next_session = function(value)
                    fake_next_session = value
                end,
                fake_available_commands = function(value)
                    fake_available_commands = value
                end,
                fake_on_new = function(value)
                    fake_on_new = value
                end,
                fake_supports_load = function(value)
                    fake_supports_load = value
                end,
                fake_on_load = function(value)
                    fake_on_load = value
                end,
                fake_load_error = function(value)
                    fake_load_error = value
                end,
            }

            return setmetatable({}, {
                __index = function(_, key)
                    local reader = readers[key]

                    if reader ~= nil then
                        return reader()
                    end

                    return _G[key]
                end,
                __newindex = function(_, key, value)
                    local writer = writers[key]

                    if writer ~= nil then
                        writer(value)
                        return
                    end

                    error('Unexpected ACP spec assignment: ' .. tostring(key))
                end,
            })
        end

        local body = assert(loadfile(body_path))
        setfenv(body, body_env())
        body()
    end)
end

return M
