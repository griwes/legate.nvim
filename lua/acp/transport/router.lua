local handlers = require('acp.handlers')
local methods = require('acp.methods')

---@class acp.RequestHandlerDescriptor
---@field requires_active_session boolean
---@field handle fun(ctx: acp.TransportContext, params: table, respond: fun(result?: any, error?: table), current_session?: acp.Session, generation?: integer)

---@class acp.TransportRouter
---@field ctx acp.TransportContext
---@field request_handlers table<string, acp.RequestHandlerDescriptor>
---@field notification_handlers table<string, fun(ctx: acp.TransportContext, params: table, generation?: integer)>
local M = {}
M.__index = M

---@param method string
---@return table
local function unsupported_request_error(method)
    return {
        code = -32601,
        message = string.format('Unsupported ACP request: %s', method),
    }
end

---@param ctx acp.TransportContext
---@return acp.TransportRouter
function M.new(ctx)
    return setmetatable({
        ctx = ctx,
        request_handlers = handlers.request_handlers(),
        notification_handlers = handlers.notification_handlers(),
    }, M)
end

---@param generation integer
---@param method string
---@param params table
---@param respond fun(result?: any, error?: table)
function M:dispatch_request(generation, method, params, respond)
    if not self.ctx.is_live_generation(generation) then
        if method == methods.SESSION_REQUEST_PERMISSION then
            respond(self.ctx.cancelled_response())
            return
        end

        respond(nil, self.ctx.inactive_request_error())
        return
    end

    local handler = self.request_handlers[method]

    if handler ~= nil then
        local current_session = nil

        if handler.requires_active_session then
            current_session = self.ctx.active_request_session(params)

            if current_session == nil then
                respond(nil, self.ctx.inactive_request_error())
                return
            end
        end

        handler.handle(self.ctx, params, respond, current_session, generation)
        return
    end

    if type(method) == 'string' and vim.startswith(method, '_') then
        local extension_handler = handlers.extension_request_handler(method)

        if extension_handler ~= nil then
            extension_handler(self.ctx, params, respond)
            return
        end
    end

    respond(nil, unsupported_request_error(method))
end

---@param generation integer
---@param method string
---@param params table
function M:dispatch_notification(generation, method, params)
    if not self.ctx.is_live_generation(generation) then
        return
    end

    local handler = self.notification_handlers[method]

    if handler ~= nil then
        handler(self.ctx, params, generation)
        return
    end

    if type(method) == 'string' and vim.startswith(method, '_') then
        local extension_handler = handlers.extension_notification_handler(method)

        if extension_handler ~= nil then
            extension_handler(self.ctx, params)
        end
    end
end

return M
