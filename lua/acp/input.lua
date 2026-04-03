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

---Anchor the ACP prompt header line. The editable prompt body starts below it.
---@param bufnr integer
---@param row integer
function M.set_anchor(bufnr, row)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
        right_gravity = false,
    })
end

---Return the anchored prompt row if the chat surface exists.
---@param bufnr integer
---@return integer?
function M.anchor_row(bufnr)
    local anchor = prompt_anchor(bufnr)

    if anchor == nil then
        return nil
    end

    return anchor.row
end

---Return the 1-based prompt header line.
---@param bufnr integer
---@return integer
function M.prompt_header_line(bufnr)
    return require_prompt_anchor(bufnr).row + 1
end

---Return the 1-based first editable prompt line.
---@param bufnr integer
---@return integer
function M.prompt_start_line(bufnr)
    return M.prompt_header_line(bufnr) + 1
end

---Return the 1-based last editable prompt line.
---@param bufnr integer
---@return integer
function M.prompt_end_line(bufnr)
    return vim.api.nvim_buf_line_count(bufnr)
end

---Return the end-of-prompt cursor position.
---@param bufnr integer
---@return integer[]
function M.prompt_end_cursor(bufnr)
    local last_line = M.prompt_end_line(bufnr)
    local text = vim.api.nvim_buf_get_lines(bufnr, last_line - 1, last_line, false)[1] or ''

    return { last_line, #text }
end

---Return the current ACP prompt text if the chat surface exists.
---@param bufnr integer
---@return string?
function M.capture_prompt(bufnr)
    local anchor = prompt_anchor(bufnr)

    if anchor == nil then
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, anchor.row + 1, -1, false)

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

    require('acp.buffer').with_mutation(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, anchor.row + 1, -1, false, replacement)
    end)
end

return M
