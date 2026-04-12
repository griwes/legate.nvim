local config = require('acp.config')
local runtime = require('acp.mcp_runtime')

local M = {}

local function guidance_for(server_name)
    return table.concat({
        'Routing guidance:',
        string.format('- Prefer the injected MCP server `%s` for editor work.', server_name),
        '- Do not rely on current-buffer semantics.',
        string.format(
            '- Use fully qualified MCP tool names exactly as advertised by `tools/list`, including the `%s/` prefix.',
            server_name
        ),
        string.format(
            '- When the tool call surface separates server selection from tool selection, choose MCP server `%s` and then tool path `editor/...` or `terminal/...` without repeating the `%s/` prefix inside the tool-path field.',
            server_name,
            server_name
        ),
        string.format(
            '- The Neovim MCP server groups tools internally as `editor/...` and `terminal/...`; the advertised MCP tool names preserve those nested slash-delimited paths under the `%s/...` namespace, such as `%s/editor/list_buffers` and `%s/terminal/create`.',
            server_name,
            server_name,
            server_name
        ),
        string.format(
            '- Enumerate buffers with `%s/editor/list_buffers`, then target buffers by `bufnr` using `%s/editor/read_buffer`, `%s/editor/write_buffer`, `%s/editor/diff_buffer`, and `%s/editor/apply_diff_buffer`.',
            server_name,
            server_name,
            server_name,
            server_name,
            server_name
        ),
        string.format(
            '- When the desired result must update disk and synchronize a loaded matching buffer, use `%s/editor/diff_file`, `%s/editor/apply_diff_file`, or `%s/editor/write_file`.',
            server_name,
            server_name,
            server_name
        ),
        string.format(
            '- Terminal execution policy: prefer ACP-native terminal methods when they are actually available and selected by the runtime; otherwise use the exact `tools/list` terminal names `%s/terminal/create`, `%s/terminal/output`, `%s/terminal/wait`, and `%s/terminal/release`.',
            server_name,
            server_name,
            server_name,
            server_name
        ),
        string.format(
            '- Do not execute shell commands through a generic execute tool when ACP terminal methods or `%s/terminal/*` are available for the task.',
            server_name
        ),
        '- If you still choose a non-terminal execution path, explicitly explain why the required terminal channels were unavailable before proceeding.',
    }, '\n')
end

local function effective_server_name()
    local injected_server_name = runtime.injected_server_name and runtime.injected_server_name() or 'neovim'

    for _, server in ipairs(runtime.effective_servers(nil, { passive = true })) do
        if server.name == injected_server_name then
            return server.name
        end
    end

    return nil
end

---@param prompt string
---@param agent_capabilities? acp.AgentCapabilities
---@return string
local function supports_mcp_guidance(agent_capabilities)
    local function has_enabled_capability(value)
        if value == true then
            return true
        end

        if type(value) ~= 'table' then
            return false
        end

        for _, nested in pairs(value) do
            if has_enabled_capability(nested) then
                return true
            end
        end

        return false
    end

    if agent_capabilities == nil or type(agent_capabilities.mcpCapabilities) ~= 'table' then
        return false
    end

    for _, supported in pairs(agent_capabilities.mcpCapabilities) do
        if has_enabled_capability(supported) then
            return true
        end
    end

    return false
end

function M.prepend(prompt, agent_capabilities, current_session)
    local adapter = config.adapter_for_session(current_session)

    if not adapter.mcp_nvim_guidance or not supports_mcp_guidance(agent_capabilities) then
        return prompt
    end

    local injected_server_name = runtime.injected_server_name and runtime.injected_server_name() or 'neovim'
    local server_name = nil

    for _, server in ipairs(runtime.effective_servers(current_session, { passive = true })) do
        if server.name == injected_server_name then
            server_name = server.name
            break
        end
    end

    if server_name == nil then
        return prompt
    end

    local guidance = guidance_for(server_name)

    if vim.startswith(prompt, guidance) then
        return prompt
    end

    return string.format('%s\n\n%s', guidance, prompt)
end

return M
