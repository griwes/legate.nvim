local DEFAULT_MAX_FRAME_BYTES = 4 * 1024 * 1024
local DEFAULT_MAX_QUEUED_BYTES = 8 * 1024 * 1024
local DEFAULT_MAX_STDERR_BYTES = 64 * 1024
local DEFAULT_MAX_INBOUND_REQUESTS = 64
local DEFAULT_MAX_INBOUND_BYTES = 8 * 1024 * 1024
local MAX_SAFE_JSON_INTEGER = 9007199254740991

---@class legate.RpcPendingRequest
---@field callback fun(result?: any, error?: table)
---@field method string

---@class legate.RpcQueuedMessage
---@field message table
---@field bytes integer

---@class legate.RpcInboundRequest
---@field ordinal integer
---@field id string|number
---@field method string
---@field bytes integer
---@field done boolean
---@field cancelled boolean
---@field cancel_error? table
---@field cancel_callbacks function[]
---@field timer? uv.uv_timer_t

---@class legate.RpcInboundRequestControl
---@field on_cancel fun(callback: function)
---@field is_active fun(): boolean

---@class legate.RpcClientImpl: legate.RpcClient
---@field command string[]
---@field cwd string?
---@field env table<string, string>
---@field timeout_ms integer
---@field max_frame_bytes integer
---@field max_queued_bytes integer
---@field max_stderr_bytes integer
---@field max_inbound_requests integer
---@field max_inbound_bytes integer
---@field inbound_request_timeout_ms integer
---@field on_notification fun(method: string, params: table)
---@field on_request fun(method: string, params: table, respond: fun(result?: any, error?: table), control: legate.RpcInboundRequestControl)
---@field system? vim.SystemObj
---@field process_generation integer
---@field next_id integer
---@field pending table<integer, legate.RpcPendingRequest>
---@field line_buffer string
---@field message_queue legate.RpcQueuedMessage[]
---@field queued_bytes integer
---@field dispatch_scheduled boolean
---@field closed boolean
---@field failure_error? table
---@field stderr_buffer string
---@field stderr_truncated boolean
---@field next_inbound_ordinal integer
---@field inbound_requests table<integer, legate.RpcInboundRequest>
---@field inbound_request_count integer
---@field inbound_request_bytes integer

local M = {}
M.__index = M

---@param value any
---@param fallback integer
---@return integer
local function positive_limit(value, fallback)
    local number = tonumber(value)

    if number == nil or number ~= number or number == math.huge or number == -math.huge or number < 1 then
        return fallback
    end

    return math.floor(number)
end

---@param message string
---@param code? integer
---@return table
local function transport_error(message, code)
    return {
        code = code or -32001,
        message = message,
    }
end

---@param message string
local function report_callback_error(message)
    pcall(vim.notify, message, vim.log.levels.ERROR)
end

---@param callback function
---@param ... any
local function invoke_callback(callback, ...)
    local args = { n = select('#', ...), ... }
    local function invoke()
        local ok, callback_error = xpcall(function()
            callback(unpack(args, 1, args.n))
        end, debug.traceback)

        if not ok then
            report_callback_error(string.format('ACP RPC callback failed: %s', callback_error))
        end
    end

    if vim.in_fast_event() then
        vim.schedule(invoke)
    else
        invoke()
    end
end

---@param self legate.RpcClientImpl
---@return table?
local function request_transport_error(self)
    if self.system == nil then
        return transport_error('ACP RPC client is not started')
    end

    local closing_ok, closing = pcall(self.system.is_closing, self.system)

    if self.closed or not closing_ok or closing then
        return transport_error('ACP RPC transport is closed')
    end

    return nil
end

