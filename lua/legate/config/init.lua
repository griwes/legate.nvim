local defaults = {
    chat_buffer_name = 'Legate',
    filetype = 'markdown',
    auto_create_session = true,
    persist_sessions = true,
    restore_sessions_on_setup = false,
    session_state_file = vim.fs.joinpath(vim.fn.stdpath('state'), 'legate.nvim', 'sessions.json'),
    terminal_backend = 'native',
    auto_open_on_setup = false,
    enable_hover_lsp = true,
    prompt_header = '## Prompt',
    transcript_header = '## Transcript',
    protocol_version = 1,
    client_info = {
        name = 'legate.nvim',
        title = 'legate.nvim',
        version = '0.1.0-dev',
    },
    client_capabilities = {
        fs = {
            readTextFile = true,
            writeTextFile = true,
        },
        terminal = true,
    },
    cwd = nil,
    mcp_servers = {},
    enable_mcp_nvim = false,
    mcp_nvim_guidance = true,
    auth_method = nil,
    request_timeout_ms = 20000,
    default_adapter = 'codex',
    adapters = {
        codex = {
            command = { 'codex-acp' },
            env = {},
            protocol_version = 1,
            client_info = {
                name = 'legate.nvim',
                title = 'legate.nvim',
                version = '0.1.0-dev',
            },
            client_capabilities = {
                fs = {
                    readTextFile = true,
                    writeTextFile = true,
                },
                terminal = true,
            },
            cwd = nil,
            mcp_servers = {},
            enable_mcphub = false,
            enable_mcp_nvim = false,
            mcp_nvim_guidance = true,
            auth_method = nil,
            request_timeout_ms = 20000,
            config_option_overrides = {},
            prompt_prelude = nil,
            prompt_decorator = nil,
            title = 'Legate Codex',
        },
    },
    permission_strategy = 'default',
    permission_default = 'reject_once',
    permission_policy = nil,
}

---@type legate.Config
local current = vim.deepcopy(defaults)

---@class legate.ConfigModule
local M = {}

local function deepcopy(value)
    return vim.deepcopy(value)
end

---@param value any
---@param field string
---@return string[]
local function normalize_command(value, field)
    if not vim.islist(value) or #value == 0 then
        error(string.format('ACP adapter %s must be a non-empty argv list', field))
    end

    local argv = {}

    for _, entry in ipairs(value) do
        if type(entry) ~= 'string' or entry == '' then
            error(string.format('ACP adapter %s must contain only non-empty strings', field))
        end

        table.insert(argv, entry)
    end

    return argv
end

---@param name string
---@param adapter table
---@param base legate.AdapterConfig
---@return legate.AdapterConfig
local function normalize_adapter(name, adapter, base)
    if type(adapter) ~= 'table' then
        error(string.format('ACP adapter %s must be a table', name))
    end

    local normalized = vim.tbl_deep_extend('force', deepcopy(base), deepcopy(adapter))

    normalized.command = normalize_command(normalized.command, string.format('%s.command', name))
    normalized.env = type(normalized.env) == 'table' and deepcopy(normalized.env) or {}
    normalized.protocol_version = tonumber(normalized.protocol_version) or base.protocol_version
    normalized.client_info = type(normalized.client_info) == 'table' and deepcopy(normalized.client_info)
        or deepcopy(base.client_info)
    normalized.client_capabilities = type(normalized.client_capabilities) == 'table'
            and deepcopy(normalized.client_capabilities)
        or deepcopy(base.client_capabilities)
    normalized.cwd = type(normalized.cwd) == 'string' and normalized.cwd or nil
    normalized.mcp_servers = type(normalized.mcp_servers) == 'table' and deepcopy(normalized.mcp_servers) or {}
    normalized.enable_mcphub = normalized.enable_mcphub == true
    normalized.enable_mcp_nvim = normalized.enable_mcp_nvim == true
    normalized.mcp_nvim_guidance = normalized.mcp_nvim_guidance ~= false
    normalized.auth_method = type(normalized.auth_method) == 'string' and normalized.auth_method or nil
    normalized.request_timeout_ms = tonumber(normalized.request_timeout_ms) or base.request_timeout_ms
    normalized.config_option_overrides = type(normalized.config_option_overrides) == 'table'
            and deepcopy(normalized.config_option_overrides)
        or {}
    normalized.prompt_prelude = type(normalized.prompt_prelude) == 'string' and normalized.prompt_prelude or nil
    normalized.prompt_decorator = type(normalized.prompt_decorator) == 'function' and normalized.prompt_decorator or nil
    normalized.title = type(normalized.title) == 'string' and normalized.title or nil
    normalized.description = type(normalized.description) == 'string' and normalized.description or nil

    return normalized
end

