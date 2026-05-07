local buffer = require('legate.ui.buffer')
local config = require('legate.config')
local approval_ui = require('legate.ui.approval')
local hover = require('legate.ui.hover')
local input = require('legate.ui.input')
local status_message = require('legate.status_message')
local surface = require('legate.ui.surface')

---@class legate.RenderModule
local M = {}

local REMOTE_SYNC_ERROR_MAX_LENGTH = 200

---@param value string?
---@return string?
local function normalize_remote_sync_error(value)
    if type(value) ~= 'string' then
        return nil
    end

    local normalized = vim.trim(value:gsub('[\r\t\n]+', ' '))

    if normalized == '' then
        return nil
    end

    if #normalized <= REMOTE_SYNC_ERROR_MAX_LENGTH then
        return normalized
    end

    return normalized:sub(1, REMOTE_SYNC_ERROR_MAX_LENGTH - 3) .. '...'
end

---@param entries legate.PlanEntry[]
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

---@param current_session legate.Session
---@return string[]
local function format_adapter(current_session)
    local adapter = config.adapter_for_session(current_session)
    local lines = {
        '## Adapter',
        string.format(
            '- Current: `%s` (%s)',
            current_session.adapter_name,
            adapter.title or current_session.adapter_name
        ),
        string.format('- Command: `%s`', table.concat(adapter.command, ' ')),
        string.format('- Auth: `%s`', adapter.auth_method or 'auto'),
    }

    local override_ids = vim.tbl_keys(adapter.config_option_overrides or {})
    table.sort(override_ids)

    if #override_ids == 0 then
        table.insert(lines, '- Config option overrides: _None._')
    else
        table.insert(lines, '- Config option overrides:')

        for _, config_id in ipairs(override_ids) do
            table.insert(lines, string.format('  - `%s = %s`', config_id, adapter.config_option_overrides[config_id]))
        end
    end

    table.insert(lines, '')

    return lines
end

