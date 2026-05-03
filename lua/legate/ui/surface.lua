---@class legate.SurfaceModule
local M = {}

local namespace = vim.api.nvim_create_namespace('legate.surface')
local highlights_ready = false

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
---@field view table

---@param session legate.Session
---@return string
function M.winbar(session)
    local parts = {
        'ACP',
        session.id,
        string.format('adapter=%s', session.adapter_name),
        session.status,
        string.format('sync=%s', session.remote_sync_state),
    }

    if session.remote_id ~= nil then
        table.insert(parts, string.format('remote=%s', session.remote_id))
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

            states[winid] = {
                at_bottom = info ~= nil and info.botline >= line_count,
                cursor = cursor,
                cursor_at_end = cursor[1] >= line_count,
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
        local prompt_header_line = require('legate.ui.input').prompt_header_line(bufnr)
        local waiting_row = math.max(prompt_header_line - 4, 0)
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
            vim.api.nvim_set_option_value('winbar', M.winbar(session), {
                win = winid,
            })
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
                if state.at_bottom and state.cursor_at_end then
                    vim.api.nvim_win_set_cursor(winid, {
                        line_count,
                        0,
                    })
                else
                    vim.api.nvim_win_call(winid, function()
                        vim.fn.winrestview(state.view)
                    end)
                end
            end
        end
    end
end

---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

function M.invalidate_highlights()
    highlights_ready = false
end

return M
