local buffer = require('acp.buffer')
local config_option = require('acp.config_option')
local config = require('acp.config')
local input = require('acp.input')
local picker = require('acp.picker')
local persistence = require('acp.persistence')
local render = require('acp.render')
local session = require('acp.session')
local terminal = require('acp.terminal')
local transport = require('acp.transport')

---@class acp.Api
local M = {}
local store_draft

---@param name string
---@return string
local function normalize_slash_command_name(name)
    local trimmed = vim.trim(name)

    if vim.startswith(trimmed, '/') then
        return trimmed:sub(2)
    end

    return trimmed
end

---@param option acp.SessionConfigOption
---@return string
local function config_option_line(option)
    return string.format('%s  (`%s`)  current=%s', option.name, option.id, option.currentValue)
end

---@param choice acp.ConfigOptionValueChoice
---@param current_value string
---@return string
local function config_option_value_line(choice, current_value)
    local marker = choice.value.value == current_value and '*' or ' '
    local label = string.format('%s %s  (`%s`)', marker, choice.value.name, choice.value.value)

    if choice.group_name ~= nil then
        return string.format('%s [%s]', label, choice.group_name)
    end

    return label
end

---@param current_session acp.Session
---@return string
local function session_line(current_session)
    local selected_session = session.current()
    local selected_id = selected_session and selected_session.id or nil
    local marker = current_session.id == selected_id and '*' or ' '

    return string.format(
        '%s %s  [%s]  remote=%s  sync=%s  messages=%d',
        marker,
        current_session.id,
        current_session.status,
        current_session.remote_id or 'unbound',
        current_session.remote_sync_state,
        #current_session.messages
    )
end

---@param approval acp.ApprovalEntry
---@return string
local function approval_line(approval)
    local selected = approval.selected_option_name

    if selected ~= nil and approval.selected_kind ~= nil then
        selected = string.format('%s [%s]', selected, approval.selected_kind)
    else
        selected = approval.outcome
    end

    return string.format(
        '[%d] %s  outcome=%s  via=%s  selected=%s',
        approval.ordinal,
        approval.title,
        approval.outcome,
        approval.source,
        selected
    )
end

---@param command acp.AvailableCommand
---@return string
local function slash_command_line(command)
    local line = string.format('/%s  %s', command.name, command.description)

    if type(command.input) == 'table' and command.input.hint ~= nil and command.input.hint ~= '' then
        line = string.format('%s  input=%s', line, command.input.hint)
    end

    return line
end

---@param options acp.SessionConfigOption[]
---@return fun(option: acp.SessionConfigOption): string
local function config_option_picker_formatter(options)
    return picker.make_formatter(options, function(option)
        return {
            option.name,
            string.format('current=%s', option.currentValue),
            string.format('id=%s', option.id),
            option.description or '',
        }
    end)
end

---@param choices acp.ConfigOptionValueChoice[]
---@param current_value string
---@return fun(choice: acp.ConfigOptionValueChoice): string
local function config_option_value_picker_formatter(choices, current_value)
    return picker.make_formatter(choices, function(choice)
        local marker = choice.value.value == current_value and '*' or ' '
        local group = choice.group_name and string.format('[%s]', choice.group_name) or ''

        return {
            string.format('%s %s', marker, choice.value.name),
            string.format('value=%s', choice.value.value),
            group,
            choice.value.description or '',
        }
    end)
end

---@param commands acp.AvailableCommand[]
---@return fun(command: acp.AvailableCommand): string
local function slash_command_picker_formatter(commands)
    return picker.make_formatter(commands, function(command)
        local input_hint = ''

        if type(command.input) == 'table' and command.input.hint ~= nil and command.input.hint ~= '' then
            input_hint = string.format('input=%s', command.input.hint)
        end

        return {
            string.format('/%s', command.name),
            command.description,
            input_hint,
        }
    end)
end

---@param sessions acp.Session[]
---@param prompt string
---@param on_choice fun(selected_session: acp.Session)
local function pick_session(sessions, prompt, on_choice)
    if #sessions == 0 then
        vim.notify('No ACP sessions exist')
        return
    end

    vim.ui.select(sessions, {
        prompt = prompt,
        format_item = session_line,
    }, function(selected_session)
        if selected_session == nil then
            return
        end

        on_choice(selected_session)
    end)
end

