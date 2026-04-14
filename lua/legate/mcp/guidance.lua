local config = require('legate.config')
local runtime = require('legate.mcp.runtime')

local M = {}

---@param value unknown
---@return boolean
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

---@param agent_capabilities? legate.AgentCapabilities
---@param family string
---@return boolean
local function supports_mcp_family(agent_capabilities, family)
    if agent_capabilities == nil or type(agent_capabilities.mcpCapabilities) ~= 'table' then
        return false
    end

    return has_enabled_capability(agent_capabilities.mcpCapabilities[family])
end

---@class legate.McpGuidanceSurface
---@field has_resources boolean
---@field has_workspace_summary boolean
---@field has_terminals_summary boolean
---@field has_any_tools boolean
---@field has_any_editor_tools boolean
---@field has_any_terminal_tools boolean
---@field has_list_buffers boolean
---@field has_read_buffer boolean
---@field has_write_buffer boolean
---@field has_diff_buffer boolean
---@field has_apply_diff_buffer boolean
---@field has_diff_file boolean
---@field has_apply_diff_file boolean
---@field has_write_file boolean
---@field has_terminal_create boolean
---@field has_terminal_output boolean
---@field has_terminal_wait boolean
---@field has_terminal_release boolean

---@param values string[]
---@return string
local function quoted_list(values)
    return table.concat(
        vim.tbl_map(function(value)
            return string.format('`%s`', value)
        end, values),
        ', '
    )
end

---@param server_name string
---@return legate.McpGuidanceSurface
local function available_surface(server_name)
    local surface = {
        has_resources = false,
        has_workspace_summary = false,
        has_terminals_summary = false,
        has_any_tools = false,
        has_any_editor_tools = false,
        has_any_terminal_tools = false,
        has_list_buffers = false,
        has_read_buffer = false,
        has_write_buffer = false,
        has_diff_buffer = false,
        has_apply_diff_buffer = false,
        has_diff_file = false,
        has_apply_diff_file = false,
        has_write_file = false,
        has_terminal_create = false,
        has_terminal_output = false,
        has_terminal_wait = false,
        has_terminal_release = false,
    }
    local ok, ministry = pcall(require, 'ministry')

    if not ok then
        return surface
    end

    if type(ministry.list_resource_descriptors) == 'function' then
        for _, resource in ipairs(ministry.list_resource_descriptors()) do
            if resource.namespaced_uri == string.format('%s/workspace://summary', server_name) then
                surface.has_resources = true
                surface.has_workspace_summary = true
            elseif resource.namespaced_uri == string.format('%s/terminals://list', server_name) then
                surface.has_resources = true
                surface.has_terminals_summary = true
            end
        end
    end

    if type(ministry.list_tool_descriptors) == 'function' then
        for _, tool in ipairs(ministry.list_tool_descriptors()) do
            if tool.namespaced_name == string.format('%s/editor/list_buffers', server_name) then
                surface.has_list_buffers = true
            elseif tool.namespaced_name == string.format('%s/editor/read_buffer', server_name) then
                surface.has_read_buffer = true
            elseif tool.namespaced_name == string.format('%s/editor/write_buffer', server_name) then
                surface.has_write_buffer = true
            elseif tool.namespaced_name == string.format('%s/editor/diff_buffer', server_name) then
                surface.has_diff_buffer = true
            elseif tool.namespaced_name == string.format('%s/editor/apply_diff_buffer', server_name) then
                surface.has_apply_diff_buffer = true
            elseif tool.namespaced_name == string.format('%s/editor/diff_file', server_name) then
                surface.has_diff_file = true
            elseif tool.namespaced_name == string.format('%s/editor/apply_diff_file', server_name) then
                surface.has_apply_diff_file = true
            elseif tool.namespaced_name == string.format('%s/editor/write_file', server_name) then
                surface.has_write_file = true
            elseif tool.namespaced_name == string.format('%s/terminal/create', server_name) then
                surface.has_terminal_create = true
            elseif tool.namespaced_name == string.format('%s/terminal/output', server_name) then
                surface.has_terminal_output = true
            elseif tool.namespaced_name == string.format('%s/terminal/wait', server_name) then
                surface.has_terminal_wait = true
            elseif tool.namespaced_name == string.format('%s/terminal/release', server_name) then
                surface.has_terminal_release = true
            end
        end
    end

    surface.has_any_editor_tools = surface.has_list_buffers
        or surface.has_read_buffer
        or surface.has_write_buffer
        or surface.has_diff_buffer
        or surface.has_apply_diff_buffer
        or surface.has_diff_file
        or surface.has_apply_diff_file
        or surface.has_write_file
    surface.has_any_terminal_tools = surface.has_terminal_create
        or surface.has_terminal_output
        or surface.has_terminal_wait
        or surface.has_terminal_release
    surface.has_any_tools = surface.has_any_editor_tools or surface.has_any_terminal_tools

    return surface
end

