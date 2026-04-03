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

it('keeps transcript edits out of the buffer while preserving prompt edits', function()
    local bufnr = api.open_chat()

    api.set_prompt('draft prompt')

    local input = require('acp.input')
    local anchor_row = input.anchor_row(bufnr)
    local prompt_start = input.prompt_start_line(bufnr)
    local edit = require('acp.edit')
    assert.is_not_nil(anchor_row)

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {
        'mutated transcript',
    })
    vim.bo[bufnr].modifiable = false

    wait_until(function()
        return not vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 'mutated transcript')
    end)

    assert.is_false(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 'mutated transcript'))

    vim.api.nvim_win_set_cursor(0, {
        prompt_start,
        0,
    })
    edit.refresh(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, prompt_start - 1, prompt_start, false, {
        'edited prompt',
    })

    wait_until(function()
        return api.get_prompt() == 'edited prompt'
    end)

    assert.are.equal('edited prompt', api.get_prompt())
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

it('keeps ACP config options out of the transcript while preserving them in session state', function()
    local bufnr = api.open_chat()

    api.set_prompt('show config options')
    api.submit_prompt()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.is_false(vim.tbl_contains(lines, '## Config Options'))
    assert.are.equal('mode', api.current_session().config_options[1].id)
    assert.are.equal('Ask', api.config_options()[1].options[1].name)
end)

it('stores ACP slash commands from session/update notifications without rendering them into the transcript', function()
    local bufnr = api.open_chat()

    api.set_prompt('show slash commands')
    api.submit_prompt()
    emit_available_commands_update()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local slash_commands = api.slash_commands()

    assert.are.equal(2, #slash_commands)
    assert.are.equal('web', slash_commands[1].name)
    assert.is_false(vim.tbl_contains(lines, '## Slash Commands'))
    assert.is_false(vim.tbl_contains(lines, '- `/web` Search the web for information'))
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

it('exposes slash-command completion through the ACP prompt omnifunc', function()
    local bufnr = api.open_chat()
    local complete = require('acp.completion').complete

    api.current_session().available_commands = vim.deepcopy(fake_available_commands)
    api.set_prompt('/we')

    assert.are.equal("v:lua.require'acp.completion'.complete", vim.bo[bufnr].omnifunc)

    vim.api.nvim_win_set_cursor(0, {
        vim.api.nvim_buf_line_count(bufnr),
        3,
    })

    assert.are.equal(0, complete(1, ''))

    local items = complete(0, '/we')

    assert.are.equal(1, #items)
    assert.are.equal('/web', items[1].word)
    assert.are.equal('ACP Slash', items[1].menu)
    assert.is_true(items[1].info:match('Search the web for information') ~= nil)
end)

it('only offers slash-command completion for the leading prompt command token', function()
    api.open_chat()
    local complete = require('acp.completion').complete

    api.current_session().available_commands = vim.deepcopy(fake_available_commands)
    api.set_prompt('/web already searching')
    vim.api.nvim_win_set_cursor(0, {
        vim.api.nvim_buf_line_count(0),
        #'/web already searching',
    })

    assert.are.equal(-3, complete(1, ''))
    assert.are.same({}, complete(0, 'searching'))
end)

it('sends session/set_config_option and rerenders the selected session', function()
    local bufnr = api.open_chat()

    api.set_prompt('draft prompt')
    local current_session = api.current_session()
    api.set_config_option('mode', 'code')

    assert.are.equal('session/set_config_option', fake_client.sync_calls[4].method)
    assert.are.same({
        sessionId = 'sess_123',
        configId = 'mode',
        value = 'code',
    }, fake_client.sync_calls[4].params)
    assert.are.equal('code', current_session.config_options[1].currentValue)
    assert.are.equal('draft prompt', api.get_prompt())
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

it('renders session status in the winbar and shows waiting state as virtual text', function()
    local bufnr = api.open_chat()
    local current_session = api.current_session()
    local input = require('acp.input')

    api.set_prompt('status widget')
    api.submit_prompt()

    local namespaces = vim.api.nvim_get_namespaces()
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespaces['acp.surface'], 0, -1, {
        details = true,
    })

    assert.are.equal(
        string.format('ACP  %s  waiting  sync=created  remote=sess_123', current_session.id),
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.are.equal(1, #marks)
    assert.are.equal(input.prompt_header_line(bufnr) - 4, marks[1][2])
    assert.are.same({ { 'Working...', 'Comment' } }, marks[1][4].virt_text)
    assert.are.equal('overlay', marks[1][4].virt_text_pos)

    fake_client:resolve({
        stopReason = 'end_turn',
    })

    assert.are.equal(
        string.format('ACP  %s  idle  sync=created  remote=sess_123', current_session.id),
        vim.api.nvim_get_option_value('winbar', {
            win = 0,
        })
    )
    assert.are.same(
        {},
        vim.api.nvim_buf_get_extmarks(bufnr, namespaces['acp.surface'], 0, -1, {
            details = true,
        })
    )
end)

it('keeps the chat pinned to the bottom while streamed updates arrive', function()
    local bufnr = api.open_chat()
    local lines = {}

    for i = 1, 20 do
        table.insert(lines, string.format('line %d', i))
    end

    vim.api.nvim_win_set_height(0, 6)
    api.set_prompt('stream down')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'agent_message_chunk',
            content = {
                type = 'text',
                text = table.concat(lines, '\n'),
            },
        },
    })

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    assert.are.equal(line_count, vim.api.nvim_win_get_cursor(0)[1])
    assert.are.equal(line_count, vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].botline)
end)

it('preserves a scrolled-up view while streamed updates arrive', function()
    local bufnr = api.open_chat()
    local initial_lines = {}

    for i = 1, 20 do
        table.insert(initial_lines, string.format('line %d', i))
    end

    vim.api.nvim_win_set_height(0, 6)
    api.set_prompt('stream preserve')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'agent_message_chunk',
            content = {
                type = 'text',
                text = table.concat(initial_lines, '\n'),
            },
        },
    })

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('normal! zt')

    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'agent_message_chunk',
            content = {
                type = 'text',
                text = '\nline 21\nline 22',
            },
        },
    })

    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.is_true(vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].botline < vim.api.nvim_buf_line_count(bufnr))
