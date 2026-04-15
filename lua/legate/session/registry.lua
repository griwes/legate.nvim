local M = {}

---@param deps { get_current_id: fun(): string?, set_current_id: fun(session_id?: string): nil, get_next_ordinal: fun(): integer, set_next_ordinal: fun(value: integer): nil, now: fun(): integer, resolved_adapter_name: fun(adapter_name?: string): string, sessions: table<string, legate.Session> }
---@return table
function M.new(deps)
    local helper = {}

    ---@return legate.Session
    local function make_session()
        local ordinal = deps.get_next_ordinal()
        deps.set_next_ordinal(ordinal + 1)

        local timestamp = deps.now()

        return {
            id = string.format('acp:%d', ordinal),
            ordinal = ordinal,
            adapter_name = deps.resolved_adapter_name(nil),
            status = 'idle',
            messages = {},
            draft_prompt = '',
            pending_approvals = {},
            plan_entries = {},
            available_commands = {},
            tool_calls = {},
            approval_entries = {},
            config_options = {},
            remote_sync_error = nil,
            remote_sync_state = 'unbound',
            turn_id = 0,
            created_at = timestamp,
            updated_at = timestamp,
            transport_remote_id = nil,
            cwd = nil,
        }
    end

    ---@param session legate.Session
    ---@return legate.Session
    local function store(session)
        deps.sessions[session.id] = session
        deps.set_current_id(session.id)
        return session
    end

    ---@param adapter_name? string
    ---@return legate.Session
    function helper.create(adapter_name)
        local current_session = make_session()
        current_session.adapter_name = deps.resolved_adapter_name(adapter_name)
        return store(current_session)
    end

    ---@param adapter_name? string
    ---@return legate.Session
    function helper.ensure(adapter_name)
        local session = helper.current()

        if session ~= nil then
            return session
        end

        return helper.create(adapter_name)
    end

    ---@return legate.Session?
    function helper.current()
        local current_id = deps.get_current_id()

        if current_id == nil then
            return nil
        end

        return deps.sessions[current_id]
    end

    ---@param session_id string
    ---@return legate.Session?
    function helper.get(session_id)
        return deps.sessions[session_id]
    end

    ---@param session_id string
    ---@return integer?, legate.Session[]
    local function ordered_index(session_id)
        local ordered = helper.list()

        for index, current_session in ipairs(ordered) do
            if current_session.id == session_id then
                return index, ordered
            end
        end

        return nil, ordered
    end

    ---@return legate.Session[]
    function helper.list()
        local ordered = {}

        for _, session in pairs(deps.sessions) do
            table.insert(ordered, session)
        end

        table.sort(ordered, function(left, right)
            return left.ordinal < right.ordinal
        end)

        return ordered
    end

    ---@param session_id string
    ---@return legate.Session
    function helper.select(session_id)
        local current_session = helper.get(session_id)

        if current_session == nil then
            error(string.format('Unknown ACP session: %s', session_id))
        end

        deps.set_current_id(session_id)

        return current_session
    end

    ---@param session_id string
    ---@return legate.Session, legate.Session?
    function helper.close(session_id)
        local closing_session = helper.get(session_id)

        if closing_session == nil then
            error(string.format('Unknown ACP session: %s', session_id))
        end

        local index, ordered = ordered_index(session_id)

        deps.sessions[session_id] = nil

        if deps.get_current_id() ~= session_id then
            return closing_session, helper.current()
        end

        local next_session = nil

        if index ~= nil then
            next_session = ordered[index + 1] or ordered[index - 1]
        end

        deps.set_current_id(next_session and next_session.id or nil)

        return closing_session, next_session
    end

    ---@return legate.Session?
    function helper.waiting()
        for _, current_session in ipairs(helper.list()) do
            if current_session.status == 'waiting' then
                return current_session
            end
        end

        return nil
    end

    ---@return legate.Session?
    function helper.pending_approval_session()
        for _, current_session in ipairs(helper.list()) do
            if #(current_session.pending_approvals or {}) > 0 then
                return current_session
            end
        end

        return nil
    end

    function helper.clear()
        for session_id in pairs(deps.sessions) do
            deps.sessions[session_id] = nil
        end

        deps.set_current_id(nil)
        deps.set_next_ordinal(1)
    end

    return helper
end

return M
