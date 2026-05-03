local persistence = require('legate.core.persistence')

it('loads and exposes setup', function()
    assert.are.equal('function', type(plugin.setup))
    assert.are.equal('function', type(api.open_chat))
    assert.are.equal('function', type(api.list_sessions))
    assert.are.equal('function', type(api.select_session))
    assert.are.equal('function', type(api.continue_last_session))
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
    assert.are.equal('codex', config.default_adapter)
    assert.are.same({ 'codex-acp' }, config.adapters.codex.command)
    assert.are.equal('default', config.permission_strategy)
    assert.are.equal('reject_once', config.permission_default)
end)

it('accepts terminal_manager as a legacy ACP terminal backend alias', function()
    local config = plugin.setup({
        terminal_backend = 'terminal_manager',
    })

    assert.are.equal('terminalia', config.terminal_backend)
end)

it('accepts select as an ACP permission strategy', function()
    local config = plugin.setup({
        permission_strategy = 'select',
    })

    assert.are.equal('select', config.permission_strategy)
end)

it('normalizes explicitly configured ACP adapters', function()
    local config = plugin.setup({
        default_adapter = 'custom',
        adapters = {
            codex = {
                command = { 'codex-acp' },
                title = 'Codex ACP',
            },
            custom = {
                command = { 'custom-acp' },
                auth_method = 'chatgpt',
                request_timeout_ms = 1234,
                config_option_overrides = {
                    mode = 'code',
                },
                title = 'Custom ACP',
            },
        },
    })

    local adapter_names = vim.tbl_keys(config.adapters)
    table.sort(adapter_names)

    assert.are.equal('custom', config.default_adapter)
    assert.are.same({ 'codex', 'custom' }, adapter_names)
    assert.are.same({ 'custom-acp' }, config.adapters.custom.command)
    assert.are.equal('chatgpt', config.adapters.custom.auth_method)
    assert.are.equal(1234, config.adapters.custom.request_timeout_ms)
    assert.are.same({ mode = 'code' }, config.adapters.custom.config_option_overrides)
end)

it('assigns the configured default adapter to new ACP sessions', function()
    plugin.setup({
        default_adapter = 'custom',
        adapters = {
            codex = {
                command = { 'codex-acp' },
            },
            custom = {
                command = { 'custom-acp' },
                title = 'Custom ACP',
            },
        },
    })

    local current_session = api.new_session()

    assert.are.equal('custom', current_session.adapter_name)
end)

it('falls back to the current default adapter when a restored session references a missing adapter', function()
    plugin.setup({
        default_adapter = 'custom',
        adapters = {
            codex = {
                command = { 'codex-acp' },
            },
            custom = {
                command = { 'custom-acp' },
            },
        },
    })

    local restored = require('legate.session').restore({
        sessions = {
            {
                id = 'acp:9',
                ordinal = 1,
                adapter_name = 'missing',
                status = 'idle',
                messages = {},
            },
        },
        current_id = 'acp:9',
        next_ordinal = 10,
    })

    assert.are.equal('custom', restored[1].adapter_name)
    assert.are.equal('custom', api.current_session().adapter_name)
end)

it('starts the ACP transport with the selected adapter and applies configured option overrides', function()
    plugin.setup({
        default_adapter = 'custom',
        adapters = {
            codex = {
                command = { 'codex-acp' },
            },
            custom = {
                command = { 'custom-acp' },
                auth_method = 'chatgpt',
                request_timeout_ms = 1234,
                config_option_overrides = {
                    mode = 'code',
                    model = 'gpt-5.4-mini',
                },
            },
        },
    })

    api.open_chat()
    api.set_prompt('adapter override prompt')
    local current_session = api.submit_prompt()

    assert.are.equal('custom', current_session.adapter_name)
    assert.are.same({ 'custom-acp' }, fake_client.opts.command)
    assert.are.equal(1234, fake_client.opts.timeout_ms)
    assert.are.equal('initialize', fake_client.sync_calls[1].method)
    assert.are.equal('authenticate', fake_client.sync_calls[2].method)
    assert.are.same({ methodId = 'chatgpt' }, fake_client.sync_calls[2].params)
    assert.are.equal('session/new', fake_client.sync_calls[3].method)
    assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
    assert.are.same({
        sessionId = current_session.remote_id,
        configId = 'mode',
        value = 'code',
    }, fake_client.sync_calls[4].params)
    assert.are.equal('session/set_config_option', fake_client.sync_calls[5].method)
    assert.are.same({
        sessionId = current_session.remote_id,
        configId = 'model',
        value = 'gpt-5.4-mini',
    }, fake_client.sync_calls[5].params)
end)

