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
        local phase_one_token = 'ACP_RESTORE_PHASE_ONE_OK'

        api.open_chat()
        api.set_prompt(string.format('Reply with exactly %s and no other text.', phase_one_token))
        local current_session = api.submit_prompt()

        assert(
            current_session.remote_id ~= nil and current_session.remote_id ~= '',
            'session/new did not bind a remote_id'
        )
        wait_for_turn_completion(current_session, prompt_timeout_ms)
        assert_transcript_contains(current_session, phase_one_token)

        local ok, payload = api.save_sessions()

        assert(ok, payload)

        write_json(result_file, {
            phase = phase,
            local_id = current_session.id,
            remote_id = current_session.remote_id,
            remote_sync_state = current_session.remote_sync_state,
            message_count = #current_session.messages,
            transcript = transcript_text(current_session),
            saved_session_count = #payload.sessions,
        })
    elseif phase == 'restore' then
        local phase_one = read_json(env('ACP_LIVE_PHASE_ONE_RESULT_FILE'))
        local phase_two_token = 'ACP_RESTORE_PHASE_TWO_OK'
        local restored = api.restore_sessions()

        assert(#restored > 0, 'restore_sessions returned no sessions')

        local current_session = api.current_session()

        assert(current_session.id == phase_one.local_id, 'restored local session id mismatch')
        assert(current_session.remote_id == phase_one.remote_id, 'restored remote_id mismatch')
        assert(
            current_session.remote_sync_state == phase_one.remote_sync_state,
            'restored remote sync state did not match the persisted snapshot'
        )
        assert(
            transcript_text(current_session):find('ACP_RESTORE_PHASE_ONE_OK', 1, true) ~= nil,
            'restored transcript did not retain the phase-one assistant response'
        )

        api.load_session(current_session.id)

        assert(
            current_session.remote_sync_state == 'loaded',
            'explicit session/load did not mark the session as loaded'
        )
        assert(current_session.remote_id == phase_one.remote_id, 'session/load changed the persisted remote_id')

        api.set_prompt(string.format('Reply with exactly %s and no other text.', phase_two_token))
        current_session = api.submit_prompt()

        wait_for_turn_completion(current_session, prompt_timeout_ms)
        assert_transcript_contains(current_session, phase_two_token)

        local ok, payload = api.save_sessions()

        assert(ok, payload)

        write_json(result_file, {
            phase = phase,
            local_id = current_session.id,
            remote_id = current_session.remote_id,
            remote_sync_state = current_session.remote_sync_state,
            message_count = #current_session.messages,
            transcript = transcript_text(current_session),
            saved_session_count = #payload.sessions,
        })
    elseif phase == 'restore_without_load' then
        local phase_one = read_json(env('ACP_LIVE_PHASE_ONE_RESULT_FILE'))
        local phase_two_token = 'ACP_RESTORE_PHASE_TWO_NO_LOAD_OK'

        local restored = api.restore_sessions()

        assert(#restored > 0, 'restore_sessions returned no sessions')

        local current_session = api.current_session()

        assert(current_session.id == phase_one.local_id, 'restored local session id mismatch')
        assert(current_session.remote_id == phase_one.remote_id, 'restored remote_id mismatch')
        assert(
            current_session.remote_sync_state == phase_one.remote_sync_state,
            'restored remote sync state did not match the persisted snapshot'
        )

        api.set_prompt(string.format('Reply with exactly %s and no other text.', phase_two_token))
        current_session = api.submit_prompt()

        wait_for_turn_completion(current_session, prompt_timeout_ms)
        assert_transcript_contains(current_session, phase_two_token)

        local ok, payload = api.save_sessions()

        assert(ok, payload)

        write_json(result_file, {
            phase = phase,
            local_id = current_session.id,
            remote_id = current_session.remote_id,
            remote_sync_state = current_session.remote_sync_state,
            message_count = #current_session.messages,
            transcript = transcript_text(current_session),
            saved_session_count = #payload.sessions,
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
