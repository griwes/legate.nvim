---@class acp.StatusMessageModule
local M = {}

---@class acp.StatusHighlightSpan
---@field start_col integer
---@field end_col integer
---@field group string

---@class acp.StatusSummary
---@field text string
---@field highlights acp.StatusHighlightSpan[]

---@param state string?
---@return string
local function tool_icon(state)
    if state == 'completed' then
        return '✓'
    end

    if state == 'failed' then
        return '✗'
    end

    if state == 'cancelled' then
        return '○'
    end

    if state == 'waiting_for_approval' then
        return '?'
    end

    return '◔'
end

---@param state string?
---@return string
local function approval_icon(state)
    if state == 'allow_once' or state == 'allow_always' or state == 'selected' then
        return '✓'
    end

    if state == 'reject_once' or state == 'reject_always' then
        return '✗'
    end

    return '○'
end

---@param state string?
---@return string
local function status_highlight_group(state)
    if state == 'completed' or state == 'allow_once' or state == 'allow_always' or state == 'selected' then
        return 'ACPStatusSuccess'
    end

    if state == 'failed' or state == 'reject_once' or state == 'reject_always' then
        return 'ACPStatusFailure'
    end

    if state == 'waiting_for_approval' then
        return 'ACPStatusWaiting'
    end

    if state == 'cancelled' then
        return 'ACPStatusNeutral'
    end

    return 'ACPStatusPending'
end

---@param location acp.ToolCallLocation
---@return string
local function plain_location(location)
    if location.line ~= nil then
        return string.format('%s:%d', location.path, location.line)
    end

    return location.path
end

---@param location acp.ToolCallLocation
---@return string
local function inline_code(text)
    text = text:gsub('[\r\n]+', ' ')
    local longest_run = 0

    for run in text:gmatch('`+') do
        if #run > longest_run then
            longest_run = #run
        end
    end

    local delimiter = ('`'):rep(longest_run + 1)

    if longest_run == 0 then
        return string.format('`%s`', text)
    end

    return string.format('%s %s %s', delimiter, text, delimiter)
end

---@param location acp.ToolCallLocation
---@return string
local function markdown_location(location)
    return inline_code(plain_location(location))
end

---@param value any
---@return string?
local function non_empty_string(value)
    if type(value) ~= 'string' then
        return nil
    end

    local trimmed = vim.trim(value)

    if trimmed == '' then
        return nil
    end

    return trimmed
end

---@param text string?
---@return string?
local function single_line_text(text)
    if text == nil then
        return nil
    end

    return text:gsub('[\r\n]+', ' ')
end

---@param argument string
---@return string
local function shell_segment(argument)
    if argument:match('^[%w%+%-%._/@:=,]+$') then
        return argument
    end

    return vim.fn.shellescape(argument)
end

---@param raw_input table?
---@return string?
local function parsed_command(raw_input)
    if type(raw_input) ~= 'table' then
        return nil
    end

    local parsed = raw_input.parsed_cmd or raw_input.parsedCmd or raw_input.parsed_command or raw_input.parsedCommand

    if type(parsed) == 'string' then
        return single_line_text(non_empty_string(parsed))
    end

    if type(parsed) == 'table' then
        if vim.islist(parsed) then
            local parts = {}

            for _, part in ipairs(parsed) do
                if type(part) == 'string' and part ~= '' then
                    table.insert(parts, shell_segment(part))
                end
            end

            if #parts > 0 then
                return table.concat(parts, ' ')
            end
        end

        local command = non_empty_string(parsed.command)

        if command ~= nil then
            local parts = {
                shell_segment(command),
            }

            if vim.islist(parsed.args) then
                for _, arg in ipairs(parsed.args) do
                    if type(arg) == 'string' and arg ~= '' then
                        table.insert(parts, shell_segment(arg))
                    end
                end
            end

            return table.concat(parts, ' ')
        end
    end

    return nil
end

---@param raw_input table?
---@return string?
local function raw_command(raw_input)
    if type(raw_input) ~= 'table' then
        return nil
    end

    local parsed = parsed_command(raw_input)

    if parsed ~= nil then
        return parsed
    end

    local command = non_empty_string(raw_input.command)

    if command == nil then
        return nil
    end

    local parts = {
        shell_segment(command),
    }

    for _, arg in ipairs(raw_input.args or {}) do
        if type(arg) == 'string' and arg ~= '' then
            table.insert(parts, shell_segment(arg))
        end
    end

    return table.concat(parts, ' ')
