local buffer = require('acp.buffer')
local config_option = require('acp.config_option')
local config = require('acp.config')
local input = require('acp.input')

---@class acp.RenderModule
local M = {}

---@param option acp.SessionConfigOption
---@return string
local function current_config_value_name(option)
    for _, choice in ipairs(config_option.choices(option)) do
        if choice.value.value == option.currentValue then
            return choice.value.name
        end
    end

    return option.currentValue
end

---@param option acp.SessionConfigOption
---@return string[]
local function format_config_options(option)
    local display_value = current_config_value_name(option)
    local lines = {
        string.format('- `%s` %s = `%s`', option.id, option.name, display_value),
    }

    if display_value ~= option.currentValue then
        table.insert(lines, string.format('  - Value ID: `%s`', option.currentValue))
    end

    if option.category ~= nil then
        table.insert(lines, string.format('  - Category: `%s`', option.category))
    end

    if option.description ~= nil and option.description ~= '' then
        table.insert(lines, string.format('  - %s', option.description))
    end

    local choices = config_option.choices(option)

    if #choices > 0 then
        local values = {}

        for _, choice in ipairs(choices) do
            local label = string.format('%s (`%s`)', choice.value.name, choice.value.value)

            if choice.group_name ~= nil then
                label = string.format('%s: %s', choice.group_name, label)
            end

            if choice.value.value == option.currentValue then
                label = label .. ' current'
            end

            table.insert(values, label)
        end

        table.insert(lines, string.format('  - Choices: %s', table.concat(values, ', ')))
    end

    return lines
end

---@param config_options acp.SessionConfigOption[]
---@return string[]
local function format_all_config_options(config_options)
    local lines = {
        '## Config Options',
    }

    for _, option in ipairs(config_options) do
        for _, line in ipairs(format_config_options(option)) do
            table.insert(lines, line)
        end
    end

    table.insert(lines, '')

    return lines
end

---@param available_commands acp.AvailableCommand[]
---@return string[]
local function format_available_commands(available_commands)
    local lines = {
        '## Slash Commands',
    }

    for _, command in ipairs(available_commands) do
        table.insert(lines, string.format('- `/%s` %s', command.name, command.description))

        if type(command.input) == 'table' and command.input.hint ~= nil and command.input.hint ~= '' then
            table.insert(lines, string.format('  - Input: %s', command.input.hint))
        end
    end

    table.insert(lines, '')

    return lines
end

---@param entries acp.PlanEntry[]
---@return string[]
local function format_plan(entries)
    local lines = {
        '## Plan',
    }

    for _, entry in ipairs(entries) do
        table.insert(lines, string.format('- `%s` %s', entry.status, entry.content))
    end

    table.insert(lines, '')

    return lines
end

---@param role acp.MessageRole
---@param text string
---@return string[]
local function format_message(role, text)
    local title = role:sub(1, 1):upper() .. role:sub(2)
    local lines = {
        string.format('### %s', title),
    }

    for _, line in
        ipairs(vim.split(text, '\n', {
            plain = true,
        }))
    do
        table.insert(lines, line)
    end

    return lines
end

---@param location acp.ToolCallLocation
---@return string
local function format_location(location)
    if location.line ~= nil then
        return string.format('`%s:%d`', location.path, location.line)
    end

    return string.format('`%s`', location.path)
end

---@param content acp.ToolCallContent
---@return string?
local function summarize_tool_content(content)
    if content.type == 'content' and content.content ~= nil then
        if content.content.type == 'text' and content.content.text ~= nil then
            local summary = content.content.text:gsub('%s+', ' ')
            return string.format('Text: %s', summary:sub(1, 120))
        end

        return string.format('Content: `%s`', content.content.type or 'unknown')
    end

    if content.type == 'diff' then
        return string.format('Diff: `%s`', content.path)
    end

    if content.type == 'terminal' then
        return string.format('Terminal: `%s`', content.terminalId)
    end

    return nil
end

---@param tool_calls acp.ToolCallState[]
---@return string[]
local function format_tool_calls(tool_calls)
    local lines = {
        '## Tools',
    }

    for _, tool_call in ipairs(tool_calls) do
        table.insert(lines, string.format('- `%s` %s', tool_call.status, tool_call.title))

        if tool_call.kind ~= nil then
            table.insert(lines, string.format('  - Kind: `%s`', tool_call.kind))
        end

        table.insert(lines, string.format('  - ID: `%s`', tool_call.tool_call_id))

        if #tool_call.locations > 0 then
            local locations = {}

            for _, location in ipairs(tool_call.locations) do
                table.insert(locations, format_location(location))
            end

            table.insert(lines, string.format('  - Locations: %s', table.concat(locations, ', ')))
        end

        for _, content in ipairs(tool_call.content) do
            local summary = summarize_tool_content(content)

            if summary ~= nil then
                table.insert(lines, string.format('  - %s', summary))
            end
        end
    end

    table.insert(lines, '')

    return lines