it('drops remote binding state when switching an ACP session to a different adapter', function()
    plugin.setup({
        default_adapter = 'codex',
        adapters = {
            codex = {
                command = { 'codex-acp' },
            },
            custom = {
                command = { 'custom-acp' },
                title = 'Custom ACP',
            },
        },
    })

    api.open_chat()
    api.set_prompt('switch adapter')
    local current_session = api.submit_prompt()
    fake_client:resolve({
        stopReason = 'end_turn',
    })

    assert.are.equal('sess_123', current_session.remote_id)

    api.select_adapter('custom')

    assert.are.equal('custom', current_session.adapter_name)
    assert.is_nil(current_session.remote_id)
    assert.are.equal('unbound', current_session.remote_sync_state)
    assert.are.same({}, current_session.available_commands)
    assert.are.same({}, current_session.config_options)
end)

it('creates and reuses a single chat buffer', function()
    local first = api.open_chat()
    local second = api.open_chat()
    local buffer = require('legate.ui.buffer')

    assert.are.equal(first, second)
    assert.are.equal('acp://session/local/acp:1', vim.api.nvim_buf_get_name(first))
    assert.are.same({
        local_id = 'acp:1',
    }, buffer.session_locator(first))
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
        string.format('  %s  adapter=codex  [idle]  remote=unbound  sync=unbound  messages=%d', first.id, 1),
        string.format('* %s  adapter=codex  [idle]  remote=unbound  sync=unbound  messages=%d', second.id, 0),
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
    assert.are.equal(
        string.format('ACP  %s  adapter=codex  idle  sync=unbound', second.id),
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_true(vim.tbl_contains(lines, '## Prompt'))
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
    plugin.setup({
        default_adapter = 'custom',
        adapters = {
            codex = {
                command = { 'codex-acp' },
            },
            custom = {
                command = { 'custom-acp' },
            },
        },
    })
    local bufnr = api.open_chat()
    local first = api.current_session()

    api.set_prompt('discard me')

    local closed, next_session = api.close_session(first.id)

    assert.are.equal(first.id, closed.id)
    assert.is_not_nil(next_session)
    assert.are.equal('acp:2', next_session.id)
    assert.are.equal('custom', next_session.adapter_name)
    assert.are.equal('acp:2', api.current_session().id)
    assert.are.equal('', api.get_prompt())
    assert.are.equal(
        'ACP  acp:2  adapter=custom  idle  sync=unbound',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '## Prompt'))
end)

it('invokes vim.ui.select for ACP session picking', function()
    api.new_session()
    api.new_session()

    local restore = with_ui_select(function(items, opts, on_choice)
        assert.are.same({ 'acp:1', 'acp:2' }, session_ids(items))
        assert.are.equal('Select ACP session', opts.prompt)
        assert.are.equal(
            '* acp:2  adapter=codex  [idle]  remote=unbound  sync=unbound  messages=0',
            opts.format_item(items[2])
        )
        on_choice(nil)
    end)

    api.pick_session()
    restore()
end)

it('preserves the next approval ordinal across restore when pending approvals were not persisted', function()
    local session = require('legate.session')

    session.restore({
        sessions = {
            {
                id = 'acp:9',
                ordinal = 1,
                status = 'idle',
                messages = {},
                approval_entries = {
                    {
                        ordinal = 1,
                        title = 'Existing approval',
                        outcome = 'cancelled',
                        source = 'default',
                        stream_key = 'approval:1',
                    },
                },
                pending_approvals = {},
            },
        },
        current_id = 'acp:9',
        next_ordinal = 10,
        next_pending_approval_ordinal = 4,
    })

    assert.are.equal(4, session.snapshot().next_pending_approval_ordinal)
end)

