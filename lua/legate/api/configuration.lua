local M = {}

local approval_mode_aliases = {
    strict = 'ask',
    yolo = 'code',
}

---@param deps { buffer: legate.BufferModule, config_option: legate.ConfigOptionModule, continuity: legate.SessionModule, formatters: table, prompt_helper: table, render: legate.RenderModule, resolve_session: fun(session_id?: string): legate.Session, transport: legate.TransportModule }
---@return table
function M.new(deps)
    local helper = {}

    ---@param current_session legate.Session
    local function assert_config_change_allowed(current_session)
        local waiting_session = deps.continuity.waiting()

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

    ---@param current_session legate.Session
    local function ensure_config_options(current_session)
        local has_live_binding = deps.continuity.transport_remote_id(current_session) ~= nil
            or current_session.remote_sync_state == 'loaded'

        if not has_live_binding and current_session.remote_sync_state == 'created' then
            return
        end

        if has_live_binding and #current_session.config_options > 0 then
            return
        end

        assert_config_change_allowed(current_session)
        deps.transport.ensure(current_session)
    end

    ---@param current_session legate.Session
    ---@param config_id string
    ---@return legate.SessionConfigOption
    local function config_option_by_id(current_session, config_id)
        for _, option in ipairs(current_session.config_options) do
            if option.id == config_id then
                return option
            end
        end

        error(string.format('Unknown ACP config option: %s', config_id))
    end

    ---@param current_session legate.Session
    ---@param prompt string
    local function rerender_selected_session(current_session, prompt)
        local selected_session = deps.continuity.current()

        if deps.buffer.get() ~= nil and selected_session ~= nil and selected_session.id == current_session.id then
            deps.render.render(current_session, prompt)
        end
    end

    ---@param session_id? string
    ---@return legate.SessionConfigOption[]
    function helper.config_options(session_id)
        local current_session = deps.resolve_session(session_id)
        ensure_config_options(current_session)
        return vim.deepcopy(current_session.config_options)
    end

    ---@param session_id? string
    ---@return string[]
    function helper.config_option_lines(session_id)
        local lines = {}

        for _, option in ipairs(helper.config_options(session_id)) do
            table.insert(lines, deps.formatters.config_option_line(option))
        end

        return lines
    end

    ---@param config_id string
    ---@param value string
    ---@param session_id? string
    ---@return legate.Session
    function helper.set_config_option(config_id, value, session_id)
        local current_session = deps.resolve_session(session_id)
        assert_config_change_allowed(current_session)
        ensure_config_options(current_session)

        local option = config_option_by_id(current_session, config_id)
        local choices = deps.config_option.choices(option)

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

        local prompt = deps.prompt_helper.visible_prompt(current_session)
        deps.transport.set_config_option(current_session, config_id, value)
        rerender_selected_session(current_session, prompt)

        return current_session
    end

    ---@param mode string
    ---@param session_id? string
    ---@return legate.Session
    function helper.set_approval_mode(mode, session_id)
        local normalized = approval_mode_aliases[mode] or mode
        return helper.set_config_option('mode', normalized, session_id)
    end

    ---@param session_id? string
    function helper.pick_config_option(session_id)
        local current_session = deps.resolve_session(session_id)
        ensure_config_options(current_session)

        if #current_session.config_options == 0 then
            vim.notify('No ACP config options are available')
            return
        end

        local format_option = deps.formatters.config_option_picker_formatter(current_session.config_options)

        local function pick_option()
            vim.ui.select(current_session.config_options, {
                prompt = 'Select ACP config option',
                format_item = format_option,
            }, function(selected_option)
                if selected_option == nil then
                    return
                end

                local values = deps.config_option.choices(selected_option)

                if #values == 0 then
                    vim.notify(string.format('ACP config option has no selectable values: %s', selected_option.id))
                    return
                end

                vim.ui.select(values, {
                    prompt = string.format('Select value for ACP config option: %s', selected_option.name),
                    format_item = deps.formatters.config_option_value_picker_formatter(
                        values,
                        selected_option.currentValue
                    ),
                }, function(selected_choice)
                    if selected_choice == nil then
                        pick_option()
                        return
                    end

                    helper.set_config_option(selected_option.id, selected_choice.value.value, current_session.id)
                end)
            end)
        end

        pick_option()
    end

    return helper
end

return M