---@param opts { command: string[], cwd?: string, env?: table<string, string>, timeout_ms?: integer, max_frame_bytes?: integer, max_queued_bytes?: integer, max_stderr_bytes?: integer, max_inbound_requests?: integer, max_inbound_bytes?: integer, inbound_request_timeout_ms?: integer, on_notification?: fun(method: string, params: table), on_request?: fun(method: string, params: table, respond: fun(result?: any, error?: table), control: legate.RpcInboundRequestControl) }
---@return legate.RpcClientImpl
function M.new(opts)
    local timeout_ms = positive_limit(opts.timeout_ms, 20000)

    return setmetatable({
        command = vim.deepcopy(opts.command),
        cwd = opts.cwd,
        env = vim.deepcopy(opts.env or {}),
        timeout_ms = timeout_ms,
        max_frame_bytes = positive_limit(opts.max_frame_bytes, DEFAULT_MAX_FRAME_BYTES),
        max_queued_bytes = positive_limit(opts.max_queued_bytes, DEFAULT_MAX_QUEUED_BYTES),
        max_stderr_bytes = positive_limit(opts.max_stderr_bytes, DEFAULT_MAX_STDERR_BYTES),
        max_inbound_requests = positive_limit(opts.max_inbound_requests, DEFAULT_MAX_INBOUND_REQUESTS),
        max_inbound_bytes = positive_limit(opts.max_inbound_bytes, DEFAULT_MAX_INBOUND_BYTES),
        inbound_request_timeout_ms = positive_limit(opts.inbound_request_timeout_ms, timeout_ms),
        on_notification = opts.on_notification or function() end,
        on_request = opts.on_request or function(_, _, respond)
            respond(nil, {
                code = -32601,
                message = 'Method not implemented by legate.nvim',
            })
        end,
        system = nil,
        process_generation = 0,
        next_id = 1,
        pending = {},
        line_buffer = '',
        message_queue = {},
        queued_bytes = 0,
        dispatch_scheduled = false,
        closed = false,
        failure_error = nil,
        stderr_buffer = '',
        stderr_truncated = false,
        next_inbound_ordinal = 1,
        inbound_requests = {},
        inbound_request_count = 0,
        inbound_request_bytes = 0,
    }, M)
end

---@param self legate.RpcClientImpl
---@param rpc_error table
local function fail_pending(self, rpc_error)
    local pending = self.pending
    self.pending = {}

    for _, request in pairs(pending) do
        invoke_callback(request.callback, nil, vim.deepcopy(rpc_error))
    end
end

---@param self legate.RpcClientImpl
---@param rpc_error table
local cancel_all_inbound

---@param self legate.RpcClientImpl
---@param rpc_error table
local function fail_transport(self, rpc_error)
    if self.failure_error ~= nil then
        return
    end

    self.failure_error = rpc_error
    self.closed = true
    self.line_buffer = ''
    self.message_queue = {}
    self.queued_bytes = 0
    self.dispatch_scheduled = false
    local generation = self.process_generation

    vim.schedule(function()
        if generation ~= self.process_generation then
            return
        end

        local system = self.system

        if system ~= nil then
            local closing_ok, closing = pcall(system.is_closing, system)

            if not closing_ok or not closing then
                pcall(system.write, system, nil)
                pcall(system.kill, system, 'term')
            end
        end

        self.system = nil
        cancel_all_inbound(self, rpc_error)
        fail_pending(self, rpc_error)
    end)
end

---@param self legate.RpcClientImpl
---@param message table
---@return boolean, table?
local function write_message(self, message)
    local unavailable = request_transport_error(self)

    if unavailable ~= nil then
        return false, unavailable
    end

    local encoded_ok, encoded = pcall(vim.json.encode, message)

    if not encoded_ok then
        return false, transport_error(string.format('Failed to encode ACP JSON-RPC message: %s', encoded))
    end

    local write_ok, write_error = pcall(self.system.write, self.system, encoded .. '\n')

    if not write_ok then
        return false, transport_error(string.format('Failed to write ACP JSON-RPC message: %s', write_error))
    end

    return true, nil
end

---@param self legate.RpcClientImpl
---@param id string|number
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
        message.result = result == nil and vim.NIL or result
    end

    local written, write_error = write_message(self, message)

    if not written then
        fail_transport(self, write_error)
    end
end

---@param value any
---@return boolean
local function valid_json_rpc_id(value)
    if type(value) == 'string' then
        return true
    end

    if type(value) ~= 'number' then
        return false
    end

    return value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math.floor(value)
        and math.abs(value) <= MAX_SAFE_JSON_INTEGER
end

---@param message any
---@return boolean, string?
local function validate_message(message)
    if type(message) ~= 'table' then
        return false, 'decoded value is not an object'
    end

    if message.jsonrpc ~= '2.0' then
        return false, 'jsonrpc must be "2.0"'
    end

    if message.method ~= nil then
        if type(message.method) ~= 'string' then
            return false, 'method must be a string'
        end

        if message.params ~= nil and type(message.params) ~= 'table' then
            return false, 'params must be an object or array'
        end

        if message.id ~= nil and not valid_json_rpc_id(message.id) then
            return false, 'request id must be a string or safe integer'
        end

        return true, nil
    end

    if not valid_json_rpc_id(message.id) then
        return false, 'response id must be a string or safe integer'
    end

    local has_result = message.result ~= nil
    local has_error = message.error ~= nil

    if has_result == has_error then
        return false, 'response must contain exactly one of result or error'
    end

    if has_error then
        if type(message.error) ~= 'table' then
            return false, 'response error must be an object'
        end

        if type(message.error.code) ~= 'number' or type(message.error.message) ~= 'string' then
            return false, 'response error must contain numeric code and string message'
        end
    end

    return true, nil
