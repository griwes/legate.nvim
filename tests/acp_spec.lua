describe('acp', function()
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
    local terminal_manager_modules = {
        'terminal_manager',
        'terminal_manager.api',
        'terminal_manager.commands',
        'terminal_manager.config',
        'terminal_manager.history',
        'terminal_manager.init',
        'terminal_manager.model',
        'terminal_manager.persistence',
        'terminal_manager.registry',
        'terminal_manager.runtime.native',
        'terminal_manager.view.float',
        'terminal_manager.view.history',
        'terminal_manager.view.split',
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
    ---@param available_commands? acp.AvailableCommand[]
    local function emit_available_commands_update(session_id, available_commands)
        fake_client:emit_notification('session/update', {
            sessionId = session_id or 'sess_123',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = vim.deepcopy(available_commands or fake_available_commands),
            },
        })
    end

    ---@param sessions acp.Session[]
    ---@return string[]
    local function session_ids(sessions)
        return vim.tbl_map(function(item)
            return item.id
        end, sessions)
    end

    ---@param selector fun(items: acp.Session[], opts: table, on_choice: fun(selected_session?: acp.Session))
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

    local function clear_terminal_manager_modules()
        for _, module_name in ipairs(terminal_manager_modules) do
            package.loaded[module_name] = nil
        end
    end

    local function setup_terminal_manager()
        local history_dir = vim.fn.tempname()
        local state_file = vim.fn.tempname()
        local repo = vim.fn.fnamemodify(vim.fn.getcwd() .. '/../terminal-manager.nvim', ':p')

        vim.opt.runtimepath:prepend(repo)
        clear_terminal_manager_modules()

        local terminal_manager = require('terminal_manager')

        terminal_manager.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = state_file,
        })
        terminal_manager.api.clear()

        return terminal_manager
    end

    local function clear_terminal_manager_state()
        if package.loaded['terminal_manager'] == nil then
            return
        end

        require('terminal_manager').api.clear()
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
                        return nil, {
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
        package.loaded['acp'] = nil
        package.loaded['acp.api'] = nil
        package.loaded['acp.buffer'] = nil
        package.loaded['acp.commands'] = nil
        package.loaded['acp.config_option'] = nil
        package.loaded['acp.config'] = nil
        package.loaded['acp.input'] = nil
        package.loaded['acp.model'] = nil
        package.loaded['acp.methods'] = nil
        package.loaded['acp.persistence'] = nil
        package.loaded['acp.rpc'] = nil
        package.loaded['acp.render'] = nil
        package.loaded['acp.session'] = nil
        package.loaded['acp.terminal'] = nil
        package.loaded['acp.transport'] = nil
        clear_terminal_manager_modules()
        vim.g.loaded_acp = nil

        plugin = require('acp')
        api = plugin.api
        transport = require('acp.transport')
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
        clear_terminal_manager_state()
        clear_terminal_manager_modules()
    end)

    it('loads and exposes setup', function()
        assert.are.equal('function', type(plugin.setup))
        assert.are.equal('function', type(api.open_chat))
        assert.are.equal('function', type(api.list_sessions))
        assert.are.equal('function', type(api.select_session))
    end)

    it('normalizes configuration with defaults', function()
        local config = plugin.setup({
            chat_buffer_name = 'ACP Test',
        })

        assert.are.equal('ACP Test', config.chat_buffer_name)
        assert.are.equal('markdown', config.filetype)
        assert.is_true(config.persist_sessions)
        assert.is_false(config.restore_sessions_on_setup)
        assert.are.equal('sessions.json', vim.fs.basename(config.session_state_file))
        assert.are.equal('native', config.terminal_backend)
        assert.are.same({ 'codex-acp' }, config.agent_command)
        assert.are.equal('default', config.permission_strategy)
        assert.are.equal('reject_once', config.permission_default)
    end)

    it('accepts terminal_manager as an ACP terminal backend', function()
        local config = plugin.setup({
            terminal_backend = 'terminal_manager',
        })

        assert.are.equal('terminal_manager', config.terminal_backend)
    end)

    it('accepts select as an ACP permission strategy', function()
        local config = plugin.setup({
            permission_strategy = 'select',
        })

        assert.are.equal('select', config.permission_strategy)
    end)

    it('creates and reuses a single chat buffer', function()
        local first = api.open_chat()
        local second = api.open_chat()

        assert.are.equal(first, second)
        assert.are.equal('ACP.md', vim.fn.fnamemodify(vim.api.nvim_buf_get_name(first), ':t'))
        assert.are.equal(
            'markdown',
            vim.api.nvim_get_option_value('filetype', {
                buf = first,
            })
        )
    end)

    it('creates ordered session identifiers', function()
        local first = api.new_session()
        local second = api.new_session()

        assert.are.equal('acp:1', first.id)
        assert.are.equal('acp:2', second.id)
        assert.are.equal('acp:2', api.current_session().id)
    end)

    it('lists sessions and preserves a draft per session when switching', function()
        api.open_chat()
        local first = api.current_session()

        api.set_prompt('draft one')
        local second = api.new_session()
        api.set_prompt('draft two')

        local sessions = api.list_sessions()

        assert.are.same({ first.id, second.id }, { sessions[1].id, sessions[2].id })

        api.select_session(first.id)
        assert.are.equal('draft one', api.get_prompt())

        api.select_session(second.id)
        assert.are.equal('draft two', api.get_prompt())
    end)

    it('formats local ACP sessions for command-line or picker use', function()
        local first = api.new_session()

        api.append_message('assistant', 'hello')
        local second = api.new_session()

        assert.are.same({
            string.format('  %s  [idle]  remote=unbound  sync=unbound  messages=%d', first.id, 1),
            string.format('* %s  [idle]  remote=unbound  sync=unbound  messages=%d', second.id, 0),
        }, api.session_lines())
    end)

    it('closes a non-current local ACP session without disturbing the selected one', function()
        local first = api.new_session()
        local second = api.new_session()

        local closed, next_session = api.close_session(first.id)

        assert.are.equal(first.id, closed.id)
        assert.are.equal(second.id, assert(next_session).id)
        assert.are.equal(second.id, api.current_session().id)
        assert.are.same({ second.id }, session_ids(api.list_sessions()))
    end)

    it('closes the current local ACP session and rerenders the next selected session', function()
        local bufnr = api.open_chat()
        local first = api.current_session()

        api.set_prompt('first draft')
        local second = api.new_session()
        api.set_prompt('second draft')
        api.select_session(first.id)

        local closed, next_session = api.close_session(first.id)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal(first.id, closed.id)
        assert.are.equal(second.id, assert(next_session).id)
        assert.are.equal(second.id, api.current_session().id)
        assert.are.equal('second draft', api.get_prompt())
        assert.is_true(vim.tbl_contains(lines, string.format('- ID: `%s`', second.id)))
    end)

    it('rejects closing a waiting ACP session', function()
        api.open_chat()
        api.set_prompt('wait')
        api.submit_prompt()

        assert.has_error(function()
            api.close_session()
        end, 'Cannot close ACP session while a prompt turn is still running: acp:1')
    end)

    it('recreates a fresh current session when closing the last session with auto-create enabled', function()
        local bufnr = api.open_chat()
        local first = api.current_session()

        api.set_prompt('discard me')

        local closed, next_session = api.close_session(first.id)

        assert.are.equal(first.id, closed.id)
        assert.is_not_nil(next_session)
        assert.are.equal('acp:2', next_session.id)
        assert.are.equal('acp:2', api.current_session().id)
        assert.are.equal('', api.get_prompt())
        assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '- ID: `acp:2`'))
    end)

    it('invokes vim.ui.select for ACP session picking', function()
        api.new_session()
        api.new_session()

        local restore = with_ui_select(function(items, opts, on_choice)
            assert.are.same({ 'acp:1', 'acp:2' }, session_ids(items))
            assert.are.equal('Select ACP session', opts.prompt)
            assert.are.equal('* acp:2  [idle]  remote=unbound  sync=unbound  messages=0', opts.format_item(items[2]))
            on_choice(nil)
        end)

        api.pick_session()
        restore()
    end)

    it('selects a local ACP session through the picker surface', function()
        api.open_chat()
        local first = api.current_session()
        local second = api.new_session()
        local restore = with_ui_select(function(_, _, on_choice)
            on_choice(first)
        end)

        api.pick_session()
        restore()

        assert.are.equal(first.id, api.current_session().id)

        restore = with_ui_select(function(_, _, on_choice)
            on_choice(second)
        end)

        api.pick_session()
        restore()

        assert.are.equal(second.id, api.current_session().id)
    end)

    it('does nothing when the picker returns no session selection', function()
        api.new_session()
        local second = api.new_session()
        local restore = with_ui_select(function(_, _, on_choice)
            on_choice(nil)
        end)

        api.pick_session()
        restore()

        assert.are.equal(second.id, api.current_session().id)
        assert.are.same({ 'acp:1', 'acp:2' }, session_ids(api.list_sessions()))
    end)

    it('closes a local ACP session through the picker surface', function()
        local first = api.new_session()
        local second = api.new_session()
        local restore = with_ui_select(function(items, opts, on_choice)
            assert.are.same({ first.id, second.id }, session_ids(items))
            assert.are.equal('Close ACP session', opts.prompt)
            on_choice(first)
        end)

        api.pick_close_session()
        restore()

        assert.are.equal(second.id, api.current_session().id)
        assert.are.same({ second.id }, session_ids(api.list_sessions()))
    end)

    it('loads an unbound local ACP session explicitly and rerenders remote sync state', function()
        local bufnr = api.open_chat()
        local current_session = api.current_session()

        api.load_session()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('sess_123', current_session.remote_id)
        assert.are.equal('created', current_session.remote_sync_state)
        assert.are.equal('session/new', fake_client.sync_calls[3].method)
        assert.is_true(vim.tbl_contains(lines, '- Remote ID: `sess_123`'))
        assert.is_true(vim.tbl_contains(lines, '- Remote Sync: `created`'))
    end)

    it('loads an existing remote ACP session explicitly when the agent supports session/load', function()
        local bufnr = api.open_chat()

        fake_supports_load = true
        fake_on_load = function(client, params)
            client:emit_notification('session/update', {
                sessionId = params.sessionId,
                update = {
                    sessionUpdate = 'available_commands_update',
                    availableCommands = vim.deepcopy(fake_available_commands),
                },
            })
        end

        api.set_prompt('first turn')
        local current_session = api.submit_prompt()
        local first_client = fake_client

        fake_client:resolve({
            stopReason = 'end_turn',
        })

        api.load_session()

        local second_client = fake_client
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(first_client.closed)
        assert.are.equal('sess_123', current_session.remote_id)
        assert.are.equal('loaded', current_session.remote_sync_state)
        assert.are.equal(2, #current_session.available_commands)
        assert.are.equal('session/load', second_client.sync_calls[3].method)
        assert.are.equal('sess_123', second_client.sync_calls[3].params.sessionId)
        assert.is_true(vim.tbl_contains(lines, '- Remote Sync: `loaded`'))
        assert.is_true(vim.tbl_contains(lines, '## Slash Commands'))
    end)

    it('rejects explicitly loading an already-bound ACP session when session/load is unsupported', function()
        local bufnr = api.open_chat()
        api.set_prompt('first turn')
        local current_session = api.submit_prompt()
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        assert.has_error(function()
            api.load_session()
        end, 'ACP agent does not advertise session/load support for session acp:1')

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('load_failed', current_session.remote_sync_state)
        assert.are.equal(
            'ACP agent does not advertise session/load support for session acp:1',
            current_session.remote_sync_error
        )
        assert.is_true(vim.tbl_contains(lines, '- Remote Sync: `load_failed`'))
        assert.is_true(
            vim.tbl_contains(
                lines,
                '- Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
            )
        )
    end)

    it('rebinds through session/new after an explicit load failure cleared the prior fast-path binding', function()
        api.open_chat()
        local current_session = api.load_session()

        assert.are.equal('sess_123', current_session.remote_id)
        assert.are.equal('created', current_session.remote_sync_state)

        assert.has_error(function()
            api.load_session()
        end, 'ACP agent does not advertise session/load support for session acp:1')

        api.set_prompt('after failed reload')
        api.submit_prompt()

        assert.are.equal('sess_124', current_session.remote_id)
        assert.are.equal('created', current_session.remote_sync_state)
        assert.are.equal('session/new', fake_client.sync_calls[4].method)
        assert.are.equal('sess_124', fake_client.async_calls[1].params.sessionId)
    end)

    it('surfaces session/load runtime failure instead of silently rebinding to a fresh remote session', function()
        local bufnr = api.open_chat()
        fake_supports_load = true
        api.set_prompt('first turn')
        local current_session = api.submit_prompt()

        fake_client:resolve({
            stopReason = 'end_turn',
        })

        local first_remote_id = current_session.remote_id

        fake_load_error = 'session/load failed'

        assert.has_error(function()
            api.load_session()
        end, 'session/load failed')

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal(first_remote_id, current_session.remote_id)
        assert.are.equal('load_failed', current_session.remote_sync_state)
        assert.are.equal(3, #fake_client.sync_calls)
        assert.are.equal('session/load', fake_client.sync_calls[3].method)
        assert.are.equal('session/load failed', current_session.remote_sync_error)
        assert.is_true(vim.tbl_contains(lines, '- Remote Sync: `load_failed`'))
        assert.is_true(vim.tbl_contains(lines, '- Remote Sync Error: `session/load failed`'))
        assert.is_true(
            vim.tbl_contains(
                lines,
                '- Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
            )
        )
        assert.is_true(
            vim.tbl_contains(api.session_lines(), '* acp:1  [idle]  remote=sess_123  sync=load_failed  messages=1')
        )
    end)

    it('rebinds a load_failed ACP session to a fresh remote session explicitly', function()
        local bufnr = api.open_chat()
        fake_supports_load = true
        api.set_prompt('first turn')
        local current_session = api.submit_prompt()

        fake_client:resolve({
            stopReason = 'end_turn',
        })

        local first_remote_id = current_session.remote_id

        fake_load_error = 'session/load failed'

        assert.has_error(function()
            api.load_session()
        end, 'session/load failed')

        api.rebind_session()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('sess_124', current_session.remote_id)
        assert.are_not.equal(first_remote_id, current_session.remote_id)
        assert.are.equal('created', current_session.remote_sync_state)
        assert.is_nil(current_session.remote_sync_error)
        assert.are.equal(1, #current_session.messages)
        assert.are.equal('first turn', current_session.messages[1].text)
        assert.are.equal('session/new', fake_client.sync_calls[3].method)
        assert.is_true(vim.tbl_contains(lines, '- Remote Sync: `created`'))
        assert.is_false(vim.tbl_contains(lines, '- Remote Sync Error: `session/load failed`'))
    end)

    it('rejects loading an ACP session while another session has a running turn', function()
        api.open_chat()
        api.set_prompt('running turn')
        local first = api.submit_prompt()
        local second = api.new_session()

        assert.are.equal('waiting', first.status)
        assert.has_error(function()
            api.load_session(second.id)
        end, 'Cannot load ACP session acp:2 while session acp:1 has a running turn')
    end)

    it('rejects rebinding an ACP session while another session has a running turn', function()
        api.open_chat()
        fake_supports_load = true
        api.set_prompt('first turn')
        local first = api.submit_prompt()
        fake_client:resolve({
            stopReason = 'end_turn',
        })
        fake_load_error = 'session/load failed'

        assert.has_error(function()
            api.load_session(first.id)
        end, 'session/load failed')

        local second = api.new_session()
        api.set_prompt('running turn')
        api.submit_prompt()

        assert.has_error(function()
            api.rebind_session(first.id)
        end, 'Cannot rebind ACP session acp:1 while session acp:2 has a running turn')

        assert.are.equal('waiting', second.status)
    end)

    it('saves and restores multiple local ACP sessions from disk', function()
        local state_file = temp_path('acp-sessions.json')

        plugin.setup({
            session_state_file = state_file,
        })
        api.open_chat()
        api.append_message('assistant', 'first reply')
        api.config_options()
        emit_available_commands_update()
        api.set_prompt('approval seed')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'persist_approval',
                title = 'Persist approval',
                status = 'pending',
                kind = 'read',
            },
        })
        fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'persist_approval',
                title = 'Persist approval',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })
        fake_client:resolve({
            stopReason = 'end_turn',
        })
        api.set_prompt('first draft')

        local first = api.current_session()
        local second = api.new_session()
        api.set_prompt('second draft')
        api.select_session(first.id)

        api.save_sessions()
        api.clear()

        plugin.setup({
            session_state_file = state_file,
        })

        local restored = api.restore_sessions()

        assert.are.same({ first.id, second.id }, session_ids(restored))
        assert.are.equal(first.id, api.current_session().id)
        assert.are.equal('first draft', api.current_session().draft_prompt)
        assert.are.equal('sess_123', api.current_session().remote_id)
        assert.are.equal(1, #api.current_session().approval_entries)
        assert.are.equal(2, #api.current_session().available_commands)
        assert.are.equal(2, #api.current_session().config_options)
        assert.are.equal('first reply', api.current_session().messages[1].text)

        api.select_session(second.id)

        assert.are.equal('second draft', api.current_session().draft_prompt)
    end)

    it('restores waiting sessions as cancelled local sessions with the prompt moved back to the draft', function()
        local state_file = temp_path('acp-waiting-sessions.json')

        plugin.setup({
            session_state_file = state_file,
        })
        api.open_chat()
        api.set_prompt('pending prompt')
        local current_session = api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'pending_tool',
                title = 'Pending tool',
                status = 'in_progress',
                kind = 'execute',
            },
        })

        assert.are.equal('waiting', current_session.status)

        api.save_sessions()
        api.clear()

        plugin.setup({
            session_state_file = state_file,
        })
        api.restore_sessions()

        local restored = api.current_session()

        assert.are.equal('cancelled', restored.status)
        assert.are.equal('cancelled', restored.stop_reason)
        assert.is_nil(restored.pending_prompt)
        assert.are.equal('pending prompt', restored.draft_prompt)
        assert.are.equal('cancelled', restored.tool_calls[1].status)
    end)

    it('restores persisted ACP sessions during setup when configured', function()
        local state_file = temp_path('acp-restore-on-setup.json')

        plugin.setup({
            session_state_file = state_file,
        })
        api.open_chat()
        api.set_prompt('restored on setup')
        local current_id = api.current_session().id
        api.save_sessions()
        api.clear()

        plugin.setup({
            session_state_file = state_file,
            restore_sessions_on_setup = true,
        })

        assert.are.equal(current_id, api.current_session().id)
        assert.are.equal('restored on setup', api.current_session().draft_prompt)
    end)

    it('restores slash commands whose optional input decodes as json null', function()
        local state_file = temp_path('acp-restore-null-input.json')

        vim.fn.writefile({
            vim.json.encode({
                current_id = 'acp:1',
                next_ordinal = 2,
                next_message_id = 3,
                sessions = {
                    {
                        id = 'acp:1',
                        ordinal = 1,
                        status = 'idle',
                        messages = {
                            {
                                id = 1,
                                role = 'assistant',
                                text = 'restored slash command',
                            },
                        },
                        draft_prompt = '',
                        remote_id = 'sess_123',
                        remote_sync_state = 'created',
                        available_commands = {
                            {
                                name = 'resume',
                                description = 'Resume work',
                                input = vim.NIL,
                            },
                        },
                    },
                },
            }),
        }, state_file)

        plugin.setup({
            session_state_file = state_file,
        })

        local ok, err = pcall(function()
            api.restore_sessions({
                open_chat = true,
            })
        end)

        assert.is_true(ok, err)
        assert.are.same({
            '/resume  Resume work',
        }, api.slash_command_lines())
        assert.is_nil(api.current_session().available_commands[1].input)
    end)

    it('restores persisted load_failed remote sync state and error metadata', function()
        local state_file = temp_path('acp-restore-load-failed.json')

        vim.fn.writefile({
            vim.json.encode({
                current_id = 'acp:1',
                next_ordinal = 2,
                next_message_id = 2,
                sessions = {
                    {
                        id = 'acp:1',
                        ordinal = 1,
                        status = 'idle',
                        messages = {
                            {
                                id = 1,
                                role = 'assistant',
                                text = 'restore failed previously',
                            },
                        },
                        draft_prompt = '',
                        remote_id = 'sess_123',
                        remote_sync_state = 'load_failed',
                        remote_sync_error = 'session/load failed',
                    },
                },
            }),
        }, state_file)

        plugin.setup({
            session_state_file = state_file,
        })

        api.restore_sessions({
            open_chat = true,
        })

        local current_session = api.current_session()
        local bufnr = api.open_chat()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('load_failed', current_session.remote_sync_state)
        assert.are.equal('session/load failed', current_session.remote_sync_error)
        assert.is_true(vim.tbl_contains(lines, '- Remote Sync: `load_failed`'))
        assert.is_true(vim.tbl_contains(lines, '- Remote Sync Error: `session/load failed`'))
        assert.is_true(
            vim.tbl_contains(
                lines,
                '- Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
            )
        )
    end)

    it('submits prompt text from the shared chat buffer into the transcript', function()
        local bufnr = api.open_chat()

        api.set_prompt('hello from ACP')
        local session = api.submit_prompt()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('waiting', session.status)
        assert.are.equal('hello from ACP', session.pending_prompt)
        assert.is_true(vim.tbl_contains(lines, '### User'))
        assert.is_true(vim.tbl_contains(lines, 'hello from ACP'))
        assert.are.equal('', api.get_prompt())

        assert.are.equal('initialize', fake_client.sync_calls[1].method)
        assert.are.equal('authenticate', fake_client.sync_calls[2].method)
        assert.are.equal('session/new', fake_client.sync_calls[3].method)
        assert.are.equal('session/prompt', fake_client.async_calls[1].method)
        assert.are.equal('sess_123', fake_client.async_calls[1].params.sessionId)
        assert.are.equal('hello from ACP', fake_client.async_calls[1].params.prompt[1].text)
        assert.are.same({
            fs = {
                readTextFile = true,
                writeTextFile = true,
            },
            terminal = true,
        }, fake_client.sync_calls[1].params.clientCapabilities)
    end)

    it('initializes the chat surface for prompt APIs without a prior open', function()
        api.set_prompt('bootstrap prompt')

        local session = api.submit_prompt()

        assert.are.equal('waiting', session.status)
        assert.are.equal('', api.get_prompt())
    end)

    it('preserves an unsent draft when reopening the chat buffer', function()
        api.open_chat()
        api.set_prompt('draft prompt')

        api.open_chat()

        assert.are.equal('draft prompt', api.get_prompt())
    end)

    it('keeps background session updates off the current buffer while another session is selected', function()
        local bufnr = api.open_chat()

        api.set_prompt('first turn')
        local first = api.current_session()
        api.submit_prompt()
        local first_client = fake_client

        local second = api.new_session()
        api.set_prompt('second draft')

        first_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'agent_message_chunk',
                content = {
                    type = 'text',
                    text = 'background update',
                },
            },
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal(second.id, api.current_session().id)
        assert.are.equal('second draft', api.get_prompt())
        assert.is_false(vim.tbl_contains(lines, 'background update'))

        api.select_session(first.id)

        local updated_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(vim.tbl_contains(updated_lines, 'background update'))
    end)

    it('does not confuse transcript markdown with the prompt region', function()
        api.open_chat()
        api.set_prompt('draft prompt')

        api.append_message('assistant', '## Prompt')

        assert.are.equal('draft prompt', api.get_prompt())
    end)

    it('renders streamed assistant updates and prompt completion', function()
        local bufnr = api.open_chat()

        api.set_prompt('stream please')
        local current_session = api.submit_prompt()

        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'agent_message_chunk',
                content = {
                    type = 'text',
                    text = 'Hello',
                },
            },
        })
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'agent_message_chunk',
                content = {
                    type = 'text',
                    text = ' world',
                },
            },
        })
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('idle', current_session.status)
        assert.are.equal('end_turn', current_session.stop_reason)
        assert.is_true(vim.tbl_contains(lines, '### Assistant'))
        assert.is_true(vim.tbl_contains(lines, 'Hello world'))
    end)

    it('renders current ACP session config options in the chat buffer', function()
        local bufnr = api.open_chat()

        api.set_prompt('show config options')
        api.submit_prompt()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(vim.tbl_contains(lines, '## Config Options'))
        assert.is_true(vim.tbl_contains(lines, '- `mode` Mode = `Ask`'))
        assert.is_true(vim.tbl_contains(lines, '- `model` Model = `GPT-5.4`'))
    end)

    it('stores and renders ACP slash commands from session/update notifications', function()
        local bufnr = api.open_chat()

        api.set_prompt('show slash commands')
        api.submit_prompt()
        emit_available_commands_update()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local slash_commands = api.slash_commands()

        assert.are.equal(2, #slash_commands)
        assert.are.equal('web', slash_commands[1].name)
        assert.is_true(vim.tbl_contains(lines, '## Slash Commands'))
        assert.is_true(vim.tbl_contains(lines, '- `/web` Search the web for information'))
        assert.is_true(vim.tbl_contains(lines, '  - Input: query to search for'))
        assert.is_true(vim.tbl_contains(lines, '- `/test` Run tests for the current project'))
    end)

    it('applies available_commands_update emitted during session/new setup', function()
        fake_on_new = function(client, session_id)
            client:emit_notification('session/update', {
                sessionId = session_id,
                update = {
                    sessionUpdate = 'available_commands_update',
                    availableCommands = vim.deepcopy(fake_available_commands),
                },
            })
        end

        api.open_chat()

        local commands = api.slash_commands()

        assert.are.equal(2, #commands)
        assert.are.equal('web', commands[1].name)
        assert.are.equal('sess_123', api.current_session().remote_id)
    end)

    it('sends session/set_config_option and rerenders the selected session', function()
        local bufnr = api.open_chat()

        api.set_prompt('draft prompt')
        local current_session = api.current_session()
        api.set_config_option('mode', 'code')

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
        assert.are.same({
            sessionId = 'sess_123',
            configId = 'mode',
            value = 'code',
        }, fake_client.sync_calls[4].params)
        assert.are.equal('code', current_session.config_options[1].currentValue)
        assert.are.equal('draft prompt', api.get_prompt())
        assert.is_true(vim.tbl_contains(lines, '- `mode` Mode = `Code`'))
    end)

    it('accepts config option updates while a prompt turn is running', function()
        api.open_chat()
        api.set_prompt('run and reconfigure')
        local current_session = api.submit_prompt()

        api.set_config_option('mode', 'code')

        assert.are.equal('waiting', current_session.status)
        assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
        assert.are.equal('code', current_session.config_options[1].currentValue)
    end)

    it('defers ACP rerenders out of fast event contexts', function()
        local bufnr = api.open_chat()

        api.set_prompt('fast event render')
        local current_session = api.submit_prompt()
        local scheduled, restore = with_fast_event_schedule()

        local ok, err = pcall(function()
            fake_client:emit_notification('session/update', {
                sessionId = 'sess_123',
                update = {
                    sessionUpdate = 'agent_message_chunk',
                    content = {
                        type = 'text',
                        text = 'Deferred render',
                    },
                },
            })
            fake_client:resolve({
                stopReason = 'end_turn',
            })
        end)

        assert.is_true(ok, err)
        assert.are.equal('idle', current_session.status)
        assert.are.equal(2, #scheduled)
        assert.is_false(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 'Deferred render'))

        restore()

        for _, callback in ipairs(scheduled) do
            callback()
        end

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(vim.tbl_contains(lines, 'Deferred render'))
    end)

    it('renders streamed plan updates in markdown', function()
        local bufnr = api.open_chat()

        api.set_prompt('make a plan')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'plan',
                entries = {
                    {
                        content = 'Inspect the repository',
                        status = 'pending',
                    },
                    {
                        content = 'Run focused tests',
                        status = 'in_progress',
                    },
                },
            },
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(vim.tbl_contains(lines, '## Plan'))
        assert.is_true(vim.tbl_contains(lines, '- `pending` Inspect the repository'))
        assert.is_true(vim.tbl_contains(lines, '- `in_progress` Run focused tests'))
    end)

    it('rerenders config options from agent session/update notifications', function()
        local bufnr = api.open_chat()

        api.set_prompt('config update')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'config_option_update',
                configOptions = {
                    {
                        id = 'mode',
                        name = 'Mode',
                        category = 'mode',
                        type = 'select',
                        currentValue = 'code',
                        options = {
                            {
                                value = 'ask',
                                name = 'Ask',
                            },
                            {
                                value = 'code',
                                name = 'Code',
                            },
                        },
                    },
                },
            },
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(vim.tbl_contains(lines, '- `mode` Mode = `Code`'))
        assert.is_false(vim.tbl_contains(lines, '- `model` Model = `GPT-5.4`'))
    end)

    it('accepts grouped config option values from agent updates', function()
        api.open_chat()
        api.set_prompt('grouped config update')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'config_option_update',
                configOptions = {
                    {
                        id = 'model',
                        name = 'Model',
                        category = 'model',
                        type = 'select',
                        currentValue = 'gpt-5.4',
                        options = {
                            {
                                group = 'frontier',
                                name = 'Frontier',
                                options = {
                                    {
                                        value = 'gpt-5.4',
                                        name = 'GPT-5.4',
                                    },
                                },
                            },
                            {
                                group = 'standard',
                                name = 'Standard',
                                options = {
                                    {
                                        value = 'gpt-5.4-mini',
                                        name = 'GPT-5.4 Mini',
                                    },
                                },
                            },
                        },
                    },
                },
            },
        })

        local ok, err = pcall(function()
            api.set_config_option('model', 'gpt-5.4-mini')
        end)

        assert.is_true(ok, err)
        assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
        assert.are.same({
            sessionId = 'sess_123',
            configId = 'model',
            value = 'gpt-5.4-mini',
        }, fake_client.sync_calls[4].params)
    end)

    it('submits ACP slash commands through the normal prompt path', function()
        api.open_chat()
        api.slash_commands()
        emit_available_commands_update()

        local current_session = api.run_slash_command('web', 'agent client protocol')

        assert.are.equal('session/prompt', fake_client.async_calls[1].method)
        assert.are.same({
            sessionId = 'sess_123',
            prompt = {
                {
                    type = 'text',
                    text = '/web agent client protocol',
                },
            },
        }, fake_client.async_calls[1].params)
        assert.are.equal('/web agent client protocol', current_session.pending_prompt)
    end)

    it('clears stale ACP slash commands when rebinding to a fresh remote session', function()
        local bufnr = api.open_chat()

        api.slash_commands()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = vim.deepcopy(fake_available_commands),
            },
        })

        api.set_prompt('first turn')
        local current_session = api.submit_prompt()

        fake_client:resolve({
            stopReason = 'end_turn',
        })

        api.set_prompt('second turn')
        current_session = api.submit_prompt()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('sess_124', current_session.remote_id)
        assert.are.same({}, current_session.available_commands)
        assert.is_false(vim.tbl_contains(lines, '## Slash Commands'))
    end)

    it('does not run a stale ACP slash command after a completed turn forces a fresh remote session', function()
        api.open_chat()

        api.slash_commands()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = vim.deepcopy(fake_available_commands),
            },
        })

        api.set_prompt('first turn')
        api.submit_prompt()
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        assert.has_error(function()
            api.run_slash_command('web', 'should fail')
        end, 'Unknown ACP slash command: web')
        assert.are.equal('sess_124', api.current_session().remote_id)
        assert.are.same({}, api.current_session().available_commands)
    end)

    it('refreshes ACP slash command names after a completed turn before command completion uses them', function()
        api.open_chat()

        api.slash_commands()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = vim.deepcopy(fake_available_commands),
            },
        })

        api.set_prompt('first turn')
        api.submit_prompt()
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        local names = api.slash_command_names()

        assert.are.same({}, names)
        assert.are.equal('sess_124', api.current_session().remote_id)
        assert.are.same({}, api.current_session().available_commands)
    end)

    it('invokes ACP slash commands through picker selection and input', function()
        api.open_chat()
        api.slash_commands()
        emit_available_commands_update()

        local restore_select = with_ui_select(function(items, opts, on_choice)
            assert.are.equal('Select ACP slash command', opts.prompt)
            assert.are.equal(
                '/web  Search the web for information  input=query to search for',
                opts.format_item(items[1])
            )
            on_choice(items[1])
        end)
        local restore_input = with_ui_input(function(opts, on_confirm)
            assert.are.equal('Input for ACP slash command /web', opts.prompt)
            on_confirm('acp slash commands')
        end)

        api.pick_slash_command()
        restore_input()
        restore_select()

        assert.are.equal('session/prompt', fake_client.async_calls[1].method)
        assert.are.equal('/web acp slash commands', fake_client.async_calls[1].params.prompt[1].text)
    end)

    it('applies available_commands_update emitted during session/load', function()
        fake_supports_load = true
        api.open_chat()

        api.slash_commands()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = vim.deepcopy(fake_available_commands),
            },
        })

        api.set_prompt('first turn')
        api.submit_prompt()
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        fake_on_load = function(client, params)
            client:emit_notification('session/update', {
                sessionId = params.sessionId,
                update = {
                    sessionUpdate = 'available_commands_update',
                    availableCommands = {
                        {
                            name = 'resume',
                            description = 'Resume-only command',
                        },
                    },
                },
            })
        end

        local commands = api.slash_commands()

        assert.are.equal(1, #commands)
        assert.are.equal('resume', commands[1].name)
    end)

    it('does not submit an ACP slash command from the picker when required input is blank', function()
        local notifications = {}
        local original_notify = vim.notify

        api.open_chat()
        api.slash_commands()
        emit_available_commands_update()

        local restore_select = with_ui_select(function(items, _, on_choice)
            on_choice(items[1])
        end)
        local restore_input = with_ui_input(function(_, on_confirm)
            on_confirm('   ')
        end)

        vim.notify = function(message)
            table.insert(notifications, message)
        end

        api.pick_slash_command()

        vim.notify = original_notify
        restore_input()
        restore_select()

        assert.are.equal(0, #fake_client.async_calls)
        assert.are.same({
            'ACP slash command requires input: /web',
        }, notifications)
    end)

    it('renders tool calls in a dedicated markdown section', function()
        local bufnr = api.open_chat()

        api.set_prompt('use a tool')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'tool_1',
                title = 'Read README',
                status = 'in_progress',
                kind = 'read',
                locations = {
                    {
                        path = '/tmp/README.md',
                        line = 12,
                    },
                },
                content = {
                    {
                        type = 'content',
                        content = {
                            type = 'text',
                            text = 'Reading README for context',
                        },
                    },
                },
            },
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(vim.tbl_contains(lines, '## Tools'))
        assert.is_true(vim.tbl_contains(lines, '- `in_progress` Read README'))
        assert.is_true(vim.tbl_contains(lines, '  - Kind: `read`'))
        assert.is_true(vim.tbl_contains(lines, '  - Locations: `/tmp/README.md:12`'))
        assert.is_true(vim.tbl_contains(lines, '  - Text: Reading README for context'))
    end)

    it('updates an existing tool row instead of appending transcript status noise', function()
        local bufnr = api.open_chat()

        api.set_prompt('update a tool')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'tool_2',
                title = 'Write config',
                status = 'in_progress',
                kind = 'edit',
            },
        })
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call_update',
                toolCallId = 'tool_2',
                status = 'completed',
                content = {
                    {
                        type = 'diff',
                        path = '/tmp/init.lua',
                        oldText = '',
                        newText = 'print("done")',
                    },
                },
            },
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(vim.tbl_contains(lines, '- `completed` Write config'))
        assert.is_false(vim.tbl_contains(lines, '- `in_progress` Write config'))
        assert.is_true(vim.tbl_contains(lines, '  - Diff: `/tmp/init.lua`'))
        assert.is_false(vim.tbl_contains(lines, '### Status'))
    end)

    it('uses an absolute cwd when creating the remote session', function()
        api.open_chat()
        api.set_prompt('cwd please')
        api.submit_prompt()

        assert.are.equal('session/new', fake_client.sync_calls[3].method)
        assert.are.equal('/', fake_client.sync_calls[3].params.cwd:sub(1, 1))
    end)

    it('preserves the prompt draft when ACP initialization fails', function()
        local closed = false

        transport._set_rpc_factory(function()
            local failing_client = {}

            function failing_client:start()
                return true
            end

            function failing_client:request_sync(method)
                if method == 'initialize' then
                    return {
                        protocolVersion = 2,
                        authMethods = {},
                    }
                end

                error('unexpected sync method')
            end

            function failing_client:request()
                error('session/prompt should not be reached')
            end

            function failing_client:notify() end

            function failing_client:close()
                closed = true
            end

            return failing_client
        end)

        api.open_chat()
        api.set_prompt('keep me')

        assert.has_error(function()
            api.submit_prompt()
        end)
        assert.is_true(closed)
        assert.are.equal('keep me', api.get_prompt())
        assert.are.equal(0, #api.current_session().messages)
    end)

    it('responds to permission requests with the configured default option', function()
        local bufnr = api.open_chat()
        api.set_prompt('need permission')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'call_1',
                title = 'Read config',
                status = 'pending',
                kind = 'read',
            },
        })

        local response = fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_1',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local approvals = api.approvals()

        assert.are.equal('selected', response.result.outcome.outcome)
        assert.are.equal('reject-once', response.result.outcome.optionId)
        assert.are.equal(1, #approvals)
        assert.are.equal(1, approvals[1].ordinal)
        assert.are.equal('default', approvals[1].source)
        assert.are.equal('Reject', approvals[1].selected_option_name)
        assert.are.equal(2, #approvals[1].options)
        assert.is_true(vim.tbl_contains(lines, '## Approvals'))
        assert.is_true(vim.tbl_contains(lines, '- [1] `selected` Read config'))
        assert.is_true(vim.tbl_contains(lines, '  - Source: `default`'))
        assert.is_true(vim.tbl_contains(lines, '  - Selected Option: Reject [reject_once] (`reject-once`)'))
        assert.is_true(
            vim.tbl_contains(
                lines,
                '  - Options: Allow once [allow_once] (`allow-once`), Reject [reject_once] (`reject-once`)'
            )
        )
    end)

    it('selects an approval outcome through vim.ui.select when configured', function()
        plugin.setup({
            permission_strategy = 'select',
        })
        local bufnr = api.open_chat()
        api.set_prompt('choose permission')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'call_select',
                title = 'Run command',
                status = 'pending',
                kind = 'execute',
            },
        })

        local restore = with_ui_select(function(items, opts, on_choice)
            assert.are.equal('ACP approval: Run command', opts.prompt)
            assert.are.equal('Allow once  [allow_once]', opts.format_item(items[1]))
            assert.are.equal('Reject  [reject_once]', opts.format_item(items[2]))
            on_choice(items[1])
        end)

        local response = fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_select',
                title = 'Run command',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        restore()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local approvals = api.approvals()

        assert.are.equal('selected', response.result.outcome.outcome)
        assert.are.equal('allow-once', response.result.outcome.optionId)
        assert.are.equal('select', approvals[1].source)
        assert.are.equal('Allow once', approvals[1].selected_option_name)
        assert.is_true(vim.tbl_contains(lines, '- [1] `selected` Run command'))
        assert.is_true(vim.tbl_contains(lines, '  - Source: `select`'))
        assert.is_true(vim.tbl_contains(lines, '  - Selected Option: Allow once [allow_once] (`allow-once`)'))
    end)

    it('cancels an approval request when the interactive picker is dismissed', function()
        plugin.setup({
            permission_strategy = 'select',
        })
        local bufnr = api.open_chat()
        api.set_prompt('dismiss permission')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'call_dismiss',
                title = 'Delete file',
                status = 'pending',
                kind = 'delete',
            },
        })

        local restore = with_ui_select(function(_, _, on_choice)
            on_choice(nil)
        end)

        local response = fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_dismiss',
                title = 'Delete file',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        restore()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('cancelled', response.result.outcome.outcome)
        assert.is_nil(response.result.outcome.optionId)
        assert.is_true(vim.tbl_contains(lines, '- [1] `cancelled` Delete file'))
        assert.is_true(vim.tbl_contains(lines, '  - Source: `select`'))
    end)

    it('reveals a recorded approval in the shared chat buffer', function()
        local bufnr = api.open_chat()
        api.set_prompt('revisit approval')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'call_revisit',
                title = 'Write file',
                status = 'pending',
                kind = 'edit',
            },
        })

        fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_revisit',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        vim.api.nvim_win_set_cursor(0, {
            vim.api.nvim_buf_line_count(bufnr),
            0,
        })

        api.reveal_approval(1)

        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]

        assert.are.equal('- [1] `selected` Write file', line)
    end)

    it('reveals an approval after switching to another local session', function()
        local bufnr = api.open_chat()
        api.set_prompt('first approval session')
        local first = api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'call_switch',
                title = 'Switch back',
                status = 'pending',
                kind = 'read',
            },
        })
        fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_switch',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        local second = api.new_session()

        assert.are.equal(second.id, api.current_session().id)

        api.reveal_approval(1, first.id)

        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]

        assert.are.equal(first.id, api.current_session().id)
        assert.are.equal('- [1] `selected` Switch back', line)
    end)

    it('reads file content from disk via fs/read_text_file', function()
        local path = temp_path('disk-read.txt')
        local handle = assert(io.open(path, 'wb'))
        assert(handle:write('alpha\nbeta\n'))
        handle:close()

        api.open_chat()
        api.set_prompt('read from disk')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/read_text_file', {
            sessionId = 'sess_123',
            path = path,
        })

        assert.is_nil(response.error)
        assert.are.equal('alpha\nbeta\n', response.result.content)
    end)

    it('reads unsaved open-buffer content via fs/read_text_file', function()
        local path = temp_path('open-buffer-read.txt')
        local handle = assert(io.open(path, 'wb'))
        assert(handle:write('on disk\n'))
        handle:close()

        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        local file_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'draft one', 'draft two' })

        api.open_chat()
        api.set_prompt('read from buffer')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/read_text_file', {
            sessionId = 'sess_123',
            path = path,
        })

        assert.is_nil(response.error)
        assert.is_true(vim.bo[file_buf].modified)
        assert.are.equal('draft one\ndraft two\n', response.result.content)
    end)

    it('reads a limited line window via fs/read_text_file', function()
        local path = temp_path('partial-read.txt')
        local handle = assert(io.open(path, 'wb'))
        assert(handle:write('one\ntwo\nthree\n'))
        handle:close()

        api.open_chat()
        api.set_prompt('read a subset')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/read_text_file', {
            sessionId = 'sess_123',
            path = path,
            line = 2,
            limit = 1,
        })

        assert.is_nil(response.error)
        assert.are.equal('two\n', response.result.content)
    end)

    it('writes file content via fs/write_text_file', function()
        local path = temp_path('write-file.txt')

        api.open_chat()
        api.set_prompt('write a file')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/write_text_file', {
            sessionId = 'sess_123',
            path = path,
            content = 'hello\nworld\n',
        })

        assert.is_nil(response.error)
        assert.are.same({}, response.result)
        assert.are.equal('hello\nworld\n', read_file(path))
    end)

    it('updates an open buffer via fs/write_text_file', function()
        local path = temp_path('write-open-buffer.txt')
        local handle = assert(io.open(path, 'wb'))
        assert(handle:write('before\n'))
        handle:close()

        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        local file_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'before', 'draft change' })

        api.open_chat()
        api.set_prompt('write through buffer')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/write_text_file', {
            sessionId = 'sess_123',
            path = path,
            content = 'after\nvalue\n',
        })

        assert.is_nil(response.error)
        assert.are.same({ 'after', 'value' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
        assert.is_false(vim.bo[file_buf].modified)
        assert.are.equal('after\nvalue\n', read_file(path))
    end)

    it('updates a loaded nomodifiable buffer via fs/write_text_file', function()
        local path = temp_path('write-nomodifiable-buffer.txt')
        local handle = assert(io.open(path, 'wb'))
        assert(handle:write('before\n'))
        handle:close()

        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        local file_buf = vim.api.nvim_get_current_buf()
        vim.bo[file_buf].modifiable = false

        api.open_chat()
        api.set_prompt('write through nomodifiable buffer')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/write_text_file', {
            sessionId = 'sess_123',
            path = path,
            content = 'after\nvalue\n',
        })

        assert.is_nil(response.error)
        assert.are.same({ 'after', 'value' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
        assert.is_false(vim.bo[file_buf].modified)
        assert.is_false(vim.bo[file_buf].modifiable)
        assert.are.equal('after\nvalue\n', read_file(path))
    end)

    it('creates a terminal and returns captured output', function()
        api.open_chat()
        api.set_prompt('run terminal command')
        api.submit_prompt()

        local created = fake_client:emit_request('terminal/create', {
            sessionId = 'sess_123',
            command = 'sh',
            args = { '-c', 'printf hello' },
            outputByteLimit = 1024,
        })

        assert.is_nil(created.error)
        assert.is_not_nil(created.result.terminalId)

        local output
        wait_until(function()
            output = fake_client:emit_request('terminal/output', {
                sessionId = 'sess_123',
                terminalId = created.result.terminalId,
            })

            return output.result ~= nil and output.result.output == 'hello' and output.result.exitStatus ~= nil
        end)

        assert.are.equal(false, output.result.truncated)
        assert.are.same({
            exitCode = 0,
            signal = nil,
        }, output.result.exitStatus)
    end)

    it('waits for terminal exit', function()
        api.open_chat()
        api.set_prompt('wait for terminal')
        api.submit_prompt()

        local created = fake_client:emit_request('terminal/create', {
            sessionId = 'sess_123',
            command = 'sh',
            args = { '-c', 'sleep 0.05; printf done' },
        })

        local waited = fake_client:emit_request('terminal/wait_for_exit', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        assert.is_nil(waited.error)
        assert.are.same({
            exitCode = 0,
            signal = nil,
        }, waited.result)
    end)

    it('kills a running terminal without invalidating it', function()
        api.open_chat()
        api.set_prompt('kill terminal')
        api.submit_prompt()

        local created = fake_client:emit_request('terminal/create', {
            sessionId = 'sess_123',
            command = 'sh',
            args = { '-c', 'printf start; sleep 10' },
        })

        wait_until(function()
            local output = fake_client:emit_request('terminal/output', {
                sessionId = 'sess_123',
                terminalId = created.result.terminalId,
            })

            return output.result ~= nil and string.find(output.result.output, 'start', 1, true) ~= nil
        end)

        local killed = fake_client:emit_request('terminal/kill', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })
        local waited = fake_client:emit_request('terminal/wait_for_exit', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })
        local output = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        assert.is_nil(killed.error)
        assert.are.same({}, killed.result)
        assert.is_nil(waited.error)
        assert.is_not_nil(waited.result.signal)
        assert.is_nil(waited.result.exitCode)
        assert.is_nil(output.error)
        assert.are.equal(waited.result.signal, output.result.exitStatus.signal)
    end)

    it('releases a terminal and invalidates its id', function()
        api.open_chat()
        api.set_prompt('release terminal')
        api.submit_prompt()

        local created = fake_client:emit_request('terminal/create', {
            sessionId = 'sess_123',
            command = 'sh',
            args = { '-c', 'printf hello' },
        })

        local released = fake_client:emit_request('terminal/release', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })
        local output = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        assert.is_nil(released.error)
        assert.are.same({}, released.result)
        assert.is_not_nil(output.error)
    end)

    it('routes terminal requests through terminal-manager when configured', function()
        local terminal_manager = setup_terminal_manager()

        plugin.setup({
            terminal_backend = 'terminal_manager',
        })
        api.open_chat()
        api.set_prompt('run terminal-manager backend')
        api.submit_prompt()

        local created = fake_client:emit_request('terminal/create', {
            sessionId = 'sess_123',
            command = 'sh',
            args = { '-c', 'printf "$ACP_TERMINAL_MANAGER_VALUE"' },
            env = {
                {
                    name = 'ACP_TERMINAL_MANAGER_VALUE',
                    value = 'tm',
                },
            },
        })
        local output

        wait_until(function()
            output = fake_client:emit_request('terminal/output', {
                sessionId = 'sess_123',
                terminalId = created.result.terminalId,
            })

            return output.result ~= nil and output.result.output == 'tm' and output.result.exitStatus ~= nil
        end)

        local terminal = terminal_manager.api.get(created.result.terminalId)

        assert.is_nil(created.error)
        assert.is_not_nil(terminal)
        assert.are.equal('acp', terminal.namespace)
        assert.are.equal('terminal_manager', api.terminal_backend_name())
        assert.are.same({
            exitCode = 0,
            signal = nil,
        }, output.result.exitStatus)

        local released = fake_client:emit_request('terminal/release', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        assert.is_nil(released.error)
        assert.is_not_nil(terminal_manager.api.get(created.result.terminalId))

        local output_after_release = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        assert.is_not_nil(output_after_release.error)
    end)

    it('applies outputByteLimit in the terminal-manager backend', function()
        setup_terminal_manager()

        plugin.setup({
            terminal_backend = 'terminal_manager',
        })
        api.open_chat()
        api.set_prompt('truncate terminal-manager backend')
        api.submit_prompt()

        local created = fake_client:emit_request('terminal/create', {
            sessionId = 'sess_123',
            command = 'sh',
            args = { '-c', 'printf abcdef' },
            outputByteLimit = 4,
        })
        local output

        wait_until(function()
            output = fake_client:emit_request('terminal/output', {
                sessionId = 'sess_123',
                terminalId = created.result.terminalId,
            })

            return output.result ~= nil and output.result.exitStatus ~= nil
        end)

        assert.is_nil(output.error)
        assert.are.equal(true, output.result.truncated)
        assert.are.equal('cdef', output.result.output)
    end)

    it('truncates retained terminal output when outputByteLimit is exceeded', function()
        api.open_chat()
        api.set_prompt('truncate output')
        api.submit_prompt()

        local created = fake_client:emit_request('terminal/create', {
            sessionId = 'sess_123',
            command = 'sh',
            args = { '-c', 'printf abcdef' },
            outputByteLimit = 4,
        })

        local output
        wait_until(function()
            output = fake_client:emit_request('terminal/output', {
                sessionId = 'sess_123',
                terminalId = created.result.terminalId,
            })

            return output.result ~= nil and output.result.exitStatus ~= nil
        end)

        assert.is_nil(output.error)
        assert.are.equal(true, output.result.truncated)
        assert.are.equal('cdef', output.result.output)
    end)

    it('keeps terminal truncation sticky across later UTF-8 output chunks', function()
        api.open_chat()
        api.set_prompt('truncate utf8 output')
        api.submit_prompt()

        local created = fake_client:emit_request('terminal/create', {
            sessionId = 'sess_123',
            command = 'sh',
            args = { '-c', "printf 'éé'; sleep 0.05; printf 'a'" },
            outputByteLimit = 3,
        })

        local output
        wait_until(function()
            output = fake_client:emit_request('terminal/output', {
                sessionId = 'sess_123',
                terminalId = created.result.terminalId,
            })

            return output.result ~= nil and output.result.exitStatus ~= nil
        end)

        assert.is_nil(output.error)
        assert.are.equal(true, output.result.truncated)
        assert.are.equal('éa', output.result.output)
    end)

    it('preserves the existing open-buffer state when fs/write_text_file fails', function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        local path = root .. '/write-open-buffer-failure.txt'

        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        local file_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'draft change' })

        chmod(root, '0555')

        api.open_chat()
        api.set_prompt('fail to write through buffer')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/write_text_file', {
            sessionId = 'sess_123',
            path = path,
            content = 'after\nvalue\n',
        })

        chmod(root, '0755')

        assert.is_not_nil(response.error)
        assert.are.same({ 'draft change' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
        assert.is_true(vim.bo[file_buf].modified)
        assert.is_false(vim.uv.fs_stat(path) ~= nil)
    end)

    it('cancels stale permission requests after a turn has already completed', function()
        api.open_chat()
        api.set_prompt('finish then stale permission')
        api.submit_prompt()
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        local response = fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_done',
            },
            options = {
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        assert.are.equal('cancelled', response.result.outcome.outcome)
        assert.is_nil(response.result.outcome.optionId)
    end)

    it('fails closed when the configured permission default is unavailable', function()
        plugin.setup({
            permission_default = 'reject_once',
        })
        api.open_chat()
        api.set_prompt('need permission')
        api.submit_prompt()

        local response = fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_2',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
            },
        })

        assert.are.equal('cancelled', response.result.outcome.outcome)
        assert.is_nil(response.result.outcome.optionId)
    end)

    it('sends session/cancel for an active remote prompt', function()
        api.open_chat()
        api.set_prompt('cancel me')
        local current_session = api.submit_prompt()

        api.cancel_prompt()

        assert.are.equal('cancelled', current_session.status)
        assert.are.equal('session/cancel', fake_client.notifications[1].method)
        assert.are.equal('sess_123', fake_client.notifications[1].params.sessionId)
    end)

    it('cancels stale permission requests after a prompt is cancelled', function()
        api.open_chat()
        api.set_prompt('cancel permissions')
        api.submit_prompt()
        api.cancel_prompt()

        local response = fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_3',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        assert.are.equal('cancelled', response.result.outcome.outcome)
        assert.is_nil(response.result.outcome.optionId)
    end)

    it('accepts config_option_update notifications after local cancellation', function()
        local bufnr = api.open_chat()

        api.set_prompt('cancel then update config')
        local current_session = api.submit_prompt()
        api.cancel_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'config_option_update',
                configOptions = {
                    {
                        id = 'mode',
                        name = 'Mode',
                        category = 'mode',
                        type = 'select',
                        currentValue = 'code',
                        options = {
                            {
                                value = 'ask',
                                name = 'Ask',
                            },
                            {
                                value = 'code',
                                name = 'Code',
                            },
                        },
                    },
                },
            },
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('cancelled', current_session.status)
        assert.are.equal('code', current_session.config_options[1].currentValue)
        assert.is_true(vim.tbl_contains(lines, '- `mode` Mode = `Code`'))
    end)

    it('does not open the interactive approval picker after the prompt is cancelled', function()
        plugin.setup({
            permission_strategy = 'select',
        })
        api.open_chat()
        api.set_prompt('cancel interactive permissions')
        api.submit_prompt()
        api.cancel_prompt()

        local picker_called = false
        local restore = with_ui_select(function()
            picker_called = true
        end)

        local response = fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_4',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        restore()

        assert.is_false(picker_called)
        assert.are.equal('cancelled', response.result.outcome.outcome)
        assert.is_nil(response.result.outcome.optionId)
    end)

    it('drops a stale interactive approval callback after the transport is closed', function()
        plugin.setup({
            permission_strategy = 'select',
        })
        local bufnr = api.open_chat()
        api.set_prompt('close stale picker')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'call_stale_picker',
                title = 'Edit file',
                status = 'pending',
                kind = 'edit',
            },
        })

        local pending_choice = nil
        local restore = with_ui_select(function(_, _, on_choice)
            pending_choice = on_choice
        end)

        local response = fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_stale_picker',
                title = 'Edit file',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        assert.is_nil(response)
        assert.is_not_nil(pending_choice)

        api.cancel_prompt()
        fake_client:resolve({
            stopReason = 'cancelled',
        })

        local ok, err = pcall(pending_choice, nil)
        restore()

        assert.is_true(ok, err)
        assert.is_false(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '## Approvals'))
    end)

    it('cancels the global live turn even after switching to another local session', function()
        api.open_chat()
        api.set_prompt('cancel from background')
        local first = api.submit_prompt()

        local second = api.new_session()
        api.set_prompt('keep this draft')

        local cancelled = api.cancel_prompt()

        assert.are.equal(first.id, cancelled.id)
        assert.are.equal('cancelled', first.status)
        assert.are.equal(second.id, api.current_session().id)
        assert.are.equal('keep this draft', api.get_prompt())

        api.select_session(first.id)
        assert.are.equal('cancel from background', api.get_prompt())
    end)

    it('allows creating a new session while another session prompt is still running', function()
        api.open_chat()
        api.set_prompt('hold this turn')
        api.submit_prompt()

        local current_session = api.new_session()

        assert.are.equal('acp:2', current_session.id)
        assert.are.equal('idle', current_session.status)
    end)

    it('blocks config changes on another local session while a turn is still running', function()
        api.open_chat()
        api.set_prompt('hold this turn')
        local first = api.submit_prompt()
        local second = api.new_session()

        assert.has_error(function()
            api.set_config_option('mode', 'code', second.id)
        end)
        assert.are.equal('waiting', first.status)
        assert.are.equal('sess_123', first.remote_id)
        assert.are.equal(3, #fake_client.sync_calls)
    end)

    it('rejects submitting a second prompt while a turn is still running', function()
        api.open_chat()
        api.set_prompt('first prompt')
        api.submit_prompt()
        api.set_prompt('second prompt')

        assert.has_error(function()
            api.submit_prompt()
        end)
        assert.are.equal(1, #fake_client.async_calls)
    end)

    it('uses a fresh remote session for the next prompt turn on the same local session', function()
        local bufnr = api.open_chat()

        api.set_prompt('first turn')
        local current_session = api.submit_prompt()
        local first_client = fake_client
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        api.set_prompt('second turn')
        api.submit_prompt()
        local second_client = fake_client

        first_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'agent_message_chunk',
                content = {
                    type = 'text',
                    text = 'stale old turn',
                },
            },
        })

        local response = first_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'old_turn',
            },
            options = {
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(first_client.closed)
        assert.are.equal(3, #second_client.sync_calls)
        assert.are.equal('sess_124', current_session.remote_id)
        assert.are.equal('sess_124', second_client.async_calls[1].params.sessionId)
        assert.are.equal(2, #second_client.async_calls[1].params.prompt)
        assert.is_not_nil(
            string.find(
                second_client.async_calls[1].params.prompt[1].text,
                'Previous conversation transcript for context:',
                1,
                true
            )
        )
        assert.is_not_nil(
            string.find(second_client.async_calls[1].params.prompt[1].text, '### User\nfirst turn', 1, true)
        )
        assert.are.equal('second turn', second_client.async_calls[1].params.prompt[2].text)
        assert.are.equal('cancelled', response.result.outcome.outcome)
        assert.is_false(vim.tbl_contains(lines, 'stale old turn'))
    end)

    it('loads an existing remote session for a follow-up turn when the agent supports session/load', function()
        local bufnr = api.open_chat()

        fake_supports_load = true
        fake_on_load = function(client, params)
            client:emit_notification('session/update', {
                sessionId = params.sessionId,
                update = {
                    sessionUpdate = 'agent_message_chunk',
                    content = {
                        type = 'text',
                        text = 'duplicate history from load',
                    },
                },
            })
        end

        api.set_prompt('first turn')
        local current_session = api.submit_prompt()
        local first_client = fake_client

        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'agent_message_chunk',
                content = {
                    type = 'text',
                    text = 'First answer',
                },
            },
        })
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        api.set_prompt('second turn')
        api.submit_prompt()
        local second_client = fake_client
        first_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'agent_message_chunk',
                content = {
                    type = 'text',
                    text = 'stale resumed turn',
                },
            },
        })
        local response = first_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'stale_resume',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.is_true(first_client.closed)
        assert.are.equal(3, #second_client.sync_calls)
        assert.are.equal('session/load', second_client.sync_calls[3].method)
        assert.are.equal('sess_123', second_client.sync_calls[3].params.sessionId)
        assert.are.equal('sess_123', current_session.remote_id)
        assert.are.equal('sess_123', second_client.async_calls[1].params.sessionId)
        assert.are.equal(1, #second_client.async_calls[1].params.prompt)
        assert.are.equal('second turn', second_client.async_calls[1].params.prompt[1].text)
        assert.are.equal('cancelled', response.result.outcome.outcome)
        assert.is_false(vim.tbl_contains(lines, 'duplicate history from load'))
        assert.is_false(vim.tbl_contains(lines, 'stale resumed turn'))
        assert.is_true(vim.tbl_contains(lines, 'first turn'))
        assert.is_true(vim.tbl_contains(lines, 'First answer'))
    end)

    it('keeps tool rows coherent after cancellation while still ignoring late chat updates', function()
        local bufnr = api.open_chat()

        api.set_prompt('cancel race')
        local current_session = api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'tool_cancel',
                title = 'Run command',
                status = 'in_progress',
                kind = 'execute',
            },
        })
        api.cancel_prompt()

        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'agent_message_chunk',
                content = {
                    type = 'text',
                    text = 'too late',
                },
            },
        })
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call_update',
                toolCallId = 'tool_cancel',
                status = 'completed',
            },
        })
        fake_client:resolve({
            stopReason = 'end_turn',
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.are.equal('cancelled', current_session.status)
        assert.are.equal(nil, current_session.stop_reason)
        assert.is_false(vim.tbl_contains(lines, 'too late'))
        assert.is_true(vim.tbl_contains(lines, '- `completed` Run command'))
        assert.is_false(vim.tbl_contains(lines, '- `in_progress` Run command'))
    end)

    it('registers ACP user commands', function()
        local commands = {
            'ACPChat',
            'ACPNewSession',
            'ACPLoadSession',
            'ACPRebindSession',
            'ACPSessions',
            'ACPSaveSessions',
            'ACPRestoreSessions',
            'ACPClearSessionStorage',
            'ACPApprovals',
            'ACPConfigOptions',
            'ACPSlashCommands',
            'ACPRevealApproval',
            'ACPPickApproval',
            'ACPSelectSession',
            'ACPPickSession',
            'ACPSetConfigOption',
            'ACPPickConfigOption',
            'ACPRunSlashCommand',
            'ACPPickSlashCommand',
            'ACPCloseSession',
            'ACPPickCloseSession',
            'ACPSubmit',
            'ACPCancel',
        }

        for _, command in ipairs(commands) do
            local definition = vim.api.nvim_get_commands({
                builtin = false,
            })[command]

            assert.is_not_nil(definition)
        end
    end)

    it('lists local ACP sessions through the command surface', function()
        local notifications = {}
        local original_notify = vim.notify

        api.new_session()
        api.new_session()

        vim.notify = function(message)
            table.insert(notifications, message)
        end

        local ok, err = pcall(vim.cmd, 'ACPSessions')

        vim.notify = original_notify

        assert.is_true(ok, err)
        assert.are.same({
            '  acp:1  [idle]  remote=unbound  sync=unbound  messages=0\n* acp:2  [idle]  remote=unbound  sync=unbound  messages=0',
        }, notifications)
    end)

    it('saves, restores, and clears ACP session storage through the command surface', function()
        local state_file = temp_path('acp-command-sessions.json')

        plugin.setup({
            session_state_file = state_file,
        })
        api.open_chat()
        api.set_prompt('command persistence')
        local current_id = api.current_session().id

        vim.cmd('ACPSaveSessions')

        api.clear()
        plugin.setup({
            session_state_file = state_file,
        })

        vim.cmd('ACPRestoreSessions')

        assert.are.equal(current_id, api.current_session().id)
        assert.are.equal('command persistence', api.current_session().draft_prompt)

        vim.cmd('ACPClearSessionStorage')

        assert.are.equal(0, vim.fn.filereadable(state_file))
    end)

    it('lists ACP approvals through the command surface', function()
        local notifications = {}
        local original_notify = vim.notify

        api.open_chat()
        api.set_prompt('approval command list')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'approval_list',
                title = 'Read file',
                status = 'pending',
                kind = 'read',
            },
        })
        fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'approval_list',
                title = 'Read file',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        vim.notify = function(message)
            table.insert(notifications, message)
        end

        local ok, err = pcall(vim.cmd, 'ACPApprovals')

        vim.notify = original_notify

        assert.is_true(ok, err)
        assert.are.same({
            '[1] Read file  outcome=selected  via=default  selected=Reject [reject_once]',
        }, notifications)
    end)

    it('lists ACP config options through the command surface', function()
        local notifications = {}
        local original_notify = vim.notify

        api.open_chat()

        vim.notify = function(message)
            table.insert(notifications, message)
        end

        local ok, err = pcall(vim.cmd, 'ACPConfigOptions')

        vim.notify = original_notify

        assert.is_true(ok, err)
        assert.are.same({
            'Mode  (`mode`)  current=ask\nModel  (`model`)  current=gpt-5.4',
        }, notifications)
    end)

    it('lists ACP slash commands through the command surface', function()
        local notifications = {}
        local original_notify = vim.notify

        api.open_chat()
        api.slash_commands()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'available_commands_update',
                availableCommands = vim.deepcopy(fake_available_commands),
            },
        })

        vim.notify = function(message)
            table.insert(notifications, message)
        end

        local ok, err = pcall(vim.cmd, 'ACPSlashCommands')

        vim.notify = original_notify

        assert.is_true(ok, err)
        assert.are.same({
            '/web  Search the web for information  input=query to search for\n/test  Run tests for the current project',
        }, notifications)
    end)

    it('reveals an ACP approval through the command surface', function()
        local bufnr = api.open_chat()
        api.set_prompt('approval command reveal')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'approval_reveal',
                title = 'Write file',
                status = 'pending',
                kind = 'edit',
            },
        })
        fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'approval_reveal',
                title = 'Write file',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        vim.api.nvim_win_set_cursor(0, {
            vim.api.nvim_buf_line_count(bufnr),
            0,
        })

        vim.cmd('ACPRevealApproval 1')

        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]

        assert.are.equal('- [1] `selected` Write file', line)
    end)

    it('selects a local ACP session through the command surface', function()
        api.open_chat()
        local first = api.current_session()
        local second = api.new_session()

        vim.cmd(string.format('ACPSelectSession %s', first.id))

        assert.are.equal(first.id, api.current_session().id)

        vim.cmd(string.format('ACPSelectSession %s', second.id))

        assert.are.equal(second.id, api.current_session().id)
    end)

    it('reveals an ACP approval through the picker command surface', function()
        local bufnr = api.open_chat()
        api.set_prompt('approval picker reveal')
        api.submit_prompt()
        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'approval_pick',
                title = 'Delete file',
                status = 'pending',
                kind = 'delete',
            },
        })
        fake_client:emit_request('session/request_permission', {
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'approval_pick',
                title = 'Delete file',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
                {
                    optionId = 'reject-once',
                    name = 'Reject',
                    kind = 'reject_once',
                },
            },
        })

        local restore = with_ui_select(function(items, opts, on_choice)
            assert.are.equal('Select ACP approval', opts.prompt)
            assert.are.equal(
                '[1] Delete file  outcome=selected  via=default  selected=Reject [reject_once]',
                opts.format_item(items[1])
            )
            on_choice(items[1])
        end)

        vim.cmd('ACPPickApproval')
        restore()

        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]

        assert.are.equal('- [1] `selected` Delete file', line)
    end)

    it('loads an ACP session through the command surface', function()
        api.open_chat()

        vim.cmd('ACPLoadSession')

        assert.are.equal('sess_123', api.current_session().remote_id)
        assert.are.equal('created', api.current_session().remote_sync_state)
    end)

    it('rebinds a load_failed ACP session through the command surface', function()
        api.open_chat()
        fake_supports_load = true
        api.set_prompt('first turn')
        local current_session = api.submit_prompt()

        fake_client:resolve({
            stopReason = 'end_turn',
        })

        local first_remote_id = current_session.remote_id

        fake_load_error = 'session/load failed'

        assert.has_error(function()
            api.load_session()
        end, 'session/load failed')

        vim.cmd('ACPRebindSession')

        assert.are.equal('sess_124', current_session.remote_id)
        assert.are_not.equal(first_remote_id, current_session.remote_id)
        assert.are.equal('created', current_session.remote_sync_state)
        assert.is_nil(current_session.remote_sync_error)
    end)

    it('selects a local ACP session through the picker command surface', function()
        api.open_chat()
        local first = api.current_session()
        api.new_session()

        local restore = with_ui_select(function(_, opts, on_choice)
            assert.are.equal('Select ACP session', opts.prompt)
            on_choice(first)
        end)

        vim.cmd('ACPPickSession')
        restore()

        assert.are.equal(first.id, api.current_session().id)
    end)

    it('sets an ACP config option through the command surface', function()
        api.open_chat()

        vim.cmd('ACPSetConfigOption mode code')

        assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
        assert.are.equal('code', api.current_session().config_options[1].currentValue)
    end)

    it('sets an ACP config option through the picker command surface', function()
        api.open_chat()

        local restore = with_ui_select(function(items, opts, on_choice)
            if opts.prompt == 'Select ACP config option' then
                on_choice(items[1])
                return
            end

            assert.are.equal('Select value for ACP config option: Mode', opts.prompt)
            on_choice(items[2])
        end)

        vim.cmd('ACPPickConfigOption')
        restore()

        assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
        assert.are.equal('code', api.current_session().config_options[1].currentValue)
    end)

    it('runs an ACP slash command through the command surface', function()
        api.open_chat()
        api.slash_commands()
        emit_available_commands_update()

        vim.cmd('ACPRunSlashCommand web agent client protocol')

        assert.are.equal('session/prompt', fake_client.async_calls[1].method)
        assert.are.equal('/web agent client protocol', fake_client.async_calls[1].params.prompt[1].text)
    end)

    it('runs an ACP slash command through the picker command surface', function()
        api.open_chat()
        api.slash_commands()
        emit_available_commands_update()

        local restore_select = with_ui_select(function(items, opts, on_choice)
            assert.are.equal('Select ACP slash command', opts.prompt)
            on_choice(items[2])
        end)

        vim.cmd('ACPPickSlashCommand')
        restore_select()

        assert.are.equal('session/prompt', fake_client.async_calls[1].method)
        assert.are.equal('/test', fake_client.async_calls[1].params.prompt[1].text)
    end)

    it('closes a local ACP session through the command surface', function()
        api.new_session()
        local second = api.new_session()

        vim.cmd('ACPCloseSession acp:1')

        assert.are.same({ second.id }, session_ids(api.list_sessions()))
        assert.are.equal(second.id, api.current_session().id)
    end)

    it('closes a local ACP session through the picker command surface', function()
        local first = api.new_session()
        local second = api.new_session()
        local restore = with_ui_select(function(_, opts, on_choice)
            assert.are.equal('Close ACP session', opts.prompt)
            on_choice(first)
        end)

        vim.cmd('ACPPickCloseSession')
        restore()

        assert.are.same({ second.id }, session_ids(api.list_sessions()))
        assert.are.equal(second.id, api.current_session().id)
    end)

    it('reports the active terminal backend name', function()
        assert.are.equal('native', api.terminal_backend_name())
    end)
end)