end

---@param raw_input table?
---@return string?
local function raw_mcp_tool_name(raw_input)
    if type(raw_input) ~= 'table' then
        return nil
    end

    local tool_name = non_empty_string(raw_input.toolName)
        or non_empty_string(raw_input.tool_name)
        or non_empty_string(raw_input.name)
        or non_empty_string(raw_input.tool)
    local server_name = non_empty_string(raw_input.serverName)
        or non_empty_string(raw_input.server_name)
        or non_empty_string(raw_input.server)

    if tool_name ~= nil then
        if server_name ~= nil and not vim.startswith(tool_name, server_name .. '/') then
            return string.format('%s/%s', server_name, tool_name)
        end

        return tool_name
    end

    local method = non_empty_string(raw_input.method)

    if method ~= nil and vim.startswith(method, 'mcp__') then
        local parts = vim.split(method, '__', {
            plain = true,
        })

        if #parts >= 3 then
            return table.concat(vim.list_slice(parts, 2), '/')
        end

        return method
    end

    return nil
end

---@param title string?
---@return boolean
local function generic_tool_title(title)
    local normalized = non_empty_string(title)

    if normalized == nil then
        return true
    end

    normalized = normalized:lower()

    return normalized == 'run'
        or normalized == 'run command'
        or normalized == 'tool call'
        or normalized == 'mcp tool call'
        or normalized == 'approve mcp tool call'
        or normalized == 'approval'
end

---@param kind string
---@return string
local function humanize_kind(kind)
    return (kind:gsub('_', ' '):gsub('^%l', string.upper))
end

---@param tool_call acp.ToolCallState
---@return string
local function tool_label(tool_call)
    local command = raw_command(tool_call.raw_input)

    if command ~= nil and (tool_call.kind == 'execute' or generic_tool_title(tool_call.title)) then
        return string.format('Run %s', inline_code(command))
    end

    local mcp_tool = raw_mcp_tool_name(tool_call.raw_input)

    if mcp_tool ~= nil and generic_tool_title(tool_call.title) then
        return string.format('Tool: %s', inline_code(mcp_tool))
    end

    local title = non_empty_string(tool_call.title)

    if title ~= nil then
        return title
    end

    if mcp_tool ~= nil then
        return string.format('Tool: %s', inline_code(mcp_tool))
    end

    if command ~= nil then
        return string.format('Run %s', inline_code(command))
    end

    if tool_call.kind ~= nil then
        return humanize_kind(tool_call.kind)
    end

    return 'Tool'
end

---@param title string?
---@param related_tool acp.ToolCallState?
---@return string
local function approval_subject(title, related_tool)
    if related_tool ~= nil and generic_tool_title(title) then
        return tool_label(related_tool)
    end

    local normalized = non_empty_string(title)

    if normalized ~= nil then
        return normalized
    end

    if related_tool ~= nil then
        return tool_label(related_tool)
    end

    return 'Approval'
end

---@param approval acp.ApprovalEntry
---@param related_tool acp.ToolCallState?
---@return string
local function approval_title(approval, related_tool)
    return approval_subject(approval.title, related_tool)
end

---@param content acp.ToolCallContent
---@param opts? { limit?: integer, include_text?: boolean }
---@return string?
local function summarize_tool_content(content, opts)
    opts = opts or {}
    local limit = opts.limit or 120
    local include_text = opts.include_text ~= false

    if include_text and content.type == 'content' and content.content ~= nil then
        if content.content.type == 'text' and content.content.text ~= nil then
            local summary = vim.trim(content.content.text:gsub('%s+', ' '))

            if summary == '' then
                return nil
            end

            if #summary > limit then
                return summary:sub(1, limit - 1) .. '…'
            end

            return summary
        end

        return string.format('content:%s', content.content.type or 'unknown')
    end

    if content.type == 'diff' then
        return inline_code(content.path)
    end

    if content.type == 'terminal' then
        return string.format('terminal %s', inline_code(content.terminalId))
    end

    return nil
end

---@param text string?
---@return boolean
local function opaque_text_payload(text)
    local normalized = non_empty_string(text)

    if normalized == nil then
        return false
    end

    local looks_like_json = (vim.startswith(normalized, '{') and vim.endswith(normalized, '}'))
        or (vim.startswith(normalized, '[') and vim.endswith(normalized, ']'))

    if not looks_like_json then
        return false
    end

    return pcall(vim.json.decode, normalized)
