local plugin = require('acp')
local terminal = require('acp.terminal')

---@param current_session acp.Session
---@return string
local function transcript_text(current_session)
    local chunks = {}

    for _, message in ipairs(current_session.messages) do
        table.insert(chunks, string.format('[%s] %s', message.role, message.text))
    end

    return table.concat(chunks, '\n')
end

---@param current_session acp.Session
---@return string?
local function last_assistant_text(current_session)
    for index = #current_session.messages, 1, -1 do
        local message = current_session.messages[index]

        if message.role == 'assistant' then
            return message.text
        end
    end

    return nil
end

---@param current_session acp.Session
---@param timeout_ms integer
local function wait_for_turn_completion(current_session, timeout_ms)
    local completed = vim.wait(timeout_ms, function()
        return current_session.status ~= 'waiting'
    end, 100)

    assert(completed, string.format('ACP prompt did not complete within %d ms', timeout_ms))
    assert(
        current_session.status == 'idle',
        string.format('ACP prompt ended with status %s\n%s', current_session.status, transcript_text(current_session))
    )
end

---@return acp.TerminalBackendName
local function requested_backend()
    local backend = vim.env.ACP_LIVE_TERMINAL_BACKEND or 'native'

    assert(
        backend == 'native' or backend == 'terminal_manager',
        string.format('Unsupported ACP_LIVE_TERMINAL_BACKEND: %s', backend)
    )

    return backend
end

---@param tool_call acp.ToolCallState
---@return table
local function tool_summary(tool_call)
    return {
        id = tool_call.tool_call_id,
        title = tool_call.title,
        kind = tool_call.kind,
        status = tool_call.status,
    }
end

local terminal_counts = {
    create = 0,
    output = 0,
    wait_for_exit = 0,
    kill = 0,
    release = 0,
}

---@param tool_calls acp.ToolCallState[]
---@return integer
local function execute_tool_call_count(tool_calls)
    local count = 0

    for _, tool_call in ipairs(tool_calls) do
        if tool_call.kind == 'execute' then
            count = count + 1
        end
    end

    return count
end

local terminal_manager_configured = false

for method_name in pairs(terminal_counts) do
    local original = terminal[method_name]

    terminal[method_name] = function(params)
        terminal_counts[method_name] = terminal_counts[method_name] + 1
        return original(params)
    end
end

local function setup_terminal_manager_backend()
    if terminal_manager_configured then
        return
    end

    local repo = vim.fn.fnamemodify(vim.fn.getcwd() .. '/../terminal-manager.nvim', ':p')

    vim.opt.runtimepath:prepend(repo)

    local terminal_manager = require('terminal_manager')

    terminal_manager.setup({
        history_dir = vim.fn.tempname(),
        notify_on_exit = false,
        state_file = vim.fn.tempname(),
    })
    terminal_manager.api.clear()

    terminal_manager_configured = true
end

local prompt_timeout_ms = tonumber(vim.env.ACP_LIVE_PROMPT_TIMEOUT_MS or '') or 180000
local session_timeout_ms = tonumber(vim.env.ACP_LIVE_SESSION_TIMEOUT_MS or '') or 60000
local backend = requested_backend()
local token = 'ACP_TERMINAL_SELECTION_PROBE_OK'

local ok, err = xpcall(function()
    if backend == 'terminal_manager' then
        setup_terminal_manager_backend()
    end

    plugin.setup({
        auth_method = 'chatgpt',
        terminal_backend = backend,
        persist_sessions = false,
        request_timeout_ms = session_timeout_ms,
    })

    local api = plugin.api

    api.open_chat()
    api.set_prompt(table.concat({
        'Probe ACP terminal-method selection.',
        'If you decide to execute a command, prefer ACP client terminal methods over alternate execution tools.',
        string.format(
            'Run `printf %s` or an equivalent command, then reply with exactly %s and no other text.',
            token,
            token
        ),
    }, ' '))

    local current_session = api.submit_prompt()

    wait_for_turn_completion(current_session, prompt_timeout_ms)

    local assistant_text = last_assistant_text(current_session) or ''

    assert(
        assistant_text:find(token, 1, true) ~= nil,
        string.format('Probe assistant response did not contain %s\n%s', token, transcript_text(current_session))
    )

    local total_terminal_calls = 0

    for _, count in pairs(terminal_counts) do
        total_terminal_calls = total_terminal_calls + count
    end

    local execute_calls = execute_tool_call_count(current_session.tool_calls)

    assert(
        total_terminal_calls > 0 or #current_session.tool_calls > 0,
        string.format(
            'Probe did not observe any terminal or tool-call path\nterminal_calls=%s\ntool_calls=%s\n%s',
            vim.inspect(terminal_counts),
            vim.inspect(current_session.tool_calls),
            transcript_text(current_session)
        )
    )

    print(vim.json.encode({
        outcome = 'success',
        terminal_backend = backend,
        used_terminal_methods = total_terminal_calls > 0,
        used_execute_tool = execute_calls > 0,
        execute_tool_call_count = execute_calls,
        terminal_calls = vim.deepcopy(terminal_counts),
        tool_calls = vim.tbl_map(tool_summary, current_session.tool_calls),
        approval_count = #current_session.approval_entries,
        remote_id = current_session.remote_id,
        stop_reason = current_session.stop_reason,
        message_count = #current_session.messages,
        assistant_text = assistant_text,
    }))
end, debug.traceback)

if not ok then
    io.stderr:write(err .. '\n')
    os.exit(1)
end
