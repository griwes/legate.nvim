---@class acp.RpcClientImpl: acp.RpcClient
---@field command string[]
---@field cwd string?
---@field env table<string, string>
---@field timeout_ms integer
---@field on_notification fun(method: string, params: table)
---@field on_request fun(method: string, params: table, respond: fun(result?: any, error?: table))
---@field system? vim.SystemObj
---@field next_id integer
---@field pending table<integer, fun(result?: any, error?: table)>
---@field line_buffer string
---@field closed boolean
---@field stderr_chunks string[]

local M = {}
M.__index = M

---@param self acp.RpcClientImpl
---@return table?
local function request_transport_error(self)
    if self.system == nil then
        return {
            code = -32001,
            message = 'ACP RPC client is not started',
        }
    end

    if self.closed or self.system:is_closing() then
        return {
            code = -32001,
            message = 'ACP RPC transport is closed',
        }
    end

    return nil
end

---@param opts { command: string[], cwd?: string, env?: table<string, string>, timeout_ms?: integer, on_notification?: fun(method: string, params: table), on_request?: fun(method: string, params: table, respond: fun(result?: any, error?: table)) }
---@return acp.RpcClientImpl
function M.new(opts)
    return setmetatable({
        command = vim.deepcopy(opts.command),
        cwd = opts.cwd,
        env = vim.deepcopy(opts.env or {}),
        timeout_ms = opts.timeout_ms or 20000,
        on_notification = opts.on_notification or function() end,
        on_request = opts.on_request or function(_, _, respond)
            respond(nil, {
                code = -32601,
                message = 'Method not implemented by acp.nvim',
            })
        end,
        system = nil,
        next_id = 1,
        pending = {},
        line_buffer = '',
        closed = false,
        stderr_chunks = {},
    }, M)
end

---@param self acp.RpcClientImpl
---@param message table
local function write_message(self, message)
    if self.system == nil then
        error('ACP RPC client is not started')
    end

    self.system:write(vim.json.encode(message) .. '\n')
end

---@param self acp.RpcClientImpl
---@param id integer
---@param result? any
---@param rpc_error? table
local function respond(self, id, result, rpc_error)
    local message = {
        jsonrpc = '2.0',
        id = id,
    }

    if rpc_error ~= nil then
        message.error = rpc_error
    else
        message.result = result
    end

    write_message(self, message)
end

---@param self acp.RpcClientImpl
---@param message table
local function dispatch_message(self, message)
    if message.method ~= nil and message.id ~= nil then
        self.on_request(message.method, message.params or {}, function(result, rpc_error)
            respond(self, message.id, result, rpc_error)
        end)
        return
    end

    if message.method ~= nil then
        self.on_notification(message.method, message.params or {})
        return
    end

    if message.id ~= nil then
        local callback = self.pending[message.id]

        if callback == nil then
            return
        end

        self.pending[message.id] = nil
        callback(message.result, message.error)
    end
end

---@param self acp.RpcClientImpl
---@param err string?
---@param data string?
local function on_stdout(self, err, data)
    if err ~= nil then
        error(err)
    end

    if data ~= nil then
        self.line_buffer = self.line_buffer .. data
    end

    while true do
        local newline = self.line_buffer:find('\n', 1, true)

        if newline == nil then
            break
        end

        local line = self.line_buffer:sub(1, newline - 1)
        self.line_buffer = self.line_buffer:sub(newline + 1)

        if line ~= '' then
            local ok, message = pcall(vim.json.decode, line)

            if not ok then
                error(string.format('Failed to decode ACP JSON-RPC message: %s', message))
            end

            dispatch_message(self, message)
        end
    end

    if data == nil and self.line_buffer ~= '' then
        local ok, message = pcall(vim.json.decode, self.line_buffer)

        self.line_buffer = ''

        if ok then
            dispatch_message(self, message)
        end
    end
end

---@param self acp.RpcClientImpl
---@param err string?
---@param data string?
local function on_stderr(self, err, data)
    if err ~= nil then
        table.insert(self.stderr_chunks, err)
        return
    end

    if data ~= nil and data ~= '' then
        table.insert(self.stderr_chunks, data)
    end
end

---@param self acp.RpcClientImpl
local function fail_pending(self)
    local stderr_text = vim.trim(table.concat(self.stderr_chunks, ''))
    local message = 'ACP agent process exited unexpectedly'

    if stderr_text ~= '' then
        message = string.format('%s: %s', message, stderr_text)
    end

    for id, callback in pairs(self.pending) do
        self.pending[id] = nil
        callback(nil, {
            code = -32001,
            message = message,
        })
    end
end

---Start the ACP RPC client process.
---@return boolean, string?
function M:start()
    if self.system ~= nil then
        return true
    end

    local ok, system = pcall(vim.system, self.command, {
        cwd = self.cwd,
        env = self.env,
        stdin = true,
        stdout = function(err, data)
            on_stdout(self, err, data)
        end,
        stderr = function(err, data)
            on_stderr(self, err, data)
        end,
        text = true,
    }, function()
        self.closed = true
        fail_pending(self)
    end)

    if not ok then
        return false, system
    end

    self.closed = false

    self.system = system
    return true
end

---Send an ACP JSON-RPC request asynchronously.
---@param method string
---@param params table
---@param callback fun(result?: any, error?: table)
---@return integer
function M:request(method, params, callback)
    local transport_error = request_transport_error(self)

    if transport_error ~= nil then
        callback(nil, transport_error)
        return -1
    end

    local id = self.next_id
    self.next_id = self.next_id + 1
    self.pending[id] = callback

    write_message(self, {
        jsonrpc = '2.0',
        id = id,
        method = method,
        params = params,
    })

    return id
end

---Send an ACP JSON-RPC request and wait for the response.
---@param method string
---@param params table
---@param timeout_ms? integer
---@return any, table?
function M:request_sync(method, params, timeout_ms)
    local done = false
    local result = nil
    local rpc_error = nil

    local request_id = self:request(method, params, function(response, error)
        result = response
        rpc_error = error
        done = true
    end)

    if request_id == -1 then
        return result, rpc_error
    end

    local timeout = timeout_ms or self.timeout_ms
    local completed = vim.wait(timeout, function()
        return done
    end, 10)

    if not completed then
        self.pending[request_id] = nil
        return nil,
            {
                code = -32002,
                message = string.format('ACP request timed out: %s', method),
            }
    end

    return result, rpc_error
end

---Send an ACP JSON-RPC notification.
---@param method string
---@param params table
function M:notify(method, params)
    write_message(self, {
        jsonrpc = '2.0',
        method = method,
        params = params,
    })
end

---Close the ACP RPC client process.
function M:close()
    if self.system == nil then
        return
    end

    if not self.system:is_closing() then
        self.system:write(nil)
        self.system:kill('term')
    end

    self.system = nil
    self.closed = true
end

return M
