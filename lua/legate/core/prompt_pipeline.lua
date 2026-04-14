local config = require('legate.config')
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
    local decorated = mcp_guidance.prepend(prompt, agent_capabilities, current_session)

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