end

---@param approval_entries acp.ApprovalEntry[]
---@return string[]
local function format_approvals(approval_entries)
    local lines = {
        '## Approvals',
    }

    for _, approval in ipairs(approval_entries) do
        table.insert(lines, M.approval_summary_line(approval))

        table.insert(lines, string.format('  - Source: `%s`', approval.source))

        if
            approval.selected_option_name ~= nil
            and approval.selected_kind ~= nil
            and approval.selected_option_id ~= nil
        then
            table.insert(
                lines,
                string.format(
                    '  - Selected Option: %s [%s] (`%s`)',
                    approval.selected_option_name,
                    approval.selected_kind,
                    approval.selected_option_id
                )
            )
        end

        if approval.tool_call_id ~= nil then
            table.insert(lines, string.format('  - Tool Call ID: `%s`', approval.tool_call_id))
        end

        if #approval.options > 0 then
            local option_lines = {}

            for _, option in ipairs(approval.options) do
                table.insert(option_lines, string.format('%s [%s] (`%s`)', option.name, option.kind, option.optionId))
            end

            table.insert(lines, string.format('  - Options: %s', table.concat(option_lines, ', ')))
        end
    end

    table.insert(lines, '')

    return lines
end

---Return the stable Markdown summary line for an approval entry.
---@param approval acp.ApprovalEntry
---@return string
function M.approval_summary_line(approval)
    return string.format('- [%d] `%s` %s', approval.ordinal, approval.outcome, approval.title)
end

---@param prompt string?
---@return string[]
local function prompt_lines(prompt)
    if prompt == nil or prompt == '' then
        return { '' }
    end

    return vim.split(prompt, '\n', {
        plain = true,
    })
end

---@param session acp.Session
---@param prompt string?
---@return string[]
local function build_lines(session, prompt)
    local prompt_body = prompt_lines(prompt)
    local lines = {
        '# ACP',
        '',
        '## Session',
        string.format('- ID: `%s`', session.id),
        string.format('- Remote ID: `%s`', session.remote_id or 'unbound'),
        string.format('- Remote Sync: `%s`', session.remote_sync_state),
    }

    if session.remote_sync_error ~= nil then
        table.insert(lines, string.format('- Remote Sync Error: `%s`', session.remote_sync_error))
    end

    if session.remote_sync_state == 'load_failed' then
        table.insert(
            lines,
            '- Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
        )
    end

    table.insert(lines, string.format('- Status: `%s`', session.status))
    table.insert(lines, string.format('- Stop Reason: `%s`', session.stop_reason or 'none'))
    table.insert(lines, '')

    if #session.plan_entries > 0 then
        for _, line in ipairs(format_plan(session.plan_entries)) do
            table.insert(lines, line)
        end
    end

    if #session.config_options > 0 then
        for _, line in ipairs(format_all_config_options(session.config_options)) do
            table.insert(lines, line)
        end
    end

    if #session.available_commands > 0 then
        for _, line in ipairs(format_available_commands(session.available_commands)) do
            table.insert(lines, line)
        end
    end

    if #session.tool_calls > 0 then
        for _, line in ipairs(format_tool_calls(session.tool_calls)) do
            table.insert(lines, line)
        end
    end

    if #session.approval_entries > 0 then
        for _, line in ipairs(format_approvals(session.approval_entries)) do
            table.insert(lines, line)
        end
    end

    table.insert(lines, config.get().transcript_header)

    if #session.messages == 0 then
        table.insert(lines, '_Empty._')
    else
        for _, message in ipairs(session.messages) do
            for _, line in ipairs(format_message(message.role, message.text)) do
                table.insert(lines, line)
            end

            table.insert(lines, '')
        end
    end

    table.insert(lines, config.get().prompt_header)

    for _, line in ipairs(prompt_body) do
        table.insert(lines, line)
    end

    return lines
end

---Render an ACP session into the shared chat buffer.
---@param session acp.Session
---@param prompt string?
---@return integer
function M.render(session, prompt)
    local bufnr = buffer.ensure()
    local prompt_body = prompt_lines(prompt)
    local lines = build_lines(session, prompt)
    local prompt_start = #lines - #prompt_body + 1

    vim.api.nvim_set_option_value('modifiable', true, {
        buf = bufnr,
    })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    input.set_anchor(bufnr, prompt_start - 1)

    return bufnr
end

return M
