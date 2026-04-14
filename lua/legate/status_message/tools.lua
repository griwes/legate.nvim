local common = require('legate.status_message.common')

local M = {}

function M.tool_label(tool_call)
    local command = common.raw_command(tool_call.raw_input)
    if command ~= nil and (tool_call.kind == 'execute' or common.generic_tool_title(tool_call.title)) then
        return string.format('Run %s', common.inline_code(command))
    end

    local mcp_tool = common.raw_mcp_tool_name(tool_call.raw_input)
    if mcp_tool ~= nil and common.generic_tool_title(tool_call.title) then
        return string.format('Tool: %s', common.inline_code(mcp_tool))
    end

    local title = common.non_empty_string(tool_call.title)
    if title ~= nil then
        return title
    end
    if mcp_tool ~= nil then
        return string.format('Tool: %s', common.inline_code(mcp_tool))
    end
    if command ~= nil then
        return string.format('Run %s', common.inline_code(command))
    end
    if tool_call.kind ~= nil then
        return common.humanize_kind(tool_call.kind)
    end
    return 'Tool'
end

function M.tool_call_status_text(tool_call)
    local lines = { string.format('Status: `%s`', tool_call.status) }
    if tool_call.kind ~= nil then
        table.insert(lines, string.format('Kind: `%s`', tool_call.kind))
    end
    if #tool_call.locations > 0 then
        local locations = {}
        for _, location in ipairs(tool_call.locations) do
            table.insert(locations, common.markdown_location(location))
        end
        table.insert(lines, string.format('Locations: %s', table.concat(locations, ', ')))
    end
    for _, content in ipairs(tool_call.content) do
        local summary = common.summarize_tool_content(content)
        if summary ~= nil then
            table.insert(lines, summary)
        end
    end
    return table.concat(lines, '\n')
end

function M.tool_hint(tool_call)
    local is_mcp_tool = common.raw_mcp_tool_name(tool_call.raw_input) ~= nil
    if #tool_call.locations > 0 then
        return common.markdown_location(tool_call.locations[1])
    end

    local preview = common.terminal_preview(common.preferred_terminal_stream(tool_call), 80)
    if preview ~= nil then
        return preview
    end

    for _, content in ipairs(tool_call.content) do
        if
            not (
                is_mcp_tool
                and content.type == 'content'
                and content.content ~= nil
                and content.content.type == 'text'
                and common.opaque_text_payload(content.content.text)
            )
        then
            local summary = common.summarize_tool_content(content, {
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

function M.tool_call_summary(tool_call)
    local icon = common.tool_icon(tool_call.status)
    local label = M.tool_label(tool_call)
    local hint = M.tool_hint(tool_call)
    if hint ~= nil and hint ~= '' then
        return common.build_summary(icon, tool_call.status, string.format('%s %s  %s', icon, label, hint))
    end
    return common.build_summary(icon, tool_call.status, string.format('%s %s', icon, label))
end

function M.tool_call_summary_line(tool_call)
    return M.tool_call_summary(tool_call).text
end

function M.tool_call_hover_lines(tool_call)
    local lines = {
        string.format('### %s', M.tool_label(tool_call)),
        '',
        common.detail_bullet('Status', string.format('`%s`', tool_call.status)),
    }

    if tool_call.kind ~= nil then
        table.insert(lines, common.detail_bullet('Kind', string.format('`%s`', tool_call.kind)))
    end

    if #tool_call.locations > 0 then
        local locations = {}
        for _, location in ipairs(tool_call.locations) do
            table.insert(locations, common.markdown_location(location))
        end
        table.insert(lines, common.detail_bullet('Locations', table.concat(locations, ', ')))
    end

    if #tool_call.content > 0 then
        table.insert(lines, '')
        table.insert(lines, '#### Content')
        for _, content in ipairs(tool_call.content) do
            if content.type == 'content' and content.content ~= nil and content.content.text ~= nil then
                table.insert(lines, common.detail_bullet('Text', content.content.text))
            elseif content.type == 'diff' then
                table.insert(lines, common.detail_bullet('Diff', string.format('`%s`', content.path)))
            elseif content.type == 'terminal' then
                table.insert(lines, common.detail_bullet('Terminal', string.format('`%s`', content.terminalId)))
            else
                table.insert(lines, common.detail_bullet('Content', string.format('`%s`', content.type)))
            end
        end
    end

    local stream = common.preferred_terminal_stream(tool_call)
    if stream ~= nil then
        table.insert(lines, '')
        table.insert(lines, '#### Terminal Stream')
        table.insert(lines, common.detail_bullet('Terminal', string.format('`%s`', stream.terminal_id)))
        if type(stream.cwd) == 'string' and stream.cwd ~= '' then
            table.insert(lines, common.detail_bullet('Cwd', string.format('`%s`', stream.cwd)))
        end
        if stream.exit_code ~= nil then
            table.insert(lines, common.detail_bullet('Exit Code', string.format('`%s`', stream.exit_code)))
        end
        if stream.signal ~= nil and stream.signal ~= '' then
            table.insert(lines, common.detail_bullet('Signal', string.format('`%s`', stream.signal)))
        end

        local output_lines = type(stream.output) == 'string' and vim.split(stream.output, '\n', { plain = true }) or {}
        if #output_lines > 0 and not (#output_lines == 1 and output_lines[1] == '') then
            table.insert(lines, '')
            table.insert(lines, '```text')
            local start_index = math.max(1, #output_lines - common.terminal_hover_output_limit + 1)
            for index = start_index, #output_lines do
                table.insert(lines, output_lines[index])
            end
            table.insert(lines, '```')
        end
    end

    if tool_call.raw_input ~= nil then
        table.insert(lines, '')
        for _, line in ipairs(common.inspect_section('Raw Input', tool_call.raw_input)) do
            table.insert(lines, line)
        end
    end

    if tool_call.raw_output ~= nil then
        table.insert(lines, '')
        for _, line in ipairs(common.inspect_section('Raw Output', tool_call.raw_output)) do
            table.insert(lines, line)
        end
    end

    return lines
end

return M
