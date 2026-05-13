---@param value string
---@return string
local function encode_path_component(value)
    return value:gsub('[^%w._-]', function(char)
        return string.format('%%%02X', char:byte())
    end)
end

---@param id string
---@return string
local function session_filename(id)
    return string.format('%s.json', encode_path_component(id))
end

---@param path string
---@param payload table
local function write_json(path, payload)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    vim.fn.writefile({ vim.json.encode(payload) }, path)
end

---@param session table
---@return table
local function persisted_session_index_entry(session)
    return {
        id = session.id,
        ordinal = session.ordinal,
        adapter_name = session.adapter_name,
        status = session.status,
        remote_id = session.remote_id,
        remote_sync_state = session.remote_sync_state,
        cwd = session.cwd,
        created_at = session.created_at,
        updated_at = session.updated_at,
        file = session_filename(session.id),
    }
end

---@param state_file string
---@param payload table
local function write_persisted_sessions(state_file, payload)
    local state_dir = string.format('%s.d', state_file)
    local sessions = vim.islist(payload.sessions) and payload.sessions or {}

    for _, session in ipairs(sessions) do
        write_json(vim.fs.joinpath(state_dir, 'sessions', session_filename(session.id)), session)
    end

    write_json(state_file, {
        version = 1,
        current_id = payload.current_id,
        next_ordinal = payload.next_ordinal,
        next_message_id = payload.next_message_id,
        next_pending_approval_ordinal = payload.next_pending_approval_ordinal,
        sessions = vim.tbl_map(persisted_session_index_entry, sessions),
    })
end

it('registers ACP user commands', function()
    local commands = {
        'LegateChat',
        'LegateNewSession',
        'LegateLoadSession',
        'LegateRebindSession',
        'LegateSessions',
        'LegateSaveSessions',
        'LegateRestoreSessions',
        'LegateContinueLastSession',
        'LegateClearSessionStorage',
        'LegateApprovals',
        'LegateClearApprovals',
        'LegateSelectApprovalOption',
        'LegateApprovalMode',
        'LegateConfigOptions',
        'LegateSlashCommands',
        'LegateRevealApproval',
        'LegatePickApproval',
        'LegateSelectSession',
        'LegatePickSession',
        'LegateAdapters',
        'LegateSelectAdapter',
        'LegatePickAdapter',
        'LegateSetConfigOption',
        'LegatePickConfigOption',
        'LegateRunSlashCommand',
        'LegatePickSlashCommand',
        'LegateCloseSession',
        'LegatePickCloseSession',
        'LegateSubmit',
        'LegateCancel',
    }

    for _, command in ipairs(commands) do
        local definition = vim.api.nvim_get_commands({
            builtin = false,
        })[command]

        assert.is_not_nil(definition)
    end
end)

