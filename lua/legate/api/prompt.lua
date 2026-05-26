local buffer = require('legate.ui.buffer')
local input = require('legate.ui.input')
local render = require('legate.ui.render')

local M = {}

local LOAD_FAILED_RECOVERY_MESSAGE =
    'ACP session is in load_failed recovery state; retry `:LegateLoadSession` or create a fresh remote with `:LegateRebindSession`'

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
    local function assert_nonempty_prompt(prompt)
        if prompt == '' then
            error('ACP prompt is empty')
        end
    end

    ---@param current_session legate.Session
    ---@param prompt string
    local function assert_can_start_turn(current_session, prompt)
        assert_nonempty_prompt(prompt)

        if current_session.status == 'waiting' then
            error('Cannot submit a new ACP prompt while this session already has a running turn')
        end

        if deps.continuity.waiting() ~= nil then
            error('Cannot submit a new ACP prompt while another session turn is still running')
        end

        if current_session.remote_sync_state == 'load_failed' then
            error(LOAD_FAILED_RECOVERY_MESSAGE, 0)
        end
    end

    ---@param current_session legate.Session
    ---@param prompt string
    local function render_if_selected(current_session, prompt)
        local selected_session = deps.continuity.current()

        if buffer.get() ~= nil and selected_session ~= nil and selected_session.id == current_session.id then
            render.render(current_session, prompt)
            input.refresh(current_session, buffer.visible_window())
        end
    end

    ---@param current_session legate.Session
    local function clear_selected_input(current_session)
        local selected_session = deps.continuity.current()

        if selected_session ~= nil and selected_session.id == current_session.id then
            input.set_prompt(buffer.get() or 0, '')
        end
    end

    ---@param current_session legate.Session
    ---@param prompt string
    ---@return legate.Session
    function helper.queue_session_prompt(current_session, prompt)
        assert_nonempty_prompt(prompt)

        current_session = deps.continuity.enqueue_prompt(current_session, prompt)
        clear_selected_input(current_session)
        render_if_selected(current_session, '')

        return current_session
    end

    ---@param current_session legate.Session
    ---@param prompt string
    ---@return legate.Session
    local function start_session_prompt_async(current_session, prompt)
        assert_can_start_turn(current_session, prompt)
        deps.continuity.set_draft_prompt(current_session, prompt)
        current_session = deps.continuity.begin_prompt(current_session, prompt)
        clear_selected_input(current_session)
        local turn_id = deps.continuity.current_turn_id(current_session)

        render_if_selected(current_session, '')

        vim.schedule(function()
            if not deps.continuity.matches_turn(current_session, turn_id) then
                return
            end

            local prepare = deps.transport.prepare_prompt or deps.transport.ensure
            local ok, err = pcall(prepare, current_session)

            if not ok then
                local message = current_session.remote_sync_state == 'load_failed' and LOAD_FAILED_RECOVERY_MESSAGE
                    or tostring(err)

                deps.continuity.append_message(current_session, 'status', message)
                deps.continuity.finish_prompt(current_session, 'cancelled')
                render_if_selected(current_session, current_session.draft_prompt or '')
                vim.notify(message, vim.log.levels.ERROR)
                return
            end

            if not deps.continuity.matches_turn(current_session, turn_id) then
                return
            end

            deps.transport.prompt(current_session, prompt, {
                prepared = true,
                on_finish = function(finished_session, stop_reason)
                    helper.drain_queue(finished_session, stop_reason)
                end,
            })
        end)

        return current_session
    end

    ---@param current_session legate.Session
    ---@param stop_reason? legate.StopReason
    ---@return boolean
    function helper.drain_queue(current_session, stop_reason)
        if vim.in_fast_event() then
            vim.schedule(function()
                helper.drain_queue(current_session, stop_reason)
            end)
            return false
        end

        if stop_reason == 'cancelled' then
            return false
        end

        if current_session.status == 'waiting' or deps.continuity.waiting() ~= nil then
            return false
        end

        local queued_session = current_session
        local prompt = deps.continuity.pop_queued_prompt(queued_session)

        if prompt == nil then
            for _, candidate in ipairs(deps.continuity.list()) do
                if candidate.id ~= current_session.id and deps.continuity.queued_prompt_count(candidate) > 0 then
                    queued_session = candidate
                    prompt = deps.continuity.pop_queued_prompt(candidate)
                    break
                end
            end
        end

        if prompt == nil then
            return false
        end

        start_session_prompt_async(queued_session, prompt)
        return true
    end

    ---@param current_session legate.Session
    ---@param prompt string
    ---@return legate.Session
    function helper.submit_session_prompt(current_session, prompt)
        if current_session.status == 'waiting' or deps.continuity.waiting() ~= nil then
            return helper.queue_session_prompt(current_session, prompt)
        end

        assert_can_start_turn(current_session, prompt)
        deps.continuity.set_draft_prompt(current_session, prompt)
        local prepare = deps.transport.prepare_prompt or deps.transport.ensure
        local ok, err = pcall(prepare, current_session)

        if not ok then
            render_if_selected(current_session, current_session.draft_prompt or prompt)

            if current_session.remote_sync_state == 'load_failed' then
                error(LOAD_FAILED_RECOVERY_MESSAGE, 0)
            end

            error(err, 0)
        end

        current_session = deps.continuity.begin_prompt(current_session, prompt)
        clear_selected_input(current_session)

        render_if_selected(current_session, '')

        deps.transport.prompt(current_session, prompt, {
            prepared = true,
            on_finish = function(finished_session, stop_reason)
                helper.drain_queue(finished_session, stop_reason)
            end,
        })

        return current_session
    end

    ---Submit a prompt while deferring blocking transport startup until after
    ---the chat buffer has rendered the waiting state and Neovim can redraw.
    ---@param current_session legate.Session
    ---@param prompt string
    ---@return legate.Session
    function helper.submit_session_prompt_async(current_session, prompt)
        if current_session.status == 'waiting' or deps.continuity.waiting() ~= nil then
            return helper.queue_session_prompt(current_session, prompt)
        end

        return start_session_prompt_async(current_session, prompt)
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
        else
            deps.continuity.set_draft_prompt(current_session, prompt)
        end

        render.render(current_session, prompt)

        return bufnr, current_session, prompt
    end

    ---@return integer
    function helper.open_chat()
        local bufnr, current_session, prompt = helper.ensure_chat_surface()

        buffer.open()
        render.render(current_session, prompt)
        input.refresh(current_session, vim.api.nvim_get_current_win())
        vim.api.nvim_win_set_cursor(0, {
            vim.api.nvim_buf_line_count(bufnr),
            0,
        })
        require('legate.ui.surface').mark_pinned_to_bottom(vim.api.nvim_get_current_win())

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

    ---@return legate.Session
    function helper.submit_prompt_async()
        local bufnr, current_session = helper.ensure_chat_surface()
        local prompt = input.get_prompt(bufnr)
        return helper.submit_session_prompt_async(current_session, prompt)
    end

    ---@return legate.Session
    function helper.queue_prompt()
        local bufnr, current_session = helper.ensure_chat_surface()
        local prompt = input.get_prompt(bufnr)

        return helper.queue_session_prompt(current_session, prompt)
    end

    ---@return legate.Session
    function helper.steer_prompt()
        local bufnr, current_session = helper.ensure_chat_surface()
        local waiting_session = deps.continuity.waiting()
        local prompt = input.get_prompt(bufnr)

        if current_session.status ~= 'waiting' then
            if waiting_session == nil then
                error('Cannot steer ACP prompt: no prompt turn is running')
            end

            deps.select_session(waiting_session.id)
            current_session = waiting_session
            bufnr = helper.ensure_chat_surface()
        end

        assert_nonempty_prompt(prompt)

        deps.continuity.append_message(current_session, 'user', prompt)
        deps.continuity.set_draft_prompt(current_session, '')
        input.set_prompt(bufnr, '')
        render_if_selected(current_session, '')
        deps.transport.steer(current_session, prompt)

        return current_session
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
            input.set_prompt(buffer.get() or 0, prompt)
            render.render(target_session, prompt)
            input.refresh(target_session, buffer.visible_window())
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
