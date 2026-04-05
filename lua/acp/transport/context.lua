---@class acp.TransportContext
---@field config acp.ConfigModule
---@field fs acp.FileSystemModule
---@field methods table
---@field session acp.SessionModule
---@field terminal acp.TerminalModule
---@field active_request_session fun(params: { sessionId?: string }): acp.Session?
---@field active_session fun(): acp.Session?
---@field apply_update fun(current_session: acp.Session, update: table)
---@field cancelled_response fun(): table
---@field cancel_pending_permission fun(current_session?: acp.Session)
---@field get_pending_permissions fun(): acp.PendingPermissionState[]
---@field pending_permission_by_session fun(session_id: string): acp.PendingPermissionState?
---@field pending_permission_by_tool_call fun(session_id: string, tool_call_id?: string): acp.PendingPermissionState?
---@field set_pending_permissions fun(pending_permissions: acp.PendingPermissionState[])
---@field inactive_request_error fun(): table
---@field is_creating_new_session fun(): boolean
---@field is_live_generation fun(generation: integer): boolean
---@field is_loading_existing_session fun(): boolean
---@field queue_session_update fun(session_id: string, update: table)
---@field reveal_inline_approval fun(current_session: acp.Session)
---@field rerender fun(current_session: acp.Session)
---@field should_apply_update fun(current_session: acp.Session, update: table): boolean

local M = {}

---@param ctx acp.TransportContext
---@return acp.TransportContext
function M.new(ctx)
    return ctx
end

return M
