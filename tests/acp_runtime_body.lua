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
    assert.is_true(vim.tbl_contains(lines, '- ✗ Approval [1] Read config'))
    assert.is_true(vim.tbl_contains(lines, '  Outcome: `selected`'))
    assert.is_true(vim.tbl_contains(lines, '  Source: `default`'))
    assert.is_true(vim.tbl_contains(lines, '  Selected Option: Reject [reject_once] (`reject-once`)'))
    assert.is_true(
        vim.tbl_contains(
            lines,
            '  Options: Allow once [allow_once] (`allow-once`), Reject [reject_once] (`reject-once`)'
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
    assert.is_true(vim.tbl_contains(lines, '- ✓ Approval [1] Run command'))
    assert.is_true(vim.tbl_contains(lines, '  Outcome: `selected`'))
    assert.is_true(vim.tbl_contains(lines, '  Source: `select`'))
    assert.is_true(vim.tbl_contains(lines, '  Selected Option: Allow once [allow_once] (`allow-once`)'))
end)

it('defers the interactive approval picker out of fast event contexts', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('fast approval')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_fast_select',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local picker_calls = 0
    local restore_select = with_ui_select(function(items, opts, on_choice)
        picker_calls = picker_calls + 1
        assert.are.equal('ACP approval: Run command', opts.prompt)
        on_choice(items[1])
    end)
    local scheduled, restore_fast = with_fast_event_schedule()
    local response = fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_fast_select',
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

    restore_fast()

    assert.is_nil(response)
    assert.are.equal(0, picker_calls)
    assert.are.equal(2, #scheduled)

    for _, callback in ipairs(scheduled) do
        callback()
    end

    restore_select()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local approvals = api.approvals()

    assert.are.equal(1, picker_calls)
    assert.are.equal(1, #approvals)
    assert.are.equal('select', approvals[1].source)
    assert.are.equal('Allow once', approvals[1].selected_option_name)
    assert.is_true(vim.tbl_contains(lines, '- ✓ Approval [1] Run command'))
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
    assert.is_true(vim.tbl_contains(lines, '- ○ Approval [1] Delete file'))
    assert.is_true(vim.tbl_contains(lines, '  Outcome: `cancelled`'))
    assert.is_true(vim.tbl_contains(lines, '  Source: `select`'))
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

    assert.are.equal('- ✗ Approval [1] Write file', line)
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
    assert.are.equal('- ✗ Approval [1] Switch back', line)
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
    assert.is_false(vim.tbl_contains(lines, '## Config Options'))
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
    assert.is_false(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '- ○ Approval [1] Run command'))
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
    assert.is_not_nil(string.find(second_client.async_calls[1].params.prompt[1].text, '### User\nfirst turn', 1, true))
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
    assert.is_true(vim.tbl_contains(lines, '- ✓ Run command'))
    assert.is_false(vim.tbl_contains(lines, '- ◔ Run command'))
end)
