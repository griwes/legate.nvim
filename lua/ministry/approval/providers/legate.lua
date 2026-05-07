local M = {}

local namespace = vim.api.nvim_create_namespace('ministry.approval.legate')

---@class ministry.legate.ProviderState
---@field decision ministry.ApprovalDecision?
---@field active boolean

---@type table<integer, ministry.legate.ProviderState>
local states = {}
---@type table<integer, boolean>
local attached = {}

local wait_timeout_ms = 300000

---@param value any
---@return string
local function inline(value)
    local text = tostring(value or '')
    text = text:gsub('[\r\n]+', ' ')
    text = text:gsub('`', '\\`')
    return string.format('`%s`', text)
end

---@param value any
---@return string
local function inspect_oneline(value)
    local text = vim.inspect(value or {})
    text = text:gsub('[\r\n]+%s*', ' ')
    if #text > 240 then
        return text:sub(1, 237) .. '...'
    end
    return text
end

---@param bufnr integer
---@return boolean
local function valid_buffer(bufnr)
    return type(bufnr) == 'number' and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

---@param bufnr integer
---@return integer
local function approval_anchor(bufnr)
    local ok, input = pcall(require, 'legate.ui.input')
    if ok and type(input.prompt_header_line) == 'function' then
        local prompt_header_line = input.prompt_header_line(bufnr)
        if type(prompt_header_line) == 'number' then
            return math.max(prompt_header_line - 3, 0)
        end
    end

    return math.max(vim.api.nvim_buf_line_count(bufnr) - 1, 0)
end

---@param bufnr integer
---@param decision ministry.ApprovalDecision
local function resolve(bufnr, decision)
    local state = states[bufnr]
    if state == nil or not state.active then
        return
    end

    state.decision = decision
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

    vim.keymap.set('n', 'ga', function()
        resolve(bufnr, 'allow')
    end, {
        buffer = bufnr,
        desc = 'Allow pending Ministry approval',
        silent = true,
    })
    vim.keymap.set('n', 'gr', function()
        resolve(bufnr, 'reject')
    end, {
        buffer = bufnr,
        desc = 'Reject pending Ministry approval',
        silent = true,
    })
    vim.keymap.set('n', ']m', function()
        local anchor = states[bufnr] and states[bufnr].active and approval_anchor(bufnr) or nil
        if anchor ~= nil then
            vim.api.nvim_win_set_cursor(0, { anchor + 1, 0 })
        end
    end, {
        buffer = bufnr,
        desc = 'Jump to the pending Ministry approval',
        silent = true,
    })
end

---@param request ministry.ApprovalRequest
---@return string[][]
local function approval_lines(request)
    return {
        { 'Ministry approval needed', 'Comment' },
        { string.format('? %s', request.namespaced_name), 'Comment' },
        { string.format('Server: %s   Method: %s', inline(request.server), inline(request.method)), 'Comment' },
        { string.format('Arguments: %s', inspect_oneline(request.arguments)), 'Comment' },
        { 'ga allow   gr reject   ]m jump', 'Comment' },
    }
end

---@param bufnr integer
---@param request ministry.ApprovalRequest
local function render(bufnr, request)
    attach(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    local virt_lines = vim.tbl_map(function(line)
        return { line }
    end, approval_lines(request))

    vim.api.nvim_buf_set_extmark(bufnr, namespace, approval_anchor(bufnr), 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
    })
end

---@param bufnr integer
local function clear(bufnr)
    if valid_buffer(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    end

    local state = states[bufnr]
    if state ~= nil then
        state.active = false
        state.decision = nil
    end
end

---@param request ministry.ApprovalRequest
---@return ministry.ApprovalDecision?
function M.request(request)
    local ok, legate = pcall(require, 'legate')
    if not ok or type(legate) ~= 'table' or type(legate.api) ~= 'table' or type(legate.api.open_chat) ~= 'function' then
        return nil
    end

    local bufnr = legate.api.open_chat()
    if not valid_buffer(bufnr) then
        return nil
    end

    local state = states[bufnr]
    if state ~= nil and state.active then
        return nil
    end

    state = {
        active = true,
        decision = nil,
    }
    states[bufnr] = state

    render(bufnr, request)

    vim.wait(wait_timeout_ms, function()
        return state.decision ~= nil or not valid_buffer(bufnr)
    end, 20)

    local decision = state.decision
    clear(bufnr)

    return decision
end

return M