end

---@param timer? uv.uv_timer_t
local function close_timer(timer)
    if timer == nil then
        return
    end

    pcall(timer.stop, timer)
    local closing_ok, closing = pcall(timer.is_closing, timer)

    if not closing_ok or not closing then
        pcall(timer.close, timer)
    end
end

---@param self legate.RpcClientImpl
---@param request legate.RpcInboundRequest
---@return boolean
local function release_inbound(self, request)
    if request.done then
        return false
    end

    request.done = true
    close_timer(request.timer)
    request.timer = nil

    if self.inbound_requests[request.ordinal] == request then
        self.inbound_requests[request.ordinal] = nil
        self.inbound_request_count = math.max(self.inbound_request_count - 1, 0)
        self.inbound_request_bytes = math.max(self.inbound_request_bytes - request.bytes, 0)
    end

    return true
end

---@param self legate.RpcClientImpl
---@param request legate.RpcInboundRequest
---@param rpc_error table
---@param send_response boolean
local function cancel_inbound(self, request, rpc_error, send_response)
    if not release_inbound(self, request) then
        return
    end

    request.cancelled = true
    request.cancel_error = rpc_error
    local callbacks = request.cancel_callbacks
    request.cancel_callbacks = {}

    for _, callback in ipairs(callbacks) do
        invoke_callback(callback, vim.deepcopy(rpc_error))
    end

    if send_response and self.failure_error == nil and not self.closed then
        respond(self, request.id, nil, rpc_error)
    end
end

cancel_all_inbound = function(self, rpc_error)
    local requests = {}

    for _, request in pairs(self.inbound_requests) do
        table.insert(requests, request)
    end

    for _, request in ipairs(requests) do
        cancel_inbound(self, request, rpc_error, false)
    end
end

---@param self legate.RpcClientImpl
---@param message table
---@param bytes integer
---@return legate.RpcInboundRequest?, table?
local function reserve_inbound(self, message, bytes)
    if self.inbound_request_count >= self.max_inbound_requests then
        return nil,
            transport_error(string.format('ACP inbound request count exceeds %d', self.max_inbound_requests), -32003)
    end

    if self.inbound_request_bytes + bytes > self.max_inbound_bytes then
        return nil,
            transport_error(string.format('ACP inbound request bytes exceed %d', self.max_inbound_bytes), -32003)
    end

    local request = {
        ordinal = self.next_inbound_ordinal,
        id = message.id,
        method = message.method,
        bytes = bytes,
        done = false,
        cancelled = false,
        cancel_callbacks = {},
        timer = nil,
    }
    self.next_inbound_ordinal = self.next_inbound_ordinal + 1
    self.inbound_requests[request.ordinal] = request
    self.inbound_request_count = self.inbound_request_count + 1
    self.inbound_request_bytes = self.inbound_request_bytes + bytes

    return request, nil
end

---@param self legate.RpcClientImpl
---@param request legate.RpcInboundRequest
---@return legate.RpcInboundRequestControl
local function inbound_control(self, request)
    return {
        on_cancel = function(callback)
            if type(callback) ~= 'function' then
                error('ACP inbound cancellation callback must be a function')
            end

            if request.done then
                if request.cancelled then
                    invoke_callback(callback, vim.deepcopy(request.cancel_error))
                end
                return
            end

            table.insert(request.cancel_callbacks, callback)
        end,
        is_active = function()
            return not request.done
        end,
    }
end

---@param self legate.RpcClientImpl
---@param request legate.RpcInboundRequest
local function arm_inbound_deadline(self, request)
    local timer = vim.uv.new_timer()
    request.timer = timer
    timer:start(self.inbound_request_timeout_ms, 0, function()
        vim.schedule(function()
            cancel_inbound(
                self,
                request,
                transport_error(string.format('ACP inbound request timed out: %s', request.method), -32002),
                true
            )
        end)
    end)
end

