local buffer = require('acp.buffer')
local config = require('acp.config')
local input = require('acp.input')
local surface = require('acp.surface')

---@class acp.RenderModule
local M = {}

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

---@param message acp.Message
---@return string
local function status_icon(message)
    if message.stream_kind == 'approval' then
        return approval_icon(message.status_state)
    end

    return tool_icon(message.status_state)
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

---@param message acp.Message
---@return string[]
local function format_message(message)
    local text = message.text

    if message.role == 'status' then
        local lines = {
            string.format('- %s %s', status_icon(message), message.status_title or 'Status'),
        }

        for _, line in
            ipairs(vim.split(text, '\n', {
                plain = true,
            }))
        do
            if line ~= '' then
                table.insert(lines, string.format('  %s', line))
            end
        end

        return lines
    end

    local title = message.role:sub(1, 1):upper() .. message.role:sub(2)
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

---Return the stable Markdown summary line for an approval entry.
---@param approval acp.ApprovalEntry
---@return string
function M.approval_summary_line(approval)
    return string.format(
        '- %s Approval [%d] %s',
        approval_icon(approval.selected_kind or approval.outcome),
        approval.ordinal,
        approval.title
    )
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
    }

    if session.remote_sync_error ~= nil then
        table.insert(lines, string.format('> Remote Sync Error: `%s`', session.remote_sync_error))
    end

    if session.remote_sync_state == 'load_failed' then
        table.insert(
            lines,
            '> Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
        )
    end

    if session.remote_sync_error ~= nil or session.remote_sync_state == 'load_failed' then
        table.insert(lines, '')
    end

    if #session.plan_entries > 0 then
        for _, line in ipairs(format_plan(session.plan_entries)) do
            table.insert(lines, line)
        end
    end

    table.insert(lines, config.get().transcript_header)

    if #session.messages == 0 then
        table.insert(lines, '_Empty._')
    else
        for _, message in ipairs(session.messages) do
            for _, line in ipairs(format_message(message)) do
                table.insert(lines, line)
            end

            table.insert(lines, '')
        end
    end

    table.insert(lines, '')
    table.insert(lines, '---')
    table.insert(lines, '')
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
    if vim.in_fast_event() then
        vim.schedule(function()
            M.render(session, prompt)
        end)

        return buffer.get() or 0
    end

    local bufnr = buffer.ensure()
    local window_states = surface.capture_window_states(bufnr)
    local prompt_body = prompt_lines(prompt)
    local lines = build_lines(session, prompt)
    local prompt_header_row = #lines - #prompt_body - 1

    buffer.with_mutation(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)
    input.set_anchor(bufnr, prompt_header_row)
    surface.decorate(bufnr, session)
    surface.restore_window_states(bufnr, window_states)

    local ok, edit = pcall(require, 'acp.edit')

    if ok and type(edit.refresh) == 'function' then
        edit.refresh(bufnr)
    end

    return bufnr
end

return M
