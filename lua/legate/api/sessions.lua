local M = {}

local LOAD_FAILED_RECOVERY_MESSAGE =
    'ACP session is in load_failed recovery state; retry `:LegateLoadSession` or create a fresh remote with `:LegateRebindSession`'

---@param deps { buffer: legate.BufferModule, config: legate.ConfigModule, continuity: legate.SessionModule, persistence: legate.PersistenceModule, prompt_helper: table, render: legate.RenderModule, transport: legate.TransportModule, pickers: table, formatters: table, active_session: fun(): legate.Session, resolve_session: fun(session_id?: string): legate.Session, assert_session_binding_change_allowed: fun(current_session: legate.Session, action: string), store_draft: fun(current_session?: legate.Session), open_chat: fun(): integer }
---@return table
function M.new(deps)
    local helper = {}

    ---@param current_session legate.Session
    ---@param prompt string
    local function rerender_selected_session(current_session, prompt)
        local selected_session = deps.continuity.current()

        if deps.buffer.get() ~= nil and selected_session ~= nil and selected_session.id == current_session.id then
            deps.render.render(current_session, prompt)
        end
    end

    ---@return legate.Session
    function helper.new_session()
        deps.store_draft(deps.continuity.current())

        local current_session = deps.continuity.create(deps.config.default_adapter_name())

        deps.render.render(current_session, current_session.draft_prompt)

        return current_session
    end

    ---@return legate.Session
    function helper.current_session()
        return deps.active_session()
    end

    ---@return legate.Session[]
    function helper.list_sessions()
        return deps.continuity.list()
    end

    ---@return string[]
    function helper.session_lines()
        local lines = {}

        for _, current_session in ipairs(deps.continuity.list()) do
            table.insert(lines, deps.formatters.session_line(current_session, deps.continuity.current()))
        end

        return lines
    end

    ---@param candidates legate.Session[]
    ---@return legate.Session?
    local function latest_session(candidates)
        local latest = nil

        for _, current_session in ipairs(candidates) do
            if
                latest == nil
                or (tonumber(current_session.updated_at) or 0) > (tonumber(latest.updated_at) or 0)
                or (
                    (tonumber(current_session.updated_at) or 0) == (tonumber(latest.updated_at) or 0)
                    and current_session.ordinal > latest.ordinal
                )
            then
                latest = current_session
            end
        end

        return latest
    end

    ---@return string[]
    function helper.adapter_names()
        return deps.config.adapter_names()
    end

    ---@param session_id? string
    ---@return string
    function helper.adapter_name(session_id)
        local current_session = session_id and deps.resolve_session(session_id) or deps.continuity.current()
        return deps.config.session_adapter_name(current_session)
    end

    ---@param session_id? string
    ---@return string[]
    function helper.adapter_lines(session_id)
        local current_session = session_id and deps.resolve_session(session_id) or deps.continuity.current()
        local current_adapter_name = deps.config.session_adapter_name(current_session)
        local lines = {}

        for _, adapter_name in ipairs(deps.config.adapter_names()) do
            local adapter = deps.config.adapter(adapter_name)
            local marker = adapter_name == current_adapter_name and '*' or ' '

            table.insert(
                lines,
                string.format(
                    '%s %s  title=%s  auth=%s  command=%s  overrides=%d',
                    marker,
                    adapter_name,
                    adapter.title or adapter_name,
                    adapter.auth_method or 'auto',
                    table.concat(adapter.command, ' '),
                    vim.tbl_count(adapter.config_option_overrides or {})
                )
            )
        end

        return lines
    end

    ---@return boolean, legate.SessionPersistencePayload|string
    function helper.save_sessions()
        deps.store_draft(deps.continuity.current())

        local payload = deps.continuity.snapshot()
        local ok, err = deps.persistence.save(payload)

        if not ok then
            vim.notify(string.format('Failed to save ACP sessions: %s', err), vim.log.levels.ERROR)
            return false, err
        end

        return true, payload
    end

    ---@param opts? { open_chat?: boolean }
    ---@return legate.Session[]
    function helper.restore_sessions(opts)
        local persisted_enabled = deps.config.get().persist_sessions
        local persisted = persisted_enabled and deps.persistence.load() or nil

        if persisted_enabled and persisted == nil then
            return {}
        end

        local restored = deps.continuity.restore(persisted)
        local current_session = deps.continuity.current()
        local should_open = opts ~= nil and opts.open_chat or false
        local has_buffer = deps.buffer.get() ~= nil

        if current_session ~= nil then
            if should_open and not has_buffer then
                deps.open_chat()
            elseif has_buffer then
                deps.render.render(current_session, current_session.draft_prompt)
                deps.buffer.reveal_in_placeholder(deps.buffer.get())
            end

            return restored
        end

        if should_open then
            if #restored > 0 or deps.config.get().auto_create_session then
                deps.open_chat()
            elseif not has_buffer then
                deps.buffer.open()
            end
        elseif has_buffer then
            deps.buffer.clear()
        end

        return restored
    end

    ---Restore/select/open the most recently updated local ACP session.
    ---@return legate.Session
    function helper.continue_last_session()
        local sessions = deps.continuity.list()

        if #sessions == 0 and deps.config.get().persist_sessions then
            helper.restore_sessions()
            sessions = deps.continuity.list()
        end

        local target = latest_session(sessions)
        deps.store_draft(deps.continuity.current())

        if target == nil then
            if deps.config.get().auto_create_session then
                deps.open_chat()
                return assert(deps.continuity.current())
            end

            error('No ACP session history exists')
        end

        target = deps.continuity.select(target.id)
        deps.render.render(target, target.draft_prompt)
        deps.open_chat()

        return target
    end

    function helper.clear_session_storage()
        deps.persistence.clear()
    end

    function helper.pick_session()
        deps.pickers.pick_session(
            deps.continuity.list(),
            deps.continuity.current(),
            'Select ACP session',
            function(selected_session)
                helper.select_session(selected_session.id)
            end
        )
    end

    ---@param adapter_name string
    ---@param session_id? string
    ---@return legate.Session
    function helper.select_adapter(adapter_name, session_id)
        local current_session = deps.resolve_session(session_id)
        deps.assert_session_binding_change_allowed(current_session, 'switch adapter for')
        deps.config.adapter(adapter_name)

        if current_session.adapter_name == adapter_name then
            return current_session
        end

        local prompt = deps.prompt_helper.visible_prompt(current_session)

        deps.continuity.set_adapter(current_session, adapter_name)
        deps.continuity.reset_adapter_runtime_state(current_session)
        deps.transport.clear()
        rerender_selected_session(current_session, prompt)

        return current_session
    end

    ---@param session_id? string
    function helper.pick_adapter(session_id)
        local current_session = deps.resolve_session(session_id)
        local adapter_names = deps.config.adapter_names()

        if #adapter_names == 0 then
            vim.notify('No ACP adapters are configured')
            return
        end

        vim.ui.select(adapter_names, {
            prompt = string.format('Select ACP adapter for %s', current_session.id),
            format_item = deps.formatters.adapter_picker_formatter(current_session),
        }, function(selected_adapter_name)
            if selected_adapter_name == nil then
                return
            end

            helper.select_adapter(selected_adapter_name, current_session.id)
        end)
    end

    ---@param session_id string
    ---@return legate.Session
    function helper.select_session(session_id)
        deps.store_draft(deps.continuity.current())

        local current_session = deps.continuity.select(session_id)

        deps.render.render(current_session, current_session.draft_prompt)

        return current_session
    end

    ---@param session_id? string
    ---@return legate.Session
    function helper.load_session(session_id)
        local current_session = deps.resolve_session(session_id)
        deps.assert_session_binding_change_allowed(current_session, 'load')
        local prompt = deps.prompt_helper.visible_prompt(current_session)
        local ok, err = pcall(deps.transport.load, current_session)

        rerender_selected_session(current_session, prompt)

        if not ok then
            if current_session.remote_sync_state == 'load_failed' then
                error(LOAD_FAILED_RECOVERY_MESSAGE, 0)
            end

            error(err, 0)
        end

        return current_session
    end

    ---@param session_id? string
    ---@return legate.Session
    function helper.rebind_session(session_id)
        local current_session = deps.resolve_session(session_id)
        deps.assert_session_binding_change_allowed(current_session, 'rebind')

        if current_session.remote_sync_state ~= 'load_failed' then
            error(string.format('ACP session is not in load_failed recovery state: %s', current_session.id))
        end

        local prompt = deps.prompt_helper.visible_prompt(current_session)
        local ok, err = pcall(deps.transport.rebind, current_session)

        if not ok then
            error(err, 0)
        end

        rerender_selected_session(current_session, prompt)

        return current_session
    end

    ---@param session_id? string
    ---@return legate.Session, legate.Session?
    function helper.close_session(session_id)
        local target_id = session_id

        if target_id == nil then
            local current_session = deps.continuity.current()

            if current_session == nil then
                error('No ACP session exists')
            end

            target_id = current_session.id
        end

        local closing_session =
            assert(deps.continuity.get(target_id), string.format('Unknown ACP session: %s', target_id))

        if closing_session.status == 'waiting' then
            error(string.format('Cannot close ACP session while a prompt turn is still running: %s', target_id))
        end

        local current_session = deps.continuity.current()
        local is_current = current_session ~= nil and current_session.id == target_id
        local had_buffer = deps.buffer.get() ~= nil

        if is_current then
            deps.store_draft(current_session)
        end

        local closed_session, next_session = deps.continuity.close(target_id)

        if is_current then
            if next_session == nil and deps.config.get().auto_create_session then
                next_session = deps.continuity.create()
            end

            if had_buffer and next_session ~= nil then
                deps.render.render(next_session, next_session.draft_prompt)
            elseif had_buffer then
                deps.buffer.clear()
            end
        end

        return closed_session, next_session
    end

    function helper.pick_close_session()
        local closable_sessions = vim.tbl_filter(function(current_session)
            return current_session.status ~= 'waiting'
        end, deps.continuity.list())

        if #closable_sessions == 0 then
            vim.notify('No closable ACP sessions exist')
            return
        end

        deps.pickers.pick_session(
            closable_sessions,
            deps.continuity.current(),
            'Close ACP session',
            function(selected_session)
                helper.close_session(selected_session.id)
            end
        )
    end

    return helper
end

return M
