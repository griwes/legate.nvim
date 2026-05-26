local config = require('legate.config')

---@class legate.InputSurfaceState
---@field bufnr? integer
---@field winid? integer
---@field session_id? string

---@class legate.InputModule
local M = {}

local group = vim.api.nvim_create_augroup('legate.input', {
    clear = false,
})
local lifecycle_group = vim.api.nvim_create_augroup('legate.input.lifecycle', {
    clear = false,
})

---@type table<'input'|'queue', legate.InputSurfaceState>
local surfaces = {
    input = {},
    queue = {},
}

---@type table<integer, integer>
local mutating = {}

---@param session legate.Session
---@param role 'input'|'queue'
---@return string
local function surface_name(session, role)
    return string.format('legate://surface/%s/%s', session.id, role)
end

---@param bufnr integer?
---@return boolean
local function valid_buf(bufnr)
    return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---@param winid integer?
---@return boolean
local function valid_win(winid)
    return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

---@param session legate.Session
---@param role 'input'|'queue'
---@return integer?
local function find_surface_buffer(session, role)
    local name = surface_name(session, role)

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
            return bufnr
        end
    end

    return nil
end

---@param role 'input'|'queue'
---@param session_id string
---@return integer?
local function find_surface_window(role, session_id)
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if
            vim.api.nvim_win_is_valid(winid)
            and vim.w[winid].legate_surface_role == role
            and vim.w[winid].legate_surface_session_id == session_id
        then
            return winid
        end
    end

    return nil
end

---@param text string?
---@return string[]
local function text_lines(text)
    if text == nil or text == '' then
        return { '' }
    end

    return vim.split(text, '\n', {
        plain = true,
    })
end

---@param bufnr integer
---@return string
local function buffer_text(bufnr)
    if not valid_buf(bufnr) then
        return ''
    end

    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n'))
end

---@param bufnr integer
---@param callback fun()
local function with_surface_mutation(bufnr, callback)
    mutating[bufnr] = (mutating[bufnr] or 0) + 1
    local was_modifiable = vim.bo[bufnr].modifiable

    if not was_modifiable then
        vim.bo[bufnr].modifiable = true
    end

    local ok, err = pcall(callback)

    vim.bo[bufnr].modifiable = was_modifiable
    vim.bo[bufnr].modified = false
    mutating[bufnr] = mutating[bufnr] - 1

    if mutating[bufnr] <= 0 then
        mutating[bufnr] = nil
    end

    if not ok then
        error(err, 0)
    end
end

---@param bufnr integer
---@param text string?
local function set_buffer_text(bufnr, text)
    local lines = text_lines(text)

    with_surface_mutation(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)
end

---@param header string
---@return string
local function header_label(header)
    return (header:gsub('^#+%s*', ''):gsub('%s*$', ''))
end

---@param role 'input'|'queue'
---@return string
local function role_winbar(role)
    if role == 'input' then
        return header_label(config.get().input_split.header or config.get().prompt_header)
    end

    return header_label(config.get().queue_split.header)
end

---@param bufnr integer
---@param session legate.Session
---@param role 'input'|'queue'
local function configure_buffer(bufnr, session, role)
    vim.bo[bufnr].buftype = role == 'input' and 'nofile' or 'acwrite'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].filetype = 'markdown'
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].modified = false
    vim.b[bufnr].legate_surface_role = role
    vim.b[bufnr].legate_surface_session_id = session.id

    if role == 'input' then
        vim.bo[bufnr].omnifunc = "v:lua.require'legate.ui.completion'.complete"
    end
end

---@param session legate.Session
---@param role 'input'|'queue'
---@return integer
local function ensure_buffer(session, role)
    local surface = surfaces[role]

    if valid_buf(surface.bufnr) and surface.session_id == session.id then
        configure_buffer(surface.bufnr, session, role)
        return surface.bufnr
    end

    local bufnr = find_surface_buffer(session, role)

    if bufnr == nil then
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, surface_name(session, role))
    end

    surface.bufnr = bufnr
    surface.session_id = session.id
    configure_buffer(bufnr, session, role)
    return bufnr