---@param self legate.RpcClientImpl
---@param message table
---@param bytes integer
local function dispatch_message(self, message, bytes)
    if message.method ~= nil and message.id ~= nil then
        local request, limit_error = reserve_inbound(self, message, bytes)

        if request == nil then
            respond(self, message.id, nil, limit_error)
            return
        end

        local function respond_once(result, rpc_error)
            if not release_inbound(self, request) then
                return
            end

            respond(self, message.id, result, rpc_error)
        end

        arm_inbound_deadline(self, request)

        local ok, handler_error = xpcall(function()
            self.on_request(message.method, message.params or {}, respond_once, inbound_control(self, request))
        end, debug.traceback)

        if not ok then
            if request.done then
                report_callback_error(string.format('ACP RPC request handler failed: %s', handler_error))
            else
                respond_once(nil, {
                    code = -32603,
                    message = 'Internal error while handling ACP request',
                })
            end
        end
        return
    end

    if message.method ~= nil then
        local ok, handler_error = xpcall(function()
            self.on_notification(message.method, message.params or {})
        end, debug.traceback)

        if not ok then
            report_callback_error(string.format('ACP RPC notification handler failed: %s', handler_error))
        end
        return
    end

    local request = self.pending[message.id]

    if request == nil then
        return
    end

    self.pending[message.id] = nil
    invoke_callback(request.callback, message.result, message.error)
end

---@param self legate.RpcClientImpl
local function schedule_dispatch(self)
    if self.dispatch_scheduled then
        return
    end

    self.dispatch_scheduled = true
    local generation = self.process_generation

    vim.schedule(function()
        if generation ~= self.process_generation or self.failure_error ~= nil or self.closed then
            return
        end

        local queue = self.message_queue
        self.message_queue = {}
        self.queued_bytes = 0
        self.dispatch_scheduled = false

        for _, queued in ipairs(queue) do
            if generation ~= self.process_generation or self.failure_error ~= nil or self.closed then
                break
            end

            dispatch_message(self, queued.message, queued.bytes)
        end

        if #self.message_queue > 0 then
            schedule_dispatch(self)
        end
    end)
end

---@param self legate.RpcClientImpl
---@param line string
---@return boolean
local function queue_frame(self, line)
    if #line > self.max_frame_bytes then
        fail_transport(
            self,
            transport_error(string.format('ACP JSON-RPC frame exceeds %d bytes', self.max_frame_bytes), -32000)
        )
        return false
    end

    local decoded_ok, message = pcall(vim.json.decode, line)

    if not decoded_ok then
        fail_transport(
            self,
            transport_error(string.format('Failed to decode ACP JSON-RPC message: %s', message), -32700)
        )
        return false
    end

    local valid, validation_error = validate_message(message)

    if not valid then
        fail_transport(
            self,
            transport_error(string.format('Invalid ACP JSON-RPC message: %s', validation_error), -32600)
        )
        return false
    end

    if self.queued_bytes + #line > self.max_queued_bytes then
        fail_transport(
            self,
            transport_error(
                string.format('ACP JSON-RPC dispatch queue exceeds %d bytes', self.max_queued_bytes),
                -32000
            )
        )
        return false
    end

    table.insert(self.message_queue, {
        message = message,
        bytes = #line,
    })
    self.queued_bytes = self.queued_bytes + #line
    schedule_dispatch(self)
    return true
end

---@param self legate.RpcClientImpl
---@param err string?
---@param data string?
local function on_stdout(self, err, data)
    if self.failure_error ~= nil then
        return
    end

    if err ~= nil then
        fail_transport(self, transport_error(string.format('Failed to read ACP agent stdout: %s', err)))
        return
    end

    if data ~= nil then
        self.line_buffer = self.line_buffer .. data
    end

    while self.failure_error == nil do
        local newline = self.line_buffer:find('\n', 1, true)

        if newline == nil then
            break
        end

        local line = self.line_buffer:sub(1, newline - 1)
        self.line_buffer = self.line_buffer:sub(newline + 1)

        if line ~= '' and not queue_frame(self, line) then
            return
        end
    end

    if self.failure_error ~= nil then
        return
    end

    if data == nil and self.line_buffer ~= '' then
        local final_frame = self.line_buffer
        self.line_buffer = ''
        queue_frame(self, final_frame)
        return
    end

    if #self.line_buffer > self.max_frame_bytes then
        fail_transport(
            self,
            transport_error(string.format('ACP JSON-RPC frame exceeds %d bytes', self.max_frame_bytes), -32000)
        )
    end
end

