local function submit_direct(prompt)
    api.set_prompt(prompt)
    return api.submit_prompt()
end

it('queues submitted prompts while a turn is running', function()
    local bufnr = api.open_chat()

    submit_direct('first turn')
    api.set_prompt('queued turn')
    api.submit_prompt_async()

    local session = api.current_session()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('waiting', session.status)
    assert.are.same({ 'queued turn' }, session.queued_prompts)
    assert.are.equal(1, #fake_client.async_calls)
    assert.is_true(vim.tbl_contains(lines, '## Queue'))
    assert.is_true(vim.tbl_contains(lines, '1. queued turn'))
end)

it('drains one queued prompt after a normal turn finish', function()
    submit_direct('first turn')
    api.set_prompt('queued turn')
    api.submit_prompt_async()

    fake_client:resolve({
        stopReason = 'end_turn',
    })

    wait_until(function()
        return api.current_session().pending_prompt == 'queued turn'
    end)

    local session = api.current_session()

    assert.are.equal('waiting', session.status)
    assert.are.equal('queued turn', session.pending_prompt)
    assert.are.same({}, session.queued_prompts)
    assert.are.equal('session/prompt', fake_client.async_calls[#fake_client.async_calls].method)
end)

it('keeps queued prompts after a cancelled turn', function()
    submit_direct('first turn')
    api.set_prompt('queued turn')
    api.submit_prompt_async()

    fake_client:resolve({
        stopReason = 'cancelled',
    })

    vim.wait(50)

    local session = api.current_session()

    assert.are.equal('cancelled', session.status)
    assert.are.same({ 'queued turn' }, session.queued_prompts)
    assert.are.equal(1, #fake_client.async_calls)
end)

it('drains queued prompts from another selected session after the running turn finishes', function()
    local first = submit_direct('first turn')
    local second = api.new_session()

    api.set_prompt('queued on second')
    api.submit_prompt_async()

    assert.are.same({ 'queued on second' }, second.queued_prompts)

    fake_client:resolve({
        stopReason = 'end_turn',
    })

    wait_until(function()
        return second.pending_prompt == 'queued on second'
    end)

    assert.are.equal('idle', first.status)
    assert.are.equal('waiting', second.status)
    assert.are.same({}, second.queued_prompts)
end)

it('sends live steering without finishing the running turn', function()
    local bufnr = api.open_chat()

    submit_direct('first turn')
    api.set_prompt('please steer this turn')
    api.steer_prompt()

    local session = api.current_session()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('waiting', session.status)
    assert.are.equal(2, #fake_client.async_calls)
    assert.is_true(vim.tbl_contains(lines, 'please steer this turn'))
    assert.matches('please steer this turn', fake_client.async_calls[2].params.prompt[1].text)

    fake_client:resolve({
        stopReason = 'end_turn',
    }, nil, 2)

    assert.are.equal('waiting', session.status)

    fake_client:resolve({
        stopReason = 'end_turn',
    })

    assert.are.equal('idle', session.status)
end)

it('registers explicit queue steer and interrupt commands', function()
    local commands = vim.api.nvim_get_commands({
        builtin = false,
    })

    assert.is_not_nil(commands.LegateQueue)
    assert.is_not_nil(commands.LegateSteer)
    assert.is_not_nil(commands.LegateInterrupt)
end)

it('interrupts the active turn through the command surface', function()
    submit_direct('first turn')

    vim.cmd('LegateInterrupt')

    assert.are.equal('session/cancel', fake_client.notifications[1].method)
    assert.are.equal('cancelled', api.current_session().status)
end)

it('persists queued prompts with local session state', function()
    local continuity = require('legate.session')

    api.open_chat()
    api.set_prompt('queued for later')
    api.queue_prompt()

    local snapshot = continuity.snapshot()

    api.clear()
    continuity.restore(snapshot)

    assert.are.same({ 'queued for later' }, api.current_session().queued_prompts)
end)
