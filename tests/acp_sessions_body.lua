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
    local buffer = require('acp.buffer')

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
    assert.are.equal(
        string.format('ACP  %s  idle  sync=unbound', second.id),
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
    local bufnr = api.open_chat()
    local first = api.current_session()

    api.set_prompt('discard me')

    local closed, next_session = api.close_session(first.id)

    assert.are.equal(first.id, closed.id)
    assert.is_not_nil(next_session)
    assert.are.equal('acp:2', next_session.id)
    assert.are.equal('acp:2', api.current_session().id)
    assert.are.equal('', api.get_prompt())
    assert.are.equal(
        'ACP  acp:2  idle  sync=unbound',
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
    assert.are.equal(
        'ACP  acp:1  idle  sync=created  remote=sess_123',
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

    assert.is_true(first_client.closed)
    assert.are.equal('sess_123', current_session.remote_id)
    assert.are.equal('loaded', current_session.remote_sync_state)
    assert.are.equal(2, #current_session.available_commands)
    assert.are.equal('session/load', second_client.sync_calls[3].method)
    assert.are.equal('sess_123', second_client.sync_calls[3].params.sessionId)
    assert.are.equal(
        'ACP  acp:1  idle  sync=loaded  remote=sess_123',
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
        'ACP  acp:1  idle  sync=load_failed  remote=sess_123',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_true(
        vim.tbl_contains(
            lines,
            '> Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
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
    assert.are.equal(
        'ACP  acp:1  idle  sync=load_failed  remote=sess_123',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_true(vim.tbl_contains(lines, '> Remote Sync Error: `session/load failed`'))
    assert.is_true(
        vim.tbl_contains(
            lines,
            '> Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
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
    assert.are.equal(
        'ACP  acp:1  idle  sync=created  remote=sess_124',
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
    assert.are.equal(
        'ACP  acp:1  idle  sync=load_failed  remote=sess_123',
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.is_true(vim.tbl_contains(lines, '> Remote Sync Error: `session/load failed`'))
    assert.is_true(
        vim.tbl_contains(
            lines,
            '> Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
        )
    )
end)
