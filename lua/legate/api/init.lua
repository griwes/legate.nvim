local approval_api = require('legate.api.approvals')
local buffer = require('legate.ui.buffer')
local configuration_api = require('legate.api.configuration')
local formatters = require('legate.api.formatters')
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

---Create and select a new ACP session, then render it.
---@return legate.Session
function M.new_session()
    return session_helper.new_session()
end

---Return the current ACP session, creating one if configured to do so.
---@return legate.Session
function M.current_session()
    return session_helper.current_session()
end

---Create or reveal the ACP chat buffer.
---@return integer
function M.open_chat()
    return prompt_helper.open_chat()
end

---Return all local ACP sessions ordered by creation ordinal.
---@return legate.Session[]
function M.list_sessions()
    return session_helper.list_sessions()
end

---Return formatted local-session lines for command-line or picker use.
---@return string[]
function M.session_lines()
    return session_helper.session_lines()
end

---Return the configured ACP adapter names.
---@return string[]
function M.adapter_names()
    return session_helper.adapter_names()
end

---Return the adapter selected for the resolved ACP continuity.---@param session_id? string
---@return string
function M.adapter_name(session_id)
    return session_helper.adapter_name(session_id)
end

---Return formatted ACP adapter lines for command-line or picker use.
---@param session_id? string
---@return string[]
function M.adapter_lines(session_id)
    return session_helper.adapter_lines(session_id)
end

---Return the current ACP approval history for command or picker use.
---@param session_id? string
---@return legate.ApprovalEntry[]
function M.approvals(session_id)
    return approval_helper.approvals(session_id)
end

---Return the currently pending inline ACP approval, if any.
---@param session_id? string
---@return legate.PendingApproval?
function M.pending_approval(session_id)
    return approval_helper.pending_approval(session_id)
end

---Return all currently pending inline ACP approvals for the resolved continuity.---@param session_id? string
---@return legate.PendingApproval[]
function M.pending_approvals(session_id)
    return approval_helper.pending_approvals(session_id)
end

---Return formatted approval lines for command-line display or picker use.
---@param session_id? string
---@return string[]
function M.approval_lines(session_id)
    return approval_helper.approval_lines(session_id)
end

---Persist all local ACP sessions to disk.
---@return boolean, legate.SessionPersistencePayload|string
function M.save_sessions()
    return session_helper.save_sessions()
end

---Restore local ACP sessions from disk.
---@param opts? { open_chat?: boolean }
---@return legate.Session[]
function M.restore_sessions(opts)
    return session_helper.restore_sessions(opts)
end

---Clear persisted ACP session storage from disk.
function M.clear_session_storage()
    return session_helper.clear_session_storage()
end

---Return the current session config options for command or picker use.
---@param session_id? string
---@return legate.SessionConfigOption[]
function M.config_options(session_id)
    return configuration_helper.config_options(session_id)
end

---Return formatted config option lines for command-line display.
---@param session_id? string
---@return string[]
function M.config_option_lines(session_id)
    return configuration_helper.config_option_lines(session_id)
end

---Return the current ACP slash commands for command or picker use.
---@param session_id? string
---@return legate.AvailableCommand[]
function M.slash_commands(session_id)
    return slash_command_helper.slash_commands(session_id)
end

---Return formatted ACP slash-command lines for command-line display or picker use.
---@param session_id? string
---@return string[]
function M.slash_command_lines(session_id)
    return slash_command_helper.slash_command_lines(session_id)
end

---Return locally known ACP slash-command names for completion use.
---@param session_id? string
---@return string[]
function M.slash_command_names(session_id)
    return slash_command_helper.slash_command_names(session_id)
end

---Open a picker for session config options, then a second picker for the selected value.
---@param session_id? string
function M.pick_config_option(session_id)
    return configuration_helper.pick_config_option(session_id)
end

---Open a picker for ACP slash commands and submit the selected command prompt.
---@param session_id? string
function M.pick_slash_command(session_id)
    return slash_command_helper.pick_slash_command(session_id)
end

---Open a picker for local ACP sessions and select the chosen one.
function M.pick_session()
    return session_helper.pick_session()
end

---Select an ACP adapter for a local session and reset stale remote binding state.
---@param adapter_name string
---@param session_id? string
---@return legate.Session
function M.select_adapter(adapter_name, session_id)
    return session_helper.select_adapter(adapter_name, session_id)
end

---Open a picker for ACP adapters and switch the resolved session to the chosen adapter.
---@param session_id? string
function M.pick_adapter(session_id)
    return session_helper.pick_adapter(session_id)
end

---Select a local ACP session and rerender the shared chat buffer.
---@param session_id string
---@return legate.Session
function M.select_session(session_id)
    return session_helper.select_session(session_id)
end

---Reveal an approval entry in the shared Markdown chat buffer.
---@param approval_ordinal integer
---@param session_id? string
---@return legate.ApprovalEntry
function M.reveal_approval(approval_ordinal, session_id)
    return approval_helper.reveal_approval(approval_ordinal, session_id)
end

---Open a picker for current-session approvals and reveal the chosen entry.
---@param session_id? string
function M.pick_approval(session_id)
    return approval_helper.pick_approval(session_id)
end

---Resolve the current inline ACP approval by option id or 1-based index.
---@param selection string|integer
---@param session_id? string
---@return legate.PermissionOutcome
function M.select_approval_option(selection, session_id)
    return approval_helper.select_approval_option(selection, session_id)
end

---Explicitly bind or reload an ACP session against the remote transport.
---@param session_id? string
---@return legate.Session
function M.load_session(session_id)
    return session_helper.load_session(session_id)
end

---Recover a load_failed ACP session by creating a fresh remote ACP continuity.---@param session_id? string
---@return legate.Session
function M.rebind_session(session_id)
    return session_helper.rebind_session(session_id)
end

---Submit an ACP slash command through the normal prompt path.
---@param name string
---@param command_input? string
---@param session_id? string
---@return legate.Session
function M.run_slash_command(name, command_input, session_id)
    return slash_command_helper.run_slash_command(name, command_input, session_id)
end

---Close a local ACP session and update the shared chat buffer if needed.
---@param session_id? string
---@return legate.Session, legate.Session?
function M.close_session(session_id)
    return session_helper.close_session(session_id)
end

---Set a session config option through ACP and rerender the chat buffer if needed.
---@param config_id string
---@param value string
---@param session_id? string
---@return legate.Session
function M.set_config_option(config_id, value, session_id)
    return configuration_helper.set_config_option(config_id, value, session_id)
end

---Open a picker for closable local ACP sessions and close the chosen one.
function M.pick_close_session()
    return session_helper.pick_close_session()
end

---Append a transcript message and rerender the chat buffer.
---@param role legate.MessageRole
---@param text string
---@return legate.Session
function M.append_message(role, text)
    return prompt_helper.append_message(role, text)
end

---Submit the editable prompt region as the next ACP prompt.
---@return legate.Session
function M.submit_prompt()
    return prompt_helper.submit_prompt()
end

---Cancel the current ACP prompt state and rerender the chat buffer.
---@return legate.Session?
function M.cancel_prompt()
    return prompt_helper.cancel_prompt()
end

---Return the current editable ACP prompt text.
---@return string
function M.get_prompt()
    return prompt_helper.get_prompt()
end

---Replace the editable ACP prompt text.
---@param text string
function M.set_prompt(text)
    return prompt_helper.set_prompt(text)
end

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

---Reset all in-memory ACP state.
function M.clear()
    transport.clear()
    terminal.clear()
    continuity.clear()
    buffer.clear()
    config.reset()
end

return M
