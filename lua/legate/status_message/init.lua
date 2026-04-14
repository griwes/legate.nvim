local approvals = require('legate.status_message.approvals')
local common = require('legate.status_message.common')
local tools = require('legate.status_message.tools')

---@class legate.StatusMessageModule
local M = {
    approval_status_text = approvals.approval_status_text,
    approval_summary = approvals.approval_summary,
    approval_summary_line = approvals.approval_summary_line,
    pending_approval_lines = approvals.pending_approval_lines,
    pending_approval_overlay_text = approvals.pending_approval_overlay_text,
    pending_approval_virtual_lines = approvals.pending_approval_virtual_lines,
    pending_approval_virtual_text = approvals.pending_approval_virtual_text,
    tool_call_status_text = tools.tool_call_status_text,
    tool_call_summary = tools.tool_call_summary,
    tool_call_summary_line = tools.tool_call_summary_line,
}

local function tool_call_by_stream_key(current_session, stream_key)
    if stream_key == nil then
        return nil
    end
    for _, tool_call in ipairs(current_session.tool_calls) do
        if tool_call.stream_key == stream_key then
            return tool_call
        end
    end
    return nil
end

local function approval_by_stream_key(current_session, stream_key)
    if stream_key == nil then
        return nil
    end
    for _, approval in ipairs(current_session.approval_entries) do
        if approval.stream_key == stream_key then
            return approval
        end
    end
    return nil
end

local function tool_call_by_id(current_session, tool_call_id)
    if tool_call_id == nil then
        return nil
    end
    for _, tool_call in ipairs(current_session.tool_calls) do
        if tool_call.tool_call_id == tool_call_id then
            return tool_call
        end
    end
    return nil
end

function M.summary(current_session, message)
    if message.stream_kind == 'tool_call' then
        local tool_call = tool_call_by_stream_key(current_session, message.stream_key)
        if tool_call ~= nil then
            return tools.tool_call_summary(tool_call)
        end
    end

    if message.stream_kind == 'approval' then
        local approval = approval_by_stream_key(current_session, message.stream_key)
        if approval ~= nil then
            return approvals.approval_summary(approval, tool_call_by_id(current_session, approval.tool_call_id))
        end
    end

    local icon = common.tool_icon(message.status_state)
    return common.build_summary(
        icon,
        message.status_state,
        string.format('%s %s', icon, message.status_title or 'Status')
    )
end

function M.summary_line(current_session, message)
    return M.summary(current_session, message).text
end

function M.hover_lines(current_session, message)
    if message.stream_kind == 'tool_call' then
        local tool_call = tool_call_by_stream_key(current_session, message.stream_key)
        if tool_call ~= nil then
            return tools.tool_call_hover_lines(tool_call)
        end
    end

    if message.stream_kind == 'approval' then
        local approval = approval_by_stream_key(current_session, message.stream_key)
        if approval ~= nil then
            return approvals.approval_hover_lines(current_session, approval)
        end
    end

    return nil
end

return M
