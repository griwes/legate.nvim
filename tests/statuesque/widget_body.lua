local function reset_statuesque_stubs()
    package.loaded['statuesque.publisher'] = nil
    package.loaded['statuesque.widgets.legate'] = nil
end

local function install_publisher_stub()
    package.loaded['statuesque.publisher'] = {
        new = function(render, subscribe, opts)
            return {
                statuesque_component = true,
                cache = opts and opts.cache or nil,
                render = render,
                subscribe = subscribe,
            }
        end,
    }
end

local function legate_widget(opts)
    install_publisher_stub()
    return require('statuesque.widgets.legate')(opts or {})
end

local function render_widget(opts)
    local component = legate_widget(opts)
    return component:render({})
end

local function child_texts(spec)
    local texts = {}

    for _, child in ipairs(spec.children or {}) do
        table.insert(texts, child.text)
    end

    return texts
end

local function has_text(texts, expected)
    for _, text in ipairs(texts) do
        if vim.trim(text) == expected then
            return true
        end
    end

    return false
end

local function highlight_fg(group)
    return vim.api.nvim_get_hl(0, { name = group }).fg
end

before_each(function()
    reset_statuesque_stubs()
    pcall(vim.api.nvim_del_augroup_by_name, 'legate-statuesque-widget')
    pcall(vim.api.nvim_del_augroup_by_name, 'legate-statuesque-widget-test')
    plugin.setup({
        auto_create_session = false,
        persist_sessions = false,
    })
end)

after_each(function()
    reset_statuesque_stubs()
    pcall(vim.api.nvim_del_augroup_by_name, 'legate-statuesque-widget')
end)

it('stays hidden when no Legate session exists and empty rendering is disabled', function()
    assert.are.equal(false, render_widget({ empty = false }))
end)

it('recreates Legate status highlights for idle rendering too', function()
    vim.api.nvim_set_hl(0, 'LegateStatusNeutral', {})

    local spec = render_widget()
    local neutral = vim.api.nvim_get_hl(0, {
        name = 'LegateStatusNeutral',
    })

    assert.are.equal('ACP idle', spec.text)
    assert.is_not_nil(neutral.fg)
end)

it('renders the selected Legate session, adapter, and state', function()
    require('legate.session').create('codex')

    local spec = render_widget()
    local texts = child_texts(spec)

    assert.are.equal('legate', spec.role)
    assert.is_true(has_text(texts, 'ACP'))
    assert.is_true(has_text(texts, 'acp:1'))
    assert.is_true(has_text(texts, 'codex'))
    assert.is_true(has_text(texts, 'idle'))
end)

it('separates Legate status chips with internal spaces', function()
    require('legate.session').create('codex')

    local spec = render_widget()
    local rendered = {}

    for _, child in ipairs(spec.children or {}) do
        table.insert(rendered, child.text)
    end

    assert.are.equal('ACP acp:1 codex idle', table.concat(rendered, ''))
end)

it('recreates Legate status highlights when a colorscheme clears them', function()
    require('legate.session').create('codex')

    vim.api.nvim_set_hl(0, 'LegateStatusPending', {})

    render_widget()

    local pending = vim.api.nvim_get_hl(0, {
        name = 'LegateStatusPending',
    })
    assert.is_not_nil(pending.fg)
end)

it('keeps semantic status colors when theme candidate groups are neutral', function()
    vim.api.nvim_set_hl(0, 'DiagnosticOk', { fg = '#eeeeee' })
    vim.api.nvim_set_hl(0, 'String', { fg = '#dddddd' })
    vim.api.nvim_set_hl(0, 'MoreMsg', { fg = '#cccccc' })
    vim.api.nvim_set_hl(0, 'Question', { fg = '#bbbbbb' })

    require('legate.ui.surface').refresh_highlights()

    assert.are.equal(0x98C379, highlight_fg('LegateStatusSuccess'))
end)

it('keeps Legate source colors independent from colorscheme candidate groups', function()
    vim.api.nvim_set_hl(0, 'DiagnosticOk', { fg = '#44cc66' })

    require('legate.ui.surface').refresh_highlights()

    assert.are.equal(0x98C379, highlight_fg('LegateStatusSuccess'))
end)

it('surfaces pending approval state ahead of idle session state', function()
    local sessions = require('legate.session')
    local current_session = sessions.create('codex')

    sessions.begin_prompt(current_session, 'change something')
    sessions.wait_for_approval(current_session, {
        request_id = 'request-1',
        toolCall = {
            toolCallId = 'call-1',
            title = 'Run command',
        },
        options = {
            {
                optionId = 'allow',
                name = 'Allow',
                kind = 'allow_once',
            },
        },
    })

    local texts = child_texts(render_widget())

    assert.is_true(has_text(texts, 'approval:1'))
    assert.is_false(has_text(texts, 'waiting'))
end)

it('notifies Statuesque publishers from Legate session mutations', function()
    local component = legate_widget()
    local notifications = 0

    component:subscribe(function()
        notifications = notifications + 1
    end)

    local current_session = require('legate.session').create('codex')
    require('legate.session').begin_prompt(current_session, 'hello')

    assert.are.equal(2, notifications)
end)

it('notifies Statuesque publishers when colorscheme changes can stale cached highlights', function()
    local component = legate_widget()
    local notifications = 0

    component:subscribe(function()
        notifications = notifications + 1
    end)

    vim.api.nvim_exec_autocmds('ColorScheme', {
        modeline = false,
    })

    assert.are.equal(1, notifications)
end)
