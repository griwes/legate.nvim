local methods = require('legate.core.methods')

local M = {}

---@param terminal_method string
---@param callback fun(terminal_module: legate.TerminalModule, params: table): any, table?
---@return legate.RequestHandlerDescriptor
local function terminal_handler(callback)
    return {
        requires_active_session = true,
        handle = function(ctx, params, respond)
            local result, error = callback(ctx.terminal, params)
            respond(result, error)
        end,
    }
end

---@return table<string, legate.RequestHandlerDescriptor>
function M.request_handlers()
    return {
        [methods.TERMINAL_CREATE] = terminal_handler(function(terminal_module, params)
            return terminal_module.create(params)
        end),
        [methods.TERMINAL_OUTPUT] = terminal_handler(function(terminal_module, params)
            return terminal_module.output(params)
        end),
        [methods.TERMINAL_WAIT_FOR_EXIT] = terminal_handler(function(terminal_module, params)
            return terminal_module.wait_for_exit(params)
        end),
        [methods.TERMINAL_KILL] = terminal_handler(function(terminal_module, params)
            return terminal_module.kill(params)
        end),
        [methods.TERMINAL_RELEASE] = terminal_handler(function(terminal_module, params)
            return terminal_module.release(params)
        end),
    }
end

return M