---@param current_session legate.Session
---@param message legate.Message
---@return string[]
local function format_message(current_session, message)
    if message.role == 'status' then
        return { status_message.summary(current_session, message).text }
    end

    local text = message.text

    local title = message.role:sub(1, 1):upper() .. message.role:sub(2)
    local lines = {
        string.format('### %s', title),
        '',
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

---Return the stable Markdown summary line for an approval entry.
---@param approval legate.ApprovalEntry
---@param current_session? legate.Session
---@return string
function M.approval_summary_line(approval, current_session)
    local related_tool = nil

    if current_session ~= nil then
        for _, tool_call in ipairs(current_session.tool_calls) do
            if tool_call.tool_call_id == approval.tool_call_id then
                related_tool = tool_call
                break
            end
        end
    end

    return status_message.approval_summary_line(approval, related_tool)
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

---@class legate.RenderStatusRow
---@field row integer
---@field message_id integer
---@field summary legate.StatusSummary

---@class legate.RenderLayout
---@field lines string[]
---@field status_rows legate.RenderStatusRow[]

---@param current_session legate.Session
---@param prompt string?
---@return legate.RenderLayout
local function build_layout(current_session, prompt)
    local prompt_body = prompt_lines(prompt)
    ---@type legate.RenderLayout
    local layout = {
        lines = {
            '# ACP',
            '',
        },
        status_rows = {},
    }

    local lines = layout.lines

    local normalized_error = current_session.remote_sync_error ~= nil
            and normalize_remote_sync_error(current_session.remote_sync_error)
        or nil

    if normalized_error ~= nil then
        table.insert(lines, string.format('> Remote Sync Error: `%s`', normalized_error))
    end

    if current_session.remote_sync_state == 'load_failed' then
        table.insert(
            lines,
            '> Recovery: retry the recorded remote session with `:LegateLoadSession`, or create a fresh one with `:LegateRebindSession`'
        )
    end

    if normalized_error ~= nil or current_session.remote_sync_state == 'load_failed' then
        table.insert(lines, '')
    end

    if #current_session.plan_entries > 0 then
        for _, line in ipairs(format_plan(current_session.plan_entries)) do
            table.insert(lines, line)
        end
    end

    for _, line in ipairs(format_adapter(current_session)) do
        table.insert(lines, line)
    end

    table.insert(lines, config.get().transcript_header)
    table.insert(lines, '')

    if #current_session.messages == 0 then
        table.insert(lines, '_Empty._')
    else
        for index, message in ipairs(current_session.messages) do
            if message.role == 'status' then
                local summary = status_message.summary(current_session, message)

                table.insert(layout.status_rows, {
                    row = #lines + 1,
                    message_id = message.id,
                    summary = summary,
                })
                table.insert(lines, summary.text)
            else
                for _, line in ipairs(format_message(current_session, message)) do
                    table.insert(lines, line)
                end
            end

            local next_message = current_session.messages[index + 1]

            if not (message.role == 'status' and next_message ~= nil and next_message.role == 'status') then
                table.insert(lines, '')
            end
        end
    end

    table.insert(lines, '')
    table.insert(lines, '---')
    table.insert(lines, '')
    table.insert(lines, config.get().prompt_header)
    table.insert(lines, '')

    for _, line in ipairs(prompt_body) do
        table.insert(lines, line)
    end

    return layout
end

---@param bufnr integer
---@param lines string[]
local function replace_changed_range(bufnr, lines)
    local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    if vim.deep_equal(current, lines) then
        return
    end

    local prefix = 0
    local prefix_limit = math.min(#current, #lines)

    while prefix < prefix_limit and current[prefix + 1] == lines[prefix + 1] do
        prefix = prefix + 1
    end

    local suffix = 0
    local current_limit = #current - prefix
    local lines_limit = #lines - prefix

    while suffix < current_limit and suffix < lines_limit and current[#current - suffix] == lines[#lines - suffix] do
        suffix = suffix + 1
    end

    local replacement = {}

    for index = prefix + 1, #lines - suffix do
        table.insert(replacement, lines[index])
    end

    vim.api.nvim_buf_set_lines(bufnr, prefix, #current - suffix, false, replacement)
end

---Render an ACP session into the shared chat buffer.
---@param session legate.Session
---@param prompt string?
---@return integer
function M.render(session, prompt)
    if vim.in_fast_event() then
        vim.schedule(function()
            M.render(session, prompt)
        end)

        return buffer.get() or 0
    end

    local bufnr = buffer.ensure()

    if bufnr == nil or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
        return 0
    end

    local window_states = surface.capture_window_states(bufnr)
    local prompt_body = prompt_lines(prompt)
    local layout = build_layout(session, prompt)
    local lines = layout.lines
    local prompt_header_row = #lines - #prompt_body - 2

    local function buffer_is_valid()
        return vim.api.nvim_buf_is_valid(bufnr)
    end

    if not buffer_is_valid() then
        return 0
    end

    buffer.set_session_name(bufnr, session)
    buffer.with_mutation(bufnr, function()
        replace_changed_range(bufnr, lines)
    end)

    if buffer_is_valid() then
        input.set_anchor(bufnr, prompt_header_row)
    end

    if buffer_is_valid() then
        hover.set_status_rows(bufnr, layout.status_rows)
    end

    if buffer_is_valid() then
        surface.decorate(bufnr, session, layout.status_rows)
    end

    if buffer_is_valid() then
        approval_ui.apply(bufnr, session, session.pending_approvals or {})
    end

    if buffer_is_valid() then
        surface.restore_window_states(bufnr, window_states)
    end

    local ok, edit = pcall(require, 'legate.ui.edit')

    if buffer_is_valid() and ok and type(edit.refresh) == 'function' then
        edit.refresh(bufnr)
    end

    return bufnr
end

return M
