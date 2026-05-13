local approval_api = require('legate.api.approvals')
local buffer = require('legate.ui.buffer')
local configuration_api = require('legate.api.configuration')
local formatters = require('legate.api.formatters')
local guidance_registry = require('legate.guidance.registry')
local pickers = require('legate.api.pickers')
local prompt_api = require('legate.api.prompt')
local session_api = require('legate.api.sessions')
local slash_command_api = require('legate.api.slash_commands')
local config = require('legate.config')
local input = require('legate.ui.input')
local mcp_runtime = require('legate.mcp.runtime')
local persistence = require('legate.core.persistence')
local render = require('legate.ui.render')
local continuity = require('legate.session')
local terminal = require('legate.terminal')
local transport = require('legate.transport')

---@class legate.Api
local M = {}
local approval_helper
local configuration_helper
local store_draft
local prompt_helper
local session_helper
local slash_command_helper

---@return legate.Session
local function active_session()
    if config.get().auto_create_session then
        return continuity.ensure(config.default_adapter_name())
    end

    local current = continuity.current()

    if current == nil then
        error('No ACP session exists')
    end

    return current
end

---@param session_id? string
---@return legate.Session
local function resolve_session(session_id)
    if session_id ~= nil then
        local existing = continuity.get(session_id)

        if existing == nil then
            error(string.format('Unknown ACP session: %s', session_id))
        end

        return existing
    end

    return active_session()
end

---@param session_id? string
---@return legate.Session
local function resolve_pending_approval_session(session_id)
    if session_id ~= nil then
        return resolve_session(session_id)
    end

    local pending_session = continuity.pending_approval_session()

    if pending_session ~= nil then
        return pending_session
    end

    local waiting_session = continuity.waiting()

    if waiting_session ~= nil then
        return waiting_session
    end

    return active_session()
end

---@param current_session legate.Session
---@param action string
local function assert_session_binding_change_allowed(current_session, action)
    if current_session.status == 'waiting' then
        error(
            string.format('Cannot %s ACP session while a prompt turn is still running: %s', action, current_session.id)
        )
    end

    local waiting_session = continuity.waiting()

    if waiting_session ~= nil and waiting_session.id ~= current_session.id then
        error(
            string.format(
                'Cannot %s ACP session %s while session %s has a running turn',
                action,
                current_session.id,
                waiting_session.id
            )
        )
    end
end

---@param current_session legate.Session?
store_draft = function(current_session)
    if current_session == nil then
        return
    end

    local bufnr = buffer.get()

    if bufnr == nil then
        return
    end

    local prompt = input.capture_prompt(bufnr)

    if prompt ~= nil then
        continuity.set_draft_prompt(current_session, prompt)
    end
end

prompt_helper = prompt_api.new({
    continuity = continuity,
    transport = transport,
    active_session = active_session,
    store_draft = store_draft,
    select_session = function(session_id)
        return M.select_session(session_id)
    end,
})

approval_helper = approval_api.new({
    buffer = buffer,
    continuity = continuity,
    formatters = formatters,
    prompt_helper = prompt_helper,
    render = render,
    resolve_pending_approval_session = resolve_pending_approval_session,
    resolve_session = resolve_session,
    select_session = function(session_id)
        return M.select_session(session_id)
    end,
    transport = transport,
})

configuration_helper = configuration_api.new({
    buffer = buffer,
    config_option = require('legate.config.option'),
    continuity = continuity,
    formatters = formatters,
    prompt_helper = prompt_helper,
    render = render,
    resolve_session = resolve_session,
    transport = transport,
})

slash_command_helper = slash_command_api.new({
    continuity = continuity,
    formatters = formatters,
    prompt_helper = prompt_helper,
    resolve_session = resolve_session,
    transport = transport,
})

session_helper = session_api.new({
    buffer = buffer,
    config = config,
    continuity = continuity,
    persistence = persistence,
    prompt_helper = prompt_helper,
    render = render,
    transport = transport,
    pickers = pickers,
    formatters = formatters,
    active_session = active_session,
    resolve_session = resolve_session,
    assert_session_binding_change_allowed = assert_session_binding_change_allowed,
    store_draft = store_draft,
    open_chat = function()
        return M.open_chat()
    end,
})