it('restores pending approvals in persisted ordinal order', function()
    local restored = require('legate.session').restore({
        sessions = {
            {
                id = 'acp:9',
                ordinal = 1,
                status = 'idle',
                messages = {},
                approval_entries = {
                    {
                        ordinal = 1,
                        title = 'Existing approval',
                        outcome = 'cancelled',
                        source = 'default',
                        stream_key = 'approval:1',
                    },
                },
                pending_approvals = {
                    {
                        request_id = 'req-later',
                        ordinal = 3,
                        title = 'Later approval',
                        created_at = 30,
                    },
                    {
                        request_id = 'req-first',
                        ordinal = 2,
                        title = 'First approval',
                        created_at = 20,
                    },
                },
            },
        },
        current_id = 'acp:9',
        next_ordinal = 10,
    })

    assert.are.equal('acp:9', api.current_session().id)
    assert.are.equal('acp:9', restored[1].id)
    assert.are.same(
        { 'req-first', 'req-later' },
        vim.tbl_map(function(item)
            return item.request_id
        end, api.pending_approvals())
    )
    assert.are.same(
        { 2, 3 },
        vim.tbl_map(function(item)
            return item.ordinal
        end, api.pending_approvals())
    )
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
    assert.are.equal(
        'ACP  acp:1  adapter=codex  idle  sync=created  remote=sess_123',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_false(vim.tbl_contains(lines, '> Remote Sync Error: `created`'))
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

    assert.is_false(first_client.closed)
    assert.are.equal('sess_123', current_session.remote_id)
    assert.are.equal('loaded', current_session.remote_sync_state)
    assert.is_nil(current_session.remote_sync_error)
    assert.are.equal(2, #current_session.available_commands)
    assert.are.equal('session/load', second_client.sync_calls[4].method)
    assert.are.equal('sess_123', second_client.sync_calls[4].params.sessionId)
    assert.are.equal(
        'ACP  acp:1  adapter=codex  idle  sync=loaded  remote=sess_123',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_false(vim.tbl_contains(lines, '## Slash Commands'))
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
    assert.are.equal(
        'ACP  acp:1  adapter=codex  idle  sync=load_failed  remote=sess_123',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_true(
        vim.tbl_contains(
            lines,
            '> Recovery: retry the recorded remote session with `:LegateLoadSession`, or create a fresh one with `:LegateRebindSession`'
        )
    )
end)

it('blocks prompt submission after an explicit load failure until the user explicitly recovers the session', function()
    api.open_chat()
    local current_session = api.load_session()

    assert.are.equal('sess_123', current_session.remote_id)
    assert.are.equal('created', current_session.remote_sync_state)

    assert.has_error(function()
        api.load_session()
    end, 'ACP agent does not advertise session/load support for session acp:1')

    api.set_prompt('after failed reload')

    assert.has_error(
        function()
            api.submit_prompt()
        end,
        'ACP session is in load_failed recovery state; retry `:LegateLoadSession` or create a fresh remote with `:LegateRebindSession`'
    )

    assert.are.equal('sess_123', current_session.remote_id)
    assert.is_nil(current_session.transport_remote_id)
    assert.are.equal('load_failed', current_session.remote_sync_state)
    assert.are.equal(0, #fake_client.async_calls)
    assert.are.equal('session/new', fake_client.sync_calls[3].method)

    api.rebind_session()
    api.submit_prompt()

    assert.are.equal('sess_124', current_session.remote_id)
    assert.are.equal('created', current_session.remote_sync_state)
    assert.is_nil(current_session.remote_sync_error)
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

    current_session.available_commands = vim.deepcopy(fake_available_commands)

    local first_remote_id = current_session.remote_id

    fake_load_error = 'session/load failed'

    assert.has_error(function()
        api.load_session()
    end, 'session/load failed')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal(first_remote_id, current_session.remote_id)
    assert.is_nil(current_session.transport_remote_id)
    assert.are.equal('load_failed', current_session.remote_sync_state)
    assert.are.equal(4, #fake_client.sync_calls)
    assert.are.equal('session/load', fake_client.sync_calls[4].method)
    assert.are.equal('session/load failed', current_session.remote_sync_error)
    assert.are.same(fake_available_commands, current_session.available_commands)
    assert.are.equal(
        'ACP  acp:1  adapter=codex  idle  sync=load_failed  remote=sess_123',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_true(vim.tbl_contains(lines, '> Remote Sync Error: `session/load failed`'))
    assert.is_true(
        vim.tbl_contains(
            lines,
            '> Recovery: retry the recorded remote session with `:LegateLoadSession`, or create a fresh one with `:LegateRebindSession`'
        )
    )
    assert.is_true(
        vim.tbl_contains(
            api.session_lines(),
            '* acp:1  adapter=codex  [idle]  remote=sess_123  sync=load_failed  messages=1'
        )
    )
end)

it('renders multiline and long remote sync errors safely on one line', function()
    local bufnr = api.open_chat()
    fake_supports_load = true
    api.set_prompt('first turn')
    api.submit_prompt()

    fake_client:resolve({
        stopReason = 'end_turn',
    })

    fake_load_error = 'first\nline\tsecond\n' .. string.rep('x', 220)

    assert.has_error(function()
        api.load_session()
    end)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local remote_sync_error_line
    for _, line in ipairs(lines) do
        if line:match('> Remote Sync Error:') then
            remote_sync_error_line = line
            break
        end
    end

    assert.is_not_nil(remote_sync_error_line)
    local remote_sync_error = remote_sync_error_line:match('^> Remote Sync Error: `(.-)`$')

    assert.is_not_nil(remote_sync_error)
    assert.is_nil(remote_sync_error:find('\n'))
    assert.is_nil(remote_sync_error:find('\t'))
    assert.is_true(remote_sync_error:find('first line second ') == 1)
    assert.is_true(#remote_sync_error <= 200)
    assert.is_true(remote_sync_error:sub(-3) == '...')
end)

it('hides blank remote sync errors from the rendered output', function()
    local bufnr = api.open_chat()
    fake_supports_load = true
    api.set_prompt('first turn')
    api.submit_prompt()

    fake_client:resolve({
        stopReason = 'end_turn',
    })

    fake_load_error = '\n\t  '

    assert.has_error(function()
        api.load_session()
    end)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local remote_sync_error_line
    for _, line in ipairs(lines) do
        if line:match('> Remote Sync Error:') then
            remote_sync_error_line = line
            break
        end
    end

    assert.is_nil(remote_sync_error_line)
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
    assert.are.equal(
        'ACP  acp:1  adapter=codex  idle  sync=created  remote=sess_124',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_false(vim.tbl_contains(lines, '> Remote Sync Error: `session/load failed`'))
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

    local ok = api.save_sessions()
    assert.is_true(ok)
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

    local ok = api.save_sessions()
    assert.is_true(ok)
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
    local ok = api.save_sessions()
    assert.is_true(ok)
    api.clear()

    plugin.setup({
        session_state_file = state_file,
        restore_sessions_on_setup = true,
    })

    assert.are.equal(current_id, api.current_session().id)
    assert.are.equal('restored on setup', api.current_session().draft_prompt)
end)

it('restores sessions with open_chat=true and auto_create_session when no state exists', function()
    local state_file = temp_path('acp-restore-open-chat-no-state.json')

    plugin.setup({
        session_state_file = state_file,
        auto_create_session = true,
    })

    local restored = api.restore_sessions({
        open_chat = true,
    })

    assert.are.same({}, restored)
    assert.is_not_nil(api.current_session())
    assert.are.equal('acp:1', api.current_session().id)
end)

it('restores sessions with open_chat=true without clobbering existing buffer draft prompt', function()
    local state_file = temp_path('acp-restore-open-chat-buffer.json')

    plugin.setup({
        session_state_file = state_file,
    })
    api.open_chat()
    api.set_prompt('persisted draft')
    local ok = api.save_sessions()
    assert.is_true(ok)
    api.clear()

    plugin.setup({
        session_state_file = state_file,
    })
    api.open_chat()
    api.set_prompt('stale buffer draft')

    api.restore_sessions({
        open_chat = true,
    })

    assert.are.equal('persisted draft', api.current_session().draft_prompt)
    assert.are.equal('persisted draft', api.get_prompt())
end)

it('continues the most recently updated in-memory ACP session', function()
    require('legate.session').restore({
        current_id = 'acp:1',
        next_ordinal = 3,
        next_message_id = 1,
        sessions = {
            {
                id = 'acp:1',
                ordinal = 1,
                status = 'idle',
                messages = {},
                draft_prompt = 'older draft',
                updated_at = 10,
            },
            {
                id = 'acp:2',
                ordinal = 2,
                status = 'idle',
                messages = {},
                draft_prompt = 'newer draft',
                updated_at = 30,
            },
        },
    })

    local continued = api.continue_last_session()

    assert.are.equal('acp:2', continued.id)
    assert.are.equal('acp:2', api.current_session().id)
    assert.are.equal('newer draft', api.get_prompt())
end)

it('continues the newest persisted ACP session when memory has no sessions', function()
    local state_file = temp_path('acp-continue-last.json')

    vim.fn.writefile({
        vim.json.encode({
            current_id = 'acp:1',
            next_ordinal = 3,
            next_message_id = 1,
            sessions = {
                {
                    id = 'acp:1',
                    ordinal = 1,
                    status = 'idle',
                    messages = {},
                    draft_prompt = 'current but older',
                    updated_at = 20,
                },
                {
                    id = 'acp:2',
                    ordinal = 2,
                    status = 'idle',
                    messages = {},
                    draft_prompt = 'latest persisted',
                    updated_at = 40,
                },
            },
        }),
    }, state_file)

    plugin.setup({
        session_state_file = state_file,
    })

    local continued = api.continue_last_session()

    assert.are.equal('acp:2', continued.id)
    assert.are.equal('acp:2', api.current_session().id)
    assert.are.equal('latest persisted', api.get_prompt())
end)

it('continues the pre-existing newest ACP session without clobbering its draft from the visible buffer', function()
    local sessions = require('legate.session')

    sessions.restore({
        current_id = 'acp:1',
        next_ordinal = 3,
        next_message_id = 1,
        sessions = {
            {
                id = 'acp:1',
                ordinal = 1,
                status = 'idle',
                messages = {},
                draft_prompt = 'older original draft',
                updated_at = 10,
            },
            {
                id = 'acp:2',
                ordinal = 2,
                status = 'idle',
                messages = {},
                draft_prompt = 'newer preserved draft',
                updated_at = 20,
            },
        },
    })
    local bufnr = api.open_chat()
    require('legate.ui.input').set_prompt(bufnr, 'old visible buffer draft')

    local continued = api.continue_last_session()

    assert.are.equal('acp:2', continued.id)
    assert.are.equal('acp:2', api.current_session().id)
    assert.are.equal('newer preserved draft', api.get_prompt())
    assert.are.equal('old visible buffer draft', sessions.get('acp:1').draft_prompt)
    assert.are.equal('newer preserved draft', sessions.get('acp:2').draft_prompt)
end)

it('creates a fresh chat when continuing with no history and auto-create enabled', function()
    plugin.setup({
        auto_create_session = true,
    })

    local continued = api.continue_last_session()

    assert.are.equal('acp:1', continued.id)
    assert.are.equal('acp:1', api.current_session().id)
end)

it('reports missing ACP history when continuing with no history and no auto-create', function()
    plugin.setup({
        auto_create_session = false,
    })

    assert.has_error(function()
        api.continue_last_session()
    end, 'No ACP session history exists')
end)

it('returns a save failure so callers can detect persistence errors', function()
    local original_save = persistence.save
    local notifications = {}
    local original_notify = vim.notify

    local ok, err = xpcall(function()
        plugin.setup()
        api.open_chat()

        local original_module_save = package.loaded['legate.core.persistence'].save
        package.loaded['legate.core.persistence'].save = function()
            return false, 'disk full'
        end

        vim.notify = function(message)
            table.insert(notifications, message)
        end

        local saved, save_err = api.save_sessions()

        assert.is_false(saved)
        assert.are.equal('disk full', save_err)
        assert.are.same({ 'Failed to save ACP sessions: disk full' }, notifications)
    end, debug.traceback)

    persistence.save = original_save
    package.loaded['legate.core.persistence'].save = original_save
    vim.notify = original_notify

    assert.is_true(ok, err)
end)

it('does not implicitly load restored remote sessions when submitting the next prompt', function()
    local state_file = temp_path('acp-no-implicit-load.json')

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
                            text = 'restored assistant message',
                        },
                    },
                    turn_id = 1,
                    draft_prompt = '',
                    remote_id = 'sess_restored',
                    remote_sync_state = 'created',
                },
            },
        }),
    }, state_file)

    plugin.setup({
        session_state_file = state_file,
    })
    fake_supports_load = true
    api.restore_sessions()
    api.set_prompt('next turn')
    local current_session = api.submit_prompt()

    assert.are.equal('sess_123', current_session.remote_id)
    assert.is_true(current_session.remote_sync_state == 'created' or current_session.remote_sync_state == 'loaded')
end)

it('explicitly reloads a restored remote session through LegateLoadSession', function()
    local state_file = temp_path('acp-explicit-load-restored.json')

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
                            text = 'restored assistant message',
                        },
                    },
                    turn_id = 1,
                    draft_prompt = '',
                    remote_id = 'sess_123',
                    remote_sync_state = 'created',
                },
            },
        }),
    }, state_file)

    plugin.setup({
        session_state_file = state_file,
    })
    fake_supports_load = true
    api.restore_sessions()

    api.load_session()

    local sync_methods = vim.tbl_map(function(item)
        return item.method
    end, fake_client.sync_calls)
    local current_session = api.current_session()

    assert.are.equal('sess_123', current_session.remote_id)
    assert.are.equal('loaded', current_session.remote_sync_state)
    assert.is_true(vim.tbl_contains(sync_methods, 'session/load'))
    assert.is_false(vim.tbl_contains(sync_methods, 'session/new'))
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
    assert.are.equal(
        'ACP  acp:1  adapter=codex  idle  sync=load_failed  remote=sess_123',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_true(vim.tbl_contains(lines, '> Remote Sync Error: `session/load failed`'))
    assert.is_true(
        vim.tbl_contains(
            lines,
            '> Recovery: retry the recorded remote session with `:LegateLoadSession`, or create a fresh one with `:LegateRebindSession`'
        )
    )
end)

