local config = require('acp.config')

---@class acp.BufferModule
local M = {}

---@type acp.BufferState
local state = {
    bufnr = nil,
    mutating = {},
}

---@return integer?
local function find_existing()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == config.get().chat_buffer_name then
            return bufnr
        end
    end

    return nil
end

---@param bufnr integer
local function configure(bufnr)
    vim.api.nvim_set_option_value('buftype', 'nofile', {
        buf = bufnr,
    })
    vim.api.nvim_set_option_value('bufhidden', 'hide', {
        buf = bufnr,
    })
    vim.api.nvim_set_option_value('swapfile', false, {
        buf = bufnr,
    })
    vim.api.nvim_set_option_value('filetype', config.get().filetype, {
        buf = bufnr,
    })
    vim.api.nvim_set_option_value('omnifunc', "v:lua.require'acp.completion'.complete", {
        buf = bufnr,
    })
    vim.api.nvim_set_option_value('modifiable', false, {
        buf = bufnr,
    })
end

local function attach_prompt_guard(bufnr)
    local ok, edit = pcall(require, 'acp.edit')

    if ok and type(edit.attach) == 'function' then
        edit.attach(bufnr)
    end
end

---Return the ACP chat buffer when it exists and is valid.
---@return integer?
function M.get()
    if state.bufnr ~= nil and vim.api.nvim_buf_is_valid(state.bufnr) then
        return state.bufnr
    end

    state.bufnr = find_existing()
    return state.bufnr
end

---Create or reuse the ACP chat buffer.
---@return integer
function M.ensure()
    local bufnr = M.get()

    if bufnr ~= nil then
        attach_prompt_guard(bufnr)
        return bufnr
    end

    bufnr = vim.api.nvim_create_buf(false, true)
    state.bufnr = bufnr
    vim.api.nvim_buf_set_name(bufnr, config.get().chat_buffer_name)
    configure(bufnr)
    attach_prompt_guard(bufnr)

    return bufnr
end

---Show the ACP chat buffer in the current window.
---@return integer
function M.open()
    local bufnr = M.ensure()

    vim.api.nvim_win_set_buf(0, bufnr)

    return bufnr
end

---Forget buffer state and close the ACP chat buffer if it exists.
function M.clear()
    local bufnr = M.get()

    state.bufnr = nil

    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, {
            force = true,
        })
    end
end

---@param bufnr integer
---@param callback fun()
function M.with_mutation(bufnr, callback)
    state.mutating[bufnr] = (state.mutating[bufnr] or 0) + 1
    local was_modifiable = vim.bo[bufnr].modifiable

    if not was_modifiable then
        vim.bo[bufnr].modifiable = true
    end

    local ok, err = pcall(callback)

    vim.bo[bufnr].modifiable = was_modifiable
    state.mutating[bufnr] = state.mutating[bufnr] - 1

    if state.mutating[bufnr] <= 0 then
        state.mutating[bufnr] = nil
    end

    if not ok then
        error(err, 0)
    end
end

---@param bufnr integer
---@return boolean
function M.is_mutating(bufnr)
    return (state.mutating[bufnr] or 0) > 0
end

return M