end

---@param icon string
---@param state string?
---@param text string
---@return acp.StatusSummary
local function build_summary(icon, state, text)
    local icon_start = 0
    local prefix = text:match('^(%-?%s*)' .. vim.pesc(icon) .. '%s')

    if prefix ~= nil then
        icon_start = #prefix
    else
        local icon_at = text:find(icon, 1, true)

        if icon_at ~= nil then
            icon_start = icon_at - 1
        end
    end

    return {
        text = text,
        highlights = {
            {
                start_col = icon_start,
                end_col = icon_start + #icon,
                group = status_highlight_group(state),
            },
        },
    }
end

---@param tool_call acp.ToolCallState
---@return string
function M.tool_call_status_text(tool_call)
    local lines = {
        string.format('Status: `%s`', tool_call.status),
    }

    if tool_call.kind ~= nil then
        table.insert(lines, string.format('Kind: `%s`', tool_call.kind))
    end

    if #tool_call.locations > 0 then
        local locations = {}

        for _, location in ipairs(tool_call.locations) do
            table.insert(locations, markdown_location(location))
        end

        table.insert(lines, string.format('Locations: %s', table.concat(locations, ', ')))
    end

    for _, content in ipairs(tool_call.content) do
        local summary = summarize_tool_content(content)

        if summary ~= nil then
            table.insert(lines, summary)
        end
    end

    return table.concat(lines, '\n')
end

