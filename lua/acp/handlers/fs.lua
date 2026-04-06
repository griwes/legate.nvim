local methods = require('acp.methods')

local M = {}

---@return table<string, acp.RequestHandlerDescriptor>
function M.request_handlers()
    return {
        [methods.FS_READ_TEXT_FILE] = {
            requires_active_session = true,
            handle = function(ctx, params, respond, current_session)
                params.cwd = params.cwd or (current_session and current_session.cwd)
                local result, error = ctx.fs.read_text_file(params)
                respond(result, error)
            end,
        },
        [methods.FS_WRITE_TEXT_FILE] = {
            requires_active_session = true,
            handle = function(ctx, params, respond, current_session)
                params.cwd = params.cwd or (current_session and current_session.cwd)
                local result, error = ctx.fs.write_text_file(params)

                if error == nil and current_session ~= nil then
                    ctx.rerender(current_session)
                end

                respond(result, error)
            end,
        },
    }
end

return M
