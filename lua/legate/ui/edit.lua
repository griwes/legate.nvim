local buffer = require('legate.ui.buffer')
local continuity = require('legate.session')
local input = require('legate.ui.input')
local render = require('legate.ui.render')

---@class legate.EditModule
local M = {}

---@type table<integer, boolean>
local attached_buffers = {}
local group = vim.api.nvim_create_augroup('legate.edit', {
    clear = false,
})

---@param bufnr integer
local function restore_chat(bufnr)
    local current_session = continuity.current()

    if current_session == nil then
        return
    end

    render.render(current_session, current_session.draft_prompt)
end

---@param bufnr integer
local function update_editability(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
end

---@param bufnr integer
local function handle_change(bufnr)
    if buffer.is_mutating(bufnr) then
        return
    end

    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            restore_chat(bufnr)
            update_editability(bufnr)
        end
    end)
end

---@param bufnr integer
function M.constrain_cursor(bufnr)
    update_editability(bufnr)
end

---@param bufnr integer
function M.refresh(bufnr)
    update_editability(bufnr)
end

---@param bufnr integer
---@param placement? 'start'|'end'
---@param opts? { startinsert?: boolean }
function M.enter_prompt_edit(bufnr, placement, opts)
    local session = continuity.current()

    if session == nil then
        return
    end

    input.open_input(session, buffer.visible_window())

    if opts == nil or opts.startinsert ~= false then
        vim.cmd.startinsert()
    end
end

---@param bufnr integer
function M.leave_prompt_edit(bufnr)
    update_editability(bufnr)
end

---Attach transcript repair behavior to the Legate chat buffer.
---@param bufnr integer
function M.attach(bufnr)
    if attached_buffers[bufnr] then
        update_editability(bufnr)
        return
    end

    attached_buffers[bufnr] = true

    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function(_, callback_bufnr)
            if callback_bufnr == bufnr then
                handle_change(callback_bufnr)
            end
        end,
        on_detach = function(_, changed_bufnr)
            attached_buffers[changed_bufnr] = nil
        end,
    })

    vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorMoved', 'InsertLeave', 'InsertEnter' }, {
        group = group,
        buffer = bufnr,
        callback = function()
            M.refresh(bufnr)
        end,
    })

    vim.keymap.set('n', '<Esc>', function()
        M.enter_prompt_edit(bufnr, 'end', {
            startinsert = false,
        })
    end, {
        buffer = bufnr,
        desc = 'Open Legate input split',
    })

    update_editability(bufnr)
end

return M
