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
        'ACPSelectApprovalOption',
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

it('resolves the current inline ACP approval through the command surface', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('approval command select')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'approval_select',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local response = nil

    fake_client.opts.on_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'approval_select',
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
    }, function(result, error)
        response = {
            result = result,
            error = error,
        }
    end)

    vim.cmd('ACPSelectApprovalOption allow-once')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('selected', response.result.outcome.outcome)
    assert.are.equal('allow-once', response.result.outcome.optionId)
    assert.is_true(vim.tbl_contains(lines, '✓ Approval [1] Run command'))
end)

it('resolves a pending inline approval through the command surface even when another session is selected', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('approval command select from another session')
    local first = api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'approval_select_other_session',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local second = api.new_session()

    assert.are.equal(second.id, api.current_session().id)

    local response = nil

    fake_client.opts.on_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'approval_select_other_session',
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
    }, function(result, error)
        response = {
            result = result,
            error = error,
        }
    end)

    vim.cmd('ACPSelectApprovalOption allow-once')

    assert.are.equal(first.id, api.current_session().id)
    assert.are.equal('selected', response.result.outcome.outcome)
    assert.are.equal('allow-once', response.result.outcome.optionId)
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

it('completes ACP config option ids and values through the command surface', function()
    api.open_chat()
    local original_current_session = api.current_session
    local original_config_options = api.config_options

    api.current_session = function()
        return {
            id = 'sess_123',
        }
    end
    api.config_options = function()
        return {
            {
                id = 'mode',
                options = {
                    {
                        name = 'Ask',
                        value = 'ask',
                    },
                    {
                        name = 'Code',
                        value = 'code',
                    },
                },
            },
            {
                id = 'model',
                options = {
                    {
                        name = 'GPT-5.4',
                        value = 'gpt-5.4',
                    },
                    {
                        name = 'GPT-5.4 Mini',
                        value = 'gpt-5.4-mini',
                    },
                },
            },
        }
    end

    local definition = vim.api.nvim_get_commands({
        builtin = false,
    })['ACPSetConfigOption']

    assert.is_function(definition.complete)
    assert.are.same({ 'mode', 'model' }, definition.complete('m', 'ACPSetConfigOption m', 0))
    assert.are.same({ 'code' }, definition.complete('c', 'ACPSetConfigOption mode c', 0))

    api.current_session = original_current_session
    api.config_options = original_config_options
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

    assert.are.equal('✗ Approval [1] Write file', line)
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

    assert.are.equal('✗ Approval [1] Delete file', line)
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
            assert.is_true(
                opts.format_item(items[1])
                    :match('^Mode%s+current=ask%s+id=mode%s+Controls how the agent requests permission$')
                    ~= nil
            )
            on_choice(items[1])
            return
        end

        assert.are.equal('Select value for ACP config option: Mode', opts.prompt)
        assert.is_true(opts.format_item(items[2]):match('^  Code%s+value=code') ~= nil)
        on_choice(items[2])
    end)

    vim.cmd('ACPPickConfigOption')
    restore()

    assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
    assert.are.equal('code', api.current_session().config_options[1].currentValue)
end)

it('goes back to ACP config option selection when the value picker is dismissed', function()
    api.open_chat()
    local prompts = {}
    local value_picker_seen = false

    local restore = with_ui_select(function(items, opts, on_choice)
        table.insert(prompts, opts.prompt)

        if opts.prompt == 'Select ACP config option' and not value_picker_seen then
            on_choice(items[1])
            return
        end

        if opts.prompt == 'Select value for ACP config option: Mode' then
            value_picker_seen = true
            on_choice(nil)
            return
        end

        on_choice(nil)
    end)

    vim.cmd('ACPPickConfigOption')
    restore()

    assert.are.same({
        'Select ACP config option',
        'Select value for ACP config option: Mode',
        'Select ACP config option',
    }, prompts)
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
        local label = vim.trim(opts.format_item(items[2]))

        assert.is_true(vim.startswith(label, '/test'))
        assert.is_true(label:match('Run tests for the current project') ~= nil)
        on_choice(items[2])
    end)

    vim.cmd('ACPPickSlashCommand')
    restore_select()

    assert.are.equal('session/prompt', fake_client.async_calls[1].method)
    assert.are.equal('/test', fake_client.async_calls[1].params.prompt[1].text)
end)

it('goes back to ACP slash-command selection when the input prompt is dismissed', function()
    api.open_chat()
    api.slash_commands()
    emit_available_commands_update()
    local prompts = {}
    local input_seen = false

    local restore_select = with_ui_select(function(items, opts, on_choice)
        table.insert(prompts, opts.prompt)

        if not input_seen then
            on_choice(items[1])
            return
        end

        on_choice(nil)
    end)
    local restore_input = with_ui_input(function(_, on_confirm)
        input_seen = true
        on_confirm(nil)
    end)

    vim.cmd('ACPPickSlashCommand')
    restore_input()
    restore_select()

    assert.are.same({
        'Select ACP slash command',
        'Select ACP slash command',
    }, prompts)
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
