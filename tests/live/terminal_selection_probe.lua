local plugin = require('legate')
local mcp = require('ministry')
local mcp_router = require('ministry.protocol.router')
local mcp_runtime = require('legate.mcp.runtime')
local terminal = require('legate.terminal')
local transport = require('legate.transport')

---@param current_session legate.Session
---@return string
local function transcript_text(current_session)
    local chunks = {}

    for _, message in ipairs(current_session.messages) do
        table.insert(chunks, string.format('[%s] %s', message.role, message.text))
    end

    return table.concat(chunks, '\n')
end

---@param current_session legate.Session
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

---@param current_session legate.Session
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

---@return legate.TerminalBackendName
local function requested_backend()
    local backend = vim.env.LEGATE_LIVE_TERMINAL_BACKEND or 'native'

    assert(
        backend == 'native' or backend == 'terminalia',
        string.format('Unsupported LEGATE_LIVE_TERMINAL_BACKEND: %s', backend)
    )

    return backend
end

---@param tool_call legate.ToolCallState
---@return table
local mcp_tool_name

---@param tool_call legate.ToolCallState
---@return table
local function tool_summary(tool_call)
    return {
        id = tool_call.tool_call_id,
        title = tool_call.title,
        kind = tool_call.kind,
        status = tool_call.status,
        mcp_tool_name = mcp_tool_name(tool_call),
        raw_input = vim.deepcopy(tool_call.raw_input),
    }
end

local terminal_counts = {
    create = 0,
    output = 0,
    wait_for_exit = 0,
    kill = 0,
    release = 0,
}

---@param tool_call legate.ToolCallState
---@return string?
mcp_tool_name = function(tool_call)
    if type(tool_call.raw_input) ~= 'table' then
        return nil
    end

    local raw = tool_call.raw_input

    if type(raw.server) == 'string' and type(raw.tool) == 'string' then
        if vim.startswith(raw.tool, raw.server .. '/') then
            return raw.tool
        end

        return string.format('%s/%s', raw.server, raw.tool)
    end

    if type(raw.serverName) == 'string' and type(raw.toolName) == 'string' then
        if vim.startswith(raw.toolName, raw.serverName .. '/') then
            return raw.toolName
        end

        return string.format('%s/%s', raw.serverName, raw.toolName)
    end

    return nil
end

---@param server_name string
---@param tool_calls legate.ToolCallState[]
---@return string[]
local function mcp_terminal_tool_calls(server_name, tool_calls)
    local names = {}
    local prefix = string.format('%s/terminal/', server_name)

    for _, tool_call in ipairs(tool_calls) do
        local name = mcp_tool_name(tool_call)

        if name ~= nil and vim.startswith(name, prefix) then
            table.insert(names, name)
        end
    end

    return names
end

