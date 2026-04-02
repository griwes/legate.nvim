local api = require('acp.api')
local commands = require('acp.commands')
local config = require('acp.config')

---@class acp.RootModule
---@field config acp.Config
---@field api acp.Api

local M = {}
local augroup = vim.api.nvim_create_augroup('acp.nvim', {
    clear = true,
})

M.config = config.get()
M.api = api
commands.ensure()

local function configure_autocmds()
    vim.api.nvim_clear_autocmds({
        group = augroup,
    })

    if not config.get().persist_sessions then
        return
    end

    vim.api.nvim_create_autocmd('VimLeavePre', {
        group = augroup,
        callback = function()
            pcall(api.save_sessions)
        end,
    })
end

---Configure ACP.
---@param opts? Partial<acp.Config>
---@return acp.Config
function M.setup(opts)
    M.config = config.set(opts)
    configure_autocmds()

    if M.config.restore_sessions_on_setup then
        api.restore_sessions({
            open_chat = M.config.auto_open_on_setup,
        })
    elseif M.config.auto_open_on_setup then
        api.open_chat()
    end

    return M.config
end

return M