it('defers transport startup for LegateSubmit until after the waiting state renders', function()
    local scheduled = {}
    local original_schedule = vim.schedule
    local bufnr = api.open_chat()

    api.set_prompt('deferred command submit')
    vim.schedule = function(callback)
        table.insert(scheduled, callback)
    end

    local ok, err = pcall(vim.cmd, 'LegateSubmit')
    vim.schedule = original_schedule

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.is_true(ok, err)
    assert.are.equal('waiting', api.current_session().status)
    assert.is_true(vim.tbl_contains(lines, '### User'))
    assert.is_true(vim.tbl_contains(lines, 'deferred command submit'))
    assert.is_nil(fake_client)
    assert.are.equal(1, #scheduled)

    scheduled[1]()

    assert.is_not_nil(fake_client)
    assert.are.equal('initialize', fake_client.sync_calls[1].method)
    assert.are.equal('authenticate', fake_client.sync_calls[2].method)
    assert.are.equal('session/new', fake_client.sync_calls[3].method)
    assert.are.equal('session/prompt', fake_client.async_calls[1].method)
end)

it('lists local ACP sessions through the command surface', function()
    local notifications = {}
    local original_notify = vim.notify

    api.new_session()
    api.new_session()

    vim.notify = function(message)
        table.insert(notifications, message)
    end

    local ok, err = pcall(vim.cmd, 'LegateSessions')

    vim.notify = original_notify

    assert.is_true(ok, err)
    assert.are.same({
        '  acp:1  adapter=codex  [idle]  remote=unbound  sync=unbound  messages=0\n* acp:2  adapter=codex  [idle]  remote=unbound  sync=unbound  messages=0',
    }, notifications)
end)

it('lists configured ACP adapters through the command surface', function()
    local notifications = {}
    local original_notify = vim.notify

    plugin.setup({
        default_adapter = 'custom',
        adapters = {
            codex = {
                command = { 'codex-acp' },
            },
            custom = {
                command = { 'custom-acp' },
                auth_method = 'chatgpt',
                config_option_overrides = {
                    mode = 'code',
                },
                title = 'Custom ACP',
            },
        },
    })
    api.open_chat()

    vim.notify = function(message)
        table.insert(notifications, message)
    end

    local ok, err = pcall(vim.cmd, 'LegateAdapters')

    vim.notify = original_notify

    assert.is_true(ok, err)
    assert.are.equal(1, #notifications)
    assert.matches('codex', notifications[1], 1, true)
    assert.matches('custom', notifications[1], 1, true)
    assert.matches('auth=chatgpt', notifications[1], 1, true)
    assert.matches('command=custom%-acp', notifications[1])
    assert.matches('overrides=1', notifications[1], 1, true)
end)

it('does not auto-create a session when listing ACP adapters', function()
    local notifications = {}
    local original_notify = vim.notify

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

    vim.notify = function(message)
        table.insert(notifications, message)
    end

    local ok, err = pcall(vim.cmd, 'LegateAdapters')

    vim.notify = original_notify

    assert.is_true(ok, err)
    assert.are.equal(0, #api.list_sessions())
    assert.are.equal(1, #notifications)
    assert.matches('* custom', notifications[1], 1, true)
end)

it('selects an ACP adapter through the picker command surface', function()
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

    local restore = with_ui_select(function(items, opts, on_choice)
        assert.are.same({ 'codex', 'custom' }, items)
        assert.are.equal('Select ACP adapter for acp:1', opts.prompt)
        on_choice('custom')
    end)

    vim.cmd('LegatePickAdapter')
    restore()

    assert.are.equal('custom', api.current_session().adapter_name)
end)

it('saves, restores, and clears ACP session storage through the command surface', function()
    local state_file = temp_path('acp-command-sessions.json')

    plugin.setup({
        session_state_file = state_file,
    })
    api.open_chat()
    api.set_prompt('command persistence')
    local current_id = api.current_session().id

    vim.cmd('LegateSaveSessions')

    api.clear()
    plugin.setup({
        session_state_file = state_file,
    })

    vim.cmd('LegateRestoreSessions')

    assert.are.equal(current_id, api.current_session().id)
    assert.are.equal('command persistence', api.current_session().draft_prompt)

    vim.cmd('LegateClearSessionStorage')

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

    local ok, err = pcall(vim.cmd, 'LegateApprovals')

    vim.notify = original_notify

    assert.is_true(ok, err)
    assert.are.same({
        '[1] Read file  outcome=selected  via=default  selected=Reject [reject_once]',
    }, notifications)
end)

it('does not auto-create a session for ACP approval completion or listing', function()
    local definition = vim.api.nvim_get_commands({
        builtin = false,
    })['LegateRevealApproval']
    local notifications = {}
    local original_notify = vim.notify

    assert.is_not_nil(definition)
    assert.are.same({}, definition.complete('', 'LegateRevealApproval ', 0))
    assert.are.equal(0, #api.list_sessions())

    vim.notify = function(message)
        table.insert(notifications, message)
    end

    local ok, err = pcall(vim.cmd, 'LegateApprovals')

    vim.notify = original_notify

    assert.is_true(ok, err)
    assert.are.same({ 'No Legate approvals are available' }, notifications)
    assert.are.equal(0, #api.list_sessions())
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

    vim.cmd('LegateSelectApprovalOption allow-once')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('selected', response.result.outcome.outcome)
    assert.are.equal('allow-once', response.result.outcome.optionId)
    assert.is_true(vim.tbl_contains(lines, '✓ Approval [1] Run command'))
end)

it('clears pending ACP approvals through the command surface', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('approval command clear')
    api.submit_prompt()

    local response = nil
    fake_client.opts.on_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'approval_clear',
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

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message)
        table.insert(notifications, message)
    end

    vim.cmd('LegateClearApprovals')

    vim.notify = original_notify

    assert.are.equal('cancelled', response.result.outcome.outcome)
    assert.is_nil(api.pending_approval())
    assert.are.same({ 'Cleared 1 pending Legate approval' }, notifications)
end)

it('completes bare approval option ids for a single pending request without numeric aliases', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('approval command completion')
    api.submit_prompt()
    fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'approval_completion',
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

    local definition = vim.api.nvim_get_commands({
        builtin = false,
    })['LegateSelectApprovalOption']

    assert.are.same({
        'allow-once',
        'reject-once',
    }, definition.complete('', 'LegateSelectApprovalOption ', 0))
end)

it('completes queued approval options for every pending request', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('approval command queued completion')
    api.submit_prompt()
    fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'approval_completion_first',
            title = 'First command',
        },
        options = {
            {
                optionId = 'allow-first',
                name = 'Allow first',
                kind = 'allow_once',
            },
        },
    })
    fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'approval_completion_second',
            title = 'Second command',
        },
        options = {
            {
                optionId = 'allow-second',
                name = 'Allow second',
                kind = 'allow_once',
            },
        },
    })

    local definition = vim.api.nvim_get_commands({
        builtin = false,
    })['LegateSelectApprovalOption']

    assert.are.same({
        'acp:1:approval_completion_first:1:allow-first',
        'acp:1:approval_completion_second:1:allow-second',
    }, definition.complete('', 'LegateSelectApprovalOption ', 0))
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

    vim.cmd('LegateSelectApprovalOption allow-once')

    assert.are.equal(first.id, api.current_session().id)
    assert.are.equal('selected', response.result.outcome.outcome)
    assert.are.equal('allow-once', response.result.outcome.optionId)
