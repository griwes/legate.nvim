local common = require('legate.status_message.common')
local tools = require('legate.status_message.tools')

local M = {}
local max_inline_approval_hint_index = 9

function M.approval_subject(title, related_tool)
    if related_tool ~= nil and common.generic_tool_title(title) then
        return tools.tool_label(related_tool)
    end
    local normalized = common.non_empty_string(title)
    if normalized ~= nil then
        return normalized
    end
    if related_tool ~= nil then
        return tools.tool_label(related_tool)
    end
    return 'Approval'
end

function M.approval_title(approval, related_tool)
    return M.approval_subject(approval.title, related_tool)
end

function M.approval_status_text(approval)
    local lines = {
        string.format('Outcome: `%s`', approval.outcome),
        string.format('Source: `%s`', approval.source),
    }
    if
        approval.selected_option_name ~= nil
        and approval.selected_kind ~= nil
        and approval.selected_option_id ~= nil
    then
        table.insert(
            lines,
            string.format(
                'Selected Option: %s [%s] (`%s`)',
                common.single_line_text(approval.selected_option_name),
                approval.selected_kind,
                approval.selected_option_id
            )
        )
    end
    if #approval.options > 0 then
        local option_lines = {}
        for _, option in ipairs(approval.options) do
            table.insert(
                option_lines,
                string.format('%s [%s] (`%s`)', common.single_line_text(option.name), option.kind, option.optionId)
            )
        end
        table.insert(lines, string.format('Options: %s', table.concat(option_lines, ', ')))
    end
    return table.concat(lines, '\n')
end

function M.approval_summary(approval, related_tool)
    local icon_state = approval.selected_kind or approval.outcome
    local icon = common.approval_icon(icon_state)
    return common.build_summary(
        icon,
        icon_state,
        string.format('%s Approval [%d] %s', icon, approval.ordinal, M.approval_title(approval, related_tool))
    )
end

function M.approval_summary_line(approval, related_tool)
    return M.approval_summary(approval, related_tool).text
end

function M.inline_code_text(value)
    local text = tostring(value or '')
    text = text:gsub('[\r\n]+', ' ')
    text = text:gsub('`', '\\`')
    return text
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

local function pending_approval_option_line(option, index)
    local selection_hint = 'or use the inline action'
    if index <= max_inline_approval_hint_index then
        selection_hint =
            string.format('select with `g%d`, `:LegateSelectApprovalOption %d`, or use the inline action', index, index)
    else
        selection_hint = 'select with `:LegateSelectApprovalOption <index>` or use the inline action'
    end
    return string.format(
        '%s [%s] (`%s`)  ->  %s',
        M.inline_code_text(option.name),
        M.inline_code_text(option.kind),
        M.inline_code_text(option.optionId),
        selection_hint
    )
end

function M.pending_approval_lines(current_session, pending_approval)
    local related_tool = tool_call_by_id(current_session, pending_approval.tool_call_id)
    local lines = {
        '## Approval Needed',
        '',
        string.format('? %s', M.approval_subject(pending_approval.title, related_tool)),
        '',
    }
    for index, option in ipairs(pending_approval.options) do
        table.insert(lines, pending_approval_option_line(option, index))
    end
    return lines
end

local function pending_approval_overlay_option(option, index)
    return string.format('g%d %s', index, common.single_line_text(option.name))
end

local function pending_approval_overlay_more_hint(total_options)
    if total_options <= max_inline_approval_hint_index then
        return nil
    end
    if total_options == max_inline_approval_hint_index + 1 then
        return string.format('… use :LegateSelectApprovalOption %d', total_options)
    end
    return string.format('… use :LegateSelectApprovalOption 10-%d', total_options)
end

function M.pending_approval_virtual_text(current_session, pending_approvals)
    local pending_approval = pending_approvals[1]
    local related_tool = tool_call_by_id(current_session, pending_approval.tool_call_id)
    local lines = {
        string.format(
            'Pending approvals (%d) — active: %s',
            #pending_approvals,
            M.approval_subject(pending_approval.title, related_tool)
        ),
    }
    for index = 1, math.min(#pending_approval.options, max_inline_approval_hint_index) do
        table.insert(lines, pending_approval_overlay_option(pending_approval.options[index], index))
    end
    local more_hint = pending_approval_overlay_more_hint(#pending_approval.options)
    if more_hint ~= nil then
        table.insert(lines, more_hint)
    end
    for index = 2, #pending_approvals do
        local queued = pending_approvals[index]
        local queued_tool = tool_call_by_id(current_session, queued.tool_call_id)
        table.insert(
            lines,
            string.format('Queued [%d] %s', queued.ordinal, M.approval_subject(queued.title, queued_tool))
        )
    end
    return lines
end

function M.pending_approval_overlay_text(current_session, pending_approval)
    local related_tool = tool_call_by_id(current_session, pending_approval.tool_call_id)
    local options = {}
    for index = 1, math.min(#pending_approval.options, max_inline_approval_hint_index) do
        table.insert(options, pending_approval_overlay_option(pending_approval.options[index], index))
    end
    local more_hint = pending_approval_overlay_more_hint(#pending_approval.options)
    if more_hint ~= nil then
        table.insert(options, more_hint)
    end
    local suffix = #options > 0 and string.format(': %s', table.concat(options, ', ')) or ''
    return string.format('Approval needed for %s%s', M.approval_subject(pending_approval.title, related_tool), suffix)
end

function M.pending_approval_virtual_lines(current_session, pending_approvals)
    local lines = {}
    for _, text in ipairs(M.pending_approval_virtual_text(current_session, pending_approvals)) do
        table.insert(lines, {
            { text, 'Comment' },
        })
    end
    return lines
end

function M.approval_hover_lines(current_session, approval)
    local lines = {
        string.format(
            '### Approval [%d]: %s',
            approval.ordinal,
            M.approval_title(approval, tool_call_by_id(current_session, approval.tool_call_id))
        ),
        '',
        common.detail_bullet('Outcome', string.format('`%s`', approval.outcome)),
        common.detail_bullet('Source', string.format('`%s`', approval.source)),
    }
    if
        approval.selected_option_name ~= nil
        and approval.selected_kind ~= nil
        and approval.selected_option_id ~= nil
    then
        table.insert(
            lines,
            common.detail_bullet(
                'Selected',
                string.format(
                    '%s [%s] (`%s`)',
                    common.single_line_text(approval.selected_option_name),
                    approval.selected_kind,
                    approval.selected_option_id
                )
            )
        )
    end
    if #approval.options > 0 then
        table.insert(lines, '')
        table.insert(lines, '#### Options')
        for _, option in ipairs(approval.options) do
            table.insert(
                lines,
                string.format('- %s [%s] (`%s`)', common.single_line_text(option.name), option.kind, option.optionId)
            )
        end
    end
    return lines
end

return M
