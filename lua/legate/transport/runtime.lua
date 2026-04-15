local M = {}

---@param deps { buffer: legate.BufferModule, continuity: legate.SessionModule, input: legate.InputModule, render: legate.RenderModule, state: legate.TransportState }
---@return table
function M.new(deps)
    local helper = {}

    function helper.cancelled_response()
        return {
            outcome = {
                outcome = 'cancelled',
            },
        }
    end

    function helper.inactive_request_error()
        return {
            code = -32000,
            message = 'ACP request is no longer active',
        }
    end

    ---@param current_session legate.Session
    ---@param update table
    ---@return boolean
    function helper.should_apply_update(current_session, update)
        if current_session.status == 'idle' or current_session.status == 'waiting' then
            return true
        end

        return current_session.status == 'cancelled'
            and (
                update.sessionUpdate == 'tool_call'
                or update.sessionUpdate == 'tool_call_update'
                or update.sessionUpdate == 'config_option_update'
                or update.sessionUpdate == 'available_commands_update'
            )
    end

    ---@param params { sessionId?: string }
    ---@return legate.Session?
    function helper.active_request_session(params)
        if deps.state.loading_existing_session then
            return nil
        end

        local session_id = params.sessionId
        local current_session = deps.state.active_session
        local current_transport_remote_id = current_session ~= nil
                and deps.continuity.transport_remote_id(current_session)
            or nil

        if
            current_session ~= nil
            and current_session.status == 'waiting'
            and (
                (session_id == nil)
                or (current_transport_remote_id ~= nil and current_transport_remote_id == session_id)
            )
        then
            return current_session
        end

        local waiting_session = deps.continuity.waiting()
        local waiting_transport_remote_id = waiting_session ~= nil
                and deps.continuity.transport_remote_id(waiting_session)
            or nil

        if
            waiting_session ~= nil
            and waiting_session.status == 'waiting'
            and (
                (session_id == nil)
                or (waiting_transport_remote_id ~= nil and waiting_transport_remote_id == session_id)
            )
        then
            return waiting_session
        end

        return nil
    end

    ---@return string
    local function prompt_snapshot()
        local bufnr = deps.buffer.get()

        if bufnr == nil then
            return ''
        end

        return deps.input.capture_prompt(bufnr) or ''
    end

    ---@param current_session legate.Session
    local function perform_rerender(current_session)
        local selected_session = deps.continuity.current()

        if selected_session == nil or selected_session.id ~= current_session.id or deps.buffer.get() == nil then
            return
        end

        deps.render.render(current_session, prompt_snapshot())
    end

    ---@param current_session legate.Session
    function helper.rerender(current_session)
        if vim.in_fast_event() then
            vim.schedule(function()
                perform_rerender(current_session)
            end)
            return
        end

        perform_rerender(current_session)
    end

    ---@param current_session legate.Session
    function helper.reveal_inline_approval(current_session)
        if vim.in_fast_event() then
            vim.schedule(function()
                helper.reveal_inline_approval(current_session)
            end)
            return
        end

        local bufnr = deps.buffer.get()

        if bufnr == nil then
            vim.notify(string.format('Legate approval pending in %s', current_session.id))
            return
        end

        local selected_session = deps.continuity.current()

        if selected_session ~= nil and selected_session.id ~= current_session.id then
            local prompt = deps.input.capture_prompt(bufnr)

            if prompt ~= nil then
                deps.continuity.set_draft_prompt(selected_session, prompt)
            end

            deps.continuity.select(current_session.id)
            deps.render.render(current_session, current_session.draft_prompt or '')
            return
        end

        helper.rerender(current_session)
    end

    ---@param current_session? legate.Session
    function helper.cancel_pending_permission(current_session)
        local pending_permissions = deps.state.pending_permissions or {}

        if #pending_permissions == 0 then
            return
        end

        local retained = {}

        for _, pending_permission in ipairs(pending_permissions) do
            if current_session ~= nil and pending_permission.local_session_id ~= current_session.id then
                table.insert(retained, pending_permission)
            else
                local pending_session = deps.continuity.get(pending_permission.local_session_id)

                if pending_session ~= nil then
                    local remaining = {}

                    for _, pending in ipairs(pending_session.pending_approvals or {}) do
                        if pending.request_id ~= pending_permission.request_id then
                            table.insert(remaining, pending)
                        end
                    end

                    pending_session.pending_approvals = remaining
                end

                pending_permission.respond(helper.cancelled_response())
            end
        end

        deps.state.pending_permissions = retained
    end

    ---@param current_session legate.Session
    ---@param update table
    function helper.apply_update(current_session, update)
        deps.continuity.apply_update(current_session, update)
        helper.rerender(current_session)
    end

    ---@param session_id string
    ---@param update table
    function helper.queue_session_update(session_id, update)
        local pending_updates = deps.state.pending_session_updates[session_id]

        if pending_updates == nil then
            pending_updates = {}
            deps.state.pending_session_updates[session_id] = pending_updates
        end

        table.insert(pending_updates, vim.deepcopy(update))
    end

    ---@param current_session legate.Session
    ---@param session_id string
    function helper.drain_session_updates(current_session, session_id)
        local pending_updates = deps.state.pending_session_updates[session_id]

        if pending_updates == nil then
            return
        end

        deps.state.pending_session_updates[session_id] = nil

        for _, update in ipairs(pending_updates) do
            if helper.should_apply_update(current_session, update) then
                helper.apply_update(current_session, update)
            end
        end
    end

    ---@param current_session legate.Session
    ---@param stop_reason legate.StopReason
    function helper.finish_turn(current_session, stop_reason)
        deps.continuity.finish_prompt(current_session, stop_reason)
        helper.rerender(current_session)
    end

    return helper
end

return M
