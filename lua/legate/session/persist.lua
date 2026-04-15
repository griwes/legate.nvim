local M = {}

---@param deps { resolved_adapter_name: fun(adapter_name?: string): string, now: fun(): integer, approval_stream_key: fun(ordinal: integer): string, is_finished_tool_status: fun(status: legate.ToolCallStatus): boolean }
---@return table
function M.new(deps)
    local helper = {}

    ---@param status any
    ---@return legate.SessionStatus
    local function normalize_status(status)
        if status == 'idle' or status == 'waiting' or status == 'cancelled' then
            return status
        end

        return 'idle'
    end

    ---@param sync_state any
    ---@param remote_id string?
    ---@return legate.RemoteSyncState
    local function normalize_remote_sync_state(sync_state, remote_id)
        if
            sync_state == 'unbound'
            or sync_state == 'created'
            or sync_state == 'loaded'
            or sync_state == 'load_failed'
        then
            return sync_state
        end

        if remote_id ~= nil then
            return 'created'
        end

        return 'unbound'
    end

    ---@param input any
    ---@return table?
    local function normalize_command_input(input)
        if type(input) ~= 'table' then
            return nil
        end

        return vim.deepcopy(input)
    end

    ---@param available_commands any
    ---@return legate.AvailableCommand[]
    local function normalize_available_commands(available_commands)
        if type(available_commands) ~= 'table' then
            return {}
        end

        local normalized = {}

        for _, command in ipairs(available_commands) do
            if type(command) == 'table' then
                local next_command = vim.deepcopy(command)

                next_command.input = normalize_command_input(next_command.input)
                table.insert(normalized, next_command)
            end
        end

        return normalized
    end

    helper.normalize_available_commands = normalize_available_commands

    ---@param entry table
    ---@return legate.ApprovalEntry?
    local function normalize_approval_entry(entry)
        if type(entry) ~= 'table' then
            return nil
        end

        local source = entry.source == 'select' and 'select' or 'default'
        local outcome = entry.outcome == 'selected' and 'selected' or 'cancelled'
        local title = type(entry.title) == 'string' and entry.title or 'Approval'
        local ordinal = math.max(tonumber(entry.ordinal) or 0, 0)

        return {
            ordinal = ordinal,
            stream_key = type(entry.stream_key) == 'string' and entry.stream_key or '',
            tool_call_id = type(entry.tool_call_id) == 'string' and entry.tool_call_id or nil,
            title = title,
            outcome = outcome,
            source = source,
            selected_kind = entry.selected_kind,
            selected_option_name = type(entry.selected_option_name) == 'string' and entry.selected_option_name or nil,
            selected_option_id = type(entry.selected_option_id) == 'string' and entry.selected_option_id or nil,
            options = type(entry.options) == 'table' and vim.deepcopy(entry.options) or {},
        }
    end

    ---@param entries any
    ---@return legate.ApprovalEntry[]
    local function normalize_approval_entries(entries)
        if type(entries) ~= 'table' then
            return {}
        end

        local normalized = {}

        for _, entry in ipairs(entries) do
            local approval = normalize_approval_entry(entry)

            if approval ~= nil then
                table.insert(normalized, approval)
            end
        end

        table.sort(normalized, function(left, right)
            if left.ordinal == right.ordinal then
                return left.title < right.title
            end

            return left.ordinal < right.ordinal
        end)

        for index, approval in ipairs(normalized) do
            approval.ordinal = index
            approval.stream_key = deps.approval_stream_key(index)
        end

        return normalized
    end

    ---@param pending any
    ---@return legate.PendingApproval?
    local function normalize_pending_approval(pending)
        if type(pending) ~= 'table' then
            return nil
        end

        local request_id = type(pending.request_id) == 'string' and pending.request_id or nil

        if request_id == nil then
            return nil
        end

        return {
            request_id = request_id,
            ordinal = math.max(tonumber(pending.ordinal) or 0, 0),
            tool_call_id = type(pending.tool_call_id) == 'string' and pending.tool_call_id or nil,
            title = type(pending.title) == 'string' and pending.title or 'Approval',
            options = type(pending.options) == 'table' and vim.deepcopy(pending.options) or {},
            generation = math.max(tonumber(pending.generation) or 0, 0),
            created_at = tonumber(pending.created_at) or deps.now(),
        }
    end

    ---@param pending_approvals any
    ---@param approval_entries legate.ApprovalEntry[]
    ---@return legate.PendingApproval[]
    local function normalize_pending_approvals(pending_approvals, approval_entries)
        if type(pending_approvals) ~= 'table' then
            return {}
        end

        local normalized = {}
        local next_ordinal = #approval_entries

        for _, pending in ipairs(pending_approvals) do
            local item = normalize_pending_approval(pending)

            if item ~= nil then
                table.insert(normalized, item)
            end
        end

        table.sort(normalized, function(left, right)
            if left.ordinal == right.ordinal then
                if left.created_at == right.created_at then
                    return left.request_id < right.request_id
                end

                return left.created_at < right.created_at
            end

            return left.ordinal < right.ordinal
        end)

        for _, item in ipairs(normalized) do
            next_ordinal = next_ordinal + 1
            item.ordinal = next_ordinal
        end

        return normalized
    end

    ---@param current_session legate.Session
    ---@return legate.Session
    function helper.persisted_session(current_session)
        local snapshot = vim.deepcopy(current_session)

        if snapshot.pending_prompt ~= nil and snapshot.pending_prompt ~= '' and snapshot.draft_prompt == '' then
            snapshot.draft_prompt = snapshot.pending_prompt
        end

        snapshot.transport_remote_id = nil
        snapshot.pending_prompt = nil
        snapshot.pending_approvals = {}

        if snapshot.status == 'waiting' then
            snapshot.status = 'cancelled'
            snapshot.stop_reason = 'cancelled'

            for _, tool_call in ipairs(snapshot.tool_calls) do
                if not deps.is_finished_tool_status(tool_call.status) then
                    tool_call.status = 'cancelled'
                end
            end
        end

        return snapshot
    end

    ---@param item table
    ---@return legate.Session?
    function helper.restore_session(item)
        local session_id = type(item.id) == 'string' and item.id or nil

        if session_id == nil then
            return nil
        end

        local restored = vim.deepcopy(item)

        restored.id = session_id
        restored.ordinal = tonumber(restored.ordinal) or 1
        restored.adapter_name = deps.resolved_adapter_name(restored.adapter_name)
        restored.status = normalize_status(restored.status)
        restored.messages = type(restored.messages) == 'table' and restored.messages or {}
        restored.draft_prompt = type(restored.draft_prompt) == 'string' and restored.draft_prompt or ''

        if
            type(restored.pending_prompt) == 'string'
            and restored.pending_prompt ~= ''
            and restored.draft_prompt == ''
        then
            restored.draft_prompt = restored.pending_prompt
        end

        restored.pending_prompt = nil
        restored.remote_id = type(restored.remote_id) == 'string' and restored.remote_id or nil
        restored.remote_sync_state = normalize_remote_sync_state(restored.remote_sync_state, restored.remote_id)
        restored.remote_sync_error = type(restored.remote_sync_error) == 'string'
                and restored.remote_sync_error ~= ''
                and restored.remote_sync_error
            or nil
        restored.plan_entries = type(restored.plan_entries) == 'table' and restored.plan_entries or {}
        restored.available_commands = normalize_available_commands(restored.available_commands)
        restored.tool_calls = type(restored.tool_calls) == 'table' and restored.tool_calls or {}
        restored.approval_entries = normalize_approval_entries(restored.approval_entries)
        restored.pending_approvals = normalize_pending_approvals(restored.pending_approvals, restored.approval_entries)
        restored.config_options = type(restored.config_options) == 'table' and restored.config_options or {}
        restored.turn_id = math.max(tonumber(restored.turn_id) or 0, 0)
        restored.transport_remote_id = nil
        restored.cwd = type(restored.cwd) == 'string' and restored.cwd or nil
        restored.created_at = tonumber(restored.created_at) or deps.now()
        restored.updated_at = tonumber(restored.updated_at) or restored.created_at

        if restored.remote_sync_state ~= 'load_failed' then
            restored.remote_sync_error = nil
        end

        if restored.status == 'waiting' then
            restored.status = 'cancelled'
            restored.stop_reason = 'cancelled'
        end

        return restored
    end

    return helper
end

return M