end

---@param role 'input'|'queue'
---@param session_id string
---@return integer?
local function current_window(role, session_id)
    local surface = surfaces[role]

    if valid_win(surface.winid) and surface.session_id == session_id then
        return surface.winid
    end

    surface.winid = find_surface_window(role, session_id)
    return surface.winid
end

---@param winid integer
---@param session legate.Session
---@param role 'input'|'queue'
local function configure_window(winid, session, role)
    vim.w[winid].legate_surface_role = role
    vim.w[winid].legate_surface_session_id = session.id
    vim.wo[winid].winbar = role_winbar(role)
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = 'no'
    vim.wo[winid].foldenable = role == 'queue'
    vim.wo[winid].winfixheight = true
end

---@param anchor_winid integer
---@param bufnr integer
---@param height integer
---@param opts? { bottom?: boolean, enter?: boolean }
---@return integer
local function split_below(anchor_winid, bufnr, height, opts)
    local created = nil
    local previous_winid = vim.api.nvim_get_current_win()
    local modifier = opts ~= nil and opts.bottom and 'botright' or 'belowright'
    local equalalways = vim.o.equalalways
    local fixed = {}

    for _, surface in pairs(surfaces) do
        if valid_win(surface.winid) then
            fixed[surface.winid] = vim.wo[surface.winid].winfixheight
            vim.wo[surface.winid].winfixheight = false
        end
    end

    vim.o.equalalways = false

    local ok, err = pcall(function()
        created = vim.api.nvim_open_win(bufnr, opts ~= nil and opts.enter == true, {
            split = 'below',
            win = anchor_winid,
            height = math.max(1, height),
        })
    end)

    if not ok then
        ok, err = pcall(vim.api.nvim_win_call, anchor_winid, function()
            vim.cmd(string.format('keepalt %s %dsplit', modifier, math.max(1, height)))
            created = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(created, bufnr)
        end)

        if ok and (opts == nil or opts.enter ~= true) and valid_win(previous_winid) then
            vim.api.nvim_set_current_win(previous_winid)
        end
    end

    vim.o.equalalways = equalalways

    for winid, was_fixed in pairs(fixed) do
        if valid_win(winid) then
            vim.wo[winid].winfixheight = was_fixed
        end
    end

    if not ok then
        error(err, 0)
    end

    return created
end

---@param role 'input'|'queue'
---@param session legate.Session
---@param anchor_winid integer
---@param height integer
---@param opts? { bottom?: boolean, enter?: boolean }
---@return integer
local function ensure_window(role, session, anchor_winid, height, opts)
    local bufnr = ensure_buffer(session, role)
    local winid = current_window(role, session.id)

    if not valid_win(winid) then
        winid = split_below(anchor_winid, bufnr, height, opts)
        surfaces[role].winid = winid
        surfaces[role].session_id = session.id
    end

    if vim.api.nvim_win_get_buf(winid) ~= bufnr then
        vim.api.nvim_win_set_buf(winid, bufnr)
    end

    configure_window(winid, session, role)
    vim.api.nvim_win_set_height(winid, height)
    return winid
end

---@param role 'input'|'queue'
local function close_window(role)
    local winid = surfaces[role].winid

    surfaces[role].winid = nil

    if valid_win(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
    end
end

---@param winid integer?
---@return boolean
local function is_at_bottom(winid)
    if not valid_win(winid) then
        return false
    end

    local info = vim.fn.getwininfo(winid)[1]

    if info == nil then
        return false
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    return info.botline >= vim.api.nvim_buf_line_count(bufnr)
end

---@param winid integer?
local function scroll_to_bottom(winid)
    if not valid_win(winid) then
        return
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)

    vim.api.nvim_win_call(winid, function()
        vim.api.nvim_win_set_cursor(winid, {
            vim.api.nvim_buf_line_count(bufnr),
            0,
        })
        vim.cmd('normal! zb')
    end)

    require('legate.ui.surface').mark_pinned_to_bottom(winid)
