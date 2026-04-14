local methods = require('legate.core.methods')

local M = {}

---@param ctx legate.TransportContext
---@param params table
local function handle_session_update(ctx, params)
    local current_session = ctx.active_session()

    if current_session == nil then
        return
    end

    if ctx.is_creating_new_session() and current_session.remote_id == nil then
        if
            params.update.sessionUpdate == 'available_commands_update'
            or params.update.sessionUpdate == 'config_option_update'
        then
            ctx.queue_session_update(params.sessionId, params.update)
        end
        return
    end

    local transport_remote_id = ctx.session.transport_remote_id(current_session)

    if transport_remote_id == nil or params.sessionId ~= transport_remote_id then
        return
    end

    if ctx.is_loading_existing_session() then
        if
            params.update.sessionUpdate == 'available_commands_update'
            or params.update.sessionUpdate == 'config_option_update'
        then
            ctx.queue_session_update(params.sessionId, params.update)
        end
        return
    end

    if not ctx.should_apply_update(current_session, params.update) then
        return
    end

    ctx.apply_update(current_session, params.update)
end

---@return table<string, fun(ctx: legate.TransportContext, params: table, generation?: integer)>
function M.notification_handlers()
    return {
        [methods.SESSION_UPDATE] = handle_session_update,
    }
end

return M