---@param self legate.RpcClientImpl
---@param chunk string
local function append_stderr(self, chunk)
    if chunk == '' then
        return
    end

    local combined = self.stderr_buffer .. chunk

    if #combined > self.max_stderr_bytes then
        self.stderr_truncated = true
        combined = combined:sub(#combined - self.max_stderr_bytes + 1)
    end

    self.stderr_buffer = combined
end

---@param self legate.RpcClientImpl
---@param err string?
---@param data string?
local function on_stderr(self, err, data)
    if err ~= nil then
        append_stderr(self, err)
    end

    if data ~= nil then
        append_stderr(self, data)
    end
end

---@param self legate.RpcClientImpl
---@return table
local function process_exit_error(self)
    local stderr_text = vim.trim(self.stderr_buffer)
    local message = 'ACP agent process exited unexpectedly'

    if stderr_text ~= '' then
        local prefix = self.stderr_truncated and '[truncated] ' or ''
        message = string.format('%s: %s%s', message, prefix, stderr_text)
    end

    return transport_error(message)
end

---Start the ACP RPC client process.
---@return boolean, string?
function M:start()
    if self.system ~= nil then
        return true
    end

    self.process_generation = self.process_generation + 1
    local generation = self.process_generation
    self.line_buffer = ''
    self.message_queue = {}
    self.queued_bytes = 0
    self.dispatch_scheduled = false
    self.failure_error = nil
    self.stderr_buffer = ''
    self.stderr_truncated = false

    local ok, system = pcall(vim.system, self.command, {
        cwd = self.cwd,
        env = self.env,
        stdin = true,
        stdout = function(err, data)
            if generation == self.process_generation then
                on_stdout(self, err, data)
            end
        end,
        stderr = function(err, data)
            if generation == self.process_generation then
                on_stderr(self, err, data)
            end
        end,
        text = true,
    }, function()
        vim.schedule(function()
            if generation ~= self.process_generation then
                return
            end

            self.closed = true
            self.system = nil
            self.line_buffer = ''
            self.message_queue = {}
            self.queued_bytes = 0
            self.dispatch_scheduled = false

            if self.failure_error == nil then
                local exit_error = process_exit_error(self)
                self.failure_error = exit_error
                cancel_all_inbound(self, exit_error)
                fail_pending(self, exit_error)
            end
        end)
    end)

    if not ok then
        return false, tostring(system)
    end

    self.closed = false
    self.system = system
    return true
end

---@param self legate.RpcClientImpl
---@param id integer
---@param method string
---@param timeout_ms integer
local function arm_request_deadline(self, id, method, timeout_ms)
    vim.defer_fn(function()
        local request = self.pending[id]

        if request == nil then
            return
        end

        self.pending[id] = nil
        invoke_callback(request.callback, nil, {
            code = -32002,
            message = string.format('ACP request timed out: %s', method),
        })
    end, timeout_ms)
end

---Send an ACP JSON-RPC request asynchronously.
---@param method string
---@param params table
---@param callback fun(result?: any, error?: table)
---@param timeout_ms? integer
---@return integer
function M:request(method, params, callback, timeout_ms)
    local unavailable = request_transport_error(self)

    if unavailable ~= nil then
        invoke_callback(callback, nil, unavailable)
        return -1
    end

    local id = self.next_id
    self.next_id = self.next_id + 1
    self.pending[id] = {
        callback = callback,
        method = method,
    }

    local written, write_error = write_message(self, {
        jsonrpc = '2.0',
        id = id,
        method = method,
        params = params,
    })

    if not written then
        self.pending[id] = nil
        invoke_callback(callback, nil, write_error)
        fail_transport(self, write_error)
        return -1
    end

    arm_request_deadline(self, id, method, positive_limit(timeout_ms, self.timeout_ms))
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

    local timeout = positive_limit(timeout_ms, self.timeout_ms)
    local request_id = self:request(method, params, function(response, error)
        result = response
        rpc_error = error
        done = true
    end, timeout)

    if request_id == -1 then
        return result, rpc_error
    end

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
---@return boolean, table?
function M:notify(method, params)
    local written, write_error = write_message(self, {
        jsonrpc = '2.0',
        method = method,
        params = params,
    })

    if not written then
        fail_transport(self, write_error)
    end

    return written, write_error
end

---Close the ACP RPC client process and fail any outstanding requests.
function M:close()
    local system = self.system
    self.process_generation = self.process_generation + 1
    self.system = nil
    self.closed = true
    self.failure_error = transport_error('ACP RPC transport is closed')
    self.line_buffer = ''
    self.message_queue = {}
    self.queued_bytes = 0
    self.dispatch_scheduled = false
    cancel_all_inbound(self, self.failure_error)

    if system ~= nil then
        local closing_ok, closing = pcall(system.is_closing, system)

        if not closing_ok or not closing then
            pcall(system.write, system, nil)
            pcall(system.kill, system, 'term')
        end
    end

    fail_pending(self, self.failure_error)
end

return M
