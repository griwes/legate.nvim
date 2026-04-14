---@class legate.CommandModule
local M = {}
local initialized = false
local config_option = require('legate.config.option')

---@return legate.Api
local function api()
    return require('legate.api')
end

---@return string[]
local function session_ids()
    local ids = {}

    for _, current_session in ipairs(api().list_sessions()) do
        table.insert(ids, current_session.id)
    end

    return ids
end

---@return string[]
local function slash_command_names()
    local ok, names = pcall(function()
        return api().slash_command_names()
    end)

    if not ok then
        return {}
    end

    return names
end

---@return legate.AvailableCommand[]
local function slash_commands()
    local ok, commands = pcall(function()
        return api().slash_commands()
    end)

    if not ok then
        return {}
    end

    return commands
end

---@param command legate.AvailableCommand
---@return string[]
local function slash_command_input_completions(command)
    if type(command.input) ~= 'table' then
        return {}
    end

    local completions = {}

    if type(command.input.hint) == 'string' and command.input.hint ~= '' then
        table.insert(completions, command.input.hint)
    end

    return completions
end

---@return string[]
local function approval_ordinals()
    local ok, approvals = pcall(function()
        return api().approvals()
    end)

    if not ok then
        return {}
    end

    if #approvals == 0 then
        return {}
    end

    return vim.tbl_map(function(approval)
        return tostring(approval.ordinal)
    end, approvals)
end

---@return string[]
local function pending_approval_option_selections()
    local ok, pending_approvals = pcall(function()
        return api().pending_approvals()
    end)

    if not ok or #pending_approvals == 0 then
        return {}
    end

    local ids = {}
    local approval = pending_approvals[1]

    if approval ~= nil then
        for _, option in ipairs(approval.options or {}) do
            if type(option.optionId) == 'string' then
                table.insert(ids, option.optionId)
            end
        end
    end

    return ids
end

---@return string[]
local function pending_approval_option_selections_with_request()
    local ok, pending_approvals = pcall(function()
        return api().pending_approvals()
    end)

    if not ok or #pending_approvals == 0 then
        return {}
    end

    if #pending_approvals == 1 then
        return pending_approval_option_selections()
    end

    local ids = {}

    for _, approval in ipairs(pending_approvals) do
        for _, option in ipairs(approval.options or {}) do
            if type(option.optionId) == 'string' then
                table.insert(ids, string.format('%s:%s', approval.request_id, option.optionId))
            end
        end
    end

    return ids
end

---@param session_id? string
---@return string[]
local function config_option_ids(session_id)
    local ids = {}

    for _, option in ipairs(api().config_options(session_id)) do
        table.insert(ids, option.id)
    end

    return ids
end

---@return string[]
local function adapter_names()
    local ok, names = pcall(function()
        return api().adapter_names()
    end)

    if not ok then
        return {}
    end

    return names
end

---@param cmdline string
---@return string[]
local function command_args(cmdline)
    local stripped = cmdline:gsub('^:?%S+%s*', '', 1)
    local args = vim.split(vim.trim(stripped), '%s+', {
        trimempty = true,
    })

    if cmdline:sub(-1):match('%s') then
        table.insert(args, '')
    end

    return args
end

---@return string[]
---@param command string
---@param rhs fun()
---@param opts? vim.api.keyset.create_user_command
local function create(command, rhs, opts)
    if vim.api.nvim_get_commands({
        builtin = false,
    })[command] ~= nil then
        pcall(vim.api.nvim_del_user_command, command)
    end

    vim.api.nvim_create_user_command(command, rhs, opts or {})
end

---@param server table
---@return table
local function mcp_server_for_display(server)
    local display = vim.deepcopy(server)

    if server.type == 'stdio' then
        display.command = server.command or vim.NIL
        display.args = server.args or {}

        if server.env == nil then
            display.env = vim.NIL
        elseif vim.islist(server.env) then
            display.env = vim.tbl_map(function(variable)
                return { name = variable.name, value = '<redacted>' }
            end, server.env)
        else
            display.env = {}

            for name, _ in pairs(server.env) do
                table.insert(display.env, { name = name, value = '<redacted>' })
            end

            table.sort(display.env, function(left, right)
                return left.name < right.name
            end)
        end
    end

    return display
