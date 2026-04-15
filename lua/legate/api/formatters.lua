local config = require('legate.config')
local picker = require('legate.ui.picker')

local M = {}

---@param option legate.SessionConfigOption
---@return string
function M.config_option_line(option)
    return string.format('%s  (`%s`)  current=%s', option.name, option.id, option.currentValue)
end

---@param choice legate.ConfigOptionValueChoice
---@param current_value string
---@return string
function M.config_option_value_line(choice, current_value)
    local marker = choice.value.value == current_value and '*' or ' '
    local label = string.format('%s %s  (`%s`)', marker, choice.value.name, choice.value.value)

    if choice.group_name ~= nil then
        return string.format('%s [%s]', label, choice.group_name)
    end

    return label
end

---@param current_session legate.Session
---@param selected_session legate.Session?
---@return string
function M.session_line(current_session, selected_session)
    local selected_id = selected_session and selected_session.id or nil
    local marker = current_session.id == selected_id and '*' or ' '

    return string.format(
        '%s %s  adapter=%s  [%s]  remote=%s  sync=%s  messages=%d',
        marker,
        current_session.id,
        config.session_adapter_name(current_session),
        current_session.status,
        current_session.remote_id or 'unbound',
        current_session.remote_sync_state,
        #current_session.messages
    )
end

---@param approval legate.ApprovalEntry
---@return string
function M.approval_line(approval)
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

---@param command legate.AvailableCommand
---@return string
function M.slash_command_line(command)
    local line = string.format('/%s  %s', command.name, command.description)

    if type(command.input) == 'table' and command.input.hint ~= nil and command.input.hint ~= '' then
        line = string.format('%s  input=%s', line, command.input.hint)
    end

    return line
end

---@param current_session legate.Session
---@return legate.AdapterConfig
local function adapter_for_session(current_session)
    return config.adapter_for_session(current_session)
end

---@param current_session legate.Session
---@param selected_session legate.Session?
---@return string
function M.adapter_line(current_session, selected_session)
    local selected_id = selected_session and selected_session.id or nil
    local marker = current_session.id == selected_id and '*' or ' '
    local adapter_name = config.session_adapter_name(current_session)
    local adapter = adapter_for_session(current_session)
    local auth_method = adapter.auth_method or 'auto'

    return string.format(
        '%s %s  title=%s  auth=%s  command=%s  overrides=%d',
        marker,
        adapter_name,
        adapter.title or adapter_name,
        auth_method,
        table.concat(adapter.command, ' '),
        vim.tbl_count(adapter.config_option_overrides or {})
    )
end

---@param options legate.SessionConfigOption[]
---@return fun(option: legate.SessionConfigOption): string
function M.config_option_picker_formatter(options)
    return picker.make_formatter(options, function(option)
        return {
            option.name,
            string.format('current=%s', option.currentValue),
            string.format('id=%s', option.id),
            option.description or '',
        }
    end)
end

---@param choices legate.ConfigOptionValueChoice[]
---@param current_value string
---@return fun(choice: legate.ConfigOptionValueChoice): string
function M.config_option_value_picker_formatter(choices, current_value)
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

---@param commands legate.AvailableCommand[]
---@return fun(command: legate.AvailableCommand): string
function M.slash_command_picker_formatter(commands)
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

---@param current_session legate.Session
---@return fun(adapter_name: string): string
function M.adapter_picker_formatter(current_session)
    local current_adapter_name = config.session_adapter_name(current_session)

    return function(adapter_name)
        local adapter = config.adapter(adapter_name)
        local marker = adapter_name == current_adapter_name and '*' or ' '

        return string.format(
            '%s %s  id=%s  auth=%s  %s',
            marker,
            adapter.title or adapter_name,
            adapter_name,
            adapter.auth_method or 'auto',
            table.concat(adapter.command, ' ')
        )
    end
end

return M
