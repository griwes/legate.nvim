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
---@return boolean
local function has_any_mcp_capability(agent_capabilities)
    if agent_capabilities == nil or type(agent_capabilities.mcpCapabilities) ~= 'table' then
        return false
    end

    return has_enabled_capability(agent_capabilities.mcpCapabilities)
end

---@param agent_capabilities? legate.AgentCapabilities
---@return legate.AgentCapabilities?
local function guidance_capabilities(agent_capabilities)
    if agent_capabilities == nil or type(agent_capabilities.mcpCapabilities) ~= 'table' then
        return agent_capabilities
    end

    if has_any_mcp_capability(agent_capabilities) then
        return agent_capabilities
    end

    local normalized = vim.deepcopy(agent_capabilities)
    normalized.mcpCapabilities = nil
    return normalized
end

---@return table|nil
local function load_ministry()
    local ok, ministry = pcall(require, 'ministry')
    return ok and ministry or nil
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
        agent_capabilities = guidance_capabilities(agent_capabilities),
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

    if not adapter.mcp_nvim_guidance then
        return prompt
    end

    local blocks = forwarded_server_guidance(load_ministry(), current_session, agent_capabilities)

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

    if not adapter.mcp_nvim_guidance then
        return nil
    end

    local blocks = forwarded_server_guidance(load_ministry(), current_session, agent_capabilities)

    return #blocks > 0 and table.concat(blocks, '\n\n') or nil
end

return M
