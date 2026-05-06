local M = {}

---@param deps { buffer: legate.BufferModule, continuity: legate.SessionModule, formatters: table, prompt_helper: table, render: legate.RenderModule, resolve_pending_approval_session: fun(session_id?: string): legate.Session, resolve_session: fun(session_id?: string): legate.Session, select_session: fun(session_id: string): legate.Session, transport: legate.TransportModule }
---@return table
function M.new(deps)
    local helper = {}

    ---@param current_session legate.Session
    ---@param approval_ordinal integer
    ---@return legate.ApprovalEntry
    local function approval_by_ordinal(current_session, approval_ordinal)
        for _, approval in ipairs(current_session.approval_entries) do
            if approval.ordinal == approval_ordinal then
                return approval
            end
        end

        error(string.format('Unknown ACP approval: %d', approval_ordinal))
    end

    ---@param session_id? string
    ---@return legate.ApprovalEntry[]
    function helper.approvals(session_id)
        local current_session = session_id and deps.continuity.get(session_id) or deps.continuity.current()

        if current_session == nil then
            return {}
        end

        return vim.deepcopy(current_session.approval_entries)
    end

    ---@param session_id? string
    ---@return legate.PendingApproval?
    function helper.pending_approval(session_id)
        local current_session = deps.resolve_pending_approval_session(session_id)
        return vim.deepcopy(deps.continuity.pending_approval(current_session))
    end

    ---@param session_id? string
    ---@return legate.PendingApproval[]
    function helper.pending_approvals(session_id)
        local current_session = deps.resolve_pending_approval_session(session_id)
        return vim.deepcopy(deps.continuity.pending_approvals(current_session))
    end

    ---@param session_id? string
    ---@return string[]
    function helper.approval_lines(session_id)
        local lines = {}

        for _, approval in ipairs(helper.approvals(session_id)) do
            table.insert(lines, deps.formatters.approval_line(approval))
        end

        return lines
    end

    ---@param approval_ordinal integer
    ---@param session_id? string
    ---@return legate.ApprovalEntry
    function helper.reveal_approval(approval_ordinal, session_id)
        local current_session = deps.resolve_session(session_id)
        local approval = approval_by_ordinal(current_session, approval_ordinal)
        local selected_session = deps.continuity.current()

        if selected_session == nil or selected_session.id ~= current_session.id then
            current_session = deps.select_session(current_session.id)
        else
            deps.render.render(current_session, deps.prompt_helper.visible_prompt(current_session))
        end

        local bufnr = deps.buffer.open()
        local target_line = deps.render.approval_summary_line(approval, current_session)
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

    ---@param session_id? string
    function helper.pick_approval(session_id)
        local current_session = deps.resolve_session(session_id)

        if #current_session.approval_entries == 0 then
            vim.notify('No Legate approvals are available')
            return
        end

        vim.ui.select(current_session.approval_entries, {
            prompt = 'Select Legate approval',
            format_item = deps.formatters.approval_line,
        }, function(selected_approval)
            if selected_approval == nil then
                return
            end

            helper.reveal_approval(selected_approval.ordinal, current_session.id)
        end)
    end

    ---@param session_id? string
    ---@return integer
    function helper.clear_pending_approvals(session_id)
        local current_session = session_id ~= nil and deps.resolve_session(session_id) or nil
        return deps.transport.cancel_pending_approvals(current_session)
    end

    ---@param selection string|integer
    ---@param session_id? string
    ---@return legate.PermissionOutcome
    function helper.select_approval_option(selection, session_id)
        local current_session = deps.resolve_pending_approval_session(session_id)

        if type(selection) == 'string' then
            local request_id, option_id = selection:match('^(.-):([^:]+)$')

            if request_id ~= nil and option_id ~= nil then
                local pending = deps.continuity.pending_approval(current_session)

                if pending == nil or pending.request_id ~= request_id then
                    for _, candidate in ipairs(deps.continuity.pending_approvals(current_session)) do
                        if candidate.request_id == request_id then
                            pending = candidate
                            break
                        end
                    end
                end

                if pending ~= nil and pending.request_id == request_id then
                    selection = option_id

                    if deps.continuity.pending_approval(current_session) ~= pending then
                        pending = deps.continuity.promote_pending_approval_by_request_id(
                            current_session,
                            pending.request_id
                        ) or pending
                    end
                end
            end
        end

        return deps.transport.select_pending_approval(current_session, selection)
    end

    return helper
end

return M
