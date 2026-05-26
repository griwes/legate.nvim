local rpc = require('legate.core.rpc')

describe('acp rpc client', function()
    local original_system
    local original_notify

    local function install_fake_system()
        local captured = {
            writes = {},
            closing = false,
            killed = false,
        }

        vim.system = function(_, opts, on_exit)
            captured.opts = opts
            captured.on_exit = on_exit
            captured.system = {
                is_closing = function()
                    return captured.closing
                end,
                write = function(_, data)
                    table.insert(captured.writes, data)
                end,
                kill = function()
                    captured.killed = true
                    captured.closing = true
                end,
            }
            return captured.system
        end

        return captured
    end

    local function wait_until(predicate)
        assert.is_true(vim.wait(1000, predicate, 10))
    end

    before_each(function()
        original_system = vim.system
        original_notify = vim.notify
        vim.notify = function() end
        package.loaded['legate.core.rpc'] = nil
        rpc = require('legate.core.rpc')
    end)

    after_each(function()
        vim.system = original_system
        vim.notify = original_notify
    end)

    it('fails requests immediately after close', function()
        local client = rpc.new({ command = { 'cat' } })
        client.system = {
            is_closing = function()
                return false
            end,
        }
        client.closed = true

        local called = false
        local id = client:request('demo', {}, function(result, err)
            called = true
            assert.is_nil(result)
            assert.are.equal(-32001, err.code)
            assert.are.equal('ACP RPC transport is closed', err.message)
        end)

        assert.is_true(called)
        assert.are.equal(-1, id)
        assert.are.same({}, client.pending)
    end)

    it('fails requests immediately while process is closing', function()
        local client = rpc.new({ command = { 'cat' } })
        client.system = {
            is_closing = function()
                return true
            end,
        }

        local called = false
        local id = client:request('demo', {}, function(result, err)
            called = true
            assert.is_nil(result)
            assert.are.equal(-32001, err.code)
            assert.are.equal('ACP RPC transport is closed', err.message)
        end)

        assert.is_true(called)
        assert.are.equal(-1, id)
        assert.are.same({}, client.pending)
    end)

    it('fails sync requests immediately after close', function()
        local client = rpc.new({ command = { 'cat' } })
        client.system = {
            is_closing = function()
                return false
            end,
        }
        client.closed = true

        local result, err = client:request_sync('demo', {}, 10)

        assert.is_nil(result)
        assert.are.equal(-32001, err.code)
        assert.are.equal('ACP RPC transport is closed', err.message)
        assert.are.same({}, client.pending)
    end)

    it('fails sync requests immediately while process is closing', function()
        local client = rpc.new({ command = { 'cat' } })
        client.system = {
            is_closing = function()
                return true
            end,
        }

        local result, err = client:request_sync('demo', {}, 10)

        assert.is_nil(result)
        assert.are.equal(-32001, err.code)
        assert.are.equal('ACP RPC transport is closed', err.message)
        assert.are.same({}, client.pending)
    end)

    it('dispatches decoded responses outside the stdout callback', function()
        local captured = install_fake_system()
        local client = rpc.new({ command = { 'agent' } })
        assert.is_true(client:start())

        local result
        client:request('demo', {}, function(value)
            result = value
        end)

        captured.opts.stdout(nil, '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n')
        assert.is_nil(result)

        wait_until(function()
            return result ~= nil
        end)
        assert.are.same({ ok = true }, result)
    end)

    it('contains handler errors and continues dispatching later frames', function()
        local captured = install_fake_system()
        local client = rpc.new({
            command = { 'agent' },
            on_notification = function()
                error('notification failure')
            end,
        })
        assert.is_true(client:start())

        local result
        client:request('demo', {}, function(value)
            result = value
        end)

        local ok = pcall(
            captured.opts.stdout,
            nil,
            '{"jsonrpc":"2.0","method":"demo/event","params":{}}\n' .. '{"jsonrpc":"2.0","id":1,"result":"continued"}\n'
        )
        assert.is_true(ok)

        wait_until(function()
            return result ~= nil
        end)
        assert.are.equal('continued', result)
    end)

    it('returns an internal error when an inbound request handler fails', function()
        local captured = install_fake_system()
        local client = rpc.new({
            command = { 'agent' },
            on_request = function()
                error('request failure')
            end,
        })
        assert.is_true(client:start())

        captured.opts.stdout(nil, '{"jsonrpc":"2.0","id":7,"method":"demo/request","params":{}}\n')
        wait_until(function()
            return #captured.writes == 1
        end)

        local response = vim.json.decode(captured.writes[1])
        assert.are.equal(7, response.id)
        assert.are.equal(-32603, response.error.code)
    end)

    it('rejects non-object JSON-RPC messages and fails every pending request', function()
        local captured = install_fake_system()
        local client = rpc.new({ command = { 'agent' } })
        assert.is_true(client:start())

        local errors = {}
        client:request('first', {}, function(_, err)
            table.insert(errors, err)
        end)
        client:request('second', {}, function(_, err)
            table.insert(errors, err)
        end)

        assert.is_true(pcall(captured.opts.stdout, nil, '42\n'))
        wait_until(function()
            return #errors == 2
        end)

        assert.are.equal(-32600, errors[1].code)
        assert.are.equal(-32600, errors[2].code)
        assert.are.same({}, client.pending)
        assert.is_true(captured.killed)
    end)

    it('treats a malformed final frame as a fatal parse error', function()
        local captured = install_fake_system()
        local client = rpc.new({ command = { 'agent' } })
        assert.is_true(client:start())

        local rpc_error
        client:request('demo', {}, function(_, err)
            rpc_error = err
        end)

        captured.opts.stdout(nil, '{"jsonrpc":"2.0"')
        assert.is_true(pcall(captured.opts.stdout, nil, nil))
        wait_until(function()
            return rpc_error ~= nil
        end)

        assert.are.equal(-32700, rpc_error.code)
        assert.is_true(rpc_error.message:match('Failed to decode') ~= nil)
    end)

    it('bounds unterminated frames and retained stderr', function()
        local captured = install_fake_system()
        local client = rpc.new({
            command = { 'agent' },
            max_frame_bytes = 16,
            max_stderr_bytes = 8,
        })
        assert.is_true(client:start())

        captured.opts.stderr(nil, '0123456789abcdef')
        assert.are.equal(8, #client.stderr_buffer)
        assert.is_true(client.stderr_truncated)

        local rpc_error
        client:request('demo', {}, function(_, err)
            rpc_error = err
        end)
        captured.opts.stdout(nil, string.rep('x', 17))

        wait_until(function()
            return rpc_error ~= nil
        end)
        assert.are.equal(-32000, rpc_error.code)
        assert.is_true(rpc_error.message:match('exceeds 16 bytes') ~= nil)
    end)

    it('times out asynchronous requests and removes them', function()
        install_fake_system()
        local client = rpc.new({
            command = { 'agent' },
            timeout_ms = 20,
        })
        assert.is_true(client:start())

        local rpc_error
        client:request('slow', {}, function(_, err)
            rpc_error = err
        end)

        wait_until(function()
            return rpc_error ~= nil
        end)
        assert.are.equal(-32002, rpc_error.code)
        assert.are.same({}, client.pending)
    end)

    it('honors a sync timeout longer than the default asynchronous deadline', function()
        local captured = install_fake_system()
        local client = rpc.new({
            command = { 'agent' },
            timeout_ms = 20,
        })
        assert.is_true(client:start())

        vim.defer_fn(function()
            captured.opts.stdout(nil, '{"jsonrpc":"2.0","id":1,"result":"late"}\n')
        end, 40)

        local result, err = client:request_sync('demo', {}, 200)

        assert.is_nil(err)
        assert.are.equal('late', result)
    end)

    it('bounds one hundred unresolved inbound requests and releases accounting exactly once', function()
        local captured = install_fake_system()
        local responders = {}
        local client = rpc.new({
            command = { 'agent' },
            max_inbound_requests = 2,
            max_inbound_bytes = 1024,
            on_request = function(_, _, respond)
                table.insert(responders, respond)
            end,
        })
        assert.is_true(client:start())

        local frames = {}
        for id = 1, 100 do
            table.insert(frames, string.format('{"jsonrpc":"2.0","id":%d,"method":"demo/wait","params":{}}', id))
        end
        captured.opts.stdout(nil, table.concat(frames, '\n') .. '\n')

        wait_until(function()
            return #captured.writes == 98
        end)
        assert.are.equal(2, #responders)
        assert.are.equal(2, client.inbound_request_count)
        assert.is_true(client.inbound_request_bytes > 0)

        for _, encoded in ipairs(captured.writes) do
            local response = vim.json.decode(encoded)
            assert.are.equal(-32003, response.error.code)
        end

        responders[1]({ ok = 1 })
        responders[1]({ ignored = true })
        responders[2]({ ok = 2 })

        assert.are.equal(0, client.inbound_request_count)
        assert.are.equal(0, client.inbound_request_bytes)
        assert.are.equal(100, #captured.writes)
    end)

    it('bounds active inbound request bytes independently of request count', function()
        local captured = install_fake_system()
        local responders = {}
        local frame = '{"jsonrpc":"2.0","id":1,"method":"demo/wait","params":{"value":"1234567890"}}'
        local client = rpc.new({
            command = { 'agent' },
            max_inbound_requests = 10,
            max_inbound_bytes = #frame,
            on_request = function(_, _, respond)
                table.insert(responders, respond)
            end,
        })
        assert.is_true(client:start())

        captured.opts.stdout(nil, frame .. '\n' .. frame:gsub('"id":1', '"id":2') .. '\n')

        wait_until(function()
            return #captured.writes == 1
        end)
        assert.are.equal(1, #responders)
        assert.are.equal(1, client.inbound_request_count)
        assert.are.equal(-32003, vim.json.decode(captured.writes[1]).error.code)
        responders[1]({})
        assert.are.equal(0, client.inbound_request_bytes)
    end)

    it('cancels and removes an inbound request on deadline', function()
        local captured = install_fake_system()
        local cancelled = 0
        local late_respond
        local client = rpc.new({
            command = { 'agent' },
            inbound_request_timeout_ms = 20,
            on_request = function(_, _, respond, control)
                late_respond = respond
                control.on_cancel(function()
                    cancelled = cancelled + 1
                end)
            end,
        })
        assert.is_true(client:start())

        captured.opts.stdout(nil, '{"jsonrpc":"2.0","id":1,"method":"demo/wait","params":{}}\n')
        wait_until(function()
            return cancelled == 1 and #captured.writes == 1
        end)

        assert.are.equal(0, client.inbound_request_count)
        assert.are.equal(-32002, vim.json.decode(captured.writes[1]).error.code)
        late_respond({ ignored = true })
        assert.are.equal(1, #captured.writes)
        assert.are.equal(0, client.inbound_request_count)
    end)

    it('cancels active inbound handlers on fatal framing failure and close', function()
        local captured = install_fake_system()
        local cancelled = 0
        local client = rpc.new({
            command = { 'agent' },
            on_request = function(_, _, _, control)
                control.on_cancel(function()
                    cancelled = cancelled + 1
                end)
            end,
        })
        assert.is_true(client:start())

        captured.opts.stdout(nil, '{"jsonrpc":"2.0","id":1,"method":"demo/wait","params":{}}\n')
        wait_until(function()
            return client.inbound_request_count == 1
        end)
        captured.opts.stdout(nil, 'not-json\n')
        wait_until(function()
            return cancelled == 1
        end)

        assert.are.equal(0, client.inbound_request_count)
        assert.are.equal(0, client.inbound_request_bytes)
        assert.is_true(captured.killed)

        local second = install_fake_system()
        local close_cancelled = 0
        local close_client = rpc.new({
            command = { 'agent' },
            on_request = function(_, _, _, control)
                control.on_cancel(function()
                    close_cancelled = close_cancelled + 1
                end)
            end,
        })
        assert.is_true(close_client:start())
        second.opts.stdout(nil, '{"jsonrpc":"2.0","id":2,"method":"demo/wait","params":{}}\n')
        wait_until(function()
            return close_client.inbound_request_count == 1
        end)
        close_client:close()

        assert.are.equal(1, close_cancelled)
        assert.are.equal(0, close_client.inbound_request_count)
    end)

    it('rejects unsafe and fractional numeric ids while preserving string ids exactly', function()
        local captured = install_fake_system()
        local client = rpc.new({
            command = { 'agent' },
            on_request = function(_, _, respond)
                respond({ ok = true })
            end,
        })
        assert.is_true(client:start())

        captured.opts.stdout(nil, '{"jsonrpc":"2.0","id":"9007199254740993","method":"demo","params":{}}\n')
        wait_until(function()
            return #captured.writes == 1
        end)
        assert.are.equal('9007199254740993', vim.json.decode(captured.writes[1]).id)

        captured.opts.stdout(nil, '{"jsonrpc":"2.0","id":9007199254740992,"method":"demo","params":{}}\n')
        wait_until(function()
            return client.failure_error ~= nil
        end)
        assert.are.equal(-32600, client.failure_error.code)

        local fractional = install_fake_system()
        local fractional_client = rpc.new({ command = { 'agent' } })
        assert.is_true(fractional_client:start())
        fractional.opts.stdout(nil, '{"jsonrpc":"2.0","id":1.5,"method":"demo","params":{}}\n')
        wait_until(function()
            return fractional_client.failure_error ~= nil
        end)
        assert.are.equal(-32600, fractional_client.failure_error.code)
    end)
end)