---@param current_session acp.Session
---@param approval_ordinal integer
---@return acp.ApprovalEntry
local function approval_by_ordinal(current_session, approval_ordinal)
    for _, approval in ipairs(current_session.approval_entries) do
        if approval.ordinal == approval_ordinal then
            return approval
        end
    end

    error(string.format('Unknown ACP approval: %d', approval_ordinal))
end

---@return acp.Session
local function active_session()
    if config.get().auto_create_session then
        return session.ensure()
    end

    local current = session.current()

    if current == nil then
        error('No ACP session exists')
    end

    return current
end

---@param session_id? string
---@return acp.Session
local function resolve_session(session_id)
    if session_id ~= nil then
        local existing = session.get(session_id)

        if existing == nil then
            error(string.format('Unknown ACP session: %s', session_id))
        end

        return existing
    end

    return active_session()
end

---@param session_id? string
---@return acp.Session
local function resolve_pending_approval_session(session_id)
    if session_id ~= nil then
        return resolve_session(session_id)
    end

    local pending_session = session.pending_approval_session()

    if pending_session ~= nil then
        return pending_session
    end

    local waiting_session = session.waiting()

    if waiting_session ~= nil then
        return waiting_session
    end

    return active_session()
end

---@param current_session acp.Session
---@param config_id string
---@return acp.SessionConfigOption
local function config_option_by_id(current_session, config_id)
    for _, option in ipairs(current_session.config_options) do
        if option.id == config_id then
            return option
        end
    end

    error(string.format('Unknown ACP config option: %s', config_id))
end

---@param current_session acp.Session
---@param name string
---@return acp.AvailableCommand
local function slash_command_by_name(current_session, name)
    local normalized = normalize_slash_command_name(name)

    for _, command in ipairs(current_session.available_commands) do
        if command.name == normalized then
            return command
        end
    end

    error(string.format('Unknown ACP slash command: %s', name))
end

---@param current_session acp.Session
local function assert_config_change_allowed(current_session)
    local waiting_session = session.waiting()

    if waiting_session ~= nil and waiting_session.id ~= current_session.id then
        error(
            string.format(
                'Cannot change ACP config options for session %s while session %s has a running turn',
                current_session.id,
                waiting_session.id
            )
        )
    end
end

---@param current_session acp.Session
local function assert_slash_command_fetch_allowed(current_session)
    local waiting_session = session.waiting()

    if waiting_session ~= nil and waiting_session.id ~= current_session.id then
        error(
            string.format(
                'Cannot resolve ACP slash commands for session %s while session %s has a running turn',
                current_session.id,
                waiting_session.id
            )
        )
    end
end

---@param current_session acp.Session
---@param action string
local function assert_session_binding_change_allowed(current_session, action)
    if current_session.status == 'waiting' then
        error(
            string.format('Cannot %s ACP session while a prompt turn is still running: %s', action, current_session.id)
        )
    end

    local waiting_session = session.waiting()

    if waiting_session ~= nil and waiting_session.id ~= current_session.id then
        error(
            string.format(
                'Cannot %s ACP session %s while session %s has a running turn',
                action,
                current_session.id,
                waiting_session.id
            )
        )
    end
end

---@param current_session acp.Session
local function ensure_config_options(current_session)
    if current_session.remote_id ~= nil and #current_session.config_options > 0 then
        return
    end

    assert_config_change_allowed(current_session)
    transport.ensure(current_session)
end

---@param current_session acp.Session
local function ensure_slash_commands(current_session)
    if current_session.remote_id ~= nil and current_session.turn_id == 0 and current_session.status ~= 'cancelled' then
        return
    end

    assert_slash_command_fetch_allowed(current_session)
    transport.ensure(current_session)
end

---@param current_session acp.Session?
store_draft = function(current_session)
    if current_session == nil then
        return
    end

    local bufnr = buffer.get()

    if bufnr == nil then
        return
    end

    local prompt = input.capture_prompt(bufnr)

    if prompt ~= nil then
        session.set_draft_prompt(current_session, prompt)
    end
end

---@param current_session acp.Session
---@return string
local function visible_prompt(current_session)
    local prompt = current_session.draft_prompt or ''
    local current = session.current()

    if current == nil or current.id ~= current_session.id then
        return prompt
    end

    store_draft(current_session)
    return current_session.draft_prompt
end