it('ignores corrupted persisted session payloads whose sessions field is not a list', function()
    local state_file = temp_path('acp-restore-corrupted-sessions.json')

    vim.fn.writefile({
        vim.json.encode({
            current_id = 'acp:1',
            next_ordinal = 2,
            next_message_id = 3,
            sessions = {
                broken = true,
            },
        }),
    }, state_file)

    plugin.setup({
        session_state_file = state_file,
    })

    local ok, restored = pcall(api.restore_sessions)

    assert.is_true(ok, restored)
    assert.are.same({}, restored)
    assert.are.equal(0, #api.list_sessions())
end)

it('returns nil when the persisted session file cannot be decoded', function()
    local state_file = temp_path('acp-load-invalid-json.json')
    local notifications = {}
    local original_notify = vim.notify
    local persistence = require('legate.core.persistence')

    vim.fn.writefile({ '{not valid json' }, state_file)

    local ok, err = xpcall(function()
        vim.notify = function(message, level)
            table.insert(notifications, { message = message, level = level })
        end

        plugin.setup({
            session_state_file = state_file,
        })

        assert.is_nil(persistence.load())
        assert.are.equal(1, #notifications)
        assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
        assert.is_truthy(notifications[1].message:find(state_file, 1, true))
        assert.is_truthy(notifications[1].message:find('Failed to restore ACP sessions from ', 1, true))
    end, debug.traceback)

    vim.notify = original_notify

    assert.is_true(ok, err)
end)

it('notifies and skips restore when the persisted session file cannot be decoded', function()
    local state_file = temp_path('acp-restore-invalid-json.json')
    local notifications = {}
    local original_notify = vim.notify

    vim.fn.writefile({ '{not valid json' }, state_file)

    local ok, err = xpcall(function()
        vim.notify = function(message, level)
            table.insert(notifications, { message = message, level = level })
        end

        plugin.setup({
            session_state_file = state_file,
        })

        local restored = api.restore_sessions()

        assert.are.same({}, restored)
        assert.are.equal(0, #api.list_sessions())
        assert.are.equal(1, #notifications)
        assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
        assert.is_truthy(notifications[1].message:find(state_file, 1, true))
        assert.is_truthy(notifications[1].message:find('Failed to restore ACP sessions from ', 1, true))
    end, debug.traceback)

    vim.notify = original_notify

    assert.is_true(ok, err)
end)
