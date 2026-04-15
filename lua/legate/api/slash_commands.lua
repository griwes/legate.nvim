local M = {}

---@param deps { continuity: legate.SessionModule, formatters: table, prompt_helper: table, resolve_session: fun(session_id?: string): legate.Session, transport: legate.TransportModule }
---@return table
function M.new(deps)
    local helper = {}

    ---@param current_session legate.Session
    local function assert_slash_command_fetch_allowed(current_session)
        local waiting_session = deps.continuity.waiting()

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

    ---@param current_session legate.Session
    ---@param opts? { allow_establish?: boolean }
    local function ensure_slash_commands(current_session, opts)
        local transport_remote_id = deps.continuity.transport_remote_id(current_session)

        if transport_remote_id == nil and current_session.remote_sync_state == 'created' then
            return
        end

        if
            transport_remote_id ~= nil
            and current_session.turn_id == 0
            and current_session.status ~= 'cancelled'
            and #current_session.available_commands > 0
        then
            return
        end

        if opts ~= nil and opts.allow_establish == false then
            return
        end

        assert_slash_command_fetch_allowed(current_session)
        deps.transport.ensure(current_session)
    end

    ---@param name string
    ---@return string
    local function normalize_slash_command_name(name)
        local trimmed = vim.trim(name)

        if vim.startswith(trimmed, '/') then
            return trimmed:sub(2)
        end

        return trimmed
    end

    ---@param current_session legate.Session
    ---@param name string
    ---@return legate.AvailableCommand
    local function slash_command_by_name(current_session, name)
        local normalized = normalize_slash_command_name(name)

        for _, command in ipairs(current_session.available_commands) do
            if command.name == normalized then
                return command
            end
        end

        error(string.format('Unknown ACP slash command: %s', name))
    end

    ---@param session_id? string
    ---@return legate.AvailableCommand[]
    function helper.slash_commands(session_id)
        local current_session = deps.resolve_session(session_id)
        ensure_slash_commands(current_session)
        return vim.deepcopy(current_session.available_commands)
    end

    ---@param session_id? string
    ---@return string[]
    function helper.slash_command_lines(session_id)
        local lines = {}

        for _, command in ipairs(helper.slash_commands(session_id)) do
            table.insert(lines, deps.formatters.slash_command_line(command))
        end

        return lines
    end

    ---@param session_id? string
    ---@return string[]
    function helper.slash_command_names(session_id)
        local current_session = session_id and deps.continuity.get(session_id) or deps.continuity.current()

        if current_session == nil then
            return {}
        end

        local names = {}

        for _, command in ipairs(current_session.available_commands) do
            table.insert(names, command.name)
        end

        return names
    end

    ---@param session_id? string
    function helper.pick_slash_command(session_id)
        local current_session = deps.resolve_session(session_id)
        ensure_slash_commands(current_session)

        if #current_session.available_commands == 0 then
            vim.notify('No ACP slash commands are available')
            return
        end

        local format_command = deps.formatters.slash_command_picker_formatter(current_session.available_commands)

        local function pick_command()
            vim.ui.select(current_session.available_commands, {
                prompt = 'Select ACP slash command',
                format_item = format_command,
            }, function(selected_command)
                if selected_command == nil then
                    return
                end

                if type(selected_command.input) ~= 'table' then
                    helper.run_slash_command(selected_command.name, nil, current_session.id)
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

                    helper.run_slash_command(selected_command.name, trimmed_input, current_session.id)
                end)
            end)
        end

        pick_command()
    end

    ---@param name string
    ---@param command_input? string
    ---@param session_id? string
    ---@return legate.Session
    function helper.run_slash_command(name, command_input, session_id)
        local current_session = deps.resolve_session(session_id)
        ensure_slash_commands(current_session)
        local command = slash_command_by_name(current_session, name)
        local prompt = deps.prompt_helper.slash_command_prompt(command, command_input)

        return deps.prompt_helper.submit_session_prompt(current_session, prompt)
    end

    return helper
end

return M
