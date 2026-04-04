---@class acp.ApprovalUiModule
local M = {}

local namespace = vim.api.nvim_create_namespace('acp.approval')

---@class acp.PendingApprovalUiState
---@field anchor_row? integer
---@field index_to_option string[]

---@type table<integer, acp.PendingApprovalUiState>
local states = {}
---@type table<integer, boolean>
local attached = {}

---@param index integer
---@return string
local function option_mapping(index)
    return string.format('g%d', index)
end

---@param bufnr integer
---@return acp.PendingApprovalUiState
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

---@param option_id string
local function select_option(option_id)
    local ok, err = pcall(function()
        require('acp.api').select_approval_option(option_id)
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

    local option_id = state.index_to_option[index]

    if option_id == nil then
        return
    end

    select_option(option_id)
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

    vim.keymap.set('n', ']a', function()
        jump_to_first_option(bufnr)
    end, {
        buffer = bufnr,
        desc = 'Jump to the pending ACP approval',
        silent = true,
    })

    for index = 1, 9 do
        vim.keymap.set('n', option_mapping(index), function()
            select_index(bufnr, index)
        end, {
            buffer = bufnr,
            desc = string.format('Resolve ACP approval option %d', index),
            silent = true,
        })
    end
end

---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    attached[bufnr] = nil
    states[bufnr] = nil
end

---@param bufnr integer
---@param current_session acp.Session
---@param pending acp.PendingApproval?
function M.apply(bufnr, current_session, pending)
    attach(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    local state = ensure_state(bufnr)
    state.index_to_option = {}
    state.anchor_row = nil

    if pending == nil then
        return
    end

    local prompt_header_line = require('acp.input').prompt_header_line(bufnr)
    local anchor_row = math.max(prompt_header_line - 3, 0)
    local virt_lines = require('acp.status_message').pending_approval_virtual_lines(current_session, pending)

    for index, option in ipairs(pending.options) do
        state.index_to_option[index] = option.optionId
    end

    state.anchor_row = anchor_row

    vim.api.nvim_buf_set_extmark(bufnr, namespace, anchor_row, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
    })
end

return M