---@param current_session acp.Session
---@param prompt string
---@return acp.Session
local function submit_session_prompt(current_session, prompt)
    if current_session.status == 'waiting' then
        error('Cannot submit a new ACP prompt while this session already has a running turn')
    end

    if session.waiting() ~= nil then
        error('Cannot submit a new ACP prompt while another session turn is still running')
    end

    if prompt == '' then
        error('ACP prompt is empty')
    end

    session.set_draft_prompt(current_session, prompt)
    transport.ensure(current_session)
    current_session = session.begin_prompt(current_session, prompt)

    local selected_session = session.current()

    if buffer.get() ~= nil and selected_session ~= nil and selected_session.id == current_session.id then
        render.render(current_session, '')
    end

    transport.prompt(current_session, prompt)

    return current_session
end

---@param command acp.AvailableCommand
---@param provided_input? string
---@return string
local function slash_command_prompt(command, provided_input)
    local normalized_input = vim.trim(provided_input or '')
    local prompt = string.format('/%s', command.name)

    if type(command.input) == 'table' and normalized_input == '' then
        error(string.format('ACP slash command requires input: /%s', command.name))
    end

    if normalized_input == '' then
        return prompt
    end

    return string.format('%s %s', prompt, normalized_input)
end

---@return integer, acp.Session, string
local function ensure_chat_surface()
    local current_session = active_session()
    local bufnr = buffer.ensure()
    local prompt = input.capture_prompt(bufnr)

    if prompt == nil then
        prompt = current_session.draft_prompt or ''
        render.render(current_session, prompt)
    else
        session.set_draft_prompt(current_session, prompt)
    end

    return bufnr, current_session, prompt
end

---Create or reveal the ACP chat buffer.
---@return integer
function M.open_chat()
    local bufnr, current_session, prompt = ensure_chat_surface()

    buffer.open()
    render.render(current_session, prompt)
    vim.api.nvim_win_set_cursor(0, {
        vim.api.nvim_buf_line_count(bufnr),
        0,
    })

    local ok, edit = pcall(require, 'acp.edit')

    if ok and type(edit.refresh) == 'function' then
        edit.refresh(bufnr)
    end

    return bufnr
end

---Create and select a new ACP session, then render it.
---@return acp.Session
function M.new_session()
    store_draft(session.current())

    local current_session = session.create()

    render.render(current_session, current_session.draft_prompt)

    return current_session
end

---Return the current ACP session, creating one if configured to do so.
---@return acp.Session
function M.current_session()
    return active_session()
end

---Return all local ACP sessions ordered by creation ordinal.
---@return acp.Session[]
function M.list_sessions()
    return session.list()
end

---Return formatted local-session lines for command-line or picker use.
---@return string[]
function M.session_lines()
    local lines = {}

    for _, current_session in ipairs(session.list()) do
        table.insert(lines, session_line(current_session))
    end

    return lines
end

---Return the current ACP approval history for command or picker use.
---@param session_id? string
---@return acp.ApprovalEntry[]
function M.approvals(session_id)
    local current_session = resolve_session(session_id)
    return vim.deepcopy(current_session.approval_entries)
end

---Return the currently pending inline ACP approval, if any.
---@param session_id? string
---@return acp.PendingApproval?
function M.pending_approval(session_id)
    local current_session = resolve_pending_approval_session(session_id)
    return vim.deepcopy(session.pending_approval(current_session))
end

---Return formatted approval lines for command-line display or picker use.
---@param session_id? string
---@return string[]
function M.approval_lines(session_id)
    local lines = {}

    for _, approval in ipairs(M.approvals(session_id)) do
        table.insert(lines, approval_line(approval))
    end

    return lines
end

---Persist all local ACP sessions to disk.
---@return acp.SessionPersistencePayload
function M.save_sessions()
    store_draft(session.current())

    local payload = session.snapshot()
    persistence.save(payload)

    return payload
end

---Restore local ACP sessions from disk.
---@param opts? { open_chat?: boolean }
---@return acp.Session[]
function M.restore_sessions(opts)
    local restored = session.restore(persistence.load())
    local current_session = session.current()
    local should_open = opts ~= nil and opts.open_chat or false
    local has_buffer = buffer.get() ~= nil

    if current_session ~= nil then
        if should_open then
            M.open_chat()
        elseif has_buffer then
            render.render(current_session, current_session.draft_prompt)
        end

        return restored
    end

    if should_open and config.get().auto_create_session then
        M.open_chat()
    elseif has_buffer then
        buffer.clear()
    end

    return restored
