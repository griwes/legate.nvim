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

---@param agent_capabilities? legate.AgentCapabilities
---@return boolean
local function has_any_mcp_capability(agent_capabilities)
    if agent_capabilities == nil or type(agent_capabilities.mcpCapabilities) ~= 'table' then
        return false
    end

    return has_enabled_capability(agent_capabilities.mcpCapabilities)
end

---@return table|nil
local function load_ministry()
    local ok, ministry = pcall(require, 'ministry')
    return ok and ministry or nil
end

---@class legate.McpGuidanceSurface
---@field has_resources boolean
---@field has_workspace_summary boolean
---@field has_terminals_summary boolean
---@field has_tasks_summary boolean
---@field has_git_repository boolean
---@field has_git_overview boolean
---@field has_git_refs boolean
---@field has_git_paths boolean
---@field has_git_path boolean
---@field has_dap_summary boolean
---@field has_dap_breakpoints boolean
---@field has_dap_threads boolean
---@field has_any_tools boolean
---@field has_any_editor_tools boolean
---@field has_any_terminal_tools boolean
---@field has_any_git_tools boolean
---@field has_any_dap_tools boolean
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
---@field has_git_overview_tool boolean
---@field has_git_list_refs boolean
---@field has_git_list_paths boolean
---@field has_git_path_state boolean
---@field has_dap_continue boolean
---@field has_dap_pause boolean
---@field has_dap_step_over boolean
---@field has_dap_step_into boolean
---@field has_dap_step_out boolean
---@field has_dap_terminate boolean
---@field has_dap_disconnect boolean
---@field has_dap_stack_template boolean
---@field has_dap_scopes_template boolean
---@field has_dap_variables_template boolean

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