---@param server_name string
---@param tool_calls legate.ToolCallState[]
---@return table[]
local function split_routing_violations(server_name, tool_calls)
    local violations = {}

    for _, tool_call in ipairs(tool_calls) do
        if type(tool_call.raw_input) == 'table' then
            local raw = tool_call.raw_input
            local routed_server = raw.server or raw.serverName
            local routed_tool = raw.tool or raw.toolName

            if
                type(routed_server) == 'string'
                and type(routed_tool) == 'string'
                and routed_server == server_name
                and vim.startswith(routed_tool, server_name .. '/')
            then
                table.insert(violations, {
                    id = tool_call.tool_call_id,
                    routed_server = routed_server,
                    routed_tool = routed_tool,
                    expected_tool = routed_tool:sub(#server_name + 2),
                })
            end
        end
    end

    return violations
end

---@param tool_calls legate.ToolCallState[]
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

local terminalia_configured = false

for method_name in pairs(terminal_counts) do
    local original = terminal[method_name]

    terminal[method_name] = function(params)
        terminal_counts[method_name] = terminal_counts[method_name] + 1
        return original(params)
    end
end

local function setup_terminalia_backend()
    if terminalia_configured then
        return
    end

    local repo = vim.fn.fnamemodify(vim.fn.getcwd() .. '/../terminalia.nvim', ':p')

    vim.opt.runtimepath:prepend(repo)

    local terminalia = require('terminalia')

    terminalia.setup({
        history_dir = vim.fn.tempname(),
        notify_on_exit = false,
        state_file = vim.fn.tempname(),
    })
    terminalia.api.clear()

    terminalia_configured = true
end

local prompt_timeout_ms = tonumber(vim.env.ACP_LIVE_PROMPT_TIMEOUT_MS or '') or 180000
local session_timeout_ms = tonumber(vim.env.ACP_LIVE_SESSION_TIMEOUT_MS or '') or 60000
local backend = requested_backend()
local token = 'ACP_TERMINAL_SELECTION_PROBE_OK'
local observed_mcp_requests = {}
local observed_rpc_requests = {}

---@param current_session? legate.Session
---@return string
local function advertised_server_name(current_session)
    local injected_server_name = mcp_runtime.injected_server_name and mcp_runtime.injected_server_name() or 'neovim'

    for _, server in ipairs(mcp_runtime.effective_servers(current_session, { passive = true })) do
        if server.name == injected_server_name then
            return server.name
        end
    end

    return injected_server_name
end

---@return string
local function requested_probe_mode()
    return vim.env.LEGATE_LIVE_PROBE_MODE or vim.env.ACP_LIVE_PROBE_MODE or 'balanced'
end

---@return string[]
local function direct_execution_explanation_lines()
    return {
        'If you do not use ACP terminal methods or the required MCP terminal tools, explain concretely why you rejected those channels.',
        'Your explanation must name the rejected channel and the specific reason, for example missing advertisement, unavailable capability, or a higher-priority tool-selection rule.',
        'If you decide the required channels are unavailable, state that before using any direct execute path.',
    }
end

---@param server_name string
---@param token string
---@return string[]
local function probe_prompt_lines(server_name, token)
    local mode = requested_probe_mode()

    if mode == 'strict_mcp_terminal' then
        return vim.list_extend({
            'Probe ACP terminal fallback selection.',
            'Policy: you SHALL NOT use a generic execute tool, shell tool, or direct command runner for this task.',
            'Policy: if ACP client terminal methods are not actually selected, you SHALL use the injected MCP terminal tools instead.',
            string.format(
                'The only approved fallback tools for this run are exactly `%s/terminal/create`, `%s/terminal/wait`, `%s/terminal/output`, and `%s/terminal/release` as advertised through tools/list.',
                server_name,
                server_name,
                server_name,
                server_name
            ),
            string.format(
                'Use only that terminal-tool path to run `printf %s`, then reply with the token %s.',
                token,
                token
            ),
        }, direct_execution_explanation_lines())
    end

    if mode == 'hard_mcp_terminal_only' then
        return vim.list_extend({
            'Terminal execution policy for this prompt:',
            '1. You SHALL use only the injected MCP terminal tools for command execution.',
            '2. You SHALL NOT run commands directly.',
            '3. You SHALL NOT use any generic execute, shell, bash, or container-exec tool.',
            '4. You SHALL first discover the available injected MCP tools, then use only the terminal subset.',
            string.format(
                'The required tool sequence is: `%s/terminal/create`, then `%s/terminal/wait`, then `%s/terminal/output`, then `%s/terminal/release`.',
                server_name,
                server_name,
                server_name,
                server_name
            ),
            string.format(
                'Execute `printf %s` only through that MCP terminal sequence, then reply with the token %s.',
                token,
                token
            ),
        }, direct_execution_explanation_lines())
    end

    if mode == 'split_mcp_routing' then
        return vim.list_extend({
            'Probe MCP terminal routing details.',
            'If ACP terminal methods are not actually selected, you SHALL use the injected MCP terminal tools and no direct execute path.',
            string.format('Select the injected MCP server named `%s`.', server_name),
            'If the tool-call schema separates the server field from the tool field, put only `terminal/create`, `terminal/wait`, `terminal/output`, and `terminal/release` in the tool field.',
            string.format(
                'Do not repeat the server prefix inside the tool field; `server = "%s"` plus `tool = "terminal/create"` is correct, while `tool = "%s/terminal/create"` is not.',
                server_name,
                server_name
            ),
            string.format(
                'Run `printf %s` through that MCP terminal path, then reply with the token %s.',
                token,
                token
            ),
        }, direct_execution_explanation_lines())
    end

    if mode == 'strict_acp_first' then
        return vim.list_extend({
            'Probe ACP terminal fallback selection.',
            'First preference: ACP client terminal methods.',
            string.format('Second preference: injected `%s/terminal/*` MCP tools.', server_name),
            'Do not use a generic execute tool unless both terminal paths are unavailable.',
            string.format('Run `printf %s`, then reply with the token %s.', token, token),
        }, direct_execution_explanation_lines())
    end

    return vim.list_extend({
        'Probe ACP terminal-method selection.',
        'If you decide to execute a command, prefer ACP client terminal methods.',
        string.format(
            'If ACP terminal methods are not actually selected, prefer the injected %s/terminal/* MCP tools over generic execute tools.',
            server_name
        ),
        string.format('Run `printf %s` or an equivalent command, then reply with the token %s.', token, token),
    }, direct_execution_explanation_lines())
end

local original_handle_request = mcp_router.handle_request
mcp_router.handle_request = function(method, params, id, ctx)
    if method == 'tools/list' then
        table.insert(observed_mcp_requests, {
            method = method,
            id = id,
            params = vim.deepcopy(params),
        })
    elseif method == 'tools/call' then
        table.insert(observed_mcp_requests, {
            method = method,
            id = id,
            params = vim.deepcopy(params),
        })
    end

    return original_handle_request(method, params, id, ctx)
end

local function instrumented_rpc_factory(opts)
    local client = require('legate.core.rpc').new(opts)
    local original_request_sync = client.request_sync
    local original_request = client.request

    client.request_sync = function(self, method, params, timeout_ms)
        table.insert(observed_rpc_requests, {
            kind = 'sync',
            method = method,
            params = vim.deepcopy(params),
        })
        return original_request_sync(self, method, params, timeout_ms)
    end

    client.request = function(self, method, params, callback)
        table.insert(observed_rpc_requests, {
            kind = 'async',
            method = method,
            params = vim.deepcopy(params),
        })
        return original_request(self, method, params, callback)
    end

    return client
end

local ok, err = xpcall(function()
    if backend == 'terminalia' then
        setup_terminalia_backend()
    end

    transport._set_rpc_factory(instrumented_rpc_factory)

    mcp.setup({
        enable_terminal_tools = true,
    })

    local tool_names = vim.tbl_map(function(tool)
        return tool.name or tool.namespaced_name
    end, mcp.list_tool_descriptors())

    assert(
        vim.tbl_contains(tool_names, 'neovim/terminal/create'),
        string.format('ministry.nvim did not advertise neovim/terminal/create: %s', vim.inspect(tool_names))
    )
    assert(
        vim.tbl_contains(tool_names, 'neovim/terminal/output'),
        string.format('ministry.nvim did not advertise neovim/terminal/output: %s', vim.inspect(tool_names))
    )
    assert(
        vim.tbl_contains(tool_names, 'neovim/terminal/wait'),
        string.format('ministry.nvim did not advertise neovim/terminal/wait: %s', vim.inspect(tool_names))
    )
    assert(
        vim.tbl_contains(tool_names, 'neovim/terminal/release'),
        string.format('ministry.nvim did not advertise neovim/terminal/release: %s', vim.inspect(tool_names))
    )

    plugin.setup({
        auth_method = 'chatgpt',
        terminal_backend = backend,
        persist_sessions = false,
        request_timeout_ms = session_timeout_ms,
        enable_mcp_nvim = true,
        mcp_nvim_guidance = true,
    })

    local server_name = advertised_server_name(nil)
    local expected_terminal_tools = {
        string.format('%s/terminal/create', server_name),
        string.format('%s/terminal/output', server_name),
        string.format('%s/terminal/wait', server_name),
        string.format('%s/terminal/release', server_name),
    }

    local api = plugin.api

    api.open_chat()
    api.set_prompt(table.concat(probe_prompt_lines(server_name, token), ' '))

    local current_session = api.submit_prompt()

    wait_for_turn_completion(current_session, prompt_timeout_ms)

    local assistant_text = last_assistant_text(current_session) or ''
    local token_seen = assistant_text:find(token, 1, true) ~= nil

    local total_terminal_calls = 0

    for _, count in pairs(terminal_counts) do
        total_terminal_calls = total_terminal_calls + count
    end

    local execute_calls = execute_tool_call_count(current_session.tool_calls)
    local mcp_terminal_calls = mcp_terminal_tool_calls(server_name, current_session.tool_calls)
    local split_tool_routing_violations = split_routing_violations(server_name, current_session.tool_calls)

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
        token_seen = token_seen,
        required_token = token,
        used_terminal_methods = total_terminal_calls > 0,
        used_execute_tool = execute_calls > 0,
        used_mcp_terminal_tools = #mcp_terminal_calls > 0,
        execute_tool_call_count = execute_calls,
        terminal_calls = vim.deepcopy(terminal_counts),
        mcp_terminal_tool_calls = mcp_terminal_calls,
        split_tool_routing_violations = split_tool_routing_violations,
        observed_mcp_requests = observed_mcp_requests,
        observed_rpc_requests = observed_rpc_requests,
        tool_calls = vim.tbl_map(tool_summary, current_session.tool_calls),
        approval_count = #current_session.approval_entries,
        remote_id = current_session.remote_id,
        stop_reason = current_session.stop_reason,
        message_count = #current_session.messages,
        assistant_text = assistant_text,
        probe_mode = requested_probe_mode(),
        split_tool_routing_ok = #split_tool_routing_violations == 0,
    }))
end, debug.traceback)

mcp_router.handle_request = original_handle_request
transport._set_rpc_factory(require('legate.core.rpc').new)

if not ok then
    io.stderr:write(err .. '\n')
    os.exit(1)
end
