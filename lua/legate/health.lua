local M = {}

function M.check()
    vim.health.start('legate.nvim')

    if vim.fn.has('nvim-0.11') == 1 then
        vim.health.ok('Neovim 0.11 or newer')
    else
        vim.health.error('Neovim 0.11 or newer is required')
    end

    local config = require('legate.config').get()
    local adapter = config.adapters[config.default_adapter]
    local command = adapter and adapter.command
    command = type(command) == 'table' and command[1] or command
    if type(command) == 'string' and vim.fn.executable(command) == 1 then
        vim.health.ok('Default ACP adapter is executable: ' .. command)
    else
        vim.health.warn('Default ACP adapter is not executable: ' .. tostring(command))
    end

    if config.terminal_backend == 'terminalia' and not pcall(require, 'terminalia') then
        vim.health.error('terminal_backend is terminalia, but terminalia.nvim is unavailable')
    elseif config.terminal_backend == 'terminalia' then
        vim.health.ok('Terminalia terminal backend is available')
    else
        vim.health.ok('Native terminal backend is selected')
    end

    if config.enable_mcp_nvim and not pcall(require, 'ministry') then
        vim.health.error('enable_mcp_nvim is set, but ministry.nvim is unavailable')
    end
end

return M