-- Session lifecycle and persistence facade.
M.new_session = session_helper.new_session
M.current_session = session_helper.current_session
M.list_sessions = session_helper.list_sessions
M.session_lines = session_helper.session_lines
M.save_sessions = session_helper.save_sessions
M.restore_sessions = session_helper.restore_sessions
M.continue_last_session = session_helper.continue_last_session
M.clear_session_storage = session_helper.clear_session_storage
M.pick_session = session_helper.pick_session
M.select_session = session_helper.select_session
M.close_session = session_helper.close_session
M.pick_close_session = session_helper.pick_close_session
M.load_session = session_helper.load_session
M.rebind_session = session_helper.rebind_session
M.adapter_names = session_helper.adapter_names
M.adapter_name = session_helper.adapter_name
M.adapter_lines = session_helper.adapter_lines
M.select_adapter = session_helper.select_adapter
M.pick_adapter = session_helper.pick_adapter

-- Prompt editing and submission facade.
M.open_chat = prompt_helper.open_chat
M.append_message = prompt_helper.append_message
M.submit_prompt = prompt_helper.submit_prompt
M.submit_prompt_async = prompt_helper.submit_prompt_async
M.cancel_prompt = prompt_helper.cancel_prompt
M.get_prompt = prompt_helper.get_prompt
M.set_prompt = prompt_helper.set_prompt

-- Approval inspection and resolution facade.
M.approvals = approval_helper.approvals
M.pending_approval = approval_helper.pending_approval
M.pending_approvals = approval_helper.pending_approvals
M.approval_lines = approval_helper.approval_lines
M.reveal_approval = approval_helper.reveal_approval
M.pick_approval = approval_helper.pick_approval
M.clear_pending_approvals = approval_helper.clear_pending_approvals
M.select_approval_option = approval_helper.select_approval_option

-- Config-option query and mutation facade.
M.config_options = configuration_helper.config_options
M.config_option_lines = configuration_helper.config_option_lines
M.pick_config_option = configuration_helper.pick_config_option
M.set_config_option = configuration_helper.set_config_option
M.set_approval_mode = configuration_helper.set_approval_mode

-- Slash-command query and submission facade.
M.slash_commands = slash_command_helper.slash_commands
M.slash_command_lines = slash_command_helper.slash_command_lines
M.slash_command_names = slash_command_helper.slash_command_names
M.pick_slash_command = slash_command_helper.pick_slash_command
M.run_slash_command = slash_command_helper.run_slash_command

---Return the configured ACP MCP servers without runtime injection side effects.
---@return table[]
function M.mcp_servers(session_id)
    local current_session = session_id and resolve_session(session_id) or continuity.current()
    return mcp_runtime.static_servers(current_session)
end

---Return the effective ACP MCP servers including runtime injection.
---@return table[]
function M.effective_mcp_servers(session_id)
    local current_session = session_id and resolve_session(session_id) or continuity.current()
    return mcp_runtime.effective_servers(current_session, { passive = false })
end

---Return the effective ACP terminal backend name.
---@return legate.TerminalBackendName
function M.terminal_backend_name()
    return terminal.resolve().name
end

---@param owner string
---@param provider string|fun(ctx: legate.GuidanceContext): string|string[]|nil
---@param opts? table
---@return boolean, string?
function M.register_guidance_provider(owner, provider, opts)
    return guidance_registry.register(owner, provider, opts)
end

---@param owner string
function M.unregister_guidance_provider(owner)
    guidance_registry.unregister(owner)
end

---@return legate.GuidanceRegistration[]
function M.guidance_providers()
    return guidance_registry.list()
end

---Reset all in-memory ACP state.
function M.clear()
    transport.clear()
    terminal.clear()
    continuity.clear()
    buffer.clear()
    guidance_registry.clear()
    config.reset()
end

return M
