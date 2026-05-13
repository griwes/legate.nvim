local config = require('legate.config')

---@class legate.TerminalModule
local M = {}

local REQUEST_ERROR_CODE = -32000

---@class legate.NativeTerminalState
---@field handle legate.TerminalHandle
---@field system vim.SystemObj
---@field output string
---@field truncated boolean
---@field output_byte_limit integer?
---@field exit_status legate.TerminalExitStatus?
---@field preview_bufnr integer?

---@type table<string, legate.NativeTerminalState>
local terminals = {}
---@class legate.TerminaliaTerminalState
---@field handle legate.TerminalHandle
---@field output_byte_limit integer?

---@type table<string, legate.TerminaliaTerminalState>
local terminalia_terminals = {}
local next_terminal_ordinal = 1
local terminalia_module_name = 'terminalia'

---@param message string
---@return table
local function request_error(message)
    return {
        code = REQUEST_ERROR_CODE,
        message = message,
    }
end

---@param path string?
---@return string?, table?
local function validate_absolute_path(path)
    if path == nil then
        return nil, nil
    end

    if path:sub(1, 1) ~= '/' then
        return nil, request_error(string.format('ACP terminal cwd must be absolute: %s', path))
    end

    return path, nil
end

---@param signal integer
---@return string?
local function normalize_signal(signal)
    if signal == 0 then
        return nil
    end

    local known = {
        [1] = 'HUP',
        [2] = 'INT',
        [3] = 'QUIT',
        [6] = 'ABRT',
        [9] = 'KILL',
        [15] = 'TERM',
    }

    return known[signal] or tostring(signal)
end

---@param result vim.SystemCompleted
---@return legate.TerminalExitStatus
local function exit_status_from_result(result)
    if result.signal ~= nil and result.signal ~= 0 then
        return {
            exitCode = nil,
            signal = normalize_signal(result.signal),
        }
    end

    return {
        exitCode = result.code,
        signal = nil,
    }
end

---@param output string
---@param limit integer?
---@return string, boolean
local function trim_output(output, limit)
    if limit == nil or limit < 0 or #output <= limit then
        return output, false
    end

    if limit == 0 then
        return '', true
    end

    local start = #output - limit + 1

    if start > #output then
        return '', true
    end

    if vim.str_utf_start(output, start) ~= 0 then
        start = start + vim.str_utf_end(output, start) + 1
    end

    if start > #output then
        return '', true
    end

    return output:sub(start), true
end

---@param state legate.NativeTerminalState
local function update_preview(state)
    local bufnr = state.preview_bufnr

    if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        local lines = state.output == '' and {} or vim.split(state.output, '\n', {
            plain = true,
        })

        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modifiable = false
    end)
end

---@param state legate.NativeTerminalState
---@param data string?
local function append_output(state, data)
    if data == nil or data == '' then
        return
    end

    local next_output = state.output .. data
    local was_truncated
    next_output, was_truncated = trim_output(next_output, state.output_byte_limit)
    state.truncated = state.truncated or was_truncated
    state.output = next_output
    update_preview(state)
end

---@param env legate.EnvVariable[]?
---@return table<string, string>?
local function env_map(env)
    if env == nil then
        return nil
    end

    local mapped = {}

    for _, variable in ipairs(env) do
        mapped[variable.name] = variable.value
    end

    return mapped
end

---@param terminal_id string
---@param session_id string
---@return legate.TerminalHandle
local function request_handle(terminal_id, session_id)
    return {
        id = terminal_id,
        backend = M.resolve().name,
        session_id = session_id,
    }
end

---@param handle legate.TerminalHandle
---@return legate.TerminaliaTerminalState?, table?
local function terminalia_state(handle)
    local state = terminalia_terminals[handle.id]

    if state == nil then
        return nil, request_error(string.format('Unknown ACP terminal id: %s', handle.id))
    end

    if handle.session_id ~= nil and state.handle.session_id ~= handle.session_id then
        return nil,
            request_error(string.format('ACP terminal %s does not belong to session %s', handle.id, handle.session_id))
    end

    return state, nil
end

---@return table
local function terminalia_api()
    local ok, terminalia = pcall(require, terminalia_module_name)

    if not ok then
        error('ACP terminalia backend requires terminalia.nvim to be installed')
    end

    return terminalia.api
end

---@param state legate.NativeTerminalState
---@return fun(err: string?, data: string?)
local function output_callback(state)
    return function(err, data)
        if err ~= nil then
            append_output(state, err)
        end

        append_output(state, data)
    end
