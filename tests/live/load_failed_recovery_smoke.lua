local uv = vim.uv or vim.loop

---@param path string
---@return boolean
local function exists(path)
    return uv.fs_stat(path) ~= nil
end

---@param path string
---@return table
local function read_json(path)
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

---@param result vim.SystemCompleted
---@param fallback string
local function assert_ok(result, fallback)
    local stderr = vim.trim(result.stderr or '')
    local stdout = vim.trim(result.stdout or '')

    assert(result.code == 0, stderr ~= '' and stderr or stdout ~= '' and stdout or fallback)
end

---@param base_env table<string, string>
---@param overrides table<string, string>
---@return table<string, string>
local function merged_env(base_env, overrides)
    local env = vim.deepcopy(base_env)

    for key, value in pairs(overrides) do
        env[key] = value
    end

    return env
end

---@param repo_root string
---@param base_env table<string, string>
---@param phase string
---@param paths table<string, string>
---@return table
local function run_phase(repo_root, base_env, phase, paths)
    local result = vim.system({
        'nvim',
        '--headless',
        '-u',
        'tests/minimal_init.lua',
        '-l',
        'tests/live_support/live_load_failed_recovery_phase.lua',
    }, {
        cwd = repo_root,
        text = true,
        env = merged_env(base_env, {
            ACP_LIVE_PHASE = phase,
            ACP_LIVE_RESULT_FILE = paths[phase .. '_result'],
            ACP_LIVE_SESSION_STATE_FILE = paths.session_state_file,
            ACP_LIVE_PHASE_ONE_RESULT_FILE = paths.save_result,
            ACP_LIVE_PROMPT_TIMEOUT_MS = '180000',
            ACP_LIVE_SESSION_TIMEOUT_MS = '60000',
        }),
    }):wait()

    assert_ok(result, string.format('phase %s failed', phase))
    assert(exists(paths[phase .. '_result']), string.format('phase %s did not produce a result file', phase))

    return read_json(paths[phase .. '_result'])
end

local repo_root = vim.fn.getcwd()
local temp_root = vim.fn.tempname()
local xdg_root = vim.fs.joinpath(temp_root, 'xdg')
local paths = {
    session_state_file = vim.fs.joinpath(temp_root, 'sessions.json'),
    save_result = vim.fs.joinpath(temp_root, 'phase-save.json'),
    recover_result = vim.fs.joinpath(temp_root, 'phase-recover.json'),
}

local base_env = vim.fn.environ()

base_env.NVIM = ''
base_env.NVIM_LISTEN_ADDRESS = ''
base_env.XDG_CONFIG_HOME = vim.fs.joinpath(xdg_root, 'config')
base_env.XDG_DATA_HOME = vim.fs.joinpath(xdg_root, 'data')
base_env.XDG_STATE_HOME = vim.fs.joinpath(xdg_root, 'state')
base_env.XDG_CACHE_HOME = vim.fs.joinpath(xdg_root, 'cache')

local function cleanup()
    vim.fn.delete(temp_root, 'rf')
end

local ok, err = xpcall(function()
    local saved = run_phase(repo_root, base_env, 'save', paths)
    local recovered = run_phase(repo_root, base_env, 'recover', paths)

    assert(saved.local_id == recovered.local_id, 'local ACP session id changed across recovery smoke')
    assert(saved.remote_id ~= recovered.failed_remote_id, 'failed remote id unexpectedly matched the saved remote id')
    assert(recovered.rebound_remote_id ~= recovered.failed_remote_id, 'rebind did not replace the failed remote id')
    assert(recovered.rebound_remote_id ~= saved.remote_id, 'rebind unexpectedly reused the original remote id')
    assert(recovered.remote_sync_state == 'created', 'rebound ACP session was not left in created sync state')
    assert(recovered.retry_error ~= '', 'recovery smoke did not capture the first load failure')
    assert(
        recovered.retry_error == recovered.second_retry_error,
        'retry path did not stay stable across repeated load failure'
    )
    assert(
        recovered.transcript:find('ACP_RECOVERY_PHASE_ONE_OK', 1, true) ~= nil,
        'recovery smoke lost the phase-one assistant response'
    )
    assert(
        recovered.transcript:find('ACP_RECOVERY_PHASE_TWO_OK', 1, true) ~= nil,
        'recovery smoke did not capture the post-rebind assistant response'
    )

    print(vim.json.encode({
        outcome = 'success',
        local_id = recovered.local_id,
        failed_remote_id = recovered.failed_remote_id,
        rebound_remote_id = recovered.rebound_remote_id,
        remote_sync_state = recovered.remote_sync_state,
        retry_error = recovered.retry_error,
    }))
end, debug.traceback)

cleanup()

if not ok then
    io.stderr:write(err .. '\n')
    os.exit(1)
end
