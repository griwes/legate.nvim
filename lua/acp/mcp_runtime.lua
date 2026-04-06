local config = require('acp.config')

local M = {}
local missing_mcp_warned = false
local injected_server_cache = nil
local injected_server_cache_key = nil

local function injected_server_name()
    return 'acp.nvim'
end

M.injected_server_name = injected_server_name

local function is_acp_managed_server(server)
    return type(server) == 'table' and (server.name == injected_server_name() or server.name == 'neovim')
end

local function transport_descriptor(mcp, opts)
    opts = opts or {}

    local http_descriptor = mcp.http_endpoint and mcp.http_endpoint() or nil

    if http_descriptor ~= nil and http_descriptor.url ~= nil then
        return 'http', http_descriptor
    end

    local stdio_descriptor = mcp.endpoint and mcp.endpoint() or nil

    if stdio_descriptor == nil then
        if opts.allow_missing_stdio then
            return nil, nil
        end

        assert(stdio_descriptor ~= nil, 'mcp.nvim did not produce an endpoint descriptor')
    end

    return 'stdio', stdio_descriptor
end

local function endpoint_cache_key(transport_name, descriptor)
    if transport_name == 'http' then
        return table.concat({ 'http', tostring(descriptor.url) }, '\0')
    end

    return table.concat({
        'stdio',
        tostring(descriptor.command),
        vim.inspect(descriptor.args or {}),
        vim.inspect(descriptor.env or {}),
    }, '\0')
end

local function current_injected_server_descriptor(mcp, opts)
    local transport_name, descriptor = transport_descriptor(mcp, opts or { allow_missing_stdio = true })

    if transport_name == nil or descriptor == nil then
        return nil, nil
    end

    local cache_key = endpoint_cache_key(transport_name, descriptor)

    if transport_name == 'http' then
        return {
            type = 'http',
            name = injected_server_name(),
            url = descriptor.url,
        },
            cache_key
    end

    return {
        type = 'stdio',
        name = injected_server_name(),
        command = descriptor.command,
        args = descriptor.args,
        env = descriptor.env,
    },
        cache_key
end

local function injected_server_descriptor(opts)
    opts = opts or {}
    local ok, mcp = pcall(require, 'mcp')

    if not ok then
        if not missing_mcp_warned then
            missing_mcp_warned = true
            vim.notify(
                'ACP enable_mcp_nvim is enabled, but mcp.nvim is not installed on the runtimepath',
                vim.log.levels.WARN
            )
        end
        return nil
    end

    local descriptor, cache_key = current_injected_server_descriptor(mcp, { allow_missing_stdio = true })

    if descriptor ~= nil and injected_server_cache ~= nil and injected_server_cache_key == cache_key then
        return vim.deepcopy(injected_server_cache)
    end

    if descriptor ~= nil then
        injected_server_cache = descriptor
        injected_server_cache_key = cache_key

        if not opts.passive then
            local start_ok, start_error = mcp.start_all()

            if not start_ok then
                error(string.format('Failed to start mcp.nvim endpoint: %s', tostring(start_error)))
            end

            descriptor, cache_key = current_injected_server_descriptor(mcp)
            assert(descriptor ~= nil and cache_key ~= nil, 'mcp.nvim did not produce an endpoint descriptor')
            injected_server_cache = descriptor
            injected_server_cache_key = cache_key
        end

        return vim.deepcopy(descriptor)
    end

    if opts.passive then
        return nil
    end

    local start_ok, start_error = mcp.start_all()

    if not start_ok then
        error(string.format('Failed to start mcp.nvim endpoint: %s', tostring(start_error)))
    end

    descriptor, cache_key = current_injected_server_descriptor(mcp)
    assert(descriptor ~= nil and cache_key ~= nil, 'mcp.nvim did not produce an endpoint descriptor')

    if injected_server_cache ~= nil and injected_server_cache_key == cache_key then
        return vim.deepcopy(injected_server_cache)
    end

    injected_server_cache = descriptor
    injected_server_cache_key = cache_key

    return vim.deepcopy(injected_server_cache)
end

---@return table[]
function M.effective_servers(opts)
    opts = opts or {}
    local servers = vim.deepcopy(config.get().mcp_servers or {})

    if not config.get().enable_mcp_nvim then
        return servers
    end

    local replacement = injected_server_descriptor(opts.passive and { passive = true } or nil)

    if replacement == nil then
        return servers
    end

    local replaced = false
    local deduped_servers = {}

    for _, server in ipairs(servers) do
        if is_acp_managed_server(server) then
            if not replaced then
                table.insert(deduped_servers, vim.deepcopy(replacement))
                replaced = true
            end
        else
            table.insert(deduped_servers, server)
        end
    end

    servers = deduped_servers

    if not replaced then
        table.insert(servers, 1, replacement)
    end

    return servers
end

---@return table[]
function M.static_servers()
    return vim.deepcopy(config.get().mcp_servers or {})
end

return M
