---@class acp.SurfaceModule
local M = {}

local namespace = vim.api.nvim_create_namespace('acp.surface')

---@class acp.WindowRenderState
---@field at_bottom boolean
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

            states[winid] = {
                at_bottom = info ~= nil and info.botline >= line_count,
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
function M.decorate(bufnr, session)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    if session.status == 'waiting' then
        local prompt_header_line = require('acp.input').prompt_header_line(bufnr)
        local waiting_row = math.max(prompt_header_line - 4, 0)

        vim.api.nvim_buf_set_extmark(bufnr, namespace, waiting_row, 0, {
            virt_text = {
                { 'Working...', 'Comment' },
            },
            virt_text_pos = 'overlay',
        })
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
                if state.at_bottom then
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

return M