end)

it('resolves queued approvals one at a time through the command surface', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('approval command queue')
    api.submit_prompt()

    local first_response = nil
    fake_client.opts.on_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = { toolCallId = 'approval_queue_first', title = 'First queued command' },
        options = {
            { optionId = 'allow-first', name = 'Allow first', kind = 'allow_once' },
        },
    }, function(result, error)
        first_response = { result = result, error = error }
    end)

    local second_response = nil
    fake_client.opts.on_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = { toolCallId = 'approval_queue_second', title = 'Second queued command' },
        options = {
            { optionId = 'allow-second', name = 'Allow second', kind = 'allow_once' },
        },
    }, function(result, error)
        second_response = { result = result, error = error }
    end)

    assert.are.equal(2, #api.pending_approvals())
    assert.is_nil(first_response)
    assert.are.equal('approval_queue_first', api.pending_approval().tool_call_id)
    vim.cmd('LegateSelectApprovalOption allow-first')
    assert.are.equal('selected', first_response.result.outcome.outcome)
    assert.are.equal('allow-first', first_response.result.outcome.optionId)
    assert.are.equal(1, #api.pending_approvals())
    assert.are.equal('approval_queue_second', api.pending_approval().tool_call_id)
    vim.cmd('LegateSelectApprovalOption allow-second')
    assert.are.equal('selected', second_response.result.outcome.outcome)
    assert.are.equal('allow-second', second_response.result.outcome.optionId)
    assert.is_nil(api.pending_approval())
end)

it('lists ACP config options through the command surface', function()
    local notifications = {}
    local original_notify = vim.notify

    api.open_chat()

    vim.notify = function(message)
        table.insert(notifications, message)
    end

    local ok, err = pcall(vim.cmd, 'LegateConfigOptions')

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
    })['LegateSetConfigOption']

    assert.is_function(definition.complete)
    assert.are.same({ 'mode', 'model' }, definition.complete('m', 'LegateSetConfigOption m', 0))
    assert.are.same({ 'code' }, definition.complete('c', 'LegateSetConfigOption mode c', 0))

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

    local ok, err = pcall(vim.cmd, 'LegateSlashCommands')

    vim.notify = original_notify

    assert.is_true(ok, err)
    assert.are.same({
        '/web  Search the web for information  input=query to search for\n/test  Run tests for the current project',
    }, notifications)
