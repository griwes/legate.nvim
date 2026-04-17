local M = {}

M.terminal_preview_limit = 120
M.terminal_hover_output_limit = 12

function M.tool_icon(state)
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

function M.approval_icon(state)
    if state == 'allow_once' or state == 'allow_always' or state == 'selected' then
        return '✓'
    end
    if state == 'reject_once' or state == 'reject_always' then
        return '✗'
    end
    return '○'
end

function M.status_highlight_group(state)
    if state == 'completed' or state == 'allow_once' or state == 'allow_always' or state == 'selected' then
        return 'LegateStatusSuccess'
    end
    if state == 'failed' or state == 'reject_once' or state == 'reject_always' then
        return 'LegateStatusFailure'
    end
    if state == 'waiting_for_approval' then
        return 'LegateStatusWaiting'
    end
    if state == 'cancelled' then
        return 'LegateStatusNeutral'
    end
    return 'LegateStatusPending'
end

function M.plain_location(location)
    if location.line ~= nil then
        return string.format('%s:%d', location.path, location.line)
    end
    return location.path
end

function M.inline_code(text)
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

function M.markdown_location(location)
    return M.inline_code(M.plain_location(location))
end

function M.non_empty_string(value)
    if type(value) ~= 'string' then
        return nil
    end
    local trimmed = vim.trim(value)
    if trimmed == '' then
        return nil
    end
    return trimmed
end

function M.single_line_text(text)
    if text == nil then
        return nil
    end
    return text:gsub('[\r\n]+', ' ')
end

function M.shell_segment(argument)
    if argument:match('^[%w%+%-%._/@:=,]+$') then
        return argument
    end
    return vim.fn.shellescape(argument)
end

function M.parsed_command(raw_input)
    if type(raw_input) ~= 'table' then
        return nil
    end
    local parsed = raw_input.parsed_cmd or raw_input.parsedCmd or raw_input.parsed_command or raw_input.parsedCommand
    if type(parsed) == 'string' then
        return M.single_line_text(M.non_empty_string(parsed))
    end
    if type(parsed) == 'table' then
        if vim.islist(parsed) then
            local parts = {}
            for _, part in ipairs(parsed) do
                if type(part) == 'string' and part ~= '' then
                    table.insert(parts, M.shell_segment(part))
                end
            end
            if #parts > 0 then
                return table.concat(parts, ' ')
            end
        end
        local command = M.non_empty_string(parsed.command)
        if command ~= nil then
            local parts = { M.shell_segment(command) }
            if vim.islist(parsed.args) then
                for _, arg in ipairs(parsed.args) do
                    if type(arg) == 'string' and arg ~= '' then
                        table.insert(parts, M.shell_segment(arg))
                    end
                end
            end
            return table.concat(parts, ' ')
        end
    end
    return nil
end

function M.raw_command(raw_input)
    if type(raw_input) ~= 'table' then
        return nil
    end
    local parsed = M.parsed_command(raw_input)
    if parsed ~= nil then
        return parsed
    end
    local command = M.non_empty_string(raw_input.command)
    if command == nil then
        return nil
    end
    local parts = { M.shell_segment(command) }
    for _, arg in ipairs(raw_input.args or {}) do
        if type(arg) == 'string' and arg ~= '' then
            table.insert(parts, M.shell_segment(arg))
        end
    end
    return table.concat(parts, ' ')
end

function M.raw_mcp_tool_name(raw_input)
    if type(raw_input) ~= 'table' then
        return nil
    end
    local tool_name = M.non_empty_string(raw_input.toolName)
        or M.non_empty_string(raw_input.tool_name)
        or M.non_empty_string(raw_input.name)
        or M.non_empty_string(raw_input.tool)
    local server_name = M.non_empty_string(raw_input.serverName)
        or M.non_empty_string(raw_input.server_name)
        or M.non_empty_string(raw_input.server)
    if tool_name ~= nil then
        if server_name ~= nil and vim.startswith(tool_name, server_name .. '/') then
            tool_name = tool_name:sub(#server_name + 2)
        end
        if server_name ~= nil and not vim.startswith(tool_name, server_name .. '/') then
            return string.format('%s/%s', server_name, tool_name)
        end
        return tool_name
    end
    local method = M.non_empty_string(raw_input.method)
    if method ~= nil and vim.startswith(method, 'mcp__') then
        local parts = vim.split(method, '__', { plain = true })
        if #parts >= 3 then
            return table.concat(vim.list_slice(parts, 2), '/')
        end
        return method
    end
    return nil
end

function M.generic_tool_title(title)
    local normalized = M.non_empty_string(title)
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

function M.humanize_kind(kind)
    return (kind:gsub('_', ' '):gsub('^%l', string.upper))
end

function M.summarize_tool_content(content, opts)
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
        return M.inline_code(content.path)
    end
    if content.type == 'terminal' then
        return string.format('terminal %s', M.inline_code(content.terminalId))
    end
    return nil
end

function M.preferred_terminal_stream(tool_call)
    if type(tool_call.terminal_streams) ~= 'table' then
        return nil
    end
    local ids = vim.tbl_keys(tool_call.terminal_streams)
    table.sort(ids)
    local fallback = nil
    for _, terminal_id in ipairs(ids) do
        local stream = tool_call.terminal_streams[terminal_id]
        if stream ~= nil then
            fallback = fallback or stream
            if type(stream.output) == 'string' and stream.output ~= '' then
                return stream
            end
        end
    end
    return fallback
end

function M.terminal_preview(stream, limit)
    if stream == nil or type(stream.output) ~= 'string' then
        return nil
    end
    local preview = vim.trim(stream.output:gsub('%s+', ' '))
    if preview == '' then
        return nil
    end
    limit = limit or M.terminal_preview_limit
    if #preview > limit then
        return preview:sub(1, limit - 1) .. '…'
    end
    return preview
end

function M.opaque_text_payload(text)
    local normalized = M.non_empty_string(text)
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

function M.build_summary(icon, state, text)
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
                group = M.status_highlight_group(state),
            },
        },
    }
end

function M.detail_bullet(title, value)
    return string.format('- %s: %s', title, value)
end

function M.inspect_section(heading, value)
    local lines = { string.format('#### %s', heading), '```lua' }
    for _, line in ipairs(vim.split(vim.inspect(value), '\n', { plain = true })) do
        table.insert(lines, line)
    end
    table.insert(lines, '```')
    return lines
end

return M