---@param groups string[]
---@return string
local function tool_group_list(groups)
    if #groups == 1 then
        return string.format('`%s`', groups[1])
    end
    if #groups == 2 then
        return string.format('`%s` or `%s`', groups[1], groups[2])
    end

    local quoted = vim.tbl_map(function(group)
        return string.format('`%s`', group)
    end, groups)
    quoted[#quoted] = 'or ' .. quoted[#quoted]
    return table.concat(quoted, ', ')
end

---@param ministry table
---@param server_name string
---@return legate.McpGuidanceSurface
local function available_surface(ministry, server_name)
    local surface = {
        has_resources = false,
        has_workspace_summary = false,
        has_terminals_summary = false,
        has_tasks_summary = false,
        has_git_repository = false,
        has_git_overview = false,
        has_git_refs = false,
        has_git_paths = false,
        has_git_path = false,
        has_dap_summary = false,
        has_dap_breakpoints = false,
        has_dap_threads = false,
        has_any_tools = false,
        has_any_editor_tools = false,
        has_any_terminal_tools = false,
        has_any_git_tools = false,
        has_any_dap_tools = false,
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
        has_git_overview_tool = false,
        has_git_list_refs = false,
        has_git_list_paths = false,
        has_git_path_state = false,
        has_dap_continue = false,
        has_dap_pause = false,
        has_dap_step_over = false,
        has_dap_step_into = false,
        has_dap_step_out = false,
        has_dap_terminate = false,
        has_dap_disconnect = false,
        has_dap_stack_template = false,
        has_dap_scopes_template = false,
        has_dap_variables_template = false,
    }
    if ministry == nil then
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
            elseif resource.namespaced_uri == string.format('%s/tasks://summary', server_name) then
                surface.has_resources = true
                surface.has_tasks_summary = true
            elseif resource.namespaced_uri == string.format('%s/git://repository', server_name) then
                surface.has_resources = true
                surface.has_git_repository = true
            elseif resource.namespaced_uri == string.format('%s/git://overview', server_name) then
                surface.has_resources = true
                surface.has_git_overview = true
            elseif resource.namespaced_uri == string.format('%s/git://refs', server_name) then
                surface.has_resources = true
                surface.has_git_refs = true
            elseif resource.namespaced_uri == string.format('%s/git://paths', server_name) then
                surface.has_resources = true
                surface.has_git_paths = true
            elseif resource.namespaced_uri == string.format('%s/git://path', server_name) then
                surface.has_resources = true
                surface.has_git_path = true
            elseif resource.namespaced_uri == string.format('%s/dap://summary', server_name) then
                surface.has_resources = true
                surface.has_dap_summary = true
            elseif resource.namespaced_uri == string.format('%s/dap://breakpoints', server_name) then
                surface.has_resources = true
                surface.has_dap_breakpoints = true
            elseif resource.namespaced_uri == string.format('%s/dap://threads', server_name) then
                surface.has_resources = true
                surface.has_dap_threads = true
            end
        end
    end

    if type(ministry.list_resource_template_descriptors) == 'function' then
        for _, resource_template in ipairs(ministry.list_resource_template_descriptors()) do
            if
                resource_template.namespaced_uri_template == string.format('%s/dap://stack/{thread_id}', server_name)
            then
                surface.has_dap_stack_template = true
            elseif
                resource_template.namespaced_uri_template == string.format('%s/dap://scopes/{frame_id}', server_name)
            then
                surface.has_dap_scopes_template = true
            elseif
                resource_template.namespaced_uri_template
                == string.format('%s/dap://variables/{variables_reference}', server_name)
            then
                surface.has_dap_variables_template = true
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
            elseif tool.namespaced_name == string.format('%s/git/overview', server_name) then
                surface.has_git_overview_tool = true
            elseif tool.namespaced_name == string.format('%s/git/list_refs', server_name) then
                surface.has_git_list_refs = true
            elseif tool.namespaced_name == string.format('%s/git/list_paths', server_name) then
                surface.has_git_list_paths = true
            elseif tool.namespaced_name == string.format('%s/git/path_state', server_name) then
                surface.has_git_path_state = true
            elseif tool.namespaced_name == string.format('%s/dap/continue', server_name) then
                surface.has_dap_continue = true
            elseif tool.namespaced_name == string.format('%s/dap/pause', server_name) then
                surface.has_dap_pause = true
            elseif tool.namespaced_name == string.format('%s/dap/step_over', server_name) then
                surface.has_dap_step_over = true
            elseif tool.namespaced_name == string.format('%s/dap/step_into', server_name) then
                surface.has_dap_step_into = true
            elseif tool.namespaced_name == string.format('%s/dap/step_out', server_name) then
                surface.has_dap_step_out = true
            elseif tool.namespaced_name == string.format('%s/dap/terminate', server_name) then
                surface.has_dap_terminate = true
            elseif tool.namespaced_name == string.format('%s/dap/disconnect', server_name) then
                surface.has_dap_disconnect = true
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
    surface.has_any_git_tools = surface.has_git_overview_tool
        or surface.has_git_list_refs
        or surface.has_git_list_paths
        or surface.has_git_path_state
    surface.has_any_dap_tools = surface.has_dap_continue
        or surface.has_dap_pause
        or surface.has_dap_step_over
        or surface.has_dap_step_into
        or surface.has_dap_step_out
        or surface.has_dap_terminate
        or surface.has_dap_disconnect
    surface.has_any_tools = surface.has_any_editor_tools
        or surface.has_any_terminal_tools
        or surface.has_any_git_tools
        or surface.has_any_dap_tools

    return surface
end

---@param surface legate.McpGuidanceSurface
---@return string[]
local function active_tool_groups(surface)
    local groups = {}

    if surface.has_any_editor_tools then
        table.insert(groups, 'editor/...')
    end
    if surface.has_any_terminal_tools then
        table.insert(groups, 'terminal/...')
    end
    if surface.has_any_git_tools then
        table.insert(groups, 'git/...')
    end
    if surface.has_any_dap_tools then
        table.insert(groups, 'dap/...')
    end

    return groups
end

---@param server_name string
---@param agent_capabilities? legate.AgentCapabilities
---@return string|nil
local function guidance_for(server_name, agent_capabilities)
    local has_resource_capabilities = supports_mcp_family(agent_capabilities, 'resources')
    local has_tool_capabilities = supports_mcp_family(agent_capabilities, 'tools')
    local surface = available_surface(load_ministry(), server_name)
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
        local tool_groups = active_tool_groups(surface)
        if #tool_groups > 0 then
            table.insert(
                lines,
                string.format(
                    '- When the tool call surface separates server selection from tool selection, choose MCP server `%s` and then tool path %s without repeating the `%s/` prefix inside the tool-path field.',
                    server_name,
                    tool_group_list(tool_groups),
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

    if has_resource_capabilities and surface.has_tasks_summary then
        table.insert(
            lines,
            string.format(
                '- For task/build orientation, prefer `%s/tasks://summary` before inventing shell-only workflows; it exposes current generic Overseer task state, including actively running tasks when available.',
                server_name
            )
        )
    end

    if
        has_resource_capabilities
        and (
            surface.has_git_overview
            or surface.has_git_repository
            or surface.has_git_refs
            or surface.has_git_paths
            or surface.has_git_path
        )
    then
        local git_resources = {}
        if surface.has_git_overview then
            table.insert(git_resources, string.format('%s/git://overview', server_name))
        end
        if surface.has_git_repository then
            table.insert(git_resources, string.format('%s/git://repository', server_name))
        end
        if surface.has_git_refs then
            table.insert(git_resources, string.format('%s/git://refs', server_name))
        end
        if surface.has_git_paths then
            table.insert(git_resources, string.format('%s/git://paths', server_name))
        end
        if surface.has_git_path then
            table.insert(git_resources, string.format('%s/git://path', server_name))
        end

        table.insert(
            lines,
            string.format(
                '- For Git/repository orientation, prefer Ministry Git resources such as %s before shelling out to `git`; these are Stratum-backed and editor-visible.',
                quoted_list(git_resources)
            )
        )
    end

    if
        has_resource_capabilities
        and (surface.has_dap_summary or surface.has_dap_breakpoints or surface.has_dap_threads)
    then
        local dap_resources = {}

        if surface.has_dap_summary then
            table.insert(dap_resources, string.format('%s/dap://summary', server_name))
        end
        if surface.has_dap_breakpoints then
            table.insert(dap_resources, string.format('%s/dap://breakpoints', server_name))
        end
        if surface.has_dap_threads then
            table.insert(dap_resources, string.format('%s/dap://threads', server_name))
        end

        table.insert(
            lines,
            string.format(
                '- When debugging through `dap.nvim`, prefer the MCP debugger resources for live debugger state, such as %s.',
                quoted_list(dap_resources)
            )
        )
    end

    if has_resource_capabilities and (surface.has_dap_stack_template or surface.has_dap_scopes_template) then
        local dap_templates = {}
        if surface.has_dap_stack_template then
            table.insert(dap_templates, string.format('%s/dap://stack/{thread_id}', server_name))
        end
        if surface.has_dap_scopes_template then
            table.insert(dap_templates, string.format('%s/dap://scopes/{frame_id}', server_name))
        end
        if surface.has_dap_variables_template then
            table.insert(dap_templates, string.format('%s/dap://variables/{variables_reference}', server_name))
        end

        table.insert(
            lines,
            string.format(
                '- After reading debugger threads or the current frame, follow the DAP resource-template flow for deeper inspection using %s.',
                quoted_list(dap_templates)
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

    if has_tool_capabilities and surface.has_any_git_tools then
        local git_tools = {}

        if surface.has_git_overview_tool then
            table.insert(git_tools, string.format('%s/git/overview', server_name))
        end
        if surface.has_git_list_refs then
            table.insert(git_tools, string.format('%s/git/list_refs', server_name))
        end
        if surface.has_git_list_paths then
            table.insert(git_tools, string.format('%s/git/list_paths', server_name))
        end
        if surface.has_git_path_state then
            table.insert(git_tools, string.format('%s/git/path_state', server_name))
        end

        table.insert(
            lines,
            string.format(
                '- Use Git MCP tools for explicit-path repository questions, especially %s, instead of re-deriving editor-visible Git state from shell commands.',
                quoted_list(git_tools)
            )
        )
    end

    if has_tool_capabilities and surface.has_any_dap_tools then
        local dap_tools = {}

        if surface.has_dap_continue then
            table.insert(dap_tools, string.format('%s/dap/continue', server_name))
        end
        if surface.has_dap_pause then
            table.insert(dap_tools, string.format('%s/dap/pause', server_name))
        end
        if surface.has_dap_step_over then
            table.insert(dap_tools, string.format('%s/dap/step_over', server_name))
        end
        if surface.has_dap_step_into then
            table.insert(dap_tools, string.format('%s/dap/step_into', server_name))
        end
        if surface.has_dap_step_out then
            table.insert(dap_tools, string.format('%s/dap/step_out', server_name))
        end
        if surface.has_dap_terminate then
            table.insert(dap_tools, string.format('%s/dap/terminate', server_name))
        end
        if surface.has_dap_disconnect then
            table.insert(dap_tools, string.format('%s/dap/disconnect', server_name))
        end

        table.insert(
            lines,
            string.format(
                '- Treat debugger control as MCP tool calls, using the surfaced `dap/...` tools for continue, pause, step, and stop operations such as %s.',
                quoted_list(dap_tools)
            )
        )
    end

    if #lines <= 3 then
        return nil
    end

    return table.concat(lines, '\n')
end

---@param ministry table|nil
---@param current_session? legate.Session
---@param agent_capabilities? legate.AgentCapabilities
---@return table[]
local function forwarded_server_guidance(ministry, current_session, agent_capabilities)
    if ministry == nil then
        return {}
    end

    local blocks = {}
    local seen = {}
    local known_guidance = {}
    local context = {
        consumer = 'legate',
        session = current_session,
        agent_capabilities = agent_capabilities,
    }

    if type(ministry.list_server_guidance) == 'function' then
        for _, descriptor in ipairs(ministry.list_server_guidance(context) or {}) do
            if
                type(descriptor) == 'table'
                and type(descriptor.server) == 'string'
                and type(descriptor.guidance) == 'string'
                and descriptor.guidance ~= ''
            then
                known_guidance[descriptor.server] = descriptor.guidance
            end
        end
    end

    for _, server in ipairs(runtime.effective_servers(current_session, { passive = true })) do
        local server_name = type(server) == 'table' and server.name or nil

        if type(server_name) == 'string' and server_name ~= '' and not seen[server_name] then
            seen[server_name] = true

            local guidance = known_guidance[server_name]

            if guidance == nil and next(known_guidance) == nil and type(ministry.server_guidance) == 'function' then
                local ok, value = pcall(ministry.server_guidance, server_name, context)
                if ok and type(value) == 'string' and value ~= '' then
                    guidance = value
                end
            end

            if type(guidance) == 'string' and guidance ~= '' then
                table.insert(
                    blocks,
                    string.format('Additional guidance for MCP server `%s`:\n%s', server_name, guidance)
                )
            end
        end
    end

    return blocks
end

function M.prepend(prompt, agent_capabilities, current_session)
    local adapter = config.adapter_for_session(current_session)

    if not adapter.mcp_nvim_guidance or not has_any_mcp_capability(agent_capabilities) then
        return prompt
    end

    local ministry = load_ministry()
    local injected_server_name = runtime.injected_server_name and runtime.injected_server_name() or 'neovim'
    local server_name = nil
    local effective_servers = runtime.effective_servers(current_session, { passive = true })

    for _, server in ipairs(effective_servers) do
        if server.name == injected_server_name then
            server_name = server.name
            break
        end
    end

    if server_name == nil then
        return prompt
    end

    local blocks = {}
    local base_guidance = guidance_for(server_name, agent_capabilities)
    if base_guidance ~= nil then
        table.insert(blocks, base_guidance)
    end

    vim.list_extend(blocks, forwarded_server_guidance(ministry, current_session, agent_capabilities))

    if #blocks == 0 then
        return prompt
    end

    local guidance = table.concat(blocks, '\n\n')

    if vim.startswith(prompt, guidance) then
        return prompt
    end

    return string.format('%s\n\n%s', guidance, prompt)
end

---@param current_session? legate.Session
---@param agent_capabilities? legate.AgentCapabilities
---@return string|nil
function M.guidance(current_session, agent_capabilities)
    local adapter = config.adapter_for_session(current_session)

    if not adapter.mcp_nvim_guidance or not has_any_mcp_capability(agent_capabilities) then
        return nil
    end

    local ministry = load_ministry()
    local injected_server_name = runtime.injected_server_name and runtime.injected_server_name() or 'neovim'
    local server_name = nil
    local effective_servers = runtime.effective_servers(current_session, { passive = true })

    for _, server in ipairs(effective_servers) do
        if server.name == injected_server_name then
            server_name = server.name
            break
        end
    end

    if server_name == nil then
        return nil
    end

    local blocks = {}
    local base_guidance = guidance_for(server_name, agent_capabilities)
    if base_guidance ~= nil then
        table.insert(blocks, base_guidance)
    end

    vim.list_extend(blocks, forwarded_server_guidance(ministry, current_session, agent_capabilities))

    return #blocks > 0 and table.concat(blocks, '\n\n') or nil
end

return M
