local namespace = vim.api.nvim_create_namespace('acp.prompt')

---@class acp.InputAnchor
---@field row integer

---@class acp.InputModule
local M = {}

---@param bufnr integer
---@return acp.InputAnchor?
local function prompt_anchor(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {
        details = false,
        limit = 1,
    })

    if #marks == 0 then
        return nil
    end

    return {
        row = marks[1][2],
    }
end

---@param bufnr integer
---@return acp.InputAnchor
local function require_prompt_anchor(bufnr)
    local anchor = prompt_anchor(bufnr)

    if anchor == nil then
        error('Prompt anchor is missing from the ACP chat buffer')
    end

    return anchor
end

---Anchor the editable ACP prompt region.
---@param bufnr integer
---@param row integer
function M.set_anchor(bufnr, row)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
        right_gravity = false,
    })
end

---Return the current ACP prompt text if the chat surface exists.
---@param bufnr integer
---@return string?
function M.capture_prompt(bufnr)
    local anchor = prompt_anchor(bufnr)

    if anchor == nil then
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, anchor.row, -1, false)

    return vim.trim(table.concat(lines, '\n'))
end

---Return the current editable ACP prompt text.
---@param bufnr integer
---@return string
function M.get_prompt(bufnr)
    local prompt = M.capture_prompt(bufnr)

    if prompt == nil then
        error('Prompt anchor is missing from the ACP chat buffer')
    end

    return prompt
end

---Replace the editable ACP prompt text.
---@param bufnr integer
---@param text string
function M.set_prompt(bufnr, text)
    local anchor = require_prompt_anchor(bufnr)
    local replacement = vim.split(text, '\n', {
        plain = true,
    })

    if text == '' then
        replacement = { '' }
    end

    vim.api.nvim_buf_set_lines(bufnr, anchor.row, -1, false, replacement)
end

return M
