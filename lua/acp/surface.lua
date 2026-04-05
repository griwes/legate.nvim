---@class acp.SurfaceModule
local M = {}

local namespace = vim.api.nvim_create_namespace('acp.surface')
local highlights_ready = false

---@class acp.HighlightPalette
---@field success integer
---@field failure integer
---@field pending integer
---@field waiting integer
---@field neutral integer

---@param group string
---@return table?
local function highlight_definition(group)
    local ok, definition = pcall(vim.api.nvim_get_hl, 0, {
        name = group,
    })

    if not ok then
        return nil
    end

    return definition
end

---@param groups string[]
---@return integer?
local function first_foreground(groups)
    for _, group in ipairs(groups) do
        local definition = highlight_definition(group)

        if definition ~= nil and definition.fg ~= nil then
            return definition.fg
        end
    end

    return nil
end

---@return acp.HighlightPalette
local function resolve_palette()
    return {
        success = first_foreground({
            'DiagnosticOk',
            'String',
            'MoreMsg',
            'Question',
        }) or 0x98C379,
        failure = first_foreground({
            'DiagnosticError',
            'ErrorMsg',
            'SpellBad',
        }) or 0xE06C75,
        pending = first_foreground({
            'DiagnosticInfo',
            'Directory',
            'Function',
            'Identifier',
        }) or 0x61AFEF,
        waiting = first_foreground({
            'DiagnosticWarn',
            'WarningMsg',
            'Special',
        }) or 0xE5C07B,
        neutral = first_foreground({
            'Comment',
            'LineNr',
            'NonText',
            'Normal',
        }) or 0x7F848E,
    }
end

local function apply_highlights()
    local palette = resolve_palette()
    local groups = {
        ACPStatusSuccess = palette.success,
        ACPStatusFailure = palette.failure,
        ACPStatusPending = palette.pending,
        ACPStatusWaiting = palette.waiting,
        ACPStatusNeutral = palette.neutral,
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

---@class acp.WindowRenderState
---@field at_bottom boolean
---@field cursor integer[]
---@field cursor_at_end boolean
---@field view table

---@param session acp.Session
---@return string
function M.winbar(session)
    local parts = {
        'ACP',
        session.id,
        session.status,
        string.format('sync=%s', session.remote_sync_state),
    }

    if session.remote_id ~= nil then
        table.insert(parts, string.format('remote=%s', session.remote_id))
    end

    return table.concat(parts, '  ')
end

---@param bufnr integer
---@return table<integer, acp.WindowRenderState>
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
---@param session acp.Session
---@param status_rows acp.RenderStatusRow[]
function M.decorate(bufnr, session, status_rows)
    status_rows = status_rows or {}

    ensure_highlights()
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    if session.status == 'waiting' then
        local prompt_header_line = require('acp.input').prompt_header_line(bufnr)
        local waiting_row = math.max(prompt_header_line - 4, 0)
        local waiting_text = 'Working...'

        local pending_approval = require('acp.session').pending_approval(session)

        if pending_approval ~= nil then
            waiting_text = require('acp.status_message').pending_approval_overlay_text(session, pending_approval)
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
---@param states table<integer, acp.WindowRenderState>
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