end

---Clear persisted ACP session storage from disk.
function M.clear_session_storage()
    persistence.clear()
end

---Return the current session config options for command or picker use.
---@param session_id? string
---@return acp.SessionConfigOption[]
function M.config_options(session_id)
    local current_session = resolve_session(session_id)
    ensure_config_options(current_session)
    return vim.deepcopy(current_session.config_options)
end

---Return formatted config option lines for command-line display.
---@param session_id? string
---@return string[]
function M.config_option_lines(session_id)
    local lines = {}

    for _, option in ipairs(M.config_options(session_id)) do
        table.insert(lines, config_option_line(option))
    end

    return lines
end

---Return the current ACP slash commands for command or picker use.
---@param session_id? string
---@return acp.AvailableCommand[]
function M.slash_commands(session_id)
    local current_session = resolve_session(session_id)
    ensure_slash_commands(current_session)
    return vim.deepcopy(current_session.available_commands)
end

---Return formatted ACP slash-command lines for command-line display or picker use.
---@param session_id? string
---@return string[]
function M.slash_command_lines(session_id)
    local lines = {}

    for _, command in ipairs(M.slash_commands(session_id)) do
        table.insert(lines, slash_command_line(command))
    end

    return lines
end

---Return locally known ACP slash-command names for completion use.
---@param session_id? string
---@return string[]
function M.slash_command_names(session_id)
    local current_session = session_id and session.get(session_id) or session.current()

    if current_session == nil then
        return {}
    end

    ensure_slash_commands(current_session)

    local names = {}

    for _, command in ipairs(current_session.available_commands) do
        table.insert(names, command.name)
    end

    return names
end

---Open a picker for session config options, then a second picker for the selected value.
---@param session_id? string
function M.pick_config_option(session_id)
    local current_session = resolve_session(session_id)
    ensure_config_options(current_session)

    if #current_session.config_options == 0 then
        vim.notify('No ACP config options are available')
        return
    end

    local format_option = config_option_picker_formatter(current_session.config_options)

    local function pick_option()
        vim.ui.select(current_session.config_options, {
            prompt = 'Select ACP config option',
            format_item = format_option,
        }, function(selected_option)
            if selected_option == nil then
                return
            end

            local values = config_option.choices(selected_option)

            if #values == 0 then
                vim.notify(string.format('ACP config option has no selectable values: %s', selected_option.id))
                return
            end

            vim.ui.select(values, {
                prompt = string.format('Select value for ACP config option: %s', selected_option.name),
                format_item = config_option_value_picker_formatter(values, selected_option.currentValue),
            }, function(selected_choice)
                if selected_choice == nil then
                    pick_option()
                    return
                end

                M.set_config_option(selected_option.id, selected_choice.value.value, current_session.id)
            end)
        end)
    end

    pick_option()
end

---Open a picker for ACP slash commands and submit the selected command prompt.
---@param session_id? string
function M.pick_slash_command(session_id)
    local current_session = resolve_session(session_id)
    ensure_slash_commands(current_session)

    if #current_session.available_commands == 0 then
        vim.notify('No ACP slash commands are available')
        return
    end

    local format_command = slash_command_picker_formatter(current_session.available_commands)

    local function pick_command()
        vim.ui.select(current_session.available_commands, {
            prompt = 'Select ACP slash command',
            format_item = format_command,
        }, function(selected_command)
            if selected_command == nil then
                return
            end

            if type(selected_command.input) ~= 'table' then
                M.run_slash_command(selected_command.name, nil, current_session.id)
                return
            end

            vim.ui.input({
                prompt = string.format('Input for ACP slash command /%s', selected_command.name),
                default = '',
            }, function(provided_input)
                if provided_input == nil then
                    pick_command()
                    return
                end

                local trimmed_input = vim.trim(provided_input)

                if trimmed_input == '' then
                    vim.notify(string.format('ACP slash command requires input: /%s', selected_command.name))
                    return
                end

                M.run_slash_command(selected_command.name, trimmed_input, current_session.id)
            end)
        end)
    end

    pick_command()
end

---Open a picker for local ACP sessions and select the chosen session.
function M.pick_session()
    pick_session(session.list(), 'Select ACP session', function(selected_session)
        M.select_session(selected_session.id)
    end)
