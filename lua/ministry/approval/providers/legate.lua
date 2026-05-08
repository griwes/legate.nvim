local M = {}

---@param _request ministry.ApprovalRequest
---@return nil
function M.request(_request)
    -- ACP permission requests are bridged asynchronously in
    -- `legate.handlers.permission`. A runtimepath-discovered Ministry provider
    -- cannot synchronously wait for chat-buffer input without freezing the
    -- request path, so direct Ministry checks should fall through to
    -- "approval required" instead of manufacturing a decision here.
    return nil
end

return M
