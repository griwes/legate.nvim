local fs = require('acp.handlers.fs')
local permission = require('acp.handlers.permission')
local session_notification = require('acp.handlers.session_notification')
local terminal = require('acp.handlers.terminal')

---@alias acp.ExtensionRequestHandler fun(ctx: acp.TransportContext, params: table, respond: fun(result?: any, error?: table))
---@alias acp.ExtensionNotificationHandler fun(ctx: acp.TransportContext, params: table)

local M = {}

---@type table<string, acp.ExtensionRequestHandler>
local extension_request_handlers = {}

---@type table<string, acp.ExtensionNotificationHandler>
local extension_notification_handlers = {}

---@param target table
---@param source table
local function extend(target, source)
    for method, handler in pairs(source) do
        target[method] = handler
    end
end

---@param method string
local function validate_extension_method(method)
    if type(method) ~= 'string' or not vim.startswith(method, '_') then
        error(string.format('ACP extension methods must begin with `_`: %s', tostring(method)))
    end
end

---@return table<string, acp.RequestHandlerDescriptor>
function M.request_handlers()
    local handlers = {}
    extend(handlers, permission.request_handlers())
    extend(handlers, fs.request_handlers())
    extend(handlers, terminal.request_handlers())
    return handlers
end

---@return table<string, fun(ctx: acp.TransportContext, params: table, generation?: integer)>
function M.notification_handlers()
    local handlers = {}
    extend(handlers, session_notification.notification_handlers())
    return handlers
end

---@param method string
---@param handler acp.ExtensionRequestHandler
function M.register_request(method, handler)
    validate_extension_method(method)
    extension_request_handlers[method] = handler
end

---@param method string
---@param handler acp.ExtensionNotificationHandler
function M.register_notification(method, handler)
    validate_extension_method(method)
    extension_notification_handlers[method] = handler
end

---@param method string
---@return acp.ExtensionRequestHandler?
function M.extension_request_handler(method)
    return extension_request_handlers[method]
end

---@param method string
---@return acp.ExtensionNotificationHandler?
function M.extension_notification_handler(method)
    return extension_notification_handlers[method]
end

function M.clear_extensions()
    extension_request_handlers = {}
    extension_notification_handlers = {}
end

return M