end

---@param bufnr integer
local function sync_input_draft(bufnr)
    if mutating[bufnr] ~= nil then
        return
    end

    vim.schedule(function()
        if not valid_buf(bufnr) then
            return
        end

        local session = require('legate.session').current()

        if session == nil or vim.b[bufnr].legate_surface_session_id ~= session.id then
            return
        end

        require('legate.session').set_draft_prompt(session, buffer_text(bufnr))
        vim.bo[bufnr].modified = false
        M.resize(require('legate.ui.buffer').visible_window())
    end)
end

---@type table<integer, boolean>
local attached_input_buffers = {}

---@param bufnr integer
local function attach_input(bufnr)
    if attached_input_buffers[bufnr] then
        return
    end

    attached_input_buffers[bufnr] = true
    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function(_, changed_bufnr)
            sync_input_draft(changed_bufnr)
        end,
        on_detach = function(_, changed_bufnr)
            attached_input_buffers[changed_bufnr] = nil
        end,
    })

    vim.keymap.set('n', '<Esc>', function()
        M.close_empty_input()
    end, {
        buffer = bufnr,
        desc = 'Close empty Legate input split',
    })
end

---@param prompts string[]
---@return string[]
local function queue_lines(prompts)
    if #prompts == 0 then
        return { '' }
    end

    local lines = {}

    for _, prompt in ipairs(prompts) do
        local prompt_lines = text_lines(prompt)

        table.insert(lines, '- ' .. (prompt_lines[1] or ''))

        for index = 2, #prompt_lines do
            table.insert(lines, '  ' .. prompt_lines[index])
        end
    end

    return lines
end

---@param lines string[]
---@return string[]
local function parse_queue_lines(lines)
    local prompts = {}
    local current = nil

    local function finish_current()
        if current == nil then
            return
        end

        local prompt = vim.trim(table.concat(current, '\n'))

        if prompt ~= '' then
            table.insert(prompts, prompt)
        end

        current = nil
    end

    for _, line in ipairs(lines) do
        local item = line:match('^%s*[-*]%s+(.*)$')

        if item ~= nil then
            finish_current()
            current = { item }
        elseif current ~= nil then
            table.insert(current, line:gsub('^%s%s?', ''))
        elseif vim.trim(line) ~= '' then
            current = { line }
        end
    end

    finish_current()
    return prompts
end

---@param bufnr integer
local function write_queue(bufnr)
    local session = require('legate.session').current()

    if session == nil or vim.b[bufnr].legate_surface_session_id ~= session.id then
        vim.bo[bufnr].modified = false
        return
    end

    local prompts = parse_queue_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

    require('legate.session').set_queued_prompts(session, prompts)
    set_buffer_text(bufnr, table.concat(queue_lines(prompts), '\n'))
    vim.bo[bufnr].modified = false
    M.refresh(session)
end

---@type table<integer, boolean>
local attached_queue_buffers = {}

---@param bufnr integer
local function attach_queue(bufnr)
    if attached_queue_buffers[bufnr] then
        return
    end

    attached_queue_buffers[bufnr] = true
    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = group,
        buffer = bufnr,
        callback = function(args)
            write_queue(args.buf)
        end,
    })
end

---@param session legate.Session
---@param role 'queue'
---@param prompts string[]
local function render_prompt_list(session, role, prompts)
    local bufnr = ensure_buffer(session, role)

    set_buffer_text(bufnr, table.concat(queue_lines(prompts), '\n'))
    attach_queue(bufnr)
end

