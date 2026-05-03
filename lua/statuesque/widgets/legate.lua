local publisher = require('statuesque.publisher')
local highlights_refreshed = false

local STATUS_GROUPS = {
    'LegateStatusSuccess',
    'LegateStatusFailure',
    'LegateStatusPending',
    'LegateStatusWaiting',
    'LegateStatusNeutral',
}

---@class legate.StatuesqueWidgetOptions
---@field icon? string
---@field empty? boolean
---@field empty_text? string
---@field cache_key? any
---@field show_session? boolean
---@field show_sync? boolean
---@field show_pending? boolean
---@field show_idle? boolean

---@param current_session? legate.Session
---@return integer
local function pending_count(current_session)
    return current_session ~= nil and #(current_session.pending_approvals or {}) or 0
end

---@param value string?
---@return boolean
local function meaningful_sync_state(value)
    return value ~= nil and value ~= '' and value ~= 'unbound'
end

---@return legate.SessionModule?
local function session_module()
    local ok, module = pcall(require, 'legate.session')
    if ok then
        return module
    end

    return nil
end

---@param group string
---@return boolean
local function highlight_has_foreground(group)
    local ok, definition = pcall(vim.api.nvim_get_hl, 0, {
        name = group,
    })

    return ok and type(definition) == 'table' and definition.fg ~= nil
end

---@return boolean
local function highlights_missing()
    for _, group in ipairs(STATUS_GROUPS) do
        if not highlight_has_foreground(group) then
            return true
        end
    end

    return false
end

local function refresh_highlights()
    if highlights_refreshed and not highlights_missing() then
        return
    end

    local ok, surface = pcall(require, 'legate.ui.surface')
    if ok and type(surface.refresh_highlights) == 'function' then
        surface.refresh_highlights()
        highlights_refreshed = true
    end
end

---@param parts statuesque.RenderSpec[]
---@param text string?
---@param role string
---@param hl? string
local function append_part(parts, text, role, hl)
    if text == nil or text == '' then
        return
    end

    if #parts > 0 then
        text = ' ' .. text
    end

    parts[#parts + 1] = {
        text = text,
        role = role,
        hl = hl,
    }
end

---@param sessions legate.SessionModule
---@return legate.Session?
local function display_session(sessions)
    return sessions.pending_approval_session() or sessions.waiting() or sessions.current()
end

---@param current_session legate.Session
---@param opts legate.StatuesqueWidgetOptions
---@return statuesque.RenderSpec
local function render_session(current_session, opts)
    refresh_highlights()

    local parts = {}
    local approvals = pending_count(current_session)
    local status_hl = 'LegateStatusNeutral'

    if approvals > 0 then
        status_hl = 'LegateStatusWaiting'
    elseif current_session.status == 'waiting' then
        status_hl = 'LegateStatusPending'
    elseif current_session.status == 'cancelled' then
        status_hl = 'LegateStatusFailure'
    elseif current_session.status == 'idle' then
        status_hl = 'LegateStatusSuccess'
    end

    append_part(parts, opts.icon or 'ACP', 'legate.icon', 'LegateStatusPending')
    if opts.show_session ~= false then
        append_part(parts, current_session.id, 'legate.session', 'LegateStatusNeutral')
    end
    append_part(parts, current_session.adapter_name, 'legate.adapter', 'LegateStatusNeutral')

    if approvals > 0 and opts.show_pending ~= false then
        append_part(parts, string.format('approval:%d', approvals), 'legate.approval', status_hl)
    else
        append_part(parts, current_session.status, 'legate.status', status_hl)
    end

    if opts.show_sync ~= false and meaningful_sync_state(current_session.remote_sync_state) then
        append_part(
            parts,
            string.format('sync=%s', current_session.remote_sync_state),
            'legate.sync',
            'LegateStatusNeutral'
        )
    end

    return {
        role = 'legate',
        children = parts,
    }
end

---@param opts? legate.StatuesqueWidgetOptions
---@return statuesque.PublisherComponent
return function(opts)
    opts = opts or {}

    return publisher.new(function()
        local sessions = session_module()

        if sessions == nil then
            return false
        end

        local current_session = display_session(sessions)

        if current_session == nil then
            if opts.empty == false or opts.show_idle == false then
                return false
            end

            refresh_highlights()
            return {
                text = opts.empty_text or 'ACP idle',
                role = 'legate',
                hl = 'LegateStatusNeutral',
            }
        end

        return render_session(current_session, opts)
    end, function(_, notify)
        local group = vim.api.nvim_create_augroup('legate-statuesque-widget', { clear = false })
        vim.api.nvim_create_autocmd('User', {
            group = group,
            pattern = 'LegateSessionChanged',
            callback = notify,
        })
        vim.api.nvim_create_autocmd('ColorScheme', {
            group = group,
            callback = function()
                highlights_refreshed = false
                notify()
            end,
        })
    end, {
        cache = { key = opts.cache_key or 'legate.widget.status' },
    })
end
