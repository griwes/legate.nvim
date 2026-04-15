local formatters = require('legate.api.formatters')

local M = {}

---@param sessions legate.Session[]
---@param selected_session legate.Session?
---@param prompt string
---@param on_choice fun(selected_session: legate.Session)
function M.pick_session(sessions, selected_session, prompt, on_choice)
    if #sessions == 0 then
        vim.notify('No ACP sessions exist')
        return
    end

    vim.ui.select(sessions, {
        prompt = prompt,
        format_item = function(item)
            return formatters.session_line(item, selected_session)
        end,
    }, function(chosen_session)
        if chosen_session == nil then
            return
        end

        on_choice(chosen_session)
    end)
end

return M