---@param approval acp.ApprovalEntry
---@return string
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
        local selected_option_name = single_line_text(approval.selected_option_name)

        table.insert(
            lines,
            string.format(
                'Selected Option: %s [%s] (`%s`)',
                selected_option_name,
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
                string.format('%s [%s] (`%s`)', single_line_text(option.name), option.kind, option.optionId)
            )
        end

        table.insert(lines, string.format('Options: %s', table.concat(option_lines, ', ')))
    end

    return table.concat(lines, '\n')
end

---@param tool_call acp.ToolCallState
---@return string?
local function tool_hint(tool_call)
    local is_mcp_tool = raw_mcp_tool_name(tool_call.raw_input) ~= nil

    if #tool_call.locations > 0 then
        return markdown_location(tool_call.locations[1])
    end

    for _, content in ipairs(tool_call.content) do
        if not (
            is_mcp_tool
            and content.type == 'content'
            and content.content ~= nil
            and content.content.type == 'text'
            and opaque_text_payload(content.content.text)
        ) then
            local summary = summarize_tool_content(content, {
                limit = 80,
                include_text = true,
            })

            if summary ~= nil then
                return summary
            end
        end
    end

    return nil
end

---@param tool_call acp.ToolCallState
---@return acp.StatusSummary
function M.tool_call_summary(tool_call)
    local icon = tool_icon(tool_call.status)
    local label = tool_label(tool_call)
    local hint = tool_hint(tool_call)

    if hint ~= nil and hint ~= '' then
        return build_summary(icon, tool_call.status, string.format('%s %s  %s', icon, label, hint))
    end

    return build_summary(icon, tool_call.status, string.format('%s %s', icon, label))
end

---@param tool_call acp.ToolCallState
---@return string
function M.tool_call_summary_line(tool_call)
    return M.tool_call_summary(tool_call).text
end

---@param approval acp.ApprovalEntry
---@param related_tool acp.ToolCallState?
---@return acp.StatusSummary
function M.approval_summary(approval, related_tool)
    local icon_state = approval.selected_kind or approval.outcome
    local icon = approval_icon(icon_state)

    return build_summary(
        icon,
        icon_state,
        string.format('%s Approval [%d] %s', icon, approval.ordinal, approval_title(approval, related_tool))
    )
end

---@param approval acp.ApprovalEntry
---@param related_tool acp.ToolCallState?
---@return string
function M.approval_summary_line(approval, related_tool)
    return M.approval_summary(approval, related_tool).text
end

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

---@param value any
---@return string
local function inline_code_text(value)
    local text = tostring(value or '')
    text = text:gsub('[\r\n]+', ' ')
    text = text:gsub('`', '\\`')
    return text
end

local MAX_INLINE_APPROVAL_HINT_INDEX = 9

---@param option acp.PermissionOption
---@param index integer
---@return string
local function pending_approval_option_line(option, index)
    local option_name = inline_code_text(option.name)
    local option_kind = inline_code_text(option.kind)
    local option_id = inline_code_text(option.optionId)

    local selection_hint = 'or use the inline action'

    if index <= MAX_INLINE_APPROVAL_HINT_INDEX then
        selection_hint =
            string.format('select with `g%d`, `:ACPSelectApprovalOption %d`, or use the inline action', index, index)
    else
        selection_hint = 'select with `:ACPSelectApprovalOption <index>` or use the inline action'
    end

    return string.format('%s [%s] (`%s`)  ->  %s', option_name, option_kind, option_id, selection_hint)
end

---@param current_session acp.Session
---@param pending_approval acp.PendingApproval
---@return string[]
function M.pending_approval_lines(current_session, pending_approval)
    local related_tool = nil

    for _, tool_call in ipairs(current_session.tool_calls or {}) do
        if tool_call.tool_call_id == pending_approval.tool_call_id then
            related_tool = tool_call
            break
        end
    end

    local lines = {
        '## Approval Needed',
        '',
        string.format('? %s', approval_subject(pending_approval.title, related_tool)),
        '',
    }

    for index, option in ipairs(pending_approval.options) do
        table.insert(lines, pending_approval_option_line(option, index))
    end

    return lines
end

---@param current_session acp.Session
---@param stream_key string?
---@return acp.ApprovalEntry?
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

---@param current_session acp.Session
---@param tool_call_id string?
---@return acp.ToolCallState?
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

---@param option acp.PermissionOption
---@param index integer
---@return string
local function pending_approval_overlay_option(option, index)
    return string.format('g%d %s', index, single_line_text(option.name))
end

---@param total_options integer
---@return string?
local function pending_approval_overlay_more_hint(total_options)
    if total_options <= MAX_INLINE_APPROVAL_HINT_INDEX then
        return nil
    end

    if total_options == MAX_INLINE_APPROVAL_HINT_INDEX + 1 then
        return string.format('… use :ACPSelectApprovalOption %d', total_options)
    end

    return string.format('… use :ACPSelectApprovalOption 10-%d', total_options)
end

---@param current_session acp.Session
---@param pending_approvals acp.PendingApproval[]
---@return string[]
function M.pending_approval_virtual_text(current_session, pending_approvals)
    local pending_approval = pending_approvals[1]
    local related_tool = tool_call_by_id(current_session, pending_approval.tool_call_id)
    local lines = {
        string.format(
            'Pending approvals (%d) — active: %s',
            #pending_approvals,
            approval_subject(pending_approval.title, related_tool)
        ),
    }

    for index = 1, math.min(#pending_approval.options, MAX_INLINE_APPROVAL_HINT_INDEX) do
        local option = pending_approval.options[index]
        local overlay_option = pending_approval_overlay_option(option, index)

        if overlay_option ~= nil then
            table.insert(lines, overlay_option)
        end
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
            string.format('Queued [%d] %s', queued.ordinal, approval_subject(queued.title, queued_tool))
        )
    end

    return lines
end

---@param current_session acp.Session
---@param pending_approval acp.PendingApproval
---@return string
function M.pending_approval_overlay_text(current_session, pending_approval)
    local related_tool = tool_call_by_id(current_session, pending_approval.tool_call_id)
    local options = {}

    for index = 1, math.min(#pending_approval.options, MAX_INLINE_APPROVAL_HINT_INDEX) do
        local option = pending_approval.options[index]
        local overlay_option = pending_approval_overlay_option(option, index)

        if overlay_option ~= nil then
            table.insert(options, overlay_option)
        end
    end

    local more_hint = pending_approval_overlay_more_hint(#pending_approval.options)

    if more_hint ~= nil then
        table.insert(options, more_hint)
    end

    local suffix = #options > 0 and string.format(': %s', table.concat(options, ', ')) or ''
    return string.format('Approval needed for %s%s', approval_subject(pending_approval.title, related_tool), suffix)
end

---@param current_session acp.Session
---@param pending_approvals acp.PendingApproval[]
---@return table[]
function M.pending_approval_virtual_lines(current_session, pending_approvals)
    local lines = {}

    for _, text in ipairs(M.pending_approval_virtual_text(current_session, pending_approvals)) do
        table.insert(lines, {
            { text, 'Comment' },
        })
    end

    return lines
end

---@param current_session acp.Session
---@param message acp.Message
---@return acp.StatusSummary
function M.summary(current_session, message)
    if message.stream_kind == 'tool_call' then
        local tool_call = tool_call_by_stream_key(current_session, message.stream_key)

        if tool_call ~= nil then
            return M.tool_call_summary(tool_call)
        end
    end

    if message.stream_kind == 'approval' then
        local approval = approval_by_stream_key(current_session, message.stream_key)

        if approval ~= nil then
            return M.approval_summary(approval, tool_call_by_id(current_session, approval.tool_call_id))
        end
    end

    local icon = tool_icon(message.status_state)
    return build_summary(icon, message.status_state, string.format('%s %s', icon, message.status_title or 'Status'))
end

---@param current_session acp.Session
---@param message acp.Message
---@return string
function M.summary_line(current_session, message)
    return M.summary(current_session, message).text
end

---@param title string
---@param value string
---@return string
local function detail_bullet(title, value)
    return string.format('- %s: %s', title, value)
end

---@param heading string
---@param value any
---@return string[]
local function inspect_section(heading, value)
    local lines = {
        string.format('#### %s', heading),
        '```lua',
    }

    for _, line in ipairs(vim.split(vim.inspect(value), '\n', { plain = true })) do
        table.insert(lines, line)
    end

    table.insert(lines, '```')

    return lines
end

---@param tool_call acp.ToolCallState
---@return string[]
local function tool_call_hover_lines(tool_call)
    local lines = {
        string.format('### %s', tool_label(tool_call)),
        '',
        detail_bullet('Status', string.format('`%s`', tool_call.status)),
    }

    if tool_call.kind ~= nil then
        table.insert(lines, detail_bullet('Kind', string.format('`%s`', tool_call.kind)))
    end

    if #tool_call.locations > 0 then
        local locations = {}

        for _, location in ipairs(tool_call.locations) do
            table.insert(locations, markdown_location(location))
        end

        table.insert(lines, detail_bullet('Locations', table.concat(locations, ', ')))
    end

    if #tool_call.content > 0 then
        table.insert(lines, '')
        table.insert(lines, '#### Content')

        for _, content in ipairs(tool_call.content) do
            if content.type == 'content' and content.content ~= nil and content.content.text ~= nil then
                table.insert(lines, detail_bullet('Text', content.content.text))
            elseif content.type == 'diff' then
                table.insert(lines, detail_bullet('Diff', string.format('`%s`', content.path)))
            elseif content.type == 'terminal' then
                table.insert(lines, detail_bullet('Terminal', string.format('`%s`', content.terminalId)))
            else
                table.insert(lines, detail_bullet('Content', string.format('`%s`', content.type)))
            end
        end
    end

    if tool_call.raw_input ~= nil then
        table.insert(lines, '')

        for _, line in ipairs(inspect_section('Raw Input', tool_call.raw_input)) do
            table.insert(lines, line)
        end
    end

    if tool_call.raw_output ~= nil then
        table.insert(lines, '')

        for _, line in ipairs(inspect_section('Raw Output', tool_call.raw_output)) do
            table.insert(lines, line)
        end
    end

    return lines
end

---@param current_session acp.Session
---@param approval acp.ApprovalEntry
---@return string[]
local function approval_hover_lines_for_session(current_session, approval)
    local lines = {
        string.format(
            '### Approval [%d]: %s',
            approval.ordinal,
            approval_title(approval, tool_call_by_id(current_session, approval.tool_call_id))
        ),
        '',
        detail_bullet('Outcome', string.format('`%s`', approval.outcome)),
        detail_bullet('Source', string.format('`%s`', approval.source)),
    }

    if
        approval.selected_option_name ~= nil
        and approval.selected_kind ~= nil
        and approval.selected_option_id ~= nil
    then
        local selected_option_name = single_line_text(approval.selected_option_name)

        table.insert(
            lines,
            detail_bullet(
                'Selected',
                string.format(
                    '%s [%s] (`%s`)',
                    selected_option_name,
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
                string.format('- %s [%s] (`%s`)', single_line_text(option.name), option.kind, option.optionId)
            )
        end
    end

    return lines
end

---@param current_session acp.Session
---@param message acp.Message
---@return string[]?
function M.hover_lines(current_session, message)
    if message.stream_kind == 'tool_call' then
        local tool_call = tool_call_by_stream_key(current_session, message.stream_key)

        if tool_call ~= nil then
            return tool_call_hover_lines(tool_call)
        end
    end

    if message.stream_kind == 'approval' then
        local approval = approval_by_stream_key(current_session, message.stream_key)

        if approval ~= nil then
            return approval_hover_lines_for_session(current_session, approval)
        end
    end

    return nil
end

return M
