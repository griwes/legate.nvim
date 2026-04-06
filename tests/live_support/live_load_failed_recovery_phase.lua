local plugin = require('acp')

---@param name string
---@return string
local function env(name)
    local value = vim.env[name]

    assert(value ~= nil and value ~= '', string.format('Missing required environment variable: %s', name))

    return value
end

---@param path string
---@return table
local function read_json(path)
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

---@param path string
---@param payload table
local function write_json(path, payload)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile({
        vim.json.encode(payload),
    }, path)
end

---@param current_session acp.Session
---@return string
local function transcript_text(current_session)
    local chunks = {}

    for _, message in ipairs(current_session.messages) do
        table.insert(chunks, string.format('[%s] %s', message.role, message.text))
    end

    return table.concat(chunks, '\n')
end

---@param current_session acp.Session
---@return string?
local function last_assistant_text(current_session)
    for index = #current_session.messages, 1, -1 do
        local message = current_session.messages[index]

        if message.role == 'assistant' then
            return message.text
        end
    end

    return nil
end

---@param current_session acp.Session
---@param timeout_ms integer
local function wait_for_turn_completion(current_session, timeout_ms)
    local completed = vim.wait(timeout_ms, function()
        return current_session.status ~= 'waiting'
    end, 100)

    assert(completed, string.format('ACP prompt did not complete within %d ms', timeout_ms))
    assert(
        current_session.status == 'idle',
        string.format('ACP prompt ended with status %s\n%s', current_session.status, transcript_text(current_session))
    )
end

---@param current_session acp.Session
---@param token string
local function assert_transcript_contains(current_session, token)
    local assistant_text = last_assistant_text(current_session) or ''

    assert(
        assistant_text:find(token, 1, true) ~= nil,
        string.format('Expected assistant text to contain %s\n%s', token, transcript_text(current_session))
    )
end

---@param path string
---@param local_id string
---@return string
local function poison_saved_remote_id(path, local_id)
    local payload = read_json(path)
    local invalid_remote_id = string.format('invalid-live-recovery-%d', os.time())

    for _, saved_session in ipairs(payload.sessions or {}) do
        if saved_session.id == local_id then
            saved_session.remote_id = invalid_remote_id
            saved_session.remote_sync_state = 'created'
            saved_session.remote_sync_error = nil
            write_json(path, payload)
            return invalid_remote_id
        end
    end

    error(string.format('Could not find persisted ACP session to corrupt: %s', local_id))
end

local phase = env('ACP_LIVE_PHASE')
local result_file = env('ACP_LIVE_RESULT_FILE')
local session_state_file = env('ACP_LIVE_SESSION_STATE_FILE')
local prompt_timeout_ms = tonumber(vim.env.ACP_LIVE_PROMPT_TIMEOUT_MS or '') or 180000
local session_timeout_ms = tonumber(vim.env.ACP_LIVE_SESSION_TIMEOUT_MS or '') or 60000

local ok, err = xpcall(function()
    plugin.setup({
        auth_method = 'chatgpt',
        persist_sessions = false,
        request_timeout_ms = session_timeout_ms,
        session_state_file = session_state_file,
    })

    local api = plugin.api

    if phase == 'save' then
        local phase_one_token = 'ACP_RECOVERY_PHASE_ONE_OK'

        api.open_chat()
        api.set_prompt(string.format('Reply with exactly %s and no other text.', phase_one_token))
        local current_session = api.submit_prompt()

        assert(
            current_session.remote_id ~= nil and current_session.remote_id ~= '',
            'session/new did not bind a remote_id'
        )
        wait_for_turn_completion(current_session, prompt_timeout_ms)
        assert_transcript_contains(current_session, phase_one_token)

        local ok, payload_or_err = api.save_sessions()

        assert(ok, payload_or_err)

        write_json(result_file, {
            phase = phase,
            local_id = current_session.id,
            remote_id = current_session.remote_id,
            remote_sync_state = current_session.remote_sync_state,
            message_count = #current_session.messages,
            transcript = transcript_text(current_session),
        })
    elseif phase == 'recover' then
        local phase_one = read_json(env('ACP_LIVE_PHASE_ONE_RESULT_FILE'))
        local phase_two_token = 'ACP_RECOVERY_PHASE_TWO_OK'
        local invalid_remote_id = poison_saved_remote_id(session_state_file, phase_one.local_id)
        local restored = api.restore_sessions({
            open_chat = true,
        })

        assert(#restored > 0, 'restore_sessions returned no sessions')

        local current_session = api.current_session()
        local bufnr = api.open_chat()

        assert(current_session.id == phase_one.local_id, 'restored local session id mismatch')
        assert(current_session.remote_id == invalid_remote_id, 'restored invalid remote_id mismatch')
        assert(current_session.remote_sync_state == 'created', 'poisoned restore did not preserve created sync state')
        assert(
            transcript_text(current_session):find('ACP_RECOVERY_PHASE_ONE_OK', 1, true) ~= nil,
            'restored transcript did not retain the phase-one assistant response'
        )

        local first_ok, first_err = pcall(api.load_session, current_session.id)

        assert(not first_ok, 'first session/load unexpectedly succeeded')
        assert(type(first_err) == 'string' and first_err ~= '', 'first session/load failure did not return an error')
        assert(
            current_session.remote_sync_state == 'load_failed',
            'failed load did not mark the session as load_failed'
        )
        assert(current_session.remote_id == invalid_remote_id, 'failed load mutated the recorded remote id')

        local first_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert(
            vim.tbl_contains(
                first_lines,
                '- Recovery: retry the recorded remote session with `:ACPLoadSession`, or create a fresh one with `:ACPRebindSession`'
            ),
            'load_failed recovery hint was not rendered after the first live load failure'
        )

        local second_ok, second_err = pcall(api.load_session, current_session.id)

        assert(not second_ok, 'second session/load unexpectedly succeeded')
        assert(type(second_err) == 'string' and second_err ~= '', 'second session/load failure did not return an error')
        assert(current_session.remote_sync_state == 'load_failed', 'retry did not keep the session in load_failed')
        assert(current_session.remote_id == invalid_remote_id, 'retry changed the recorded failed remote id')

        api.rebind_session(current_session.id)

        local rebound_remote_id = current_session.remote_id

        assert(rebound_remote_id ~= nil and rebound_remote_id ~= '', 'rebind did not produce a fresh remote id')
        assert(rebound_remote_id ~= invalid_remote_id, 'rebind kept the failed remote id')
        assert(rebound_remote_id ~= phase_one.remote_id, 'rebind unexpectedly reused the original remote id')
        assert(current_session.remote_sync_state == 'created', 'rebind did not reset the sync state to created')
        assert(current_session.remote_sync_error == nil, 'rebind did not clear the prior sync error')

        api.set_prompt(string.format('Reply with exactly %s and no other text.', phase_two_token))
        current_session = api.submit_prompt()

        wait_for_turn_completion(current_session, prompt_timeout_ms)
        assert_transcript_contains(current_session, phase_two_token)

        write_json(result_file, {
            phase = phase,
            local_id = current_session.id,
            failed_remote_id = invalid_remote_id,
            retry_error = first_err,
            second_retry_error = second_err,
            rebound_remote_id = current_session.remote_id,
            remote_sync_state = current_session.remote_sync_state,
            message_count = #current_session.messages,
            transcript = transcript_text(current_session),
        })
    else
        error(string.format('Unsupported ACP live smoke phase: %s', phase))
    end

    print(vim.json.encode(read_json(result_file)))
end, debug.traceback)

if not ok then
    io.stderr:write(err .. '\n')
    os.exit(1)
end
