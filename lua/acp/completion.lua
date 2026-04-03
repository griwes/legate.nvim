local input = require('acp.input')
local session = require('acp.session')

---@class acp.CompletionModule
local M = {}

---@param command acp.AvailableCommand
---@return string
local function completion_info(command)
    local lines = {
        string.format('/%s', command.name),
        command.description,
    }

    if type(command.input) == 'table' and command.input.hint ~= nil and command.input.hint ~= '' then
        table.insert(lines, '')
        table.insert(lines, string.format('Input: %s', command.input.hint))
    end

    return table.concat(lines, '\n')
end

---@return acp.AvailableCommand[]
local function available_commands()
    local current_session = session.current()

    if current_session == nil then
        return {}
    end

    if #current_session.available_commands == 0 then
        local ok, api = pcall(require, 'acp.api')

        if ok then
            pcall(api.slash_commands, current_session.id)
        end
    end

    return current_session.available_commands
end

---@param bufnr integer
---@return integer, string?
local function slash_start_column(bufnr)
    if vim.api.nvim_get_current_buf() ~= bufnr then
        return -3, nil
    end

    local cursor = vim.api.nvim_win_get_cursor(0)

    if cursor[1] < input.prompt_start_line(bufnr) then
        return -3, nil
    end

    local line = vim.api.nvim_get_current_line()
    local before_cursor = line:sub(1, cursor[2])
    local slash_start = before_cursor:find('/[^%s]*$')

    if slash_start == nil then
        return -3, nil
    end

    if before_cursor:sub(1, slash_start - 1):match('%S') then
        return -3, nil
    end

    return slash_start - 1, before_cursor
end

---ACP omnifunc for slash-command completion inside the prompt region.
---@param findstart 0|1
---@param base string
---@return integer|table[]
function M.complete(findstart, base)
    local bufnr = vim.api.nvim_get_current_buf()
    local start_col = slash_start_column(bufnr)

    if type(start_col) ~= 'number' or start_col < 0 then
        return findstart == 1 and -3 or {}
    end

    if findstart == 1 then
        return start_col
    end

    local prefix = base:gsub('^/', '')
    local items = {}

    for _, command in ipairs(available_commands()) do
        if prefix == '' or vim.startswith(command.name, prefix) then
            table.insert(items, {
                word = string.format('/%s', command.name),
                abbr = string.format('/%s', command.name),
                menu = 'ACP Slash',
                info = completion_info(command),
            })
        end
    end

    table.sort(items, function(left, right)
        return left.word < right.word
    end)

    return items
end

return M
