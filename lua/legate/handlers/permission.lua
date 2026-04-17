local continuity = require('legate.session')
local methods = require('legate.core.methods')

local M = {}

---@param option_kind legate.PermissionOptionKind
---@param options legate.PermissionOption[]
---@return legate.PermissionOption?
local function find_permission_option(option_kind, options)
    for _, option in ipairs(options) do
        if option.kind == option_kind then
            return option
        end
    end

    return nil
end

---@param option_id string
---@param options legate.PermissionOption[]
---@return legate.PermissionOption?
local function find_permission_option_by_id(option_id, options)
    for _, option in ipairs(options) do
        if option.optionId == option_id then
            return option
        end
    end
end

---@param value any
---@return string?
local function non_empty_string(value)
    if type(value) == 'string' and value ~= '' then
        return value
    end

    return nil
end

---@param raw_input table?
---@return string?, string?
local function raw_mcp_target(raw_input)
    if type(raw_input) ~= 'table' then
        return nil, nil
    end

    local server_name = non_empty_string(raw_input.server)
        or non_empty_string(raw_input.serverName)
        or non_empty_string(raw_input.server_name)
    local tool_name = non_empty_string(raw_input.tool)
        or non_empty_string(raw_input.toolName)
        or non_empty_string(raw_input.tool_name)
        or non_empty_string(raw_input.name)

    return server_name, tool_name
end

