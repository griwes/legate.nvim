local buffer = require('legate.ui.buffer')
local sessions = require('legate.session')
local surface = require('legate.ui.surface')

---@class legate.WinbarModule
local M = {}

local SIGIL = '󰚩'
local EXPRESSION = "%!v:lua.require'legate.ui.winbar'.render()"

---@param session legate.Session
---@return statuesque.RenderSpec
local function render_spec(session)
    return {
        left = {
            {
                role = 'legate',
                children = surface.winbar_parts(session),
            },
        },
    }
end

---@param bufnr integer
---@return legate.Session?
local function session_for_buffer(bufnr)
    local locator = buffer.session_locator(bufnr)

    if locator == nil then
        return nil
    end

    if locator.local_id ~= nil then
        local current_session = sessions.get(locator.local_id)

        if current_session ~= nil then
            return current_session
        end
    end

    if locator.remote_id ~= nil then
        for _, current_session in ipairs(sessions.list()) do
            if
                current_session.remote_id == locator.remote_id
                or current_session.transport_remote_id == locator.remote_id
            then
                return current_session
            end
        end
    end

    return sessions.current()
end

---@param winid integer?
---@return integer
local function resolve_window(winid)
    winid = tonumber(winid or vim.g.statusline_winid)

    if winid ~= nil and vim.api.nvim_win_is_valid(winid) then
        return winid
    end

    return vim.api.nvim_get_current_win()
end

---@return string
function M.expression()
    return EXPRESSION
end

---@param winid? integer
---@return string
function M.render(winid)
    winid = resolve_window(winid)

    local current_session = session_for_buffer(vim.api.nvim_win_get_buf(winid))

    if current_session == nil then
        current_session = sessions.current()
    end

    if current_session == nil then
        return ''
    end

    local ok, statuesque = pcall(require, 'statuesque')

    if not ok or type(statuesque.compose) ~= 'function' or type(statuesque.render) ~= 'function' then
        return surface.winbar(current_session)
    end

    local composed = statuesque.compose(render_spec(current_session), {
        surface = 'winbar',
        sigil = SIGIL,
    })

    return statuesque.render(composed, 'winbar', {
        surface = 'winbar',
        winid = winid,
    })
end

---@param bufnr integer
---@param session? legate.Session
function M.install(bufnr, session)
    local ok, statuesque = pcall(require, 'statuesque')

    if ok and type(statuesque.replace_window_surface) == 'function' then
        statuesque.replace_window_surface({
            owner = 'legate',
            target = 'winbar',
            bufnr = bufnr,
            expression = EXPRESSION,
            all_windows = true,
        })
        return
    end

    local winbar = session ~= nil and surface.winbar(session) or EXPRESSION

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            vim.wo[winid].winbar = winbar
        end
    end
end

---@param bufnr integer
function M.clear(bufnr)
    local ok, statuesque = pcall(require, 'statuesque')

    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            if ok and type(statuesque.clear_window_surface) == 'function' then
                statuesque.clear_window_surface(winid, 'winbar')
            else
                vim.wo[winid].winbar = ''
            end
        end
    end
end

return M
