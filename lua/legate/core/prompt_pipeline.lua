local config = require('legate.config')
local guidance_registry = require('legate.guidance.registry')
local mcp_guidance = require('legate.mcp.guidance')

local M = {}

---@param prompt string
---@param prelude? string
---@return string
local function prepend_once(prompt, prelude)
    if type(prelude) ~= 'string' or prelude == '' then
        return prompt
    end

    if vim.startswith(prompt, prelude) then
        return prompt
    end

    return string.format('%s\n\n%s', prelude, prompt)
end

---@param prompt string
---@param agent_capabilities? legate.AgentCapabilities
---@param current_session? legate.Session
---@return string
function M.decorate(prompt, agent_capabilities, current_session)
    local adapter = config.adapter_for_session(current_session)
    adapter.name = config.session_adapter_name(current_session)
    local decorated = prompt
    local guidance_blocks = {}
    local mcp_block = mcp_guidance.guidance(current_session, agent_capabilities)
    local plugin_guidance = guidance_registry.compose({
        adapter = adapter,
        session = current_session,
        agent_capabilities = agent_capabilities,
    })

    if mcp_block ~= nil then
        table.insert(guidance_blocks, mcp_block)
    end
    if plugin_guidance ~= nil then
        table.insert(guidance_blocks, plugin_guidance)
    end
    if #guidance_blocks > 0 then
        decorated = prepend_once(decorated, table.concat(guidance_blocks, '\n\n'))
    end

    decorated = prepend_once(decorated, adapter.prompt_prelude)

    if adapter.prompt_decorator ~= nil then
        local next_prompt = adapter.prompt_decorator(decorated, adapter, current_session, agent_capabilities)

        if type(next_prompt) == 'string' and next_prompt ~= '' then
            decorated = next_prompt
        end
    end

    return decorated
end

return M