---@param server_name string?
---@param tool_name string?
---@return string?, string?
local function normalized_mcp_target(server_name, tool_name)
    if type(server_name) ~= 'string' or type(tool_name) ~= 'string' then
        return server_name, tool_name
    end

    local prefix = server_name .. '/'

    if vim.startswith(tool_name, prefix) then
        return server_name, tool_name:sub(#prefix + 1)
    end

    return server_name, tool_name
end

---@param tool_call legate.ToolCallState?
---@param permission legate.PermissionRequest
---@return boolean
local function is_injected_neovim_terminal_permission(tool_call, permission)
    local server_name, tool_name = normalized_mcp_target(raw_mcp_target(tool_call and tool_call.raw_input or nil))

    if server_name == 'neovim' and type(tool_name) == 'string' and tool_name:match('(^|/)terminal/') ~= nil then
        return true
    end

    local title = non_empty_string(permission.toolCall.title) or non_empty_string(tool_call and tool_call.title or nil)

    return type(title) == 'string' and title:find('neovim/terminal/', 1, true) ~= nil
end

---@param ctx legate.TransportContext
---@param current_session legate.Session
---@param permission legate.PermissionRequest
---@return legate.PermissionOutcome
local function default_permission_outcome(ctx, current_session, permission)
    local matched_tool_call = ctx.session.tool_call_by_id(current_session, permission.toolCall.toolCallId)

    if is_injected_neovim_terminal_permission(matched_tool_call, permission) then
        local allowed = find_permission_option('allow_once', permission.options)
            or find_permission_option('allow_always', permission.options)

        if allowed ~= nil then
            return {
                outcome = 'selected',
                optionId = allowed.optionId,
            }
        end
    end

    local selected = find_permission_option(ctx.config.get().permission_default, permission.options)

    if selected == nil then
        selected = find_permission_option('reject_once', permission.options)
            or find_permission_option('reject_always', permission.options)
    end

    if selected == nil then
        return {
            outcome = 'cancelled',
        }
    end

    return {
        outcome = 'selected',
        optionId = selected.optionId,
    }
end

---@param ctx legate.TransportContext
---@param current_session legate.Session
---@param permission legate.PermissionRequest
---@return legate.PermissionOutcome?
local function policy_permission_outcome(ctx, current_session, permission)
    local callback = ctx.config.get().permission_policy

    if type(callback) ~= 'function' then
        return nil
    end

    local cfg = require('legate.config')
    local adapter = cfg.adapter_for_session(current_session)
    adapter.name = cfg.session_adapter_name(current_session)
    local matched_tool_call = ctx.session.tool_call_by_id(current_session, permission.toolCall.toolCallId)
    local ok, result = pcall(callback, current_session, permission, adapter, matched_tool_call)

    if not ok or result == nil then
        return nil
    end

    if type(result) == 'string' then
        local option = find_permission_option_by_id(result, permission.options)
            or find_permission_option(result, permission.options)

        if option ~= nil then
            return {
                outcome = 'selected',
                optionId = option.optionId,
            }
        end

        return nil
    end

    if type(result) ~= 'table' then
        return nil
    end

    local option = type(result.optionId) == 'string'
            and find_permission_option_by_id(result.optionId, permission.options)
        or nil

    if option == nil and type(result.selected) == 'string' then
        option = find_permission_option_by_id(result.selected, permission.options)
    end

    if option == nil and type(result.kind) == 'string' then
        option = find_permission_option(result.kind, permission.options)
    end

    if option ~= nil then
        return {
            outcome = 'selected',
            optionId = option.optionId,
        }
    end

    return nil
end

---@param permission legate.PermissionRequest
---@param selection string|integer
---@return legate.PermissionOutcome?
local function permission_outcome_from_selection(permission, selection)
    local selected_index = nil
    local selected_option_id = nil

    if type(selection) == 'number' then
        selected_index = selection
    elseif type(selection) == 'string' then
        local trimmed = vim.trim(selection)

        if trimmed == '' then
            return nil
        end

        selected_option_id = trimmed
        selected_index = tonumber(trimmed)
    else
        return nil
    end

    if selected_option_id ~= nil then
        for _, option in ipairs(permission.options) do
            if option.optionId == selected_option_id then
                return {
                    outcome = 'selected',
                    optionId = option.optionId,
                }
            end
        end
    end

    if selected_index ~= nil then
        local option = permission.options[selected_index]

        if option == nil then
            return nil
        end

        return {
            outcome = 'selected',
            optionId = option.optionId,
        }
    end

    return nil
end

---@param pending_permissions legate.PendingPermissionState[]
---@param current_session legate.Session
---@param selection string|integer
---@return legate.PendingPermissionState?, legate.PermissionOutcome?
local function resolve_pending_permission(pending_permissions, current_session, selection)
    local pending_permission = nil
    local option_selection = selection

    if type(selection) == 'string' then
        local trimmed_selection = vim.trim(selection)
        local request_id, option_id = trimmed_selection:match('^(.*):(.-)$')

        if request_id ~= nil and option_id ~= nil and request_id ~= '' and option_id ~= '' then
            for _, candidate in ipairs(pending_permissions) do
                if candidate.local_session_id == current_session.id and candidate.request_id == request_id then
                    pending_permission = candidate
                    option_selection = option_id
                    break
                end
            end
        end
    end

    if pending_permission == nil then
        local pending = continuity.pending_approval(current_session)

        if pending ~= nil then
            for _, candidate in ipairs(pending_permissions) do
                if candidate.local_session_id == current_session.id and candidate.request_id == pending.request_id then
                    pending_permission = candidate
                    break
                end
            end
        end
    end

    if pending_permission == nil then
        return nil, nil
    end

    return pending_permission, permission_outcome_from_selection(pending_permission.permission, option_selection)
end

---@param ctx legate.TransportContext
---@param generation integer
---@param permission legate.PermissionRequest
---@param respond fun(result?: any, error?: table)
function M.handle_request(ctx, generation, permission, respond)
    local current_session = ctx.active_request_session(permission)

    if current_session == nil then
        respond(ctx.cancelled_response())
        return
    end

    local policy_outcome = policy_permission_outcome(ctx, current_session, permission)

    if policy_outcome ~= nil then
        ctx.session.record_approval(current_session, permission, policy_outcome, 'policy')
        ctx.rerender(current_session)
        respond({
            outcome = policy_outcome,
        })
        return
    end

    if ctx.config.get().permission_strategy == 'default' then
        local outcome = default_permission_outcome(ctx, current_session, permission)
        ctx.session.record_approval(current_session, permission, outcome, 'default')
        ctx.rerender(current_session)
        respond({
            outcome = outcome,
        })
        return
    end

    local request_id =
        string.format('%s:%s:%d', current_session.id, permission.toolCall.toolCallId or 'approval', generation)
    permission.request_id = request_id
    permission.generation = generation

    ctx.session.wait_for_approval(current_session, permission)

    local pending_permissions = ctx.get_pending_permissions()
    table.insert(pending_permissions, {
        request_id = request_id,
        generation = generation,
        local_session_id = current_session.id,
        permission = vim.deepcopy(permission),
        respond = respond,
    })
    ctx.set_pending_permissions(pending_permissions)
    ctx.reveal_inline_approval(current_session)
end

---@param ctx legate.TransportContext
---@param current_session legate.Session
---@param selection string|integer
---@return legate.PermissionOutcome
function M.select_pending_approval(ctx, current_session, selection)
    local pending_permissions = ctx.get_pending_permissions()
    local pending_permission, outcome = resolve_pending_permission(pending_permissions, current_session, selection)

    if pending_permission == nil then
        error(string.format('No ACP approval is pending for session: %s', current_session.id))
    end

    if not ctx.is_live_generation(pending_permission.generation) then
        local retained = {}

        for _, candidate in ipairs(pending_permissions) do
            if candidate.request_id ~= pending_permission.request_id then
                table.insert(retained, candidate)
            end
        end

        ctx.set_pending_permissions(retained)
        continuity.clear_pending_approval_by_request_id(current_session, pending_permission.request_id)
        ctx.rerender(current_session)
        error('ACP approval is no longer active')
    end

    local live_session = ctx.active_request_session(pending_permission.permission)

    if live_session == nil then
        local retained = {}

        for _, candidate in ipairs(pending_permissions) do
            if candidate.request_id ~= pending_permission.request_id then
                table.insert(retained, candidate)
            end
        end

        ctx.set_pending_permissions(retained)
        continuity.clear_pending_approval_by_request_id(current_session, pending_permission.request_id)
        ctx.rerender(current_session)
        error('ACP approval is no longer active')
    end

    if outcome == nil then
        error(string.format('Unknown ACP approval option: %s', tostring(selection)))
    end

    local retained = {}

    for _, candidate in ipairs(pending_permissions) do
        if candidate.request_id ~= pending_permission.request_id then
            table.insert(retained, candidate)
        end
    end

    ctx.set_pending_permissions(retained)
    ctx.session.record_approval(live_session, pending_permission.permission, outcome, 'select')
    ctx.rerender(live_session)
    pending_permission.respond({
        outcome = outcome,
    })

    return outcome
end

---@return table<string, legate.RequestHandlerDescriptor>
function M.request_handlers()
    return {
        [methods.SESSION_REQUEST_PERMISSION] = {
            requires_active_session = false,
            handle = function(ctx, params, respond, _, generation)
                M.handle_request(ctx, generation, params, respond)
            end,
        },
    }
end

return M
