---@class legate.SurfaceModule
local M = {}

local namespace = vim.api.nvim_create_namespace('legate.surface')
local highlights_ready = false
local PIN_BOTTOM_KEY = 'legate_chat_pin_bottom'

---@class legate.HighlightPalette
---@field success integer
---@field failure integer
---@field pending integer
---@field waiting integer
---@field neutral integer

---@return legate.HighlightPalette
local function resolve_palette()
    return {
        success = 0x98C379,
        failure = 0xE06C75,
        pending = 0x61AFEF,
        waiting = 0xE5C07B,
        neutral = 0x7F848E,
    }
end

local function apply_highlights()
    local palette = resolve_palette()
    local groups = {
        LegateStatusSuccess = palette.success,
        LegateStatusFailure = palette.failure,
        LegateStatusPending = palette.pending,
        LegateStatusWaiting = palette.waiting,
        LegateStatusNeutral = palette.neutral,
    }

    for group, fg in pairs(groups) do
        vim.api.nvim_set_hl(0, group, {
            fg = fg,
        })
    end

    highlights_ready = true
end

function M.refresh_highlights()
    apply_highlights()
end

local function ensure_highlights()
    if not highlights_ready then
        apply_highlights()
    end
end

---@class legate.WindowRenderState
---@field at_bottom boolean
---@field cursor integer[]
---@field cursor_at_end boolean
---@field pin_to_bottom boolean
---@field view table

---@param session legate.Session
---@return statuesque.RenderSpec[]
function M.winbar_parts(session)
    local parts = {
        { text = 'ACP', role = 'legate.icon', hl = 'LegateStatusPending' },
        { text = ' ' .. session.id, role = 'legate.session', hl = 'LegateStatusNeutral' },
        {
            text = string.format(' adapter=%s', session.adapter_name),
            role = 'legate.adapter',
            hl = 'LegateStatusNeutral',
        },
        { text = ' ' .. session.status, role = 'legate.status', hl = 'LegateStatusSuccess' },
        {
            text = string.format(' sync=%s', session.remote_sync_state),
            role = 'legate.sync',
            hl = 'LegateStatusNeutral',
        },
    }

    if session.remote_id ~= nil then
        table.insert(parts, {
            text = string.format(' remote=%s', session.remote_id),
            role = 'legate.remote',
            hl = 'LegateStatusNeutral',
        })
    end

    if session.status == 'waiting' then
        parts[4].hl = 'LegateStatusPending'
    elseif session.status == 'cancelled' then
        parts[4].hl = 'LegateStatusFailure'
    end

    return parts
end

---@param session legate.Session
---@return string
function M.winbar(session)
    local parts = {}

    for _, part in ipairs(M.winbar_parts(session)) do
        parts[#parts + 1] = vim.trim(part.text or '')
    end

    return table.concat(parts, '  ')
end

---@param bufnr integer
---@return table<integer, legate.WindowRenderState>
function M.capture_window_states(bufnr)
    local states = {}
    local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)

    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            local info = vim.fn.getwininfo(winid)[1]
            local cursor = vim.api.nvim_win_get_cursor(winid)
            local at_bottom = info ~= nil and info.botline >= line_count
            local cursor_at_end = cursor[1] >= line_count
            local scrolled_to_bottom = at_bottom and info ~= nil and info.topline > 1
            local pin_to_bottom = cursor_at_end or scrolled_to_bottom

            if pin_to_bottom then
                vim.w[winid][PIN_BOTTOM_KEY] = true
            else
                vim.w[winid][PIN_BOTTOM_KEY] = false
            end

            states[winid] = {
                at_bottom = at_bottom,
                cursor = cursor,
                cursor_at_end = cursor_at_end,
                pin_to_bottom = pin_to_bottom,
                view = vim.api.nvim_win_call(winid, function()
                    return vim.fn.winsaveview()
                end),
            }
        end
    end

    return states
end

---@param bufnr integer
---@param session legate.Session
---@param status_rows legate.RenderStatusRow[]
function M.decorate(bufnr, session, status_rows)
    status_rows = status_rows or {}

    ensure_highlights()
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    if session.status == 'waiting' then
        local waiting_row = math.max(vim.api.nvim_buf_line_count(bufnr) - 1, 0)
        local waiting_text = 'Working...'

        local pending_approval = require('legate.session').pending_approval(session)

        if pending_approval ~= nil then
            waiting_text = require('legate.status_message').pending_approval_overlay_text(session, pending_approval)
        end

        vim.api.nvim_buf_set_extmark(bufnr, namespace, waiting_row, 0, {
            virt_text = {
                { waiting_text, 'Comment' },
            },
            virt_text_pos = 'overlay',
        })
    end

    for _, entry in ipairs(status_rows) do
        for _, highlight in ipairs(entry.summary.highlights or {}) do
            vim.api.nvim_buf_set_extmark(bufnr, namespace, entry.row - 1, highlight.start_col, {
                end_col = highlight.end_col,
                hl_group = highlight.group,
            })
        end
    end

    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            require('legate.ui.winbar').install(bufnr, session)
        end
    end
end

---@param bufnr integer
---@param states table<integer, legate.WindowRenderState>
function M.restore_window_states(bufnr, states)
    local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)

    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            local state = states[winid]

            if state ~= nil then
                if state.at_bottom and state.pin_to_bottom then
                    vim.api.nvim_win_set_cursor(winid, {
                        line_count,
                        0,
                    })
                    vim.w[winid][PIN_BOTTOM_KEY] = true
                elseif type(state.view) == 'table' then
                    vim.api.nvim_win_call(winid, function()
                        pcall(vim.fn.winrestview, state.view)
                    end)
                    vim.w[winid][PIN_BOTTOM_KEY] = false
                end
            end
        end
    end
end

---@param winid integer
function M.mark_pinned_to_bottom(winid)
    if vim.api.nvim_win_is_valid(winid) then
        vim.w[winid][PIN_BOTTOM_KEY] = true
    end
end

---@param winid integer
---@return boolean
function M.is_pinned_to_bottom(winid)
    return vim.api.nvim_win_is_valid(winid) and vim.w[winid][PIN_BOTTOM_KEY] == true
end

---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

function M.invalidate_highlights()
    highlights_ready = false
end

return M
