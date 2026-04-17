local M = {}

---@class legate.GuidanceRegistration
---@field owner string
---@field provider string|fun(ctx: legate.GuidanceContext): string|string[]|nil
---@field priority integer
---@field requires_mcp_families? string[]

---@class legate.GuidanceContext
---@field adapter legate.AdapterConfig
---@field session? legate.Session
---@field agent_capabilities? legate.AgentCapabilities

---@type table<string, legate.GuidanceRegistration>
local registrations = {}

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

---@param value unknown
---@return string[]|nil
local function normalize_blocks(value)
    if type(value) == 'string' then
        return value ~= '' and { value } or nil
    end

    if type(value) ~= 'table' or not vim.islist(value) then
        return nil
    end

    local blocks = {}
    for _, item in ipairs(value) do
        if type(item) == 'string' and item ~= '' then
            table.insert(blocks, item)
        end
    end

    return #blocks > 0 and blocks or nil
end

---@param opts? table
---@return integer
local function normalize_priority(opts)
    local priority = type(opts) == 'table' and opts.priority or nil

    if type(priority) ~= 'number' or priority % 1 ~= 0 then
        return 100
    end

    return priority
end

---@param opts? table
---@return string[]|nil
local function normalize_required_families(opts)
    local value = type(opts) == 'table' and opts.requires_mcp_families or nil

    if type(value) == 'string' and value ~= '' then
        return { value }
    end

    if type(value) ~= 'table' or not vim.islist(value) then
        return nil
    end

    local families = {}
    for _, item in ipairs(value) do
        if type(item) == 'string' and item ~= '' then
            table.insert(families, item)
        end
    end

    return #families > 0 and families or nil
end

---@param registration legate.GuidanceRegistration
---@param ctx legate.GuidanceContext
---@return string[]|nil
local function blocks_for(registration, ctx)
    if registration.requires_mcp_families ~= nil then
        for _, family in ipairs(registration.requires_mcp_families) do
            if not supports_mcp_family(ctx.agent_capabilities, family) then
                return nil
            end
        end
    end

    if type(registration.provider) == 'string' then
        return normalize_blocks(registration.provider)
    end

    local ok, value = pcall(registration.provider, ctx)
    if not ok then
        vim.notify(
            string.format('Legate guidance provider %s failed: %s', registration.owner, tostring(value)),
            vim.log.levels.WARN
        )
        return nil
    end

    return normalize_blocks(value)
end

---@param owner string
---@param provider string|fun(ctx: legate.GuidanceContext): string|string[]|nil
---@param opts? table
---@return boolean, string?
function M.register(owner, provider, opts)
    if type(owner) ~= 'string' or owner == '' then
        return false, 'guidance owner must be a non-empty string'
    end

    if type(provider) ~= 'string' and type(provider) ~= 'function' then
        return false, 'guidance provider must be a string or function'
    end

    registrations[owner] = {
        owner = owner,
        provider = provider,
        priority = normalize_priority(opts),
        requires_mcp_families = normalize_required_families(opts),
    }

    return true, nil
end

---@param owner string
function M.unregister(owner)
    registrations[owner] = nil
end

---@return legate.GuidanceRegistration[]
function M.list()
    local items = {}

    for _, registration in pairs(registrations) do
        table.insert(items, vim.deepcopy(registration))
    end

    table.sort(items, function(left, right)
        if left.priority ~= right.priority then
            return left.priority < right.priority
        end

        return left.owner < right.owner
    end)

    return items
end

---@param ctx legate.GuidanceContext
---@return string|nil
function M.compose(ctx)
    local blocks = {}

    for _, registration in ipairs(M.list()) do
        local contributed = blocks_for(registration, ctx)
        if contributed ~= nil then
            vim.list_extend(blocks, contributed)
        end
    end

    return #blocks > 0 and table.concat(blocks, '\n\n') or nil
end

function M.clear()
    registrations = {}
end

return M