---@param role 'queue'
---@return integer
function M.queue_foldexpr(role)
    local line = vim.api.nvim_buf_get_lines(0, vim.v.lnum - 1, vim.v.lnum, false)[1] or ''

    if line:match('^%s*[-*]%s+') then
        return 1
    end

    if line:match('^%s+') then
        return 1
    end

    return 0
end

---@param session legate.Session
---@param transcript_winid? integer
---@param opts? { open_input?: boolean, focus_input?: boolean }
function M.refresh(session, transcript_winid, opts)
    if vim.in_fast_event() then
        vim.schedule(function()
            M.refresh(session, transcript_winid, opts)
        end)
        return
    end

    opts = opts or {}
    transcript_winid = transcript_winid or require('legate.ui.buffer').visible_window()

    local keep_bottom = is_at_bottom(transcript_winid)
    local anchor_winid = transcript_winid

    if not valid_win(transcript_winid) then
        return
    end

    local queued = session.queued_prompts or {}
    local input_bufnr = ensure_buffer(session, 'input')
    attach_input(input_bufnr)
    local should_open_input = opts.open_input or buffer_text(input_bufnr) ~= '' or (session.draft_prompt or '') ~= ''

    if should_open_input then
        if buffer_text(input_bufnr) == '' and (session.draft_prompt or '') ~= '' then
            set_buffer_text(input_bufnr, session.draft_prompt)
        end

        if #queued > 0 then
            close_window('queue')
        end

        local input_winid = ensure_window('input', session, transcript_winid, M.input_height(), {
            bottom = true,
            enter = opts.focus_input,
        })

        if opts.focus_input then
            vim.api.nvim_set_current_win(input_winid)
        end
    elseif current_window('input', session.id) ~= nil then
        close_window('input')
    end

    if #queued > 0 then
        render_prompt_list(session, 'queue', queued)
        local queue_winid = ensure_window(
            'queue',
            session,
            anchor_winid,
            math.min(#queue_lines(queued), config.get().queue_split.max_height)
        )
        vim.wo[queue_winid].foldmethod = 'expr'
        vim.wo[queue_winid].foldexpr = "v:lua.require'legate.ui.input'.queue_foldexpr('queue')"
        vim.wo[queue_winid].foldlevel = 0
        anchor_winid = queue_winid
    else
        close_window('queue')
    end

    M.resize(transcript_winid)

    if keep_bottom then
        scroll_to_bottom(transcript_winid)
    end
end

---@param transcript_winid? integer
function M.resize(transcript_winid)
    local session = require('legate.session').current()

    if session == nil then
        return
    end

    local keep_bottom = is_at_bottom(transcript_winid)
    local input_winid = current_window('input', session.id)

    if valid_win(input_winid) then
        vim.api.nvim_win_set_height(input_winid, M.input_height(input_winid))
    end

    local queue_winid = current_window('queue', session.id)

    if valid_win(queue_winid) then
        local count = math.max(1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(queue_winid)))
        vim.api.nvim_win_set_height(queue_winid, math.min(count, config.get().queue_split.max_height))
    end

    if keep_bottom then
        scroll_to_bottom(transcript_winid)
    end
end

---@param winid? integer
---@return integer
function M.input_height(winid)
    local split_config = config.get().input_split
    local max_height = tonumber(split_config.max_height) or 5
    local min_height = tonumber(split_config.min_height) or 1
    local height = min_height
    local session = require('legate.session').current()
    local input_winid = winid or (session and current_window('input', session.id) or nil)

    if valid_win(input_winid) and vim.api.nvim_win_text_height ~= nil then
        local ok, measured = pcall(vim.api.nvim_win_text_height, input_winid, {
            start_row = 0,
            end_row = -1,
        })

        if ok and type(measured) == 'table' and type(measured.all) == 'number' then
            height = measured.all
        end
    elseif session ~= nil and valid_buf(surfaces.input.bufnr) then
        height = vim.api.nvim_buf_line_count(surfaces.input.bufnr)
    end

    return math.max(min_height, math.min(max_height, height))
