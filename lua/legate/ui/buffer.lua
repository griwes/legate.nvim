local config = require('legate.config')

---@class legate.BufferModule
local M = {}

---@type legate.BufferState
local state = {
    bufnr = nil,
    mutating = {},
}

---@param session legate.Session
---@return string
local function session_buffer_name(session)
    if session.remote_id ~= nil and session.remote_id ~= '' then
        return string.format('acp://session/remote/%s', session.remote_id)
    end

    return string.format('acp://session/local/%s', session.id)
end

---@param name string
---@return legate.BufferLocator?
local function session_locator_from_name(name)
    local prefix = 'acp://session/'

    if not vim.startswith(name, prefix) then
        return nil
    end

    local rest = name:sub(#prefix + 1)

    if rest == '' then
        return nil
    end

    local parts = vim.split(rest, '/', {
        plain = true,
        trimempty = true,
    })

    if parts[1] == 'pending' then
        return {
            pending = true,
        }
    end

    if #parts == 1 then
        return {
            local_id = parts[1],
        }
    end

    local locator = {}
    local index = 1

    while index < #parts do
        local key = parts[index]
        local value = parts[index + 1]

        if value == nil then
            return nil
        end

        if key == 'local' then
            locator.local_id = value
        elseif key == 'remote' then
            locator.remote_id = value
        else
            return nil
        end

        index = index + 2
    end

    if locator.local_id == nil and locator.remote_id == nil then
        return nil
    end

    return locator
end

---@return string
local function pending_buffer_name()
    return 'acp://session/pending'
end

---@param name string
---@return boolean
local function is_acp_buffer_name(name)
    return name == config.get().chat_buffer_name or session_locator_from_name(name) ~= nil
end

---@param bufnr integer
---@return boolean
local function is_chat_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local name = vim.api.nvim_buf_get_name(bufnr)

    if not is_acp_buffer_name(name) then
        return false
    end

    return vim.bo[bufnr].buftype == 'nofile' and not vim.bo[bufnr].swapfile
end

---@param bufnr integer
---@return boolean
local function is_session_uri_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    return session_locator_from_name(vim.api.nvim_buf_get_name(bufnr)) ~= nil
end

---@param keep_bufnr? integer
local function purge_stale_buffers(keep_bufnr)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if bufnr ~= keep_bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)

            if is_acp_buffer_name(name) and not is_chat_buffer(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, {
                    force = true,
                })
            end
        end
    end
end

---@param bufnr integer
local function configure(bufnr)
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].filetype = config.get().filetype
    vim.bo[bufnr].omnifunc = "v:lua.require'legate.ui.completion'.complete"
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
end

---@param bufnr integer
local function attach_prompt_guard(bufnr)
    local ok, edit = pcall(require, 'legate.ui.edit')

    if ok and type(edit.attach) == 'function' then
        edit.attach(bufnr)
    end
end

---@param bufnr integer
local function attach_hover_lsp(bufnr)
    if not config.get().enable_hover_lsp then
        return
    end

    local ok, hover_lsp = pcall(require, 'legate.ui.hover_lsp')

    if ok and type(hover_lsp.attach) == 'function' then
        hover_lsp.attach(bufnr)
    end
end

---@param bufnr integer
---@return boolean
local function visible_in_any_window(bufnr)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
            return true
        end
    end

    return false
end

---@param bufnr integer
---@return boolean
local function is_empty_placeholder(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    return vim.api.nvim_buf_get_name(bufnr) == ''
        and vim.bo[bufnr].buftype == ''
        and not vim.bo[bufnr].modified
        and vim.api.nvim_buf_line_count(bufnr) == 1
        and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ''
end

---@return integer?
local function find_existing()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if is_chat_buffer(bufnr) then
            return bufnr
        end
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if is_session_uri_buffer(bufnr) then
            configure(bufnr)
            attach_prompt_guard(bufnr)
            attach_hover_lsp(bufnr)
            return bufnr
        end
    end

    return nil
end

---@param bufnr integer
---@param session legate.Session
function M.set_session_name(bufnr, session)
    local target = session_buffer_name(session)

    if vim.api.nvim_buf_get_name(bufnr) ~= target then
        vim.api.nvim_buf_set_name(bufnr, target)
    end

    purge_stale_buffers(bufnr)
end

---@param bufnr integer
---@return legate.BufferLocator?
function M.session_locator(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    return session_locator_from_name(vim.api.nvim_buf_get_name(bufnr))
end

---@param bufnr integer
---@return string?
function M.session_id(bufnr)
    local locator = M.session_locator(bufnr)

    return locator and locator.local_id or nil
end

---@return integer?
function M.get()
    if state.bufnr ~= nil and vim.api.nvim_buf_is_valid(state.bufnr) then
        return state.bufnr
    end

    state.bufnr = find_existing()
    purge_stale_buffers(state.bufnr)
    return state.bufnr
end

---Create or reuse the ACP chat buffer.
---@return integer
function M.ensure()
    local bufnr = M.get()

    if bufnr ~= nil then
        attach_prompt_guard(bufnr)
        attach_hover_lsp(bufnr)
        return bufnr
    end

    bufnr = vim.api.nvim_create_buf(false, true)
    state.bufnr = bufnr
    configure(bufnr)
    vim.api.nvim_buf_set_name(bufnr, pending_buffer_name())
    purge_stale_buffers(bufnr)
    attach_prompt_guard(bufnr)
    attach_hover_lsp(bufnr)

    return bufnr
end

---Show the ACP chat buffer in the current window.
---@return integer
function M.open()
    local bufnr = M.ensure()

    vim.api.nvim_win_set_buf(0, bufnr)

    return bufnr
end

---@param bufnr? integer
---@return boolean
function M.reveal_in_placeholder(bufnr)
    if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    if visible_in_any_window(bufnr) then
        return true
    end

    local current = vim.api.nvim_get_current_buf()

    if not is_empty_placeholder(current) then
        return false
    end

    vim.api.nvim_win_set_buf(0, bufnr)
    pcall(vim.api.nvim_buf_delete, current, {
        force = true,
    })
    return true
end

---Forget buffer state and close the ACP chat buffer if it exists.
function M.clear()
    local bufnr = M.get()

    state.bufnr = nil

    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
        local ok, approval_ui = pcall(require, 'legate.ui.approval')

        if ok and type(approval_ui.clear) == 'function' then
            approval_ui.clear(bufnr)
        end

        local ok, hover = pcall(require, 'legate.ui.hover')

        if ok and type(hover.clear) == 'function' then
            hover.clear(bufnr)
        end

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
    M.mark_clean(bufnr)
    state.mutating[bufnr] = state.mutating[bufnr] - 1

    if state.mutating[bufnr] <= 0 then
        state.mutating[bufnr] = nil
    end

    if not ok then
        error(err, 0)
    end
end

---@param bufnr integer
function M.mark_clean(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    if not is_acp_buffer_name(vim.api.nvim_buf_get_name(bufnr)) then
        return
    end

    vim.bo[bufnr].modified = false
end

---@param bufnr integer
---@return boolean
function M.is_mutating(bufnr)
    return (state.mutating[bufnr] or 0) > 0
end

return M
