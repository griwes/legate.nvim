local defaults = {
    chat_buffer_name = 'ACP',
    filetype = 'markdown',
    auto_create_session = true,
    persist_sessions = true,
    restore_sessions_on_setup = false,
    session_state_file = vim.fs.joinpath(vim.fn.stdpath('state'), 'acp.nvim', 'sessions.json'),
    terminal_backend = 'native',
    auto_open_on_setup = false,
    prompt_header = '## Prompt',
    transcript_header = '## Transcript',
    agent_command = { 'codex-acp' },
    agent_env = {},
    protocol_version = 1,
    client_info = {
        name = 'acp.nvim',
        title = 'acp.nvim',
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
    auth_method = nil,
    permission_strategy = 'default',
    permission_default = 'reject_once',
    request_timeout_ms = 20000,
}

---@type acp.Config
local current = vim.deepcopy(defaults)

---@class acp.ConfigModule
local M = {}

---Return the effective ACP configuration.
---@return acp.Config
function M.get()
    return current
end

---Normalize and store ACP configuration.
---@param opts? Partial<acp.Config>
---@return acp.Config
function M.set(opts)
    current = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})

    if current.terminal_backend ~= 'native' and current.terminal_backend ~= 'terminal_manager' then
        error(string.format('Unsupported ACP terminal backend in the bootstrap slice: %s', current.terminal_backend))
    end

    if current.permission_strategy ~= 'default' and current.permission_strategy ~= 'select' then
        error(string.format('Unsupported ACP permission_strategy: %s', current.permission_strategy))
    end

    if current.permission_default == nil then
        error('ACP permission_default must not be nil')
    end

    return current
end

---Reset configuration to defaults.
---@return acp.Config
function M.reset()
    current = vim.deepcopy(defaults)
    return current
end

return M
