local fs = require('legate.handlers.fs')
local permission = require('legate.handlers.permission')
local session_notification = require('legate.handlers.session_notification')
local terminal = require('legate.handlers.terminal')

---@alias legate.ExtensionRequestHandler fun(ctx: legate.TransportContext, params: table, respond: fun(result?: any, error?: table))
---@alias legate.ExtensionNotificationHandler fun(ctx: legate.TransportContext, params: table)

local M = {}

---@type table<string, legate.ExtensionRequestHandler>
local extension_request_handlers = {}

---@type table<string, legate.ExtensionNotificationHandler>
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

---@return table<string, legate.RequestHandlerDescriptor>
function M.request_handlers()
    local handlers = {}
    extend(handlers, permission.request_handlers())
    extend(handlers, fs.request_handlers())
    extend(handlers, terminal.request_handlers())
    return handlers
end

---@return table<string, fun(ctx: legate.TransportContext, params: table, generation?: integer)>
function M.notification_handlers()
    local handlers = {}
    extend(handlers, session_notification.notification_handlers())
    return handlers
end

---@param method string
---@param handler legate.ExtensionRequestHandler
function M.register_request(method, handler)
    validate_extension_method(method)
    extension_request_handlers[method] = handler
end

---@param method string
---@param handler legate.ExtensionNotificationHandler
function M.register_notification(method, handler)
    validate_extension_method(method)
    extension_notification_handlers[method] = handler
end

---@param method string
---@return legate.ExtensionRequestHandler?
function M.extension_request_handler(method)
    return extension_request_handlers[method]
end

---@param method string
---@return legate.ExtensionNotificationHandler?
function M.extension_notification_handler(method)
    return extension_notification_handlers[method]
end

function M.clear_extensions()
    extension_request_handlers = {}
    extension_notification_handlers = {}
end

return M