end

---@param handle legate.TerminalHandle
---@return legate.NativeTerminalState?, table?
local function terminal_state(handle)
    local state = terminals[handle.id]

    if state == nil then
        return nil, request_error(string.format('Unknown ACP terminal id: %s', handle.id))
    end

    if handle.session_id ~= nil and state.handle.session_id ~= handle.session_id then
        return nil,
            request_error(string.format('ACP terminal %s does not belong to session %s', handle.id, handle.session_id))
    end

    return state, nil
end

---@param handle legate.TerminalHandle
---@param timeout_ms? integer
---@return legate.TerminalWaitForExitResponse?, table?
local function wait_for_exit(handle, timeout_ms)
    local state, state_error = terminal_state(handle)

    if state == nil then
        return nil, state_error
    end

    if state.exit_status ~= nil then
        return vim.deepcopy(state.exit_status), nil
    end

    local result = state.system:wait(timeout_ms)

    if result == nil then
        return nil, request_error(string.format('ACP terminal wait timed out: %s', handle.id))
    end

    state.exit_status = exit_status_from_result(result)

    return vim.deepcopy(state.exit_status), nil
end

---@type legate.TerminalBackend
local native_backend = {
    name = 'native',
    create = function(opts)
        local cwd, cwd_error = validate_absolute_path(opts.cwd)

        if cwd_error ~= nil then
            return nil, cwd_error
        end

        local terminal_id = string.format('term:%d', next_terminal_ordinal)
        next_terminal_ordinal = next_terminal_ordinal + 1

        local state = {
            handle = {
                id = terminal_id,
                backend = 'native',
                session_id = opts.sessionId,
            },
            system = nil,
            output = '',
            truncated = false,
            output_byte_limit = opts.outputByteLimit,
            exit_status = nil,
            preview_bufnr = nil,
        }

        local argv = { opts.command }
        vim.list_extend(argv, opts.args or {})

        local ok, system_or_error = pcall(vim.system, argv, {
            cwd = cwd,
            env = env_map(opts.env),
            stdin = true,
            stdout = output_callback(state),
            stderr = output_callback(state),
            text = true,
        }, function(result)
            state.exit_status = exit_status_from_result(result)
        end)

        if not ok then
            return nil, request_error(tostring(system_or_error))
        end

        state.system = system_or_error
        terminals[terminal_id] = state

        return state.handle, nil
    end,
    send = function(handle, data)
        local state, state_error = terminal_state(handle)

        if state == nil then
            error(state_error.message)
        end

        state.system:write(data)
    end,
    output = function(handle)
        local state, state_error = terminal_state(handle)

        if state == nil then
            return nil, state_error
        end

        return {
            output = state.output,
            truncated = state.truncated,
            exitStatus = state.exit_status and vim.deepcopy(state.exit_status) or nil,
        },
            nil
    end,
    wait = wait_for_exit,
    kill = function(handle)
        local state, state_error = terminal_state(handle)

        if state == nil then
            return nil, state_error
        end

        if state.exit_status == nil then
            state.system:kill(15)
        end

        return {}, nil
    end,
    release = function(handle)
        local state, state_error = terminal_state(handle)

        if state == nil then
            return nil, state_error
        end

        if state.exit_status == nil then
            state.system:kill(15)
            wait_for_exit(handle)
        end

        terminals[handle.id] = nil

        return {}, nil
    end,
    reveal = function(handle)
        local state, state_error = terminal_state(handle)

        if state == nil then
            return state_error
        end

        if state.preview_bufnr == nil or not vim.api.nvim_buf_is_valid(state.preview_bufnr) then
            local bufnr = vim.api.nvim_create_buf(false, true)

            vim.api.nvim_buf_set_name(bufnr, string.format('LegateTerminal:%s', handle.id))
            vim.bo[bufnr].buftype = 'nofile'
            vim.bo[bufnr].bufhidden = 'hide'
            vim.bo[bufnr].swapfile = false
            vim.bo[bufnr].modifiable = false

            state.preview_bufnr = bufnr
        end

        vim.cmd('botright split')
        vim.api.nvim_win_set_buf(0, state.preview_bufnr)
        update_preview(state)

        return nil
    end,
}