end)

it('lists ACP MCP servers with redacted env values through the command surface', function()
    local notifications = {}
    local original_notify = vim.notify
    local original_effective_mcp_servers = api.effective_mcp_servers
    local call_count = 0

    api.effective_mcp_servers = function(...)
        assert.are.same({}, { ... })
        call_count = call_count + 1
        return {
            {
                name = 'stdio-map',
                type = 'stdio',
                command = 'node',
                args = { 'server.js' },
                env = {
                    API_KEY = 'secret',
                    TOKEN = 'top-secret',
                },
            },
            {
                name = 'stdio-list',
                type = 'stdio',
                command = 'python',
                args = { '-m', 'server' },
                env = {
                    { name = 'PASSWORD', value = 'classified' },
                },
            },
        }
    end

    vim.notify = function(message)
        table.insert(notifications, message)
    end

    local ok, err = pcall(vim.cmd, 'LegateMcpServers')

    vim.notify = original_notify
    api.effective_mcp_servers = original_effective_mcp_servers

    assert.is_true(ok, err)
    assert.are.equal(1, call_count)
    assert.are.equal(1, #notifications)
    assert.is_true(notifications[1]:match('Legate MCP servers:') ~= nil)
    assert.is_true(notifications[1]:match('%- stdio%-map') ~= nil)
    assert.is_true(notifications[1]:match('command = "node"') ~= nil)
    assert.is_true(notifications[1]:match('server%.js') ~= nil)
    assert.is_true(notifications[1]:match('name = "API_KEY"') ~= nil)
    assert.is_true(notifications[1]:match('name = "TOKEN"') ~= nil)
    assert.is_true(notifications[1]:match('name = "PASSWORD"') ~= nil)
    assert.is_true(notifications[1]:match('value = "<redacted>"') ~= nil)
    assert.is_nil(notifications[1]:match('secret'))
    assert.is_nil(notifications[1]:match('top%-secret'))
    assert.is_nil(notifications[1]:match('classified'))
    assert.is_true(notifications[1]:match('%- stdio%-list') ~= nil)
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

    vim.cmd('LegateRevealApproval 1')

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]

    assert.are.equal('✗ Approval [1] Write file', line)
end)

it('selects a local ACP session through the command surface', function()
    api.open_chat()
    local first = api.current_session()
    local second = api.new_session()

    vim.cmd(string.format('LegateSelectSession %s', first.id))

    assert.are.equal(first.id, api.current_session().id)

    vim.cmd(string.format('LegateSelectSession %s', second.id))

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
        assert.are.equal('Select Legate approval', opts.prompt)
        assert.are.equal(
            '[1] Delete file  outcome=selected  via=default  selected=Reject [reject_once]',
            opts.format_item(items[1])
        )
        on_choice(items[1])
    end)

    vim.cmd('LegatePickApproval')
    restore()

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]

    assert.are.equal('✗ Approval [1] Delete file', line)
end)

it('loads an ACP session through the command surface', function()
    api.open_chat()

    vim.cmd('LegateLoadSession')

    assert.are.equal('sess_123', api.current_session().remote_id)
    assert.are.equal('created', api.current_session().remote_sync_state)
end)