---@param server_name string
---@param agent_capabilities? legate.AgentCapabilities
---@return string|nil
local function guidance_for(server_name, agent_capabilities)
    local has_resource_capabilities = supports_mcp_family(agent_capabilities, 'resources')
    local has_tool_capabilities = supports_mcp_family(agent_capabilities, 'tools')
    local surface = available_surface(server_name)
    local lines = {
        'Routing guidance:',
        string.format('- Prefer the injected MCP server `%s` for editor work.', server_name),
        '- Do not rely on current-buffer semantics.',
    }

    if has_tool_capabilities and surface.has_any_tools then
        table.insert(
            lines,
            string.format(
                '- Use fully qualified MCP tool names exactly as advertised by `tools/list`, including the `%s/` prefix.',
                server_name
            )
        )
        if surface.has_any_editor_tools and surface.has_any_terminal_tools then
            table.insert(
                lines,
                string.format(
                    '- When the tool call surface separates server selection from tool selection, choose MCP server `%s` and then tool path `editor/...` or `terminal/...` without repeating the `%s/` prefix inside the tool-path field.',
                    server_name,
                    server_name
                )
            )
        elseif surface.has_any_editor_tools then
            table.insert(
                lines,
                string.format(
                    '- When the tool call surface separates server selection from tool selection, choose MCP server `%s` and then tool path `editor/...` without repeating the `%s/` prefix inside the tool-path field.',
                    server_name,
                    server_name
                )
            )
        elseif surface.has_any_terminal_tools then
            table.insert(
                lines,
                string.format(
                    '- When the tool call surface separates server selection from tool selection, choose MCP server `%s` and then tool path `terminal/...` without repeating the `%s/` prefix inside the tool-path field.',
                    server_name,
                    server_name
                )
            )
        end
    end

    if has_tool_capabilities and surface.has_any_editor_tools then
        local editor_examples = {}

        if surface.has_list_buffers then
            table.insert(editor_examples, string.format('%s/editor/list_buffers', server_name))
        end
        if surface.has_read_buffer then
            table.insert(editor_examples, string.format('%s/editor/read_buffer', server_name))
        end

        if #editor_examples > 0 then
            table.insert(
                lines,
                string.format(
                    '- The Neovim MCP server groups tools internally as `editor/...`; the advertised MCP tool names preserve those nested slash-delimited paths under the `%s/...` namespace, such as %s.',
                    server_name,
                    quoted_list(editor_examples)
                )
            )
        end

        if surface.has_list_buffers then
            local buffer_tools = {}

            if surface.has_read_buffer then
                table.insert(buffer_tools, string.format('%s/editor/read_buffer', server_name))
            end
            if surface.has_write_buffer then
                table.insert(buffer_tools, string.format('%s/editor/write_buffer', server_name))
            end
            if surface.has_diff_buffer then
                table.insert(buffer_tools, string.format('%s/editor/diff_buffer', server_name))
            end
            if surface.has_apply_diff_buffer then
                table.insert(buffer_tools, string.format('%s/editor/apply_diff_buffer', server_name))
            end

            if #buffer_tools > 0 then
                table.insert(
                    lines,
                    string.format(
                        '- Enumerate buffers with `%s/editor/list_buffers`, then target buffers by `bufnr` using %s.',
                        server_name,
                        quoted_list(buffer_tools)
                    )
                )
            else
                table.insert(
                    lines,
                    string.format(
                        '- Enumerate buffers with `%s/editor/list_buffers` before choosing a specific buffer target.',
                        server_name
                    )
                )
            end
        end

        local file_tools = {}

        if surface.has_diff_file then
            table.insert(file_tools, string.format('%s/editor/diff_file', server_name))
        end
        if surface.has_apply_diff_file then
            table.insert(file_tools, string.format('%s/editor/apply_diff_file', server_name))
        end
        if surface.has_write_file then
            table.insert(file_tools, string.format('%s/editor/write_file', server_name))
        end

        if #file_tools > 0 then
            table.insert(
                lines,
                string.format(
                    '- When the desired result must update disk and synchronize a loaded matching buffer, use %s.',
                    quoted_list(file_tools)
                )
            )
        end
    end

    if has_resource_capabilities and surface.has_workspace_summary then
        table.insert(
            lines,
            string.format(
                '- Start workspace orientation with `%s/workspace://summary` when you need lightweight, session-global editor/workspace metadata before choosing specific buffers or files.',
                server_name
            )
        )
    end

    if has_resource_capabilities and surface.has_terminals_summary then
        table.insert(
            lines,
            string.format(
                '- Use `%s/terminals://list` for lightweight, session-global Ministry terminal runtime summaries before choosing a specific `%s/terminal/output`, `%s/terminal/wait`, or `%s/terminal/release` target.',
                server_name,
                server_name,
                server_name,
                server_name
            )
        )
    end

    if has_tool_capabilities and surface.has_any_terminal_tools then
        local terminal_tools = {}

        if surface.has_terminal_create then
            table.insert(terminal_tools, string.format('%s/terminal/create', server_name))
        end
        if surface.has_terminal_output then
            table.insert(terminal_tools, string.format('%s/terminal/output', server_name))
        end
        if surface.has_terminal_wait then
            table.insert(terminal_tools, string.format('%s/terminal/wait', server_name))
        end
        if surface.has_terminal_release then
            table.insert(terminal_tools, string.format('%s/terminal/release', server_name))
        end

        table.insert(
            lines,
            string.format(
                '- Terminal execution policy: prefer ACP-native terminal methods when they are actually available and selected by the runtime; otherwise use the exact `tools/list` terminal names %s.',
                quoted_list(terminal_tools)
            )
        )
        table.insert(
            lines,
            string.format(
                '- Do not execute shell commands through a generic execute tool when ACP terminal methods or `%s/terminal/*` are available for the task.',
                server_name
            )
        )
        table.insert(
            lines,
            '- If you still choose a non-terminal execution path, explicitly explain why the required terminal channels were unavailable before proceeding.'
        )
    end

    if #lines <= 3 then
        return nil
    end

    return table.concat(lines, '\n')
end

function M.prepend(prompt, agent_capabilities, current_session)
    local adapter = config.adapter_for_session(current_session)

    if not adapter.mcp_nvim_guidance then
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

    local guidance = guidance_for(server_name, agent_capabilities)

    if guidance == nil then
        return prompt
    end

    if vim.startswith(prompt, guidance) then
        return prompt
    end

    return string.format('%s\n\n%s', guidance, prompt)
end

return M