end

---Select a local ACP session and rerender the shared chat buffer.
---@param session_id string
---@return acp.Session
function M.select_session(session_id)
    store_draft(session.current())

    local current_session = session.select(session_id)

    render.render(current_session, current_session.draft_prompt)

    return current_session
end

---Reveal an approval entry in the shared Markdown chat buffer.
---@param approval_ordinal integer
---@param session_id? string
---@return acp.ApprovalEntry
function M.reveal_approval(approval_ordinal, session_id)
    local current_session = resolve_session(session_id)
    local approval = approval_by_ordinal(current_session, approval_ordinal)
    local selected_session = session.current()

    if selected_session == nil or selected_session.id ~= current_session.id then
        current_session = M.select_session(current_session.id)
    else
        render.render(current_session, visible_prompt(current_session))
    end

    local bufnr = buffer.open()
    local target_line = render.approval_summary_line(approval, current_session)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    for line_number, line in ipairs(lines) do
        if line == target_line then
            vim.api.nvim_win_set_cursor(0, {
                line_number,
                0,
            })
            return approval
        end
    end

    error(string.format('ACP approval is not visible in the chat buffer: %d', approval_ordinal))
end

---Open a picker for current-session approvals and reveal the chosen entry.
---@param session_id? string
function M.pick_approval(session_id)
    local current_session = resolve_session(session_id)

    if #current_session.approval_entries == 0 then
        vim.notify('No ACP approvals are available')
        return
    end

    vim.ui.select(current_session.approval_entries, {
        prompt = 'Select ACP approval',
        format_item = approval_line,
    }, function(selected_approval)
        if selected_approval == nil then
            return
        end
        M.reveal_approval(selected_approval.ordinal, current_session.id)
    end)
end

---Resolve the current inline ACP approval by option id or 1-based index.
---@param selection string|integer
---@param session_id? string
---@return acp.PermissionOutcome
function M.select_approval_option(selection, session_id)
    local current_session = resolve_pending_approval_session(session_id)
    return transport.select_pending_approval(current_session, selection)
end

---Explicitly bind or reload an ACP session against the remote transport.
---@param session_id? string
---@return acp.Session
function M.load_session(session_id)
    local current_session = resolve_session(session_id)
    assert_session_binding_change_allowed(current_session, 'load')
    local prompt = visible_prompt(current_session)
    local ok, err = pcall(transport.load, current_session)

    local selected_session = session.current()

    if buffer.get() ~= nil and selected_session ~= nil and selected_session.id == current_session.id then
        render.render(current_session, prompt)
    end

    if not ok then
        error(err, 0)
    end

    return current_session
end

---Recover a load_failed ACP session by creating a fresh remote ACP session.
---@param session_id? string
---@return acp.Session
function M.rebind_session(session_id)
    local current_session = resolve_session(session_id)
    assert_session_binding_change_allowed(current_session, 'rebind')

    if current_session.remote_sync_state ~= 'load_failed' then
        error(string.format('ACP session is not in load_failed recovery state: %s', current_session.id))
    end

    local prompt = visible_prompt(current_session)
    local ok, err = pcall(transport.rebind, current_session)
    local selected_session = session.current()

    if buffer.get() ~= nil and selected_session ~= nil and selected_session.id == current_session.id then
        render.render(current_session, prompt)
    end

    if not ok then
        error(err, 0)
    end

    return current_session
end

---Submit an ACP slash command through the normal prompt path.
---@param name string
---@param command_input? string
---@param session_id? string
---@return acp.Session
function M.run_slash_command(name, command_input, session_id)
    local current_session = resolve_session(session_id)
    ensure_slash_commands(current_session)
    local command = slash_command_by_name(current_session, name)
    local prompt = slash_command_prompt(command, command_input)

    return submit_session_prompt(current_session, prompt)
end

