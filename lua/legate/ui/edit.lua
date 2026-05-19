local buffer = require('legate.ui.buffer')
local input = require('legate.ui.input')
local render = require('legate.ui.render')
local continuity = require('legate.session')

---@class legate.EditModule
local M = {}

---@type table<integer, boolean>
local attached_buffers = {}
local group = vim.api.nvim_create_augroup('legate.edit', {
    clear = false,
})

---@param bufnr integer
local function current_prompt(bufnr)
    return input.capture_prompt(bufnr) or ''
end

---@param bufnr integer
local function restore_chat(bufnr)
    local current_session = continuity.current()

    if current_session == nil then
        return
    end

    render.render(current_session, current_session.draft_prompt)
end

---@param bufnr integer
---@param bufnr integer
---@return boolean
local function can_edit_prompt(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
        return false
    end

    local current_session = continuity.current()

    if current_session == nil or current_session.status == 'waiting' then
        return false
    end

    if input.anchor_row(bufnr) == nil then
        return false
    end

    return vim.api.nvim_win_get_cursor(0)[1] >= input.prompt_start_line(bufnr)
end

---@param bufnr integer
local function update_editability(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    vim.bo[bufnr].modifiable = can_edit_prompt(bufnr)
end

---@param bufnr integer
---@param placement? 'start'|'end'
local function move_cursor_to_prompt(bufnr, placement)
    if placement == 'start' then
        vim.api.nvim_win_set_cursor(0, {
            input.prompt_start_line(bufnr),
            0,
        })
        return
    end

    vim.api.nvim_win_set_cursor(0, input.prompt_end_cursor(bufnr))
end

---@param bufnr integer
---@param firstline integer
local function handle_change(bufnr, firstline)
    if buffer.is_mutating(bufnr) then
        return
    end

    vim.schedule(function()
        buffer.mark_clean(bufnr)
    end)

    local current_session = continuity.current()

    if current_session == nil then
        return
    end

    local anchor_row = input.anchor_row(bufnr)

    if anchor_row == nil then
        return
    end

    if firstline <= anchor_row then
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                restore_chat(bufnr)
            end
        end)
        return
    end

    continuity.set_draft_prompt(current_session, current_prompt(bufnr))
end

---@param bufnr integer
function M.constrain_cursor(bufnr)
    if vim.api.nvim_get_current_buf() ~= bufnr or not vim.api.nvim_get_mode().mode:match('^i') then
        return
    end

    if vim.api.nvim_win_get_cursor(0)[1] < input.prompt_start_line(bufnr) then
        move_cursor_to_prompt(bufnr, 'end')
    end
end

---@param bufnr integer
function M.refresh(bufnr)
    if buffer.is_mutating(bufnr) then
        return
    end

    update_editability(bufnr)
end

---@param bufnr integer
---@param placement? 'start'|'end'
---@param opts? { startinsert?: boolean }
function M.enter_prompt_edit(bufnr, placement, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
        return
    end

    move_cursor_to_prompt(bufnr, placement)
    update_editability(bufnr)

    if opts == nil or opts.startinsert ~= false then
        vim.cmd.startinsert()
    end
end

---@param bufnr integer
function M.leave_prompt_edit(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    vim.bo[bufnr].modifiable = false
end

---Attach buffer-local prompt-edit behavior to the Legate chat buffer.
---@param bufnr integer
function M.attach(bufnr)
    if attached_buffers[bufnr] then
        return
    end

    attached_buffers[bufnr] = true

    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function(_, callback_bufnr, _, firstline, _, _, _)
            if callback_bufnr ~= bufnr then
                return
            end

            handle_change(callback_bufnr, firstline)
        end,
        on_detach = function(_, changed_bufnr)
            attached_buffers[changed_bufnr] = nil
        end,
    })

    vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorMoved', 'InsertLeave' }, {
        group = group,
        buffer = bufnr,
        callback = function()
            M.refresh(bufnr)
        end,
    })
    vim.api.nvim_create_autocmd({ 'CursorMovedI', 'InsertEnter' }, {
        group = group,
        buffer = bufnr,
        callback = function()
            M.constrain_cursor(bufnr)
            M.refresh(bufnr)
        end,
    })

    update_editability(bufnr)
end

return M
