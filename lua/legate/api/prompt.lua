local buffer = require('legate.ui.buffer')
local input = require('legate.ui.input')
local render = require('legate.ui.render')

local M = {}

---@param deps { continuity: legate.SessionModule, transport: legate.TransportModule, active_session: fun(): legate.Session, store_draft: fun(current_session?: legate.Session), select_session: fun(session_id: string): legate.Session }
---@return table
function M.new(deps)
    local helper = {}

    ---@param current_session legate.Session
    ---@return string
    function helper.visible_prompt(current_session)
        local prompt = current_session.draft_prompt or ''
        local current = deps.continuity.current()

        if current == nil or current.id ~= current_session.id then
            return prompt
        end

        deps.store_draft(current_session)
        return current_session.draft_prompt
    end

    ---@param current_session legate.Session
    ---@param prompt string
    ---@return legate.Session
    function helper.submit_session_prompt(current_session, prompt)
        if current_session.status == 'waiting' then
            error('Cannot submit a new ACP prompt while this session already has a running turn')
        end

        if deps.continuity.waiting() ~= nil then
            error('Cannot submit a new ACP prompt while another session turn is still running')
        end

        if prompt == '' then
            error('ACP prompt is empty')
        end

        if current_session.remote_sync_state == 'load_failed' then
            error(
                'ACP session is in load_failed recovery state; retry `:LegateLoadSession` or create a fresh remote with `:LegateRebindSession`'
            )
        end

        deps.continuity.set_draft_prompt(current_session, prompt)
        deps.transport.ensure(current_session)
        current_session = deps.continuity.begin_prompt(current_session, prompt)

        local selected_session = deps.continuity.current()

        if buffer.get() ~= nil and selected_session ~= nil and selected_session.id == current_session.id then
            render.render(current_session, '')
        end

        deps.transport.prompt(current_session, prompt)

        return current_session
    end

    ---@param command legate.AvailableCommand
    ---@param provided_input? string
    ---@return string
    function helper.slash_command_prompt(command, provided_input)
        local normalized_input = vim.trim(provided_input or '')
        local prompt = string.format('/%s', command.name)

        if type(command.input) == 'table' and normalized_input == '' then
            error(string.format('ACP slash command requires input: /%s', command.name))
        end

        if normalized_input == '' then
            return prompt
        end

        return string.format('%s %s', prompt, normalized_input)
    end

    ---@return integer, legate.Session, string
    function helper.ensure_chat_surface()
        local current_session = deps.active_session()
        local bufnr = buffer.ensure()
        local prompt = input.capture_prompt(bufnr)

        if prompt == nil then
            prompt = current_session.draft_prompt or ''
            render.render(current_session, prompt)
        else
            deps.continuity.set_draft_prompt(current_session, prompt)
        end

        return bufnr, current_session, prompt
    end

    ---@return integer
    function helper.open_chat()
        local bufnr, current_session, prompt = helper.ensure_chat_surface()

        buffer.open()
        render.render(current_session, prompt)
        vim.api.nvim_win_set_cursor(0, {
            vim.api.nvim_buf_line_count(bufnr),
            0,
        })

        local ok, edit = pcall(require, 'legate.ui.edit')

        if ok and type(edit.refresh) == 'function' then
            edit.refresh(bufnr)
        end

        return bufnr
    end

    ---@param role legate.MessageRole
    ---@param text string
    ---@return legate.Session
    function helper.append_message(role, text)
        local _, current_session, prompt = helper.ensure_chat_surface()

        deps.continuity.append_message(current_session, role, text)
        render.render(current_session, prompt)

        return current_session
    end

    ---@return legate.Session
    function helper.submit_prompt()
        local bufnr, current_session = helper.ensure_chat_surface()
        local prompt = input.get_prompt(bufnr)
        return helper.submit_session_prompt(current_session, prompt)
    end

    ---@return legate.Session?
    function helper.cancel_prompt()
        local current_session = deps.continuity.current()
        local waiting_session = deps.continuity.waiting()

        if current_session == nil and waiting_session == nil then
            return nil
        end

        if current_session ~= nil then
            deps.store_draft(current_session)
        end

        local target_session = nil

        if current_session ~= nil and current_session.status == 'waiting' then
            target_session = current_session
        else
            target_session = waiting_session
        end

        if target_session == nil or target_session.status ~= 'waiting' then
            return nil
        end

        if current_session ~= nil and current_session.id ~= target_session.id then
            deps.select_session(target_session.id)
            current_session = deps.continuity.current()
        end

        local prompt = target_session.pending_prompt or target_session.draft_prompt or ''

        deps.transport.cancel(target_session)
        deps.continuity.set_draft_prompt(target_session, prompt)
        target_session = deps.continuity.cancel(target_session)

        if current_session ~= nil and current_session.id == target_session.id then
            render.render(target_session, prompt)
        end

        return target_session
    end

    ---@return string
    function helper.get_prompt()
        local bufnr, current_session = helper.ensure_chat_surface()
        local prompt = input.get_prompt(bufnr)

        deps.continuity.set_draft_prompt(current_session, prompt)

        return prompt
    end

    ---@param text string
    function helper.set_prompt(text)
        local bufnr, current_session = helper.ensure_chat_surface()

        input.set_prompt(bufnr, text)
        deps.continuity.set_draft_prompt(current_session, text)
    end

    return helper
end

return M