---Close a local ACP session and update the shared chat buffer if needed.
---@param session_id? string
---@return acp.Session, acp.Session?
function M.close_session(session_id)
    local target_id = session_id

    if target_id == nil then
        local current_session = session.current()

        if current_session == nil then
            error('No ACP session exists')
        end

        target_id = current_session.id
    end

    local closing_session = assert(session.get(target_id), string.format('Unknown ACP session: %s', target_id))

    if closing_session.status == 'waiting' then
        error(string.format('Cannot close ACP session while a prompt turn is still running: %s', target_id))
    end

    local current_session = session.current()
    local is_current = current_session ~= nil and current_session.id == target_id
    local had_buffer = buffer.get() ~= nil

    if is_current then
        store_draft(current_session)
    end

    local closed_session, next_session = session.close(target_id)

    if is_current then
        if next_session == nil and config.get().auto_create_session then
            next_session = session.create()
        end

        if had_buffer and next_session ~= nil then
            render.render(next_session, next_session.draft_prompt)
        elseif had_buffer then
            buffer.clear()
        end
    end

    return closed_session, next_session
end

---Set a session config option through ACP and rerender the chat buffer if needed.
---@param config_id string
---@param value string
---@param session_id? string
---@return acp.Session
function M.set_config_option(config_id, value, session_id)
    local current_session = resolve_session(session_id)
    assert_config_change_allowed(current_session)
    ensure_config_options(current_session)

    local option = config_option_by_id(current_session, config_id)
    local choices = config_option.choices(option)

    if #choices == 0 then
        error(string.format('ACP config option has no selectable values: %s', config_id))
    end

    local value_exists = false

    for _, choice in ipairs(choices) do
        if choice.value.value == value then
            value_exists = true
            break
        end
    end

    if not value_exists then
        error(string.format('Invalid ACP config option value for %s: %s', config_id, value))
    end

    local prompt = visible_prompt(current_session)
    transport.set_config_option(current_session, config_id, value)

    local selected_session = session.current()

    if buffer.get() ~= nil and selected_session ~= nil and selected_session.id == current_session.id then
        render.render(current_session, prompt)
    end

    return current_session
end

---Open a picker for closable local ACP sessions and close the chosen session.
function M.pick_close_session()
    local closable_sessions = vim.tbl_filter(function(current_session)
        return current_session.status ~= 'waiting'
    end, session.list())

    if #closable_sessions == 0 then
        vim.notify('No closable ACP sessions exist')
        return
    end

    pick_session(closable_sessions, 'Close ACP session', function(selected_session)
        M.close_session(selected_session.id)
    end)
end

---Append a transcript message and rerender the chat buffer.
---@param role acp.MessageRole
---@param text string
---@return acp.Session
function M.append_message(role, text)
    local _, current_session, prompt = ensure_chat_surface()

    session.append_message(current_session, role, text)
    render.render(current_session, prompt)

    return current_session
end

---Submit the editable prompt region as the next ACP prompt.
---@return acp.Session
function M.submit_prompt()
    local bufnr, current_session = ensure_chat_surface()
    local prompt = input.get_prompt(bufnr)
    return submit_session_prompt(current_session, prompt)
end

---Cancel the current ACP prompt state and rerender the chat buffer.
---@return acp.Session?
function M.cancel_prompt()
    local current_session = session.current()
    local waiting_session = session.waiting()

    if current_session == nil and waiting_session == nil then
        return nil
    end

    if current_session ~= nil and (waiting_session == nil or waiting_session.id ~= current_session.id) then
        store_draft(current_session)
    end

    local target_session = waiting_session or current_session

    if target_session == nil or target_session.status ~= 'waiting' then
        return nil
    end

    local prompt = target_session.pending_prompt or target_session.draft_prompt or ''

    transport.cancel(target_session)
    session.set_draft_prompt(target_session, prompt)
    target_session = session.cancel(target_session)

    if current_session ~= nil and current_session.id == target_session.id then
        render.render(target_session, prompt)
    end

    return target_session
end

---Return the current editable ACP prompt text.
---@return string
function M.get_prompt()
    local bufnr, current_session = ensure_chat_surface()
    local prompt = input.get_prompt(bufnr)

    session.set_draft_prompt(current_session, prompt)

    return prompt
end

---Replace the editable ACP prompt text.
---@param text string
function M.set_prompt(text)
    local bufnr, current_session = ensure_chat_surface()

    input.set_prompt(bufnr, text)
    session.set_draft_prompt(current_session, text)
end

---Return the effective ACP terminal backend name.
---@return acp.TerminalBackendName
function M.terminal_backend_name()
    return terminal.resolve().name
end

---Reset all in-memory ACP state.
function M.clear()
    transport.clear()
    terminal.clear()
    session.clear()
    buffer.clear()
    config.reset()
end

return M