---@type legate.TerminalBackend
local terminalia_backend = {
    name = 'terminalia',
    create = function(opts)
        local cwd, cwd_error = validate_absolute_path(opts.cwd)

        if cwd_error ~= nil then
            return nil, cwd_error
        end

        local terminal_api = terminalia_api()
        local argv = { opts.command }
        vim.list_extend(argv, opts.args or {})

        local terminal = terminal_api.create({
            name = opts.command,
            namespace = 'acp',
            command = argv,
            cwd = cwd,
            env = env_map(opts.env),
        })
        terminal_api.start(terminal.id)

        local state = {
            handle = {
                id = terminal.id,
                backend = 'terminalia',
                session_id = opts.sessionId,
            },
            output_byte_limit = opts.outputByteLimit,
        }

        terminalia_terminals[state.handle.id] = state

        return state.handle, nil
    end,
    send = function(handle, data)
        local state, state_error = terminalia_state(handle)

        if state == nil then
            error(state_error.message)
        end

        terminalia_api().send(state.handle.id, data)
    end,
    output = function(handle)
        local state, state_error = terminalia_state(handle)

        if state == nil then
            return nil, state_error
        end

        local output = terminalia_api().output(state.handle.id)
        local exit_status = nil
        local trimmed_output, truncated = trim_output(output.output, state.output_byte_limit)

        if output.exit_code ~= nil then
            exit_status = {
                exitCode = output.exit_code,
                signal = nil,
            }
        end

        return {
            output = trimmed_output,
            truncated = truncated,
            exitStatus = exit_status,
        },
            nil
    end,
    wait = function(handle, timeout_ms)
        local state, state_error = terminalia_state(handle)

        if state == nil then
            return nil, state_error
        end

        local terminal = terminalia_api().wait(state.handle.id, timeout_ms)

        if terminal == nil or terminal.status ~= 'exited' then
            return nil, request_error(string.format('ACP terminal wait timed out: %s', handle.id))
        end

        return {
            exitCode = terminal.exit_code,
            signal = nil,
        }, nil
    end,
    kill = function(handle)
        local state, state_error = terminalia_state(handle)

        if state == nil then
            return nil, state_error
        end

        terminalia_api().kill(state.handle.id)

        return {}, nil
    end,
    release = function(handle)
        local state, state_error = terminalia_state(handle)

        if state == nil then
            return nil, state_error
        end

        terminalia_terminals[handle.id] = nil

        return {}, nil
    end,
    reveal = function(handle)
        local state, state_error = terminalia_state(handle)

        if state == nil then
            return state_error
        end

        terminalia_api().open(state.handle.id)

        return nil
    end,
}

---Return the effective ACP terminal backend.
---@return legate.TerminalBackend
function M.resolve()
    if config.get().terminal_backend == 'native' then
        return native_backend
    end

    if config.get().terminal_backend == 'terminalia' then
        return terminalia_backend
    end

    error(string.format('Unsupported ACP terminal backend: %s', config.get().terminal_backend))
end

---@param params legate.TerminalCreateRequest
---@return legate.TerminalCreateResponse?, table?
function M.create(params)
    local handle, create_error = M.resolve().create(params)

    if handle == nil then
        return nil, create_error
    end

    return {
        terminalId = handle.id,
    }, nil
end

---@param params legate.TerminalOutputRequest
---@return legate.TerminalOutputResponse?, table?
function M.output(params)
    return M.resolve().output(request_handle(params.terminalId, params.sessionId))
end

---@param params legate.TerminalWaitForExitRequest
---@return legate.TerminalWaitForExitResponse?, table?
function M.wait_for_exit(params)
    return M.resolve().wait(request_handle(params.terminalId, params.sessionId))
end

---@param params legate.TerminalKillRequest
---@return legate.TerminalKillResponse?, table?
function M.kill(params)
    return M.resolve().kill(request_handle(params.terminalId, params.sessionId))
end

---@param params legate.TerminalReleaseRequest
---@return legate.TerminalReleaseResponse?, table?
function M.release(params)
    return M.resolve().release(request_handle(params.terminalId, params.sessionId))
end

---Clear all live ACP terminal state.
function M.clear()
    for id, state in pairs(terminals) do
        if state.exit_status == nil then
            state.system:kill(15)
            wait_for_exit(state.handle)
        end

        terminals[id] = nil
    end

    local ok, terminal_api = pcall(terminalia_api)

    if ok then
        for id, handle in pairs(terminalia_terminals) do
            pcall(terminal_api.release, handle.handle.id)
            terminalia_terminals[id] = nil
        end
    else
        terminalia_terminals = {}
    end

    next_terminal_ordinal = 1
end

return M