---@param adapters table<string, legate.AdapterConfig>
---@return string[]
local function sorted_adapter_names(adapters)
    local names = {}

    for name, _ in pairs(adapters) do
        table.insert(names, name)
    end

    table.sort(names)

    return names
end

---@return legate.AdapterConfig
---@param merged legate.Config
---@return legate.AdapterConfig
local function base_adapter_defaults(merged)
    local base = deepcopy(defaults.adapters.codex)
    base.protocol_version = tonumber(merged.protocol_version) or base.protocol_version
    base.client_info = type(merged.client_info) == 'table' and deepcopy(merged.client_info) or base.client_info
    base.client_capabilities = type(merged.client_capabilities) == 'table' and deepcopy(merged.client_capabilities)
        or base.client_capabilities
    base.cwd = type(merged.cwd) == 'string' and merged.cwd or nil
    base.mcp_servers = type(merged.mcp_servers) == 'table' and deepcopy(merged.mcp_servers) or {}
    base.enable_mcphub = merged.enable_mcphub == true
    base.enable_mcp_nvim = merged.enable_mcp_nvim == true
    base.mcp_nvim_guidance = merged.mcp_nvim_guidance ~= false
    base.auth_method = type(merged.auth_method) == 'string' and merged.auth_method or nil
    base.request_timeout_ms = tonumber(merged.request_timeout_ms) or base.request_timeout_ms
    base.prompt_prelude = type(merged.prompt_prelude) == 'string' and merged.prompt_prelude or nil
    base.prompt_decorator = type(merged.prompt_decorator) == 'function' and merged.prompt_decorator or nil
    return base
end

---@param opts? Partial<legate.Config>
---@return legate.Config
local function normalize(opts)
    local merged = vim.tbl_deep_extend('force', deepcopy(defaults), opts or {})
    local normalized = vim.tbl_deep_extend('force', deepcopy(defaults), merged)
    local adapters = {}
    local configured_adapters = type(opts) == 'table' and type(opts.adapters) == 'table' and deepcopy(opts.adapters)
        or {}
    local base = base_adapter_defaults(merged)

    if next(configured_adapters) == nil then
        configured_adapters[normalized.default_adapter] = {}
    end

    for name, adapter in pairs(configured_adapters) do
        if type(name) ~= 'string' or name == '' then
            error('ACP adapter names must be non-empty strings')
        end

        adapters[name] = normalize_adapter(name, adapter, base)
    end

    if next(adapters) == nil then
        error('ACP configuration must define at least one adapter')
    end

    normalized.adapters = adapters

    if type(normalized.default_adapter) ~= 'string' or normalized.default_adapter == '' then
        error('ACP default_adapter must be a non-empty string')
    end

    if normalized.adapters[normalized.default_adapter] == nil then
        error(string.format('Unknown ACP default adapter: %s', normalized.default_adapter))
    end

    if normalized.terminal_backend == 'terminal_manager' then
        normalized.terminal_backend = 'terminalia'
    end

    if normalized.terminal_backend ~= 'native' and normalized.terminal_backend ~= 'terminalia' then
        error(string.format('Unsupported ACP terminal backend in the bootstrap slice: %s', normalized.terminal_backend))
    end

    if normalized.permission_strategy ~= 'default' and normalized.permission_strategy ~= 'select' then
        error(string.format('Unsupported ACP permission_strategy: %s', normalized.permission_strategy))
    end

    if normalized.permission_default == nil then
        error('ACP permission_default must not be nil')
    end

    normalized.permission_policy = type(normalized.permission_policy) == 'function' and normalized.permission_policy
        or nil

    return normalized
end

---Return the effective ACP configuration.
---@return legate.Config
function M.get()
    return current
end

---Normalize and store ACP configuration.
---@param opts? Partial<legate.Config>
---@return legate.Config
function M.set(opts)
    current = normalize(opts)
    return current
end

---Reset configuration to defaults.
---@return legate.Config
function M.reset()
    current = deepcopy(defaults)
    return current
end

---@return string[]
function M.adapter_names()
    return sorted_adapter_names(current.adapters or {})
end

---@return string
function M.default_adapter_name()
    return current.default_adapter
end

---@param adapter_name string
---@return legate.AdapterConfig
function M.adapter(adapter_name)
    local adapter = current.adapters[adapter_name]

    if adapter == nil then
        error(string.format('Unknown ACP adapter: %s', adapter_name))
    end

    return deepcopy(adapter)
end

---@param current_session? legate.Session
---@return string
function M.session_adapter_name(current_session)
    if
        current_session ~= nil
        and type(current_session.adapter_name) == 'string'
        and current_session.adapter_name ~= ''
    then
        return current_session.adapter_name
    end

    return M.default_adapter_name()
end

---@param current_session? legate.Session
---@return legate.AdapterConfig
function M.adapter_for_session(current_session)
    return M.adapter(M.session_adapter_name(current_session))
end

return M