it('reports ACP session load failures through the command surface without throwing', function()
    local bufnr = api.open_chat()
    fake_supports_load = true
    api.set_prompt('first turn')
    api.submit_prompt()
    fake_client:resolve({
        stopReason = 'end_turn',
    })
    fake_load_error = 'Resource not found'

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
        table.insert(notifications, {
            message = message,
            level = level,
        })
    end

    local ok, err = pcall(vim.cmd, 'LegateLoadSession')

    vim.notify = original_notify

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.is_true(ok, err)
    assert.are.equal(1, #notifications)
    assert.are.equal(
        'ACP session is in load_failed recovery state; retry `:LegateLoadSession` or create a fresh remote with `:LegateRebindSession`',
        notifications[1].message
    )
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.are.equal('load_failed', api.current_session().remote_sync_state)
    assert.are.equal('Resource not found', api.current_session().remote_sync_error)
    assert.is_true(vim.tbl_contains(lines, '> Remote Sync Error: `Resource not found`'))
end)

it('continues the newest persisted ACP session through the command surface', function()
    local state_file = temp_path('acp-command-continue-last.json')

    write_persisted_sessions(state_file, {
        current_id = 'acp:1',
        next_ordinal = 3,
        next_message_id = 1,
        sessions = {
            {
                id = 'acp:1',
                ordinal = 1,
                status = 'idle',
                messages = {},
                draft_prompt = 'older command draft',
                updated_at = 10,
            },
            {
                id = 'acp:2',
                ordinal = 2,
                status = 'idle',
                messages = {},
                draft_prompt = 'newer command draft',
                updated_at = 20,
            },
        },
    })

    plugin.setup({
        session_state_file = state_file,
    })

    vim.cmd('LegateContinueLastSession')

    assert.are.equal('acp:2', api.current_session().id)
    assert.are.equal('newer command draft', api.get_prompt())
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

    assert.has_error(
        function()
            api.load_session()
        end,
        'ACP session is in load_failed recovery state; retry `:LegateLoadSession` or create a fresh remote with `:LegateRebindSession`'
    )

    vim.cmd('LegateRebindSession')

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

    vim.cmd('LegatePickSession')
    restore()

    assert.are.equal(first.id, api.current_session().id)
end)

it('sets an ACP config option through the command surface', function()
    api.open_chat()

    vim.cmd('LegateSetConfigOption mode code')

    assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
    assert.are.equal('code', api.current_session().config_options[1].currentValue)
end)

it('sets ACP approval mode aliases through the command surface', function()
    api.open_chat()

    vim.cmd('LegateApprovalMode yolo')
    assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
    assert.are.equal('code', fake_client.sync_calls[4].params.value)
    assert.are.equal('code', api.current_session().config_options[1].currentValue)

    vim.cmd('LegateApprovalMode strict')
    assert.are.equal('session/set_config_option', fake_client.sync_calls[5].method)
    assert.are.equal('ask', fake_client.sync_calls[5].params.value)
    assert.are.equal('ask', api.current_session().config_options[1].currentValue)
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

    vim.cmd('LegatePickConfigOption')
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

    vim.cmd('LegatePickConfigOption')
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

    vim.cmd('LegateRunSlashCommand web agent client protocol')

    assert.are.equal('session/prompt', fake_client.async_calls[1].method)
    assert.is_true(fake_client.async_calls[1].params.prompt[1].text:match('/web agent client protocol%s*$') ~= nil)
end)

it('rejects ACP slash command invocation without a command name', function()
    api.open_chat()
    api.slash_commands()
    emit_available_commands_update()

    local ok, err = pcall(vim.cmd, 'LegateRunSlashCommand')

    assert.is_false(ok)
    assert.is_true(err:match('ACP slash command name is required') ~= nil)
end)

it('completes ACP slash command names and input hints through the command surface', function()
    api.open_chat()
    api.slash_commands()
    emit_available_commands_update()

    local definition = vim.api.nvim_get_commands({
        builtin = false,
    })['LegateRunSlashCommand']

    assert.is_function(definition.complete)
    assert.are.same({ 'web' }, definition.complete('w', 'LegateRunSlashCommand w', 0))
    assert.are.same({ 'query to search for' }, definition.complete('q', 'LegateRunSlashCommand web q', 0))
    assert.are.same({}, definition.complete('', 'LegateRunSlashCommand test ', 0))
    assert.are.same({ 'web' }, definition.complete('w', 'LegateRunSlashCommand foo w', 0))
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

    vim.cmd('LegatePickSlashCommand')
    restore_select()

    assert.are.equal('session/prompt', fake_client.async_calls[1].method)
    assert.is_true(fake_client.async_calls[1].params.prompt[1].text:match('/test%s*$') ~= nil)
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

    vim.cmd('LegatePickSlashCommand')
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

    vim.cmd('LegateCloseSession acp:1')

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

    vim.cmd('LegatePickCloseSession')
    restore()

    assert.are.same({ second.id }, session_ids(api.list_sessions()))
    assert.are.equal(second.id, api.current_session().id)
end)

it('reports the active terminal backend name', function()
    assert.are.equal('native', api.terminal_backend_name())
end)
