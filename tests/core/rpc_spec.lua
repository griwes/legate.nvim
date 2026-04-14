local rpc = require('legate.core.rpc')

describe('acp rpc client', function()
    before_each(function()
        package.loaded['legate.core.rpc'] = nil
        rpc = require('legate.core.rpc')
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
end)
