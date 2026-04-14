---@class legate.ApprovalUiModule
local M = {}

local namespace = vim.api.nvim_create_namespace('legate.approval')

---@class legate.PendingApprovalUiState
---@field anchor_row? integer
---@field index_to_option string[]

---@type table<integer, legate.PendingApprovalUiState>
local states = {}
---@type table<integer, boolean>
local attached = {}

local jump_mapping = ']a'

---@param bufnr integer?
---@return boolean
local function valid_buffer(bufnr)
    return type(bufnr) == 'number' and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

---@param index integer
---@return string
local function option_mapping(index)
    return string.format('g%d', index)
end

---@param bufnr integer
---@return legate.PendingApprovalUiState
local function ensure_state(bufnr)
    local state = states[bufnr]

    if state == nil then
        state = {
            index_to_option = {},
        }
        states[bufnr] = state
    end

    return state
end

---@param selection string
local function select_option(selection)
    local ok, err = pcall(function()
        require('legate.api').select_approval_option(selection)
    end)

    if not ok then
        vim.schedule(function()
            vim.notify(err)
        end)
    end
end

---@param bufnr integer
---@param index integer
local function select_index(bufnr, index)
    local state = states[bufnr]

    if state == nil then
        return
    end

    local selection = state.index_to_option[index]

    if selection == nil then
        return
    end

    select_option(selection)
end

---@param bufnr integer
local function jump_to_first_option(bufnr)
    local state = states[bufnr]

    if state == nil or state.anchor_row == nil then
        return
    end

    vim.api.nvim_win_set_cursor(0, {
        state.anchor_row + 1,
        0,
    })
end

---@param bufnr integer
local function attach(bufnr)
    if attached[bufnr] then
        return
    end

    attached[bufnr] = true
    vim.api.nvim_buf_attach(bufnr, false, {
        on_detach = function(_, detached_bufnr)
            attached[detached_bufnr] = nil
            states[detached_bufnr] = nil
        end,
    })

    vim.keymap.set('n', jump_mapping, function()
        jump_to_first_option(bufnr)
    end, {
        buffer = bufnr,
        desc = 'Jump to the pending Legate approval',
        silent = true,
    })

    for index = 1, 9 do
        vim.keymap.set('n', option_mapping(index), function()
            select_index(bufnr, index)
        end, {
            buffer = bufnr,
            desc = string.format('Resolve Legate approval option %d', index),
            silent = true,
        })
    end
end

---@param bufnr integer
function M.clear(bufnr)
    if not valid_buffer(bufnr) then
        states[bufnr] = nil
        attached[bufnr] = nil
        return
    end

    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    local state = states[bufnr]
    if state ~= nil then
        state.index_to_option = {}
        state.anchor_row = nil
    end
end

---@param bufnr integer
---@param current_session legate.Session
---@param pending_approvals legate.PendingApproval[]?
function M.apply(bufnr, current_session, pending_approvals)
    if not valid_buffer(bufnr) then
        return
    end

    attach(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    local state = ensure_state(bufnr)
    state.index_to_option = {}
    state.anchor_row = nil

    pending_approvals = pending_approvals or {}

    if #pending_approvals == 0 then
        return
    end

    local active_pending = pending_approvals[1]
    local prompt_header_line = require('legate.ui.input').prompt_header_line(bufnr)
    local anchor_row = math.max(prompt_header_line - 3, 0)
    local virt_lines =
        require('legate.status_message').pending_approval_virtual_lines(current_session, pending_approvals)

    for index, option in ipairs(active_pending.options) do
        state.index_to_option[index] = string.format('%s:%s', active_pending.request_id, option.optionId)
    end

    state.anchor_row = anchor_row

    vim.api.nvim_buf_set_extmark(bufnr, namespace, anchor_row, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
    })
end

return M
