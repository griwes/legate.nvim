local config = require('acp.config')

---@class acp.BufferModule
local M = {}

---@type acp.BufferState
local state = {
    bufnr = nil,
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
        return bufnr
    end

    bufnr = vim.api.nvim_create_buf(false, true)
    state.bufnr = bufnr
    vim.api.nvim_buf_set_name(bufnr, config.get().chat_buffer_name)
    configure(bufnr)

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

return M
