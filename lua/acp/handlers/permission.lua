local session = require('acp.session')
local methods = require('acp.methods')

local M = {}

---@param option_kind acp.PermissionOptionKind
---@param options acp.PermissionOption[]
---@return acp.PermissionOption?
local function find_permission_option(option_kind, options)
    for _, option in ipairs(options) do
        if option.kind == option_kind then
            return option
        end
    end

    return nil
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

---@param tool_call acp.ToolCallState?
---@param permission acp.PermissionRequest
---@return boolean
local function is_injected_neovim_terminal_permission(tool_call, permission)
    local server_name, tool_name = raw_mcp_target(tool_call and tool_call.raw_input or nil)

    if server_name == 'neovim' and type(tool_name) == 'string' and tool_name:match('(^|/)terminal/') ~= nil then
        return true
    end

    local title = non_empty_string(permission.toolCall.title) or non_empty_string(tool_call and tool_call.title or nil)

    return type(title) == 'string' and title:find('neovim/terminal/', 1, true) ~= nil
end

---@param ctx acp.TransportContext
---@param current_session acp.Session
---@param permission acp.PermissionRequest
---@return acp.PermissionOutcome
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

---@param permission acp.PermissionRequest
---@param selection string|integer
---@return acp.PermissionOutcome?
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

---@param pending_permissions acp.PendingPermissionState[]
---@param current_session acp.Session
---@param selection string|integer
---@return acp.PendingPermissionState?, acp.PermissionOutcome?
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
        local pending = session.pending_approval(current_session)

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

---@param ctx acp.TransportContext
---@param generation integer
---@param permission acp.PermissionRequest
---@param respond fun(result?: any, error?: table)
function M.handle_request(ctx, generation, permission, respond)
    local current_session = ctx.active_request_session(permission)

    if current_session == nil then
        respond(ctx.cancelled_response())
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

---@param ctx acp.TransportContext
---@param current_session acp.Session
---@param selection string|integer
---@return acp.PermissionOutcome
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
        session.clear_pending_approval_by_request_id(current_session, pending_permission.request_id)
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
        session.clear_pending_approval_by_request_id(current_session, pending_permission.request_id)
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

---@return table<string, acp.RequestHandlerDescriptor>
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