end)

it('keeps the transcript read-only while leaving the prompt naturally editable', function()
    local bufnr = api.open_chat()
    local edit = require('acp.edit')

    assert.is_true(vim.bo[bufnr].modifiable)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    edit.refresh(bufnr)

    assert.is_false(vim.bo[bufnr].modifiable)

    api.set_prompt('draft')

    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 0 })
    edit.refresh(bufnr)

    assert.is_true(vim.bo[bufnr].modifiable)

    api.submit_prompt()

    assert.is_false(vim.bo[bufnr].modifiable)
end)

it('limits editing to the ACP prompt region', function()
    local bufnr = api.open_chat()
    local edit = require('acp.edit')
    local prompt_start = require('acp.input').prompt_start_line(bufnr)

    vim.api.nvim_win_set_cursor(0, {
        prompt_start,
        0,
    })
    edit.refresh(bufnr)

    assert.is_true(vim.bo[bufnr].modifiable)
    assert.are.same({ prompt_start, 0 }, vim.api.nvim_win_get_cursor(0))

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    edit.refresh(bufnr)

    assert.is_false(vim.bo[bufnr].modifiable)
end)

it('keeps the ACP prompt header outside the editable region', function()
    local bufnr = api.open_chat()
    local input = require('acp.input')
    local edit = require('acp.edit')
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    vim.api.nvim_win_set_cursor(0, {
        input.prompt_header_line(bufnr),
        0,
    })
    edit.refresh(bufnr)

    assert.is_false(vim.bo[bufnr].modifiable)

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, input.prompt_header_line(bufnr) - 1, input.prompt_header_line(bufnr), false, {
        'Mutated Header',
    })
    vim.bo[bufnr].modifiable = false

    wait_until(function()
        return vim.api.nvim_buf_get_lines(
            bufnr,
            input.prompt_header_line(bufnr) - 1,
            input.prompt_header_line(bufnr),
            false
        )[1] == '## Prompt'
    end)

    assert.are.equal(
        '## Prompt',
        vim.api.nvim_buf_get_lines(bufnr, input.prompt_header_line(bufnr) - 1, input.prompt_header_line(bufnr), false)[1]
    )
    assert.are.equal('', lines[input.prompt_header_line(bufnr) - 1])
    assert.are.equal('---', lines[input.prompt_header_line(bufnr) - 2])
end)

it('preserves prompt edit mode across ACP rerenders', function()
    local bufnr = api.open_chat()
    local edit = require('acp.edit')

    vim.api.nvim_win_set_cursor(0, {
        vim.api.nvim_buf_line_count(bufnr),
        0,
    })
    edit.refresh(bufnr)
    api.append_message('assistant', 'rerender while editing')

    assert.is_true(vim.bo[bufnr].modifiable)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    edit.refresh(bufnr)

    assert.is_false(vim.bo[bufnr].modifiable)
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

    assert.are.equal('code', api.current_session().config_options[1].currentValue)
    assert.is_false(vim.tbl_contains(lines, '## Config Options'))
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
        assert.is_true(
            opts.format_item(items[1]):match('^/web%s+Search the web for information%s+input=query to search for$')
                ~= nil
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

it('renders tool calls inline in the transcript stream', function()
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

    assert.is_true(vim.tbl_contains(lines, '- ◔ Read README'))
    assert.is_true(vim.tbl_contains(lines, '  Status: `in_progress`'))
    assert.is_true(vim.tbl_contains(lines, '  Kind: `read`'))
    assert.is_true(vim.tbl_contains(lines, '  Locations: `/tmp/README.md:12`'))
    assert.is_true(vim.tbl_contains(lines, '  Text: Reading README for context'))
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

    assert.is_true(vim.tbl_contains(lines, '- ✓ Write config'))
    assert.is_false(vim.tbl_contains(lines, '- ◔ Write config'))
    assert.is_true(vim.tbl_contains(lines, '  Status: `completed`'))
    assert.is_true(vim.tbl_contains(lines, '  Diff: `/tmp/init.lua`'))
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
