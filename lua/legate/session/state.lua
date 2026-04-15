local M = {}

---@param deps { now: fun(): integer, normalize_available_commands: fun(available_commands: legate.AvailableCommand[]): legate.AvailableCommand[], next_message_id: fun(): integer, increment_message_id: fun(): nil }
---@return table
function M.new(deps)
    local helper = {}

    ---@param session legate.Session
    ---@param role legate.MessageRole
    ---@param text string
    ---@param opts? { stream_kind?: 'tool_call'|'approval', stream_key?: string, status_state?: string, status_title?: string }
    ---@return legate.Message
    function helper.append_message(session, role, text, opts)
        local message = {
            id = deps.next_message_id(),
            role = role,
            text = text,
            created_at = deps.now(),
            stream_kind = opts and opts.stream_kind or nil,
            stream_key = opts and opts.stream_key or nil,
            status_state = opts and opts.status_state or nil,
            status_title = opts and opts.status_title or nil,
        }

        deps.increment_message_id()
        table.insert(session.messages, message)
        session.updated_at = deps.now()

        return message
    end

    ---@param previous string
    ---@param next_chunk string
    ---@return boolean
    local function needs_chunk_spacing(previous, next_chunk)
        if previous == '' or next_chunk == '' then
            return false
        end

        local previous_last = previous:sub(-1)
        local next_first = next_chunk:sub(1, 1)

        if next_first:match('%s') or next_first:match('^[%]%)}%.,;:!?]$') then
            return false
        end

        return previous_last:match('[%.!?]') ~= nil
    end

    ---@param current_session legate.Session
    ---@param role legate.MessageRole
    ---@param text string
    ---@return legate.Message?
    function helper.append_chunk(current_session, role, text)
        if text == '' then
            return nil
        end

        local last = current_session.messages[#current_session.messages]

        if last ~= nil and last.role == role then
            local separator = needs_chunk_spacing(last.text, text) and ' ' or ''

            last.text = last.text .. separator .. text
            current_session.updated_at = deps.now()
            return last
        end

        return helper.append_message(current_session, role, text)
    end

    ---@param current_session legate.Session
    ---@param prompt string
    function helper.set_draft_prompt(current_session, prompt)
        current_session.draft_prompt = prompt
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param prompt string
    ---@return legate.Session
    function helper.begin_prompt(current_session, prompt)
        current_session.turn_id = current_session.turn_id + 1
        current_session.pending_prompt = prompt
        current_session.draft_prompt = ''
        current_session.stop_reason = nil
        current_session.plan_entries = {}
        current_session.status = 'waiting'
        helper.append_message(current_session, 'user', prompt)

        return current_session
    end

    ---@param current_session legate.Session
    ---@return integer
    function helper.current_turn_id(current_session)
        return current_session.turn_id
    end

    ---@param current_session legate.Session
    ---@param turn_id integer
    ---@return boolean
    function helper.matches_turn(current_session, turn_id)
        return current_session.turn_id == turn_id
    end

    ---@param current_session legate.Session
    ---@param stop_reason legate.StopReason
    function helper.finish_prompt(current_session, stop_reason)
        current_session.pending_prompt = nil
        current_session.pending_approvals = {}
        current_session.stop_reason = stop_reason
        current_session.status = stop_reason == 'cancelled' and 'cancelled' or 'idle'
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param remote_id string?
    ---@param remote_sync_state? legate.RemoteSyncState
    ---@param remote_sync_error? string
    function helper.set_remote_id(current_session, remote_id, remote_sync_state, remote_sync_error)
        current_session.remote_id = remote_id
        current_session.transport_remote_id = remote_id
        current_session.remote_sync_state = remote_sync_state or current_session.remote_sync_state
        current_session.remote_sync_error = remote_sync_error
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param remote_id string?
    ---@param remote_sync_state? legate.RemoteSyncState
    ---@param remote_sync_error? string
    function helper.set_transport_remote_id(current_session, remote_id, remote_sync_state, remote_sync_error)
        current_session.transport_remote_id = remote_id
        current_session.remote_sync_state = remote_sync_state or current_session.remote_sync_state
        current_session.remote_sync_error = remote_sync_error
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param remote_sync_state? legate.RemoteSyncState
    ---@param remote_sync_error? string
    function helper.clear_remote_id(current_session, remote_sync_state, remote_sync_error)
        current_session.remote_id = nil
        current_session.transport_remote_id = nil
        current_session.remote_sync_state = remote_sync_state or 'unbound'
        current_session.remote_sync_error = remote_sync_error
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@return string?
    function helper.transport_remote_id(current_session)
        return current_session.transport_remote_id
    end

    ---@param current_session legate.Session
    ---@param cwd string?
    function helper.set_cwd(current_session, cwd)
        current_session.cwd = cwd
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param remote_sync_state legate.RemoteSyncState
    ---@param remote_sync_error? string
    function helper.set_remote_sync_state(current_session, remote_sync_state, remote_sync_error)
        current_session.remote_sync_state = remote_sync_state
        current_session.remote_sync_error = remote_sync_error
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param agent_info? legate.AgentInfo
    function helper.set_agent_info(current_session, agent_info)
        current_session.agent_info = agent_info
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param config_options legate.SessionConfigOption[]
    function helper.set_config_options(current_session, config_options)
        current_session.config_options = config_options
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param entries legate.PlanEntry[]
    function helper.set_plan(current_session, entries)
        current_session.plan_entries = vim.deepcopy(entries)
        current_session.updated_at = deps.now()
    end

    ---@param current_session legate.Session
    ---@param available_commands legate.AvailableCommand[]
    function helper.set_available_commands(current_session, available_commands)
        current_session.available_commands = deps.normalize_available_commands(available_commands)
        current_session.updated_at = deps.now()
    end

    return helper
end

return M