end

---@param session legate.Session
---@param transcript_winid? integer
function M.open_input(session, transcript_winid)
    M.refresh(session, transcript_winid, {
        open_input = true,
        focus_input = true,
    })
end

function M.close_empty_input()
    local session = require('legate.session').current()

    if session == nil then
        return
    end

    local input_bufnr = surfaces.input.bufnr

    if valid_buf(input_bufnr) and buffer_text(input_bufnr) ~= '' then
        return
    end

    require('legate.session').set_draft_prompt(session, '')
    close_window('input')
    scroll_to_bottom(require('legate.ui.buffer').visible_window())
end

---@param bufnr integer
---@return string?
function M.capture_prompt(bufnr)
    local session = require('legate.session').current()

    if
        session ~= nil
        and valid_buf(surfaces.input.bufnr)
        and surfaces.input.session_id == session.id
        and vim.b[surfaces.input.bufnr].legate_surface_session_id == session.id
    then
        return buffer_text(surfaces.input.bufnr)
    end

    if session ~= nil then
        return session.draft_prompt or ''
    end

    return nil
end

---@param bufnr integer
---@return string
function M.get_prompt(bufnr)
    return M.capture_prompt(bufnr) or ''
end

---@param bufnr integer
---@param text string
function M.set_prompt(bufnr, text)
    local session = require('legate.session').current()

    if session ~= nil then
        require('legate.session').set_draft_prompt(session, text)
    end

    local input_bufnr = surfaces.input.bufnr

    if valid_buf(input_bufnr) and session ~= nil and surfaces.input.session_id == session.id then
        set_buffer_text(input_bufnr, text)
    end
end

---@param bufnr integer
---@return integer?
function M.anchor_row(bufnr)
    return nil
end

---@param bufnr integer
---@param row integer
function M.set_anchor(bufnr, row) end

---@param bufnr integer
---@return integer
function M.prompt_header_line(bufnr)
    return 1
end

---@param bufnr integer
---@return integer
function M.prompt_start_line(bufnr)
    return 1
end

---@param bufnr integer
---@return integer
function M.prompt_end_line(bufnr)
    return vim.api.nvim_buf_line_count(bufnr)
end

---@param bufnr integer
---@return integer[]
function M.prompt_end_cursor(bufnr)
    local last_line = M.prompt_end_line(bufnr)
    local text = vim.api.nvim_buf_get_lines(bufnr, last_line - 1, last_line, false)[1] or ''

    return { last_line, #text }
end

---@return integer?
function M.input_buffer()
    return surfaces.input.bufnr
end

---@return integer?
function M.input_window()
    local session = require('legate.session').current()
    return session and current_window('input', session.id) or nil
end

---@return integer?
function M.queue_buffer()
    return surfaces.queue.bufnr
end

---@return integer?
function M.queue_window()
    local session = require('legate.session').current()
    return session and current_window('queue', session.id) or nil
end

function M.clear()
    for role, surface in pairs(surfaces) do
        close_window(role)
        if valid_buf(surface.bufnr) then
            pcall(vim.api.nvim_buf_delete, surface.bufnr, {
                force = true,
            })
        end
        surface.bufnr = nil
        surface.session_id = nil
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if
            vim.api.nvim_buf_is_valid(bufnr)
            and vim.startswith(vim.api.nvim_buf_get_name(bufnr), 'legate://surface/')
        then
            pcall(vim.api.nvim_buf_delete, bufnr, {
                force = true,
            })
        end
    end
end

vim.api.nvim_create_autocmd('User', {
    group = lifecycle_group,
    pattern = 'LegateSessionChanged',
    callback = function(args)
        local reason = type(args.data) == 'table' and args.data.reason or nil

        if reason == 'clear' or reason == 'restore' then
            M.clear()
        end
    end,
})

return M