end

---Register ACP user commands.
function M.ensure()
    if initialized then
        return
    end

    create('LegateChat', function()
        api().open_chat()
    end, {
        desc = 'Open the Legate chat buffer',
    })

    create('LegateNewSession', function()
        api().new_session()
    end, {
        desc = 'Create a new Legate session',
    })

    create('LegateLoadSession', function(opts)
        local args = vim.trim(opts.args)
        api().load_session(args ~= '' and args or nil)
    end, {
        desc = 'Bind or reload a Legate session',
        nargs = '?',
        complete = function()
            return session_ids()
        end,
    })

    create('LegateRebindSession', function(opts)
        local args = vim.trim(opts.args)
        api().rebind_session(args ~= '' and args or nil)
    end, {
        desc = 'Recover a load_failed Legate session with a fresh remote binding',
        nargs = '?',
        complete = function()
            return session_ids()
        end,
    })

    create('LegateSubmit', function()
        api().submit_prompt()
    end, {
        desc = 'Submit the Legate prompt from the chat buffer',
    })

    create('LegateCancel', function()
        api().cancel_prompt()
    end, {
        desc = 'Cancel the active Legate prompt turn',
    })

    create('LegateSessions', function()
        local lines = api().session_lines()

        if #lines == 0 then
            vim.notify('No Legate sessions exist')
            return
        end

        vim.notify(table.concat(lines, '\n'))
    end, {
        desc = 'List local Legate sessions',
    })

    create('LegateSaveSessions', function()
        api().save_sessions()
    end, {
        desc = 'Persist local Legate sessions to disk',
    })

    create('LegateRestoreSessions', function()
        api().restore_sessions({
            open_chat = true,
        })
    end, {
        desc = 'Restore local Legate sessions from disk',
    })

    create('LegateClearSessionStorage', function()
        api().clear_session_storage()
    end, {
        desc = 'Clear persisted Legate session storage',
    })

    create('LegateApprovals', function()
        local lines = api().approval_lines()

        if #lines == 0 then
            vim.notify('No Legate approvals are available')
            return
        end

        vim.notify(table.concat(lines, '\n'))
    end, {
        desc = 'List Legate approval history',
    })

    create('LegateSelectApprovalOption', function(opts)
        local selection = vim.trim(opts.args)

        if selection == '' then
            error('LegateSelectApprovalOption expects an approval option index or id')
        end

        api().select_approval_option(selection)
    end, {
        desc = 'Resolve the current inline Legate approval by index or requestId:optionId; bare option ids are still accepted for a single pending approval',
        nargs = 1,
        complete = function()
            return pending_approval_option_selections_with_request()
        end,
    })

    create('LegateConfigOptions', function()
        local lines = api().config_option_lines()

        if #lines == 0 then
            vim.notify('No Legate config options are available')
            return
        end

        vim.notify(table.concat(lines, '\n'))
    end, {
        desc = 'List Legate session config options',
    })

    create('LegateSlashCommands', function()
        local lines = api().slash_command_lines()

        if #lines == 0 then
            vim.notify('No Legate slash commands are available')
            return
        end

        vim.notify(table.concat(lines, '\n'))
    end, {
        desc = 'List Legate slash commands',
    })

    create('LegateMcpServers', function()
        local servers = api().effective_mcp_servers()

        if #servers == 0 then
            vim.notify('No Legate MCP servers are configured')
            return
        end

        local lines = { 'Legate MCP servers:' }

        for _, server in ipairs(servers) do
            table.insert(lines, string.format('- %s', server.name or '<unnamed>'))
            vim.list_extend(lines, vim.split(vim.inspect(mcp_server_for_display(server)), '\n', { plain = true }))
        end

        vim.notify(table.concat(lines, '\n'))
    end, {
        desc = 'List effective Legate MCP servers',
    })

    create('LegateRevealApproval', function(opts)
        local ordinal = tonumber(vim.trim(opts.args))

        if ordinal == nil then
            error('LegateRevealApproval expects a numeric approval ordinal')
        end

        api().reveal_approval(ordinal)
    end, {
        desc = 'Reveal a Legate approval in the chat buffer',
        nargs = 1,
        complete = function()
            return approval_ordinals()
        end,
    })

    create('LegatePickApproval', function()
        api().pick_approval()
    end, {
        desc = 'Reveal a Legate approval through the UI picker',
    })

    create('LegateSelectSession', function(opts)
        api().select_session(vim.trim(opts.args))
    end, {
        desc = 'Select a local Legate session',
        nargs = 1,
        complete = function()
            return session_ids()
        end,
    })

    create('LegatePickSession', function()
        api().pick_session()
    end, {
        desc = 'Select a local Legate session through the UI picker',
    })

    create('LegateAdapters', function()
        local lines = api().adapter_lines()

        if #lines == 0 then
            vim.notify('No Legate adapters are configured')
            return
        end

        vim.notify(table.concat(lines, '\n'))
    end, {
        desc = 'List configured Legate adapters',
    })

    create('LegateSelectAdapter', function(opts)
        api().select_adapter(vim.trim(opts.args))
    end, {
        desc = 'Select the Legate adapter for the current session',
        nargs = 1,
        complete = function()
            return adapter_names()
        end,
    })

    create('LegatePickAdapter', function()
        api().pick_adapter()
    end, {
        desc = 'Select the Legate adapter for the current session through the UI picker',
    })

    create('LegateSetConfigOption', function(opts)
        if #opts.fargs ~= 2 then
            error('LegateSetConfigOption expects exactly 2 arguments: <config-id> <value>')
        end

        api().set_config_option(opts.fargs[1], opts.fargs[2])
    end, {
        desc = 'Set a Legate session config option',
        nargs = '+',
        complete = function(arglead, cmdline)
            local current_session = api().current_session()

            if current_session == nil then
                return {}
            end

            local args = command_args(cmdline)

            if #args <= 1 then
                return vim.tbl_filter(function(option_id)
                    return vim.startswith(option_id, arglead)
                end, config_option_ids(current_session.id))
            end

            local option_id = args[1]
            local option = nil

            for _, current_option in ipairs(api().config_options(current_session.id)) do
                if current_option.id == option_id then
                    option = current_option
                    break
                end
            end

            if option == nil then
                return {}
            end

            local values = {}

            for _, choice in ipairs(config_option.choices(option)) do
                if vim.startswith(choice.value.value, arglead) then
                    table.insert(values, choice.value.value)
                end
            end

            return values
        end,
    })

    create('LegatePickConfigOption', function()
        api().pick_config_option()
    end, {
        desc = 'Set a Legate session config option through the UI picker',
    })

    create('LegateRunSlashCommand', function(opts)
        local name = opts.fargs[1]

        if name == nil or name == '' then
            error('ACP slash command name is required')
        end

        local command_input = nil

        if #opts.fargs > 1 then
            command_input = table.concat(vim.list_slice(opts.fargs, 2), ' ')
        end

        api().run_slash_command(name, command_input)
    end, {
        desc = 'Run a Legate slash command',
        nargs = '*',
        complete = function(arglead, cmdline)
            local args = command_args(cmdline)
            local command_name = args[1]
            local command = nil

            if command_name ~= nil then
                for _, current_command in ipairs(slash_commands()) do
                    if current_command.name == command_name then
                        command = current_command
                        break
                    end
                end
            end

            if #args <= 1 or command == nil then
                return vim.tbl_filter(function(name)
                    return vim.startswith(name, arglead)
                end, slash_command_names())
            end

            return vim.tbl_filter(function(item)
                return vim.startswith(item, arglead)
            end, slash_command_input_completions(command))
        end,
    })

    create('LegatePickSlashCommand', function()
        api().pick_slash_command()
    end, {
        desc = 'Run a Legate slash command through the UI picker',
    })

    create('LegateCloseSession', function(opts)
        local args = vim.trim(opts.args)
        api().close_session(args ~= '' and args or nil)
    end, {
        desc = 'Close a local Legate session',
        nargs = '?',
        complete = function()
            return session_ids()
        end,
    })

    create('LegatePickCloseSession', function()
        api().pick_close_session()
    end, {
        desc = 'Close a local Legate session through the UI picker',
    })

    initialized = true
end

return M
