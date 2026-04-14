local hover = require('legate.ui.hover')

---@class legate.HoverLspModule
local M = {}

local client_name = 'acp-hover'

---@param dispatchers vim.lsp.rpc.Dispatchers
---@param bufnr integer
---@return vim.lsp.rpc.PublicClient
function M.server(dispatchers, bufnr)
    local id = 0
    local closing = false

    return {
        request = function(method, params, callback)
            id = id + 1

            if method == 'initialize' then
                callback(nil, {
                    capabilities = {
                        hoverProvider = true,
                    },
                }, id)
            elseif method == 'textDocument/hover' then
                callback(nil, hover.hover_result(bufnr, params.position.line), id)
            elseif method == 'shutdown' then
                callback(nil, nil, id)
            end

            return true, id
        end,
        notify = function(method)
            if method == 'exit' then
                dispatchers.on_exit(0, 15)
            end

            return true
        end,
        is_closing = function()
            return closing
        end,
        terminate = function()
            closing = true
        end,
    }
end

---@param bufnr integer
function M.attach(bufnr)
    vim.lsp.start({
        name = client_name,
        cmd = function(dispatchers)
            return M.server(dispatchers, bufnr)
        end,
    }, {
        bufnr = bufnr,
        reuse_client = function(client, config)
            return client.name == config.name and client.attached_buffers[bufnr]
        end,
    })
end

return M
