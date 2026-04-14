local api = require('legate.api')
local commands = require('legate.commands')
local config = require('legate.config')
local surface = require('legate.ui.surface')

---@class legate.RootModule
---@field config legate.Config
---@field api legate.Api

local M = {}
local augroup = vim.api.nvim_create_augroup('legate.nvim', {
    clear = true,
})

M.config = config.get()
M.api = api
commands.ensure()

local function configure_autocmds()
    vim.api.nvim_clear_autocmds({
        group = augroup,
    })

    vim.api.nvim_create_autocmd('ColorScheme', {
        group = augroup,
        callback = function()
            surface.invalidate_highlights()
            surface.refresh_highlights()
        end,
    })

    if config.get().persist_sessions then
        vim.api.nvim_create_autocmd('VimLeavePre', {
            group = augroup,
            callback = function()
                pcall(api.save_sessions)
            end,
        })
    end
end

---Configure ACP.
---@param opts? Partial<legate.Config>
---@return legate.Config
function M.setup(opts)
    M.config = config.set(opts)
    configure_autocmds()
    surface.refresh_highlights()

    if M.config.persist_sessions and M.config.restore_sessions_on_setup then
        api.restore_sessions({
            open_chat = M.config.auto_open_on_setup,
        })
    elseif M.config.auto_open_on_setup then
        api.open_chat()
    end

    return M.config
end

return M
