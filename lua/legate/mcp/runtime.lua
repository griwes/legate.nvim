local config = require('legate.config')

local M = {}
local missing_mcp_warned = false
local missing_mcphub_warned = false
local injected_server_cache = nil
local injected_server_cache_key = nil

local function injected_server_name()
    return 'neovim'
end

M.injected_server_name = injected_server_name

---@param current_session_or_opts? legate.Session|{ passive?: boolean }
---@param opts? { passive?: boolean }
---@return legate.Session?, { passive?: boolean }
local function normalize_args(current_session_or_opts, opts)
    if
        opts == nil
        and type(current_session_or_opts) == 'table'
        and current_session_or_opts.id == nil
        and current_session_or_opts.adapter_name == nil
    then
        return nil, current_session_or_opts
    end

    return current_session_or_opts, opts or {}
end

local function is_acp_managed_server(server)
    return type(server) == 'table' and server.name == injected_server_name()
end

---@param adapter legate.AdapterConfig
---@return table[]
local function adapter_servers(adapter)
    local servers = vim.deepcopy(adapter.mcp_servers or {})
    return servers
end

---@param adapter legate.AdapterConfig
---@return table[]
local function mcphub_servers(adapter)
    if not adapter.enable_mcphub then
        return {}
    end

    local ok_mcphub, mcphub = pcall(require, 'ministryhub')

    if not ok_mcphub then
        ok_mcphub, mcphub = pcall(require, 'mcphub')
    end

    local ok_proxy, proxy_module = pcall(require, 'ministryhub.extensions.proxy')

    if not ok_proxy then
        ok_proxy, proxy_module = pcall(require, 'mcphub.extensions.proxy')
    end

    if not ok_mcphub or not ok_proxy then
        if not missing_mcphub_warned then
            missing_mcphub_warned = true
            vim.notify(
                'ACP enable_mcphub is enabled, but MCPHub is not available on the runtimepath',
                vim.log.levels.WARN
            )
        end
        return {}
    end

    local instance = mcphub.get_hub_instance and mcphub.get_hub_instance() or nil

    if instance == nil or (instance.is_ready ~= nil and not instance:is_ready()) then
        return {}
    end

    local proxy = proxy_module.get and proxy_module.get() or nil

    if type(proxy) ~= 'table' then
        return {}
    end

    return {
        vim.tbl_extend('force', { name = 'mcphub' }, vim.deepcopy(proxy)),
    }
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

        assert(stdio_descriptor ~= nil, 'ministry.nvim did not produce an endpoint descriptor')
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
    local ok, mcp = pcall(require, 'ministry')

    if not ok then
        if not missing_mcp_warned then
            missing_mcp_warned = true
            vim.notify(
                'ACP enable_mcp_nvim is enabled, but ministry.nvim is not installed on the runtimepath',
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
                error(string.format('Failed to start ministry.nvim endpoint: %s', tostring(start_error)))
            end

            descriptor, cache_key = current_injected_server_descriptor(mcp)
            assert(descriptor ~= nil and cache_key ~= nil, 'ministry.nvim did not produce an endpoint descriptor')
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
        error(string.format('Failed to start ministry.nvim endpoint: %s', tostring(start_error)))
    end

    descriptor, cache_key = current_injected_server_descriptor(mcp)
    assert(descriptor ~= nil and cache_key ~= nil, 'ministry.nvim did not produce an endpoint descriptor')

    if injected_server_cache ~= nil and injected_server_cache_key == cache_key then
        return vim.deepcopy(injected_server_cache)
    end

    injected_server_cache = descriptor
    injected_server_cache_key = cache_key

    return vim.deepcopy(injected_server_cache)
end

---@param current_session_or_opts? legate.Session|{ passive?: boolean }
---@param opts? { passive?: boolean }
---@return table[]
function M.effective_servers(current_session_or_opts, opts)
    local current_session
    current_session, opts = normalize_args(current_session_or_opts, opts)
    local adapter = config.adapter_for_session(current_session)
    local servers = adapter_servers(adapter)

    vim.list_extend(servers, mcphub_servers(adapter))

    if not adapter.enable_mcp_nvim then
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

---@param current_session? legate.Session
---@return table[]
function M.static_servers(current_session)
    local adapter = config.adapter_for_session(current_session)
    local servers = adapter_servers(adapter)
    vim.list_extend(servers, mcphub_servers(adapter))
    return servers
end

return M
