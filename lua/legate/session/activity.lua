local M = {}

---@param deps { now: fun(): integer, approval_stream_key: fun(ordinal: integer): string, is_finished_tool_status: fun(status: legate.ToolCallStatus): boolean, append_message: fun(session: legate.Session, role: legate.MessageRole, text: string, opts?: table): legate.Message, append_chunk: fun(session: legate.Session, role: legate.MessageRole, text: string): legate.Message?, set_plan: fun(session: legate.Session, entries: legate.PlanEntry[]): nil, set_available_commands: fun(session: legate.Session, commands: legate.AvailableCommand[]): nil, set_config_options: fun(session: legate.Session, options: legate.SessionConfigOption[]): nil, status_message: legate.StatusMessageModule }
---@return table
function M.new(deps)
    local helper = {}

    ---@param current_session legate.Session
    ---@param tool_call_id string
    ---@return integer?, legate.ToolCallState?
    local function find_tool_call(current_session, tool_call_id)
        for index, tool_call in ipairs(current_session.tool_calls) do
            if tool_call.tool_call_id == tool_call_id then
                return index, tool_call
            end
        end

        return nil, nil
    end

    ---@param tool_call legate.ToolCallState
    ---@return table<string, legate.MetaTerminalStream>
    local function terminal_streams(tool_call)
        if type(tool_call.terminal_streams) ~= 'table' then
            tool_call.terminal_streams = {}
        end

        return tool_call.terminal_streams
    end

    ---@param tool_call legate.ToolCallState
    ---@param terminal_id string
    ---@return legate.MetaTerminalStream
    local function ensure_terminal_stream(tool_call, terminal_id)
        local streams = terminal_streams(tool_call)
        local stream = streams[terminal_id]

        if stream == nil then
            stream = {
                terminal_id = terminal_id,
                output = '',
            }
            streams[terminal_id] = stream
        end

        local has_terminal_content = false

        for _, content in ipairs(tool_call.content or {}) do
            if content.type == 'terminal' and content.terminalId == terminal_id then
                has_terminal_content = true
                break
            end
        end

        if not has_terminal_content then
            table.insert(tool_call.content, {
                type = 'terminal',
                terminalId = terminal_id,
            })
        end

        return stream
    end

    ---@param tool_call legate.ToolCallState
    ---@param meta table?
    local function apply_tool_call_meta(tool_call, meta)
        if type(meta) ~= 'table' then
            return
        end

        local terminal_info = type(meta.terminal_info) == 'table' and meta.terminal_info or nil
        if terminal_info ~= nil and type(terminal_info.terminal_id) == 'string' and terminal_info.terminal_id ~= '' then
            local stream = ensure_terminal_stream(tool_call, terminal_info.terminal_id)

            if type(terminal_info.cwd) == 'string' and terminal_info.cwd ~= '' then
                stream.cwd = terminal_info.cwd
            end
        end

        local terminal_output = type(meta.terminal_output) == 'table' and meta.terminal_output or nil
        if
            terminal_output ~= nil
            and type(terminal_output.terminal_id) == 'string'
            and terminal_output.terminal_id ~= ''
        then
            local stream = terminal_streams(tool_call)[terminal_output.terminal_id]

            if stream ~= nil and type(terminal_output.data) == 'string' then
                stream.output = stream.output .. terminal_output.data
            end
        end

        local terminal_exit = type(meta.terminal_exit) == 'table' and meta.terminal_exit or nil
        if terminal_exit ~= nil and type(terminal_exit.terminal_id) == 'string' and terminal_exit.terminal_id ~= '' then
            local stream = terminal_streams(tool_call)[terminal_exit.terminal_id]

            if stream ~= nil then
                stream.exit_code = tonumber(terminal_exit.exit_code)

                if terminal_exit.signal == vim.NIL then
                    stream.signal = nil
                elseif type(terminal_exit.signal) == 'string' then
                    stream.signal = terminal_exit.signal
                end
            end
        end
    end

    ---@param tool_call legate.ToolCallState
    ---@return string
    local function tool_stream_key(tool_call)
        return tool_call.stream_key
    end

    ---@param current_session legate.Session
    ---@param stream_kind 'tool_call'|'approval'
    ---@param stream_key string
    ---@return legate.Message?
    local function stream_status_message(current_session, stream_kind, stream_key)
        for _, message in ipairs(current_session.messages) do
            if message.role == 'status' and message.stream_kind == stream_kind and message.stream_key == stream_key then
                return message
            end
        end

        return nil
    end

    ---@param current_session legate.Session
    ---@param stream_kind 'tool_call'|'approval'
    ---@param stream_key string
    ---@param text string
    ---@param opts { status_state?: string, status_title?: string }
    local function upsert_status_message(current_session, stream_kind, stream_key, text, opts)
        local message = stream_status_message(current_session, stream_kind, stream_key)

        if message ~= nil then
            message.text = text
            message.status_state = opts.status_state
            message.status_title = opts.status_title
            current_session.updated_at = deps.now()
            return message
        end

        return deps.append_message(current_session, 'status', text, {
            stream_kind = stream_kind,
            stream_key = stream_key,
            status_state = opts.status_state,
            status_title = opts.status_title,
        })
    end

    ---@param current_session legate.Session
    ---@param tool_call legate.ToolCall
    ---@return legate.ToolCallState
    function helper.add_tool_call(current_session, tool_call)
        local _, existing = find_tool_call(current_session, tool_call.toolCallId)

        if existing ~= nil then
            return helper.update_tool_call(current_session, tool_call)
        end

        local next_tool_call = {
            tool_call_id = tool_call.toolCallId,
            stream_key = string.format('tool:%d:%s', current_session.turn_id, tool_call.toolCallId),
            title = tool_call.title,
            status = tool_call.status or 'pending',
            kind = tool_call.kind,
            locations = vim.deepcopy(tool_call.locations or {}),
            content = vim.deepcopy(tool_call.content or {}),
            raw_input = vim.deepcopy(tool_call.rawInput),
            raw_output = vim.deepcopy(tool_call.rawOutput),
        }

        apply_tool_call_meta(next_tool_call, tool_call._meta)

        table.insert(current_session.tool_calls, next_tool_call)
        current_session.updated_at = deps.now()
        upsert_status_message(
            current_session,
            'tool_call',
            tool_stream_key(next_tool_call),
            deps.status_message.tool_call_status_text(next_tool_call),
            {
                status_state = next_tool_call.status,
                status_title = next_tool_call.title,
            }
        )

        return next_tool_call
    end

    ---@param current_session legate.Session
    ---@param tool_call_update legate.ToolCallUpdate
    ---@return legate.ToolCallState
    function helper.update_tool_call(current_session, tool_call_update)
        local _, tool_call = find_tool_call(current_session, tool_call_update.toolCallId)

        if tool_call == nil then
            tool_call = {
                tool_call_id = tool_call_update.toolCallId,
                stream_key = string.format('tool:%d:%s', current_session.turn_id, tool_call_update.toolCallId),
                title = tool_call_update.title or tool_call_update.toolCallId,
                status = tool_call_update.status or 'pending',
                locations = {},
                content = {},
            }
            table.insert(current_session.tool_calls, tool_call)
        end

        if tool_call_update.title ~= nil then
            tool_call.title = tool_call_update.title
        end

        if tool_call_update.status ~= nil then
            tool_call.status = tool_call_update.status
        end

        if tool_call_update.kind ~= nil then
            tool_call.kind = tool_call_update.kind
        end

        if tool_call_update.locations ~= nil then
            tool_call.locations = vim.deepcopy(tool_call_update.locations)
        end

        if tool_call_update.content ~= nil then
            tool_call.content = vim.deepcopy(tool_call_update.content)
        end

        if tool_call_update.rawInput ~= nil then
            tool_call.raw_input = vim.deepcopy(tool_call_update.rawInput)
        end

        if tool_call_update.rawOutput ~= nil then
            tool_call.raw_output = vim.deepcopy(tool_call_update.rawOutput)
        end

        apply_tool_call_meta(tool_call, tool_call_update._meta)

        current_session.updated_at = deps.now()
        upsert_status_message(
            current_session,
            'tool_call',
            tool_stream_key(tool_call),
            deps.status_message.tool_call_status_text(tool_call),
            {
                status_state = tool_call.status,
                status_title = tool_call.title,
            }
        )

        return tool_call
    end

    ---@param current_session legate.Session
    ---@param tool_call_id string?
    ---@return legate.ToolCallState?
    function helper.tool_call_by_id(current_session, tool_call_id)
        if tool_call_id == nil then
            return nil
        end

        local _, tool_call = find_tool_call(current_session, tool_call_id)
        return tool_call
    end

    ---@param current_session legate.Session
    ---@param permission legate.PermissionRequest
    ---@param outcome legate.PermissionOutcome
    ---@param source legate.PermissionStrategy
    function helper.record_approval(current_session, permission, outcome, source)
        local matched_tool_call = helper.tool_call_by_id(current_session, permission.toolCall.toolCallId)
        local selected_kind = nil
        local selected_option_name = nil

        if outcome.outcome == 'selected' and outcome.optionId ~= nil then
            for _, option in ipairs(permission.options) do
                if option.optionId == outcome.optionId then
                    selected_kind = option.kind
                    selected_option_name = option.name
                    break
                end
            end
        end

        local approval = {
            ordinal = #current_session.approval_entries + 1,
            stream_key = deps.approval_stream_key(#current_session.approval_entries + 1),
            tool_call_id = permission.toolCall.toolCallId,
            title = permission.toolCall.title
                or (matched_tool_call and matched_tool_call.title)
                or permission.toolCall.toolCallId
                or 'Approval',
            outcome = outcome.outcome,
            source = source,
            selected_kind = selected_kind,
            selected_option_name = selected_option_name,
            selected_option_id = outcome.optionId,
            options = vim.deepcopy(permission.options),
        }

        table.insert(current_session.approval_entries, approval)
        for index, pending in ipairs(current_session.pending_approvals) do
            if pending.request_id == permission.request_id then
                table.remove(current_session.pending_approvals, index)
                break
            end
        end
        upsert_status_message(
            current_session,
            'approval',
            approval.stream_key,
            deps.status_message.approval_status_text(approval),
            {
                status_state = approval.selected_kind or approval.outcome,
                status_title = string.format('Approval [%d] %s', approval.ordinal, approval.title),
            }
        )
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param permission legate.PermissionRequest
    function helper.wait_for_approval(current_session, permission)
        local tool_call_id = permission.toolCall.toolCallId

        if tool_call_id ~= nil then
            helper.update_tool_call(current_session, {
                toolCallId = tool_call_id,
                title = permission.toolCall.title,
                status = 'waiting_for_approval',
            })
        end

        table.insert(current_session.pending_approvals, {
            request_id = permission.request_id,
            ordinal = deps.next_pending_approval_ordinal(),
            tool_call_id = tool_call_id,
            title = permission.toolCall.title or tool_call_id or 'Approval',
            options = vim.deepcopy(permission.options),
            generation = permission.generation,
            created_at = deps.now(),
        })
        deps.increment_pending_approval_ordinal()
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param update table
    function helper.apply_update(current_session, update)
        local kind = update.sessionUpdate

        if kind == 'agent_message_chunk' and update.content ~= nil and update.content.type == 'text' then
            deps.append_chunk(current_session, 'assistant', update.content.text)
            return
        end

        if kind == 'user_message_chunk' and update.content ~= nil and update.content.type == 'text' then
            deps.append_chunk(current_session, 'user', update.content.text)
            return
        end

        if kind == 'plan' then
            deps.set_plan(current_session, update.entries or {})
            return
        end

        if kind == 'available_commands_update' then
            deps.set_available_commands(current_session, update.availableCommands or {})
            return
        end

        if kind == 'config_option_update' then
            deps.set_config_options(current_session, update.configOptions or {})
            return
        end

        if kind == 'session_info_update' then
            current_session.updated_at = deps.now()
            return
        end

        if kind == 'tool_call' then
            helper.add_tool_call(current_session, update)
            return
        end

        if kind == 'tool_call_update' then
            helper.update_tool_call(current_session, update)
        end
    end

    ---@param current_session legate.Session
    ---@return legate.PendingApproval?
    function helper.pending_approval(current_session)
        return current_session.pending_approvals[1]
    end

    ---@param current_session legate.Session
    ---@return legate.PendingApproval[]
    function helper.pending_approvals(current_session)
        return current_session.pending_approvals
    end

    ---@param current_session legate.Session
    ---@param tool_call_id string?
    ---@return legate.PendingApproval?
    function helper.pending_approval_by_tool_call_id(current_session, tool_call_id)
        if tool_call_id == nil then
            return nil
        end

        for _, pending in ipairs(current_session.pending_approvals) do
            if pending.tool_call_id == tool_call_id then
                return pending
            end
        end

        return nil
    end

    ---@param current_session legate.Session
    ---@param request_id string
    ---@return legate.PendingApproval?
    function helper.clear_pending_approval_by_request_id(current_session, request_id)
        for index, pending in ipairs(current_session.pending_approvals or {}) do
            if pending.request_id == request_id then
                table.remove(current_session.pending_approvals, index)
                current_session.updated_at = deps.now()
                return pending
            end
        end

        return nil
    end

    ---@param current_session legate.Session
    ---@param request_id string
    ---@return legate.PendingApproval?
    function helper.promote_pending_approval_by_request_id(current_session, request_id)
        local pending = helper.clear_pending_approval_by_request_id(current_session, request_id)

        if pending == nil then
            return nil
        end

        table.insert(current_session.pending_approvals, 1, pending)
        current_session.updated_at = deps.now()
        return pending
    end

    ---@param current_session legate.Session
    ---@param tool_call_id string?
    ---@return legate.PendingApproval?
    function helper.clear_pending_approval(current_session, tool_call_id)
        local pending = helper.pending_approval_by_tool_call_id(current_session, tool_call_id)

        if pending == nil then
            return nil
        end

        return helper.clear_pending_approval_by_request_id(current_session, pending.request_id)
    end

    ---@param current_session legate.Session
    function helper.cancel(current_session)
        for _, tool_call in ipairs(current_session.tool_calls) do
            if not deps.is_finished_tool_status(tool_call.status) then
                tool_call.status = 'cancelled'
                upsert_status_message(
                    current_session,
                    'tool_call',
                    tool_stream_key(tool_call),
                    deps.status_message.tool_call_status_text(tool_call),
                    {
                        status_state = tool_call.status,
                        status_title = tool_call.title,
                    }
                )
            end
        end

        current_session.turn_id = current_session.turn_id + 1
        current_session.pending_prompt = nil
        current_session.pending_approvals = {}
        current_session.status = 'cancelled'
        current_session.updated_at = deps.now()

        return current_session
    end

    ---@param current_session legate.Session
    function helper.reconcile_status_messages(current_session)
        for _, tool_call in ipairs(current_session.tool_calls) do
            if tool_call.stream_key == nil or tool_call.stream_key == '' then
                tool_call.stream_key = string.format('tool:%d:%s', current_session.turn_id, tool_call.tool_call_id)
            end

            upsert_status_message(
                current_session,
                'tool_call',
                tool_stream_key(tool_call),
                deps.status_message.tool_call_status_text(tool_call),
                {
                    status_state = tool_call.status,
                    status_title = tool_call.title,
                }
            )
        end

        for _, approval in ipairs(current_session.approval_entries) do
            if approval.stream_key == nil or approval.stream_key == '' then
                approval.stream_key = deps.approval_stream_key(approval.ordinal)
            end

            upsert_status_message(
                current_session,
                'approval',
                approval.stream_key,
                deps.status_message.approval_status_text(approval),
                {
                    status_state = approval.selected_kind or approval.outcome,
                    status_title = string.format('Approval [%d] %s', approval.ordinal, approval.title),
                }
            )
        end
    end

    return helper
end

return M
