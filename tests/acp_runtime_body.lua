local function begin_permission_request(params)
    local response = nil

    params = vim.deepcopy(params)

    fake_client.opts.on_request('session/request_permission', params, function(result, error)
        response = {
            result = result,
            error = error,
        }
    end)

    return function()
        return response
    end
end

---@param bufnr integer
---@return string[], table[]
local function approval_virtual_lines(bufnr)
    local namespace = vim.api.nvim_get_namespaces()['acp.approval']
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {
        details = true,
    })

    if #marks == 0 then
        return {}, marks
    end

    local virt_lines = marks[1][4].virt_lines or {}
    local lines = vim.tbl_map(function(line)
        local chunks = vim.tbl_map(function(chunk)
            return chunk[1]
        end, line)

        return table.concat(chunks, '')
    end, virt_lines)

    return lines, marks
end

---@param bufnr integer
---@return string[]
local function surface_virtual_texts(bufnr)
    local namespace = vim.api.nvim_get_namespaces()['acp.surface']
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {
        details = true,
    })

    return vim.tbl_map(function(mark)
        return mark[4].virt_text and mark[4].virt_text[1] and mark[4].virt_text[1][1] or nil
    end, marks)
end

it('warns when enable_mcp_nvim is enabled without mcp.nvim installed', function()
    local original_notify = vim.notify
    local notifications = {}
    local original_preload = package.preload['mcp']

    package.loaded['mcp'] = nil
    package.preload['mcp'] = function()
        error('mcp.nvim not installed')
    end
    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
        },
    })

    vim.notify = function(message, level)
        table.insert(notifications, {
            message = message,
            level = level,
        })
    end

    local ok, err = xpcall(function()
        package.loaded['acp.mcp_runtime'] = nil
        local runtime = require('acp.mcp_runtime')
        local servers = runtime.effective_servers({ passive = true })

        assert.are.same({
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
        }, servers)
        assert.are.same({
            {
                message = 'ACP enable_mcp_nvim is enabled, but mcp.nvim is not installed on the runtimepath',
                level = vim.log.levels.WARN,
            },
        }, notifications)
    end, debug.traceback)

    vim.notify = original_notify
    package.preload['mcp'] = original_preload
    package.loaded['mcp'] = nil

    if not ok then
        error(err)
    end
end)

it('injects the stdio neovim server and replaces existing neovim entries', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
                env = { FOO = 'bar' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
            {
                name = 'neovim',
                type = 'stdio',
                command = 'old-acp',
            },
        },
    })

    package.loaded['acp.mcp_runtime'] = nil
    local runtime = require('acp.mcp_runtime')
    local servers = runtime.effective_servers({ passive = true })

    package.loaded['mcp'] = original_mcp

    assert.are.same({
        {
            name = 'custom',
            type = 'stdio',
            command = 'custom-mcp',
        },
        {
            name = 'neovim',
            type = 'stdio',
            command = 'nvim-mcp',
            args = { '--stdio' },
            env = { FOO = 'bar' },
        },
    }, servers)
end)

it('injects the http ACP-managed server without replacing user-defined aliases', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return {
                url = 'http://127.0.0.1:7777/mcp',
            }
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {
            {
                name = 'mcp.nvim',
                type = 'stdio',
                command = 'old-mcp',
            },
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
        },
    })

    package.loaded['acp.mcp_runtime'] = nil
    local runtime = require('acp.mcp_runtime')
    local servers = runtime.effective_servers()

    package.loaded['mcp'] = original_mcp

    assert.are.same({
        {
            name = 'neovim',
            type = 'http',
            url = 'http://127.0.0.1:7777/mcp',
        },
        {
            name = 'mcp.nvim',
            type = 'stdio',
            command = 'old-mcp',
        },
        {
            name = 'custom',
            type = 'stdio',
            command = 'custom-mcp',
        },
    }, servers)
end)

it('deduplicates only ACP-managed injected servers', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
                env = { FOO = 'bar' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {
            {
                name = 'neovim',
                type = 'stdio',
                command = 'old-acp',
            },
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
            {
                name = 'mcp.nvim',
                type = 'stdio',
                command = 'old-mcp',
            },
            {
                name = 'neovim',
                type = 'stdio',
                command = 'old-neovim',
            },
        },
    })

    package.loaded['acp.mcp_runtime'] = nil
    local runtime = require('acp.mcp_runtime')
    local servers = runtime.effective_servers()

    package.loaded['mcp'] = original_mcp

    assert.are.same({
        {
            name = 'neovim',
            type = 'stdio',
            command = 'nvim-mcp',
            args = { '--stdio' },
            env = { FOO = 'bar' },
        },
        {
            name = 'custom',
            type = 'stdio',
            command = 'custom-mcp',
        },
        {
            name = 'mcp.nvim',
            type = 'stdio',
            command = 'old-mcp',
        },
    }, servers)
end)

it('replaces legacy neovim MCP server entries with the managed neovim server', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
                env = { FOO = 'bar' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {
            {
                name = 'neovim',
                type = 'stdio',
                command = 'old-neovim',
            },
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
        },
    })

    package.loaded['acp.mcp_runtime'] = nil
    local runtime = require('acp.mcp_runtime')
    local servers = runtime.effective_servers()

    package.loaded['mcp'] = original_mcp

    assert.are.same({
        {
            name = 'neovim',
            type = 'stdio',
            command = 'nvim-mcp',
            args = { '--stdio' },
            env = { FOO = 'bar' },
        },
        {
            name = 'custom',
            type = 'stdio',
            command = 'custom-mcp',
        },
    }, servers)
end)

it('keeps static MCP server introspection side-effect free', function()
    local original_mcp = package.loaded['mcp']
    local started = 0

    package.loaded['mcp'] = {
        start_all = function()
            started = started + 1
            return true
        end,
        http_endpoint = function()
            return {
                url = 'http://127.0.0.1:7777/mcp',
            }
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
        },
    })

    package.loaded['acp.mcp_runtime'] = nil
    package.loaded['acp.api'] = nil

    local runtime = require('acp.mcp_runtime')
    local acp_api = require('acp.api')

    assert.are.same({
        {
            name = 'custom',
            type = 'stdio',
            command = 'custom-mcp',
        },
    }, runtime.static_servers())
    assert.are.same({
        {
            name = 'custom',
            type = 'stdio',
            command = 'custom-mcp',
        },
    }, acp_api.mcp_servers())
    assert.are.equal(0, started)

    package.loaded['mcp'] = original_mcp
end)

it('keeps passive effective_servers introspection side-effect free when a descriptor already exists', function()
    local original_mcp = package.loaded['mcp']
    local started = 0

    package.loaded['mcp'] = {
        start_all = function()
            started = started + 1
            return true
        end,
        http_endpoint = function()
            return {
                url = 'http://127.0.0.1:7777/mcp',
            }
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
        },
    })

    package.loaded['acp.mcp_runtime'] = nil
    local runtime = require('acp.mcp_runtime')
    local servers = runtime.effective_servers({ passive = true })

    package.loaded['mcp'] = original_mcp

    assert.are.same({
        {
            name = 'neovim',
            type = 'http',
            url = 'http://127.0.0.1:7777/mcp',
        },
        {
            name = 'custom',
            type = 'stdio',
            command = 'custom-mcp',
        },
    }, servers)
    assert.are.equal(0, started)
end)

it('preserves effective MCP server introspection through the public API', function()
    local original_mcp = package.loaded['mcp']
    local started = 0

    package.loaded['mcp'] = {
        start_all = function()
            started = started + 1
            return true
        end,
        http_endpoint = function()
            return {
                url = 'http://127.0.0.1:7777/mcp',
            }
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {
            {
                name = 'custom',
                type = 'stdio',
                command = 'custom-mcp',
            },
        },
    })

    package.loaded['acp.mcp_runtime'] = nil
    package.loaded['acp.api'] = nil

    local acp_api = require('acp.api')

    assert.are.same({
        {
            name = 'neovim',
            type = 'http',
            url = 'http://127.0.0.1:7777/mcp',
        },
        {
            name = 'custom',
            type = 'stdio',
            command = 'custom-mcp',
        },
    }, acp_api.effective_mcp_servers())
    assert.are.equal(1, started)

    package.loaded['mcp'] = original_mcp
end)

it('merges MCPHub proxy descriptors into static and effective server lists', function()
    local runtime = require('acp.mcp_runtime')
    local acp_api = require('acp.api')
    local original_mcphub = package.loaded['mcphub']
    local original_proxy = package.loaded['mcphub.extensions.proxy']

    package.loaded['mcphub'] = {
        get_hub_instance = function()
            return {
                is_ready = function()
                    return true
                end,
            }
        end,
    }
    package.loaded['mcphub.extensions.proxy'] = {
        get = function()
            return {
                type = 'stdio',
                command = 'mcphub-proxy',
            }
        end,
    }

    plugin.setup({
        adapters = {
            codex = {
                command = { 'codex-acp' },
                mcp_servers = {
                    {
                        name = 'static',
                        type = 'stdio',
                        command = 'static-proxy',
                    },
                },
                enable_mcphub = true,
            },
        },
    })

    assert.are.same({
        {
            name = 'static',
            type = 'stdio',
            command = 'static-proxy',
        },
        {
            name = 'mcphub',
            type = 'stdio',
            command = 'mcphub-proxy',
        },
    }, runtime.static_servers())
    assert.are.same({
        {
            name = 'static',
            type = 'stdio',
            command = 'static-proxy',
        },
        {
            name = 'mcphub',
            type = 'stdio',
            command = 'mcphub-proxy',
        },
    }, acp_api.mcp_servers())
    assert.are.same({
        {
            name = 'static',
            type = 'stdio',
            command = 'static-proxy',
        },
        {
            name = 'mcphub',
            type = 'stdio',
            command = 'mcphub-proxy',
        },
    }, runtime.effective_servers({ passive = true }))

    package.loaded['mcphub'] = original_mcphub
    package.loaded['mcphub.extensions.proxy'] = original_proxy
end)

it('refreshes the injected MCP server descriptor when the endpoint changes', function()
    local original_mcp = package.loaded['mcp']
    local started = 0
    local url = 'http://127.0.0.1:7777/mcp'

    package.loaded['mcp'] = {
        start_all = function()
            started = started + 1
            return true
        end,
        http_endpoint = function()
            return {
                url = url,
            }
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {},
    })

    package.loaded['acp.mcp_runtime'] = nil
    local runtime = require('acp.mcp_runtime')

    local first = runtime.effective_servers()
    url = 'http://127.0.0.1:8888/mcp'
    local second = runtime.effective_servers()

    package.loaded['mcp'] = original_mcp

    assert.are.same('http://127.0.0.1:7777/mcp', first[1].url)
    assert.are.same('http://127.0.0.1:8888/mcp', second[1].url)
    assert.are.equal(2, started)
end)

it('starts mcp.nvim before refreshing a stale cached stdio descriptor', function()
    local original_mcp = package.loaded['mcp']
    local started = 0

    package.loaded['mcp'] = {
        start_all = function()
            started = started + 1
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            if started == 0 then
                return nil
            end

            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_servers = {},
    })

    package.loaded['acp.mcp_runtime'] = nil
    local runtime = require('acp.mcp_runtime')

    local first = runtime.effective_servers()
    local second = runtime.effective_servers()

    package.loaded['mcp'] = original_mcp

    assert.are.same({
        {
            name = 'neovim',
            type = 'stdio',
            command = 'nvim-mcp',
            args = { '--stdio' },
        },
    }, first)
    assert.are.same(first, second)
    assert.are.equal(1, started)
end)

it('prepends guidance with the effective injected server namespace', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return {
                url = 'http://127.0.0.1:7777/mcp',
            }
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_nvim_guidance = true,
        mcp_servers = {},
    })

    package.loaded['acp.mcp_runtime'] = nil
    package.loaded['acp.mcp_guidance'] = nil
    local guidance = require('acp.mcp_guidance')
    local prompt = guidance.prepend('hello', {
        mcpCapabilities = {
            loadSession = true,
        },
    })

    package.loaded['mcp'] = original_mcp

    assert.is_true(prompt:find('`neovim`', 1, true) ~= nil)
    assert.is_true(prompt:find('neovim/editor/list_buffers', 1, true) ~= nil)
    assert.is_true(prompt:find('neovim/terminal/wait', 1, true) ~= nil)
    assert.is_false(prompt:find('editor__list_buffers', 1, true) ~= nil)
    assert.is_false(prompt:find('terminal__wait', 1, true) ~= nil)
    assert.is_false(prompt:find('acp%.nvim/editor/list_buffers', 1, false) ~= nil)
end)

it('ignores the legacy mcp.nvim alias when selecting guidance namespace', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_nvim_guidance = true,
        mcp_servers = {
            {
                name = 'mcp.nvim',
                type = 'stdio',
                command = 'old-mcp',
            },
        },
    })

    package.loaded['acp.mcp_runtime'] = nil
    package.loaded['acp.mcp_guidance'] = nil
    local guidance = require('acp.mcp_guidance')
    local prompt = guidance.prepend('hello', {
        mcpCapabilities = {
            loadSession = true,
        },
    })

    package.loaded['mcp'] = original_mcp

    assert.is_true(prompt:find('`neovim`', 1, true) ~= nil)
    assert.is_true(prompt:find('neovim/editor/list_buffers', 1, true) ~= nil)
    assert.is_false(prompt:find('mcp%.nvim/editor/list_buffers', 1, false) ~= nil)
end)

it('skips MCP guidance when the agent advertises an empty MCP capability set', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_nvim_guidance = true,
        mcp_servers = {},
    })

    package.loaded['acp.mcp_runtime'] = nil
    package.loaded['acp.mcp_guidance'] = nil
    local guidance = require('acp.mcp_guidance')
    local prompt = guidance.prepend('hello', {
        mcpCapabilities = {},
    })

    package.loaded['mcp'] = original_mcp

    assert.are.equal('hello', prompt)
end)

it('skips MCP guidance when nested MCP capability payloads do not enable any capability', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_nvim_guidance = true,
        mcp_servers = {},
    })

    package.loaded['acp.mcp_runtime'] = nil
    package.loaded['acp.mcp_guidance'] = nil
    local guidance = require('acp.mcp_guidance')
    local prompt = guidance.prepend('hello', {
        mcpCapabilities = {
            tools = {},
            prompts = {
                listChanged = false,
            },
        },
    })

    package.loaded['mcp'] = original_mcp

    assert.are.equal('hello', prompt)
end)

it('prepends MCP guidance when a nested MCP capability payload enables a capability', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_nvim_guidance = true,
        mcp_servers = {},
    })

    package.loaded['acp.mcp_runtime'] = nil
    package.loaded['acp.mcp_guidance'] = nil
    local guidance = require('acp.mcp_guidance')
    local prompt = guidance.prepend('hello', {
        mcpCapabilities = {
            tools = {
                listChanged = true,
            },
        },
    })

    package.loaded['mcp'] = original_mcp

    assert.is_true(prompt:find('neovim/editor/list_buffers', 1, true) ~= nil)
end)

it('skips MCP guidance when the agent does not advertise MCP capabilities', function()
    local original_mcp = package.loaded['mcp']

    package.loaded['mcp'] = {
        start_all = function()
            return true
        end,
        http_endpoint = function()
            return nil
        end,
        endpoint = function()
            return {
                command = 'nvim-mcp',
                args = { '--stdio' },
            }
        end,
    }

    plugin.setup({
        enable_mcp_nvim = true,
        mcp_nvim_guidance = true,
        mcp_servers = {},
    })

    package.loaded['acp.mcp_runtime'] = nil
    package.loaded['acp.mcp_guidance'] = nil
    local guidance = require('acp.mcp_guidance')
    local prompt = guidance.prepend('hello', {
        promptCapabilities = {
            image = true,
        },
    })

    package.loaded['mcp'] = original_mcp

    assert.are.equal('hello', prompt)
end)

it('responds to permission requests with the configured default option', function()
    local bufnr = api.open_chat()
    api.set_prompt('need permission')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_1',
            title = 'Read config',
            status = 'pending',
            kind = 'read',
        },
    })

    local response = fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_1',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local approvals = api.approvals()

    assert.are.equal('selected', response.result.outcome.outcome)
    assert.are.equal('reject-once', response.result.outcome.optionId)
    assert.are.equal(1, #approvals)
    assert.are.equal(1, approvals[1].ordinal)
    assert.are.equal('default', approvals[1].source)
    assert.are.equal('Reject', approvals[1].selected_option_name)
    assert.are.equal(2, #approvals[1].options)
    assert.is_true(vim.tbl_contains(lines, '✗ Approval [1] Read config'))
end)

it('auto-approves injected neovim terminal MCP permissions in default mode', function()
    local bufnr = api.open_chat()
    api.set_prompt('need terminal permission')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_terminal_1',
            title = 'Tool: neovim/neovim/terminal/create',
            status = 'pending',
            kind = 'execute',
            rawInput = {
                server = 'neovim',
                tool = 'neovim/terminal/create',
                arguments = {
                    command = { 'printf', 'hi' },
                },
            },
        },
    })

    local response = fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_terminal_1',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local approvals = api.approvals()

    assert.are.equal('selected', response.result.outcome.outcome)
    assert.are.equal('allow-once', response.result.outcome.optionId)
    assert.are.equal(1, #approvals)
    assert.are.equal('default', approvals[1].source)
    assert.are.equal('Allow once', approvals[1].selected_option_name)
    assert.is_true(vim.tbl_contains(lines, '✓ Approval [1] Tool: neovim/neovim/terminal/create'))
end)

it('uses the configured permission policy hook before the default strategy', function()
    local bufnr = api.open_chat()
    local plugin = require('acp')

    plugin.setup({
        permission_policy = function(current_session, permission, adapter)
            if current_session.id == api.current_session().id and adapter.name == 'codex' then
                return 'allow_once'
            end
        end,
    })

    api.set_prompt('need permission')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_policy_1',
            title = 'Read config',
            status = 'pending',
            kind = 'read',
        },
    })

    local response = fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_policy_1',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    local approvals = api.approvals()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('selected', response.result.outcome.outcome)
    assert.are.equal('allow-once', response.result.outcome.optionId)
    assert.are.equal('policy', approvals[1].source)
    assert.are.equal('Allow once', approvals[1].selected_option_name)
    assert.is_true(vim.tbl_contains(lines, '✓ Approval [1] Read config'))
end)

it('sanitizes multiline approval option names for rendering', function()
    local bufnr = api.open_chat()
    api.set_prompt('need multiline permission')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_2',
            title = 'Read config',
            status = 'pending',
            kind = 'read',
        },
    })

    local response = fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_2',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject\none',
                kind = 'reject_once',
            },
        },
    })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local status_text = require('acp.status_message').approval_status_text(api.approvals()[1])

    assert.are.equal('selected', response.result.outcome.outcome)
    assert.are.equal('reject-once', response.result.outcome.optionId)
    assert.is_false(status_text:find('Reject\none', 1, true) ~= nil)
    assert.is_true(status_text:find('Reject one', 1, true) ~= nil)
    assert.is_true(vim.tbl_contains(lines, '✗ Approval [1] Read config'))
end)

it('renders an inline approval surface and resolves it through the ACP API when configured', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('choose permission')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_select',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local picker_called = false
    local restore = with_ui_select(function()
        picker_called = true
    end)

    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_select',
            title = 'Run command',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    assert.is_nil(response())
    assert.is_false(picker_called)
    assert.are.equal('call_select', api.pending_approval().tool_call_id)
    assert.are.same(
        { 'allow-once', 'reject-once' },
        vim.tbl_map(function(option)
            return option.optionId
        end, api.pending_approval().options)
    )
    assert.is_false(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '## Approval Needed'))

    local approval_lines, marks = approval_virtual_lines(bufnr)

    assert.are.same(1, #marks)
    assert.are.same({
        'Pending approvals (1) — active: Run command',
        'g1 Allow once',
        'g2 Reject',
    }, approval_lines)

    api.select_approval_option('allow-once')
    restore()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local approvals = api.approvals()

    assert.are.equal('selected', response().result.outcome.outcome)
    assert.are.equal('allow-once', response().result.outcome.optionId)
    assert.are.equal('select', approvals[1].source)
    assert.are.equal('Allow once', approvals[1].selected_option_name)
    assert.is_true(vim.tbl_contains(lines, '✓ Approval [1] Run command'))
end)

it('limits approval overlay shortcuts to mapped keys', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('many approval options')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_many_overlay',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local options = {}

    for index = 1, 10 do
        table.insert(options, {
            optionId = string.format('option-%d', index),
            name = string.format('Option %d', index),
            kind = 'allow_once',
        })
    end

    begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_many_overlay',
            title = 'Run command',
        },
        options = options,
    })

    assert.is_true(
        vim.tbl_contains(
            surface_virtual_texts(bufnr),
            'Approval needed for Run command: g1 Option 1, g2 Option 2, g3 Option 3, g4 Option 4, g5 Option 5, g6 Option 6, g7 Option 7, g8 Option 8, g9 Option 9, … use :ACPSelectApprovalOption 10'
        )
    )
    assert.are.same({
        'Pending approvals (1) — active: Run command',
        'g1 Option 1',
        'g2 Option 2',
        'g3 Option 3',
        'g4 Option 4',
        'g5 Option 5',
        'g6 Option 6',
        'g7 Option 7',
        'g8 Option 8',
        'g9 Option 9',
        '… use :ACPSelectApprovalOption 10',
    }, approval_virtual_lines(bufnr))
end)

it(
    'reuses a placeholder tool-call row when the canonical tool-call event arrives late for a pending approval',
    function()
        plugin.setup({
            permission_strategy = 'select',
        })
        local bufnr = api.open_chat()
        api.set_prompt('late tool event')
        api.submit_prompt()
        local response = begin_permission_request({
            sessionId = 'sess_123',
            toolCall = {
                toolCallId = 'call_late_tool',
                title = 'Late tool',
            },
            options = {
                {
                    optionId = 'allow-once',
                    name = 'Allow once',
                    kind = 'allow_once',
                },
            },
        })

        local session = api.current_session()
        assert.is_not_nil(session)
        assert.are.equal(1, #session.tool_calls)
        assert.are.equal('waiting_for_approval', session.tool_calls[1].status)
        assert.are.equal('Late tool', session.tool_calls[1].title)

        fake_client:emit_notification('session/update', {
            sessionId = 'sess_123',
            update = {
                sessionUpdate = 'tool_call',
                toolCallId = 'call_late_tool',
                title = 'Late tool',
                status = 'in_progress',
                kind = 'write',
            },
        })

        session = api.current_session()
        assert.is_not_nil(session)
        assert.are.equal(1, #session.tool_calls)
        assert.are.equal('in_progress', session.tool_calls[1].status)
        assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '◔ Late tool'))

        api.select_approval_option('allow-once')

        assert.are.equal('selected', response().result.outcome.outcome)
        assert.are.equal('allow-once', response().result.outcome.optionId)
    end
)

it('matches a live inline approval request even when the request omits sessionId', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('choose permission without session id')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_select_no_session',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local response = begin_permission_request({
        toolCall = {
            toolCallId = 'call_select_no_session',
            title = 'Run command',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    assert.is_nil(response())
    assert.are.equal('call_select_no_session', api.pending_approval().tool_call_id)
    assert.are.same({
        'Pending approvals (1) — active: Run command',
        'g1 Allow once',
        'g2 Reject',
    }, approval_virtual_lines(bufnr))

    api.select_approval_option('allow-once')

    assert.are.equal('selected', response().result.outcome.outcome)
    assert.are.equal('allow-once', response().result.outcome.optionId)
end)

it('falls back to command-based approval hints for options beyond mapped keys', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('many permissions')
    api.submit_prompt()

    local options = {}

    for index = 1, 10 do
        table.insert(options, {
            optionId = string.format('option-%d', index),
            name = string.format('Option %d', index),
            kind = 'allow_once',
        })
    end

    begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_many_select',
            title = 'Run command',
        },
        options = options,
    })

    local lines = require('acp.status_message').pending_approval_lines(api.current_session(), api.pending_approval())
    assert.are.equal(
        'Option 1 [allow_once] (`option-1`)  ->  select with `g1`, `:ACPSelectApprovalOption 1`, or use the inline action',
        lines[5]
    )
    assert.are.equal(
        'Option 9 [allow_once] (`option-9`)  ->  select with `g9`, `:ACPSelectApprovalOption 9`, or use the inline action',
        lines[13]
    )
    assert.are.equal(
        'Option 10 [allow_once] (`option-10`)  ->  select with `:ACPSelectApprovalOption <index>` or use the inline action',
        lines[14]
    )
end)

it('renders inline approvals even when the permission request arrives in a fast event context', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('fast approval')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_fast_select',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local scheduled, restore_fast = with_fast_event_schedule()
    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_fast_select',
            title = 'Run command',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    restore_fast()

    assert.is_nil(response())
    assert.are.equal(1, #scheduled)

    for _, callback in ipairs(scheduled) do
        callback()
    end

    restore_fast()

    assert.are.equal('call_fast_select', api.pending_approval().tool_call_id)
    api.select_approval_option('allow-once')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('selected', response().result.outcome.outcome)
    assert.are.equal('allow-once', response().result.outcome.optionId)
    assert.is_true(vim.tbl_contains(lines, '✓ Approval [1] Run command'))
end)

it('queues a new pending approval without cancelling the prior in-flight request', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('replace pending approval')
    api.submit_prompt()

    local first = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_replace_first',
            title = 'First command',
        },
        options = {
            {
                optionId = 'allow-first',
                name = 'Allow first',
                kind = 'allow_once',
            },
        },
    })

    assert.is_nil(first())
    assert.are.equal('call_replace_first', api.pending_approval().tool_call_id)

    local second = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_replace_second',
            title = 'Second command',
        },
        options = {
            {
                optionId = 'allow-second',
                name = 'Allow second',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-second',
                name = 'Reject second',
                kind = 'reject_once',
            },
        },
    })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.is_nil(second())
    assert.is_nil(first())
    assert.are.equal('call_replace_first', api.pending_approval().tool_call_id)
    assert.are.equal(2, #api.pending_approvals())
    assert.is_true(vim.tbl_contains(lines, '? First command'))
    assert.are.same({
        'Pending approvals (2) — active: First command',
        'g1 Allow first',
        'Queued [2] Second command',
    }, approval_virtual_lines(bufnr))

    api.select_approval_option('allow-first')

    assert.are.equal('selected', first().result.outcome.outcome)
    assert.are.equal('allow-first', first().result.outcome.optionId)
    assert.is_nil(second())
    assert.are.equal('call_replace_second', api.pending_approval().tool_call_id)

    api.select_approval_option('allow-second')

    assert.are.equal('selected', second().result.outcome.outcome)
    assert.are.equal('allow-second', second().result.outcome.optionId)
    assert.is_nil(api.pending_approval())
end)

it('resolves queued approvals by request-qualified option id', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('multiple pending approvals')
    api.submit_prompt()

    local first = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_first_queue',
            title = 'First command',
        },
        options = {
            {
                optionId = 'allow-first',
                name = 'Allow first',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-first',
                name = 'Reject first',
                kind = 'reject_once',
            },
        },
    })

    local second = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_second_queue',
            title = 'Second command',
        },
        options = {
            {
                optionId = 'allow-second',
                name = 'Allow second',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-second',
                name = 'Reject second',
                kind = 'reject_once',
            },
        },
    })

    local pending = api.pending_approvals()
    assert.are.equal(2, #pending)
    assert.are.equal('call_first_queue', pending[1].tool_call_id)
    assert.are.equal('call_second_queue', pending[2].tool_call_id)
    assert.is_nil(first())

    api.select_approval_option(string.format('%s:%s', pending[1].request_id, 'allow-first'))
    assert.are.equal('allow-first', first().result.outcome.optionId)
    assert.are.equal('call_second_queue', api.pending_approval().tool_call_id)
    api.select_approval_option(string.format('%s:%s', pending[2].request_id, 'allow-second'))
    assert.are.equal('allow-second', second().result.outcome.optionId)
    assert.is_nil(api.pending_approval())
end)

it('keeps other queued approvals when a selected request has no active session', function()
    local permission = require('acp.handlers.permission')
    local current_session = {
        id = 'acp:1',
    }
    local rerendered = nil
    local cancelled = false
    local retained = nil
    local stale_permission = {
        options = {
            {
                optionId = 'allow-stale',
                kind = 'allow_once',
            },
        },
    }
    local fresh_permission = {
        options = {
            {
                optionId = 'allow-fresh',
                kind = 'allow_once',
            },
        },
    }
    local pending_permissions = {
        {
            local_session_id = current_session.id,
            request_id = 'stale-request',
            permission = stale_permission,
            respond = function() end,
        },
        {
            local_session_id = current_session.id,
            request_id = 'fresh-request',
            permission = fresh_permission,
            respond = function() end,
        },
    }

    local ctx = {
        get_pending_permissions = function()
            return pending_permissions
        end,
        is_live_generation = function()
            return true
        end,
        active_request_session = function(request_permission)
            if request_permission == stale_permission then
                return nil
            end

            return current_session
        end,
        set_pending_permissions = function(next_pending)
            retained = next_pending
            pending_permissions = next_pending
        end,
        rerender = function(session_to_render)
            rerendered = session_to_render
        end,
        cancel_pending_permission = function()
            cancelled = true
        end,
        session = {
            record_approval = function() end,
        },
    }

    assert.has_error(function()
        permission.select_pending_approval(ctx, current_session, 'stale-request:allow-stale')
    end, 'ACP approval is no longer active')
    assert.is_false(cancelled)
    assert.are.equal(1, #retained)
    assert.are.equal('fresh-request', retained[1].request_id)
    assert.are.equal(current_session, rerendered)
end)

it('resolves inline approvals through ACP buffer-local keymaps', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('mapped approval')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_mapped_select',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_mapped_select',
            title = 'Run command',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    local prompt_header_line = require('acp.input').prompt_header_line(bufnr)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode(']a'), 'xt', false)

    assert.are.same({ prompt_header_line - 2, 0 }, vim.api.nvim_win_get_cursor(0))

    vim.api.nvim_feedkeys(vim.keycode('g2'), 'xt', false)

    assert.is_true(vim.wait(1000, function()
        return response() ~= nil
    end, 10))
    assert.are.equal('selected', response().result.outcome.outcome)
    assert.are.equal('reject-once', response().result.outcome.optionId)
    assert.is_nil(api.pending_approval())
end)

it('accepts numeric inline approval selectors', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('index approval')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_index_only',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_index_only',
            title = 'Run command',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    api.select_approval_option(1)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('selected', response().result.outcome.outcome)
    assert.are.equal('allow-once', response().result.outcome.optionId)
    assert.is_true(vim.tbl_contains(lines, '✓ Approval [1] Run command'))
end)

it('keeps an inline approval visible when an invalid option is selected', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('dismiss permission')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_dismiss',
            title = 'Delete file',
            status = 'pending',
            kind = 'delete',
        },
    })

    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_dismiss',
            title = 'Delete file',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    assert.has_error(function()
        api.select_approval_option('nope')
    end, 'Unknown ACP approval option: nope')
    assert.is_nil(response())
    assert.are.equal('call_dismiss', api.pending_approval().tool_call_id)
    assert.are.same({
        'Pending approvals (1) — active: Delete file',
        'g1 Allow once',
        'g2 Reject',
    }, approval_virtual_lines(bufnr))
end)

it('reveals a recorded approval in the shared chat buffer', function()
    local bufnr = api.open_chat()
    api.set_prompt('revisit approval')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_revisit',
            title = 'Write file',
            status = 'pending',
            kind = 'edit',
        },
    })

    fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_revisit',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    vim.api.nvim_win_set_cursor(0, {
        vim.api.nvim_buf_line_count(bufnr),
        0,
    })

    api.reveal_approval(1)

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]

    assert.are.equal('✗ Approval [1] Write file', line)
end)

it('reveals an approval after switching to another local session', function()
    local bufnr = api.open_chat()
    api.set_prompt('first approval session')
    local first = api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_switch',
            title = 'Switch back',
            status = 'pending',
            kind = 'read',
        },
    })
    fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_switch',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    local second = api.new_session()

    assert.are.equal(second.id, api.current_session().id)

    api.reveal_approval(1, first.id)

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]

    assert.are.equal(first.id, api.current_session().id)
    assert.are.equal('✗ Approval [1] Switch back', line)
end)

it('switches back to the waiting session when an inline approval arrives for it', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('first approval session')
    local first = api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_switch_back',
            title = 'Run command',
            status = 'pending',
            kind = 'execute',
        },
    })

    local second = api.new_session()

    assert.are.equal(second.id, api.current_session().id)

    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_switch_back',
            title = 'Run command',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    assert.are.equal(first.id, api.current_session().id)
    assert.are.equal('call_switch_back', api.pending_approval().tool_call_id)
    assert.are.same({
        'Pending approvals (1) — active: Run command',
        'g1 Allow once',
        'g2 Reject',
    }, approval_virtual_lines(bufnr))

    api.select_approval_option('allow-once')

    assert.are.equal('selected', response().result.outcome.outcome)
    assert.are.equal('allow-once', response().result.outcome.optionId)
end)

it('reads file content from disk via fs/read_text_file', function()
    local path = vim.fn.getcwd() .. '/tests/fixtures/disk-read.txt'
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write('alpha\nbeta\n'))
    handle:close()

    api.open_chat()
    api.set_prompt('read from disk')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/read_text_file', {
        sessionId = 'sess_123',
        path = path,
        cwd = vim.fn.getcwd(),
    })

    assert.is_nil(response.error)
    assert.are.equal('alpha\nbeta\n', response.result.content)
end)

it('reads unsaved open-buffer content via fs/read_text_file outside allowed roots when the buffer is loaded', function()
    local path = temp_path('open-buffer-read.txt')
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write('on disk\n'))
    handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'draft one', 'draft two' })

    api.open_chat()
    api.set_prompt('read from buffer')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/read_text_file', {
        sessionId = 'sess_123',
        path = path,
        cwd = vim.fn.getcwd(),
    })

    assert.is_nil(response.error)
    assert.is_true(vim.bo[file_buf].modified)
    assert.are.equal('draft one\ndraft two\n', response.result.content)
end)

it('reads a limited line window via fs/read_text_file', function()
    local path = vim.fn.getcwd() .. '/tests/fixtures/partial-read.txt'
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write('one\ntwo\nthree\n'))
    handle:close()

    api.open_chat()
    api.set_prompt('read a subset')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/read_text_file', {
        sessionId = 'sess_123',
        path = path,
        cwd = vim.fn.getcwd(),
        line = 2,
        limit = 1,
    })

    assert.is_nil(response.error)
    assert.are.equal('two\n', response.result.content)
end)

it('returns an empty snapshot when fs/read_text_file targets a missing file inside the workspace', function()
    local path = vim.fn.getcwd() .. '/missing-read.txt'
    os.remove(path)

    api.open_chat()
    api.set_prompt('read missing file')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/read_text_file', {
        sessionId = 'sess_123',
        path = path,
        cwd = vim.fn.getcwd(),
    })

    assert.is_nil(response.error)
    assert.are.equal('', response.result.content)
end)

it('rejects fs/read_text_file when opening a broken symlink inside the workspace fails', function()
    local target = vim.fn.getcwd() .. '/missing-symlink-target.txt'
    local path = vim.fn.getcwd() .. '/broken-read-link.txt'

    os.remove(path)
    os.remove(target)
    assert.is_truthy(vim.uv.fs_symlink(target, path))

    api.open_chat()
    api.set_prompt('read broken symlink')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/read_text_file', {
        sessionId = 'sess_123',
        path = path,
        cwd = vim.fn.getcwd(),
    })

    os.remove(path)

    assert.is_nil(response.result)
    assert.is_not_nil(response.error)
    assert.is_truthy(response.error.message:match('No such file'))
end)

it('rejects fs/read_text_file outside allowed roots', function()
    local path = '/tmp/acp-fs-outside-read.txt'
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write('outside\n'))
    handle:close()

    api.open_chat()
    api.set_prompt('reject outside read')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/read_text_file', {
        sessionId = 'sess_123',
        path = path,
    })

    os.remove(path)

    assert.is_not_nil(response.error)
    assert.is_true(response.error.message:match('allowed workspace root') ~= nil)
end)

it('writes file content via fs/write_text_file', function()
    local path = vim.fn.getcwd() .. '/tests/fixtures/write-file.txt'
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    os.remove(path)

    api.open_chat()
    api.set_prompt('write a file')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        cwd = vim.fn.getcwd(),
        content = 'hello\nworld\n',
    })

    assert.is_nil(response.error)
    assert.are.same({}, response.result)
    assert.are.equal('hello\nworld\n', read_file(path))
end)

it('rejects updating a modified open buffer via fs/write_text_file outside allowed roots', function()
    local path = temp_path('write-open-buffer.txt')
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write('before\n'))
    handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'before', 'draft change' })

    api.open_chat()
    api.set_prompt('write through buffer')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        content = 'after\nvalue\n',
    })

    assert.is_not_nil(response.error)
    assert.are.same({ 'before', 'draft change' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
    assert.is_true(vim.bo[file_buf].modified)
    assert.are.equal('before\n', read_file(path))
end)

it('rejects reloading a modified open buffer for fs/write_text_file outside allowed roots', function()
    local path = temp_path('write-open-buffer-undo.txt')
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write('before\n'))
    handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'before', 'draft change' })

    api.open_chat()
    api.set_prompt('write through buffer without undo divergence')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        content = 'after\nvalue\n',
    })

    assert.is_not_nil(response.error)
    assert.are.same({ 'before', 'draft change' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
    assert.is_true(vim.bo[file_buf].modified)
end)

it('reloads an open buffer for fs/write_text_file outside allowed roots when it is safe to synchronize', function()
    local path = temp_path('write-open-buffer-reload.txt')
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write('alpha\nbeta\n'))
    handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()
    vim.bo[file_buf].fileformat = 'unix'

    api.open_chat()
    api.set_prompt('write through buffer and reload file metadata')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        content = 'alpha\r\nbeta updated\r\n',
    })

    assert.is_nil(response.error)
    local file_lines = vim.tbl_map(function(line)
        return line:gsub('\r$', '')
    end, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
    assert.are.same({ 'alpha', 'beta updated' }, file_lines)
    assert.is_false(vim.bo[file_buf].modified)
    assert.are.equal('dos', vim.bo[file_buf].fileformat)
    assert.is_true(read_file(path):match('alpha\r\nbeta updated\r\n') ~= nil)
end)

it('reloads a hidden buffer for fs/write_text_file outside allowed roots when it is safe to synchronize', function()
    local visible_path = temp_path('write-hidden-buffer-visible.txt')
    local visible_handle = assert(io.open(visible_path, 'wb'))
    assert(visible_handle:write('visible\n'))
    visible_handle:close()

    local hidden_path = temp_path('write-hidden-buffer-reload.txt')
    local hidden_handle = assert(io.open(hidden_path, 'wb'))
    assert(hidden_handle:write('alpha\nbeta\n'))
    hidden_handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(hidden_path))
    local hidden_buf = vim.api.nvim_get_current_buf()
    vim.bo[hidden_buf].fileformat = 'unix'
    vim.bo[hidden_buf].modifiable = false

    vim.cmd('edit ' .. vim.fn.fnameescape(visible_path))
    local visible_buf = vim.api.nvim_get_current_buf()

    api.open_chat()
    api.set_prompt('write through hidden buffer and reload file metadata')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = hidden_path,
        content = 'alpha\r\nbeta updated\r\n',
    })

    assert.is_nil(response.error)
    local hidden_lines = vim.tbl_map(function(line)
        return line:gsub('\r$', '')
    end, vim.api.nvim_buf_get_lines(hidden_buf, 0, -1, false))
    assert.are.same({ 'alpha', 'beta updated' }, hidden_lines)
    assert.is_false(vim.bo[hidden_buf].modified)
    assert.is_false(vim.bo[hidden_buf].modifiable)
    assert.are.equal('dos', vim.bo[hidden_buf].fileformat)
    assert.is_true(read_file(hidden_path):match('alpha\r\nbeta updated\r\n') ~= nil)
end)

it(
    'preserves the current window when updating another open buffer via fs/write_text_file outside allowed roots',
    function()
        local left_path = temp_path('write-open-buffer-window-left.txt')
        local left_handle = assert(io.open(left_path, 'wb'))
        assert(left_handle:write('left\n'))
        left_handle:close()

        local right_path = temp_path('write-open-buffer-window-right.txt')
        local right_handle = assert(io.open(right_path, 'wb'))
        assert(right_handle:write('right\nbefore\n'))
        right_handle:close()

        vim.cmd('edit ' .. vim.fn.fnameescape(left_path))
        local left_win = vim.api.nvim_get_current_win()
        local left_buf = vim.api.nvim_get_current_buf()

        vim.cmd('vsplit')
        vim.cmd('edit ' .. vim.fn.fnameescape(right_path))
        local right_buf = vim.api.nvim_get_current_buf()

        vim.api.nvim_set_current_win(left_win)

        api.open_chat()
        api.set_prompt('write through buffer in another window')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/write_text_file', {
            sessionId = 'sess_123',
            path = right_path,
            content = 'right\nafter\n',
        })

        assert.is_nil(response.error)
        assert.are.equal(left_win, vim.api.nvim_get_current_win())
        assert.are.same({ 'right', 'after' }, vim.api.nvim_buf_get_lines(right_buf, 0, -1, false))
    end
)

it('reloads an open buffer shown in multiple windows outside allowed roots', function()
    local left_path = temp_path('write-open-buffer-multi-window-left.txt')
    local left_handle = assert(io.open(left_path, 'wb'))
    assert(left_handle:write('left\n'))
    left_handle:close()

    local shared_path = temp_path('write-open-buffer-multi-window-shared.txt')
    local shared_handle = assert(io.open(shared_path, 'wb'))
    assert(shared_handle:write('shared\nbefore\n'))
    shared_handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(left_path))
    local left_win = vim.api.nvim_get_current_win()
    local left_buf = vim.api.nvim_get_current_buf()
    vim.wo[left_win].statusline = 'left-status'

    vim.cmd('vsplit')
    vim.cmd('edit ' .. vim.fn.fnameescape(shared_path))
    local first_shared_win = vim.api.nvim_get_current_win()
    local shared_buf = vim.api.nvim_get_current_buf()
    vim.wo[first_shared_win].statusline = 'shared-status-a'

    vim.cmd('split')
    local second_shared_win = vim.api.nvim_get_current_win()
    assert.are.equal(shared_buf, vim.api.nvim_get_current_buf())
    vim.wo[second_shared_win].statusline = 'shared-status-b'

    vim.api.nvim_set_current_win(left_win)

    api.open_chat()
    api.set_prompt('write through buffer in two windows')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = shared_path,
        content = 'shared\nafter\n',
    })

    assert.is_nil(response.error)
    assert.are.equal(left_win, vim.api.nvim_get_current_win())
    assert.are.same({ 'shared', 'after' }, vim.api.nvim_buf_get_lines(shared_buf, 0, -1, false))
end)

it('rejects fs/write_text_file before mutating disk when a hidden non-modifiable buffer has unsaved changes', function()
    local visible_path = temp_path('write-hidden-nomodifiable-visible.txt')
    local visible_handle = assert(io.open(visible_path, 'wb'))
    assert(visible_handle:write('visible\n'))
    visible_handle:close()

    local hidden_path = temp_path('write-hidden-nomodifiable-modified.txt')
    local hidden_handle = assert(io.open(hidden_path, 'wb'))
    assert(hidden_handle:write('before\n'))
    hidden_handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(hidden_path))
    local hidden_buf = vim.api.nvim_get_current_buf()
    vim.bo[hidden_buf].modifiable = true
    vim.api.nvim_buf_set_lines(hidden_buf, 0, -1, false, { 'local change' })
    vim.bo[hidden_buf].modifiable = false

    vim.cmd('edit ' .. vim.fn.fnameescape(visible_path))

    api.open_chat()
    api.set_prompt('reject write through hidden modified nomodifiable buffer')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = hidden_path,
        content = 'after\nvalue\n',
    })

    assert.is_not_nil(response.error)
    assert.are.same({ 'local change' }, vim.api.nvim_buf_get_lines(hidden_buf, 0, -1, false))
    assert.is_true(vim.bo[hidden_buf].modified)
    assert.is_false(vim.bo[hidden_buf].modifiable)
    assert.are.equal('before\n', read_file(hidden_path))
end)

it('rejects fs/write_text_file before mutating disk when a hidden modifiable buffer has unsaved changes', function()
    local visible_path = temp_path('write-hidden-modifiable-visible.txt')
    local visible_handle = assert(io.open(visible_path, 'wb'))
    assert(visible_handle:write('visible\n'))
    visible_handle:close()

    local hidden_path = temp_path('write-hidden-modifiable-modified.txt')
    local hidden_handle = assert(io.open(hidden_path, 'wb'))
    assert(hidden_handle:write('before\n'))
    hidden_handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(hidden_path))
    local hidden_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(hidden_buf, 0, -1, false, { 'local change' })

    vim.cmd('edit ' .. vim.fn.fnameescape(visible_path))

    api.open_chat()
    api.set_prompt('reject write through hidden modified buffer')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = hidden_path,
        content = 'after\nvalue\n',
    })

    assert.is_not_nil(response.error)
    assert.are.same({ 'local change' }, vim.api.nvim_buf_get_lines(hidden_buf, 0, -1, false))
    assert.is_true(vim.bo[hidden_buf].modified)
    assert.are.equal('before\n', read_file(hidden_path))
end)

it(
    'rejects fs/write_text_file before mutating disk when a visible non-modifiable non-file buffer cannot be synchronized',
    function()
        local path = temp_path('write-nomodifiable-buffer.txt')
        local handle = assert(io.open(path, 'wb'))
        assert(handle:write('before\n'))
        handle:close()

        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        local file_buf = vim.api.nvim_get_current_buf()
        vim.bo[file_buf].modifiable = false
        vim.bo[file_buf].buftype = 'nofile'

        api.open_chat()
        api.set_prompt('write through nomodifiable buffer')
        api.submit_prompt()

        local response = fake_client:emit_request('fs/write_text_file', {
            sessionId = 'sess_123',
            path = path,
            content = 'after\nvalue\n',
        })

        assert.is_not_nil(response.error)
        assert.are.same({ 'before' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
        assert.is_false(vim.bo[file_buf].modified)
        assert.is_false(vim.bo[file_buf].modifiable)
        assert.are.equal('before\n', read_file(path))
    end
)

it('rejects fs/write_text_file before mutating disk when hidden buffer synchronization would fail', function()
    local visible_path = temp_path('write-hidden-sync-visible.txt')
    local visible_handle = assert(io.open(visible_path, 'wb'))
    assert(visible_handle:write('visible\n'))
    visible_handle:close()

    local hidden_path = temp_path('write-hidden-sync-fail.txt')
    local hidden_handle = assert(io.open(hidden_path, 'wb'))
    assert(hidden_handle:write('before\n'))
    hidden_handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(hidden_path))
    local hidden_buf = vim.api.nvim_get_current_buf()

    vim.cmd('edit ' .. vim.fn.fnameescape(visible_path))

    local original_set_lines = vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function(bufnr, start, finish, strict, lines)
        if bufnr == hidden_buf then
            error('sync failed')
        end

        return original_set_lines(bufnr, start, finish, strict, lines)
    end

    api.open_chat()
    api.set_prompt('reject write when hidden buffer sync fails')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = hidden_path,
        content = 'after\nvalue\n',
    })

    vim.api.nvim_buf_set_lines = original_set_lines

    assert.is_not_nil(response.error)
    assert.are.same({ 'before' }, vim.api.nvim_buf_get_lines(hidden_buf, 0, -1, false))
    assert.are.equal('before\n', read_file(hidden_path))
end)

it('allows unchanged fs/write_text_file content for a loaded non-modifiable buffer outside allowed roots', function()
    local path = temp_path('write-nomodifiable-buffer-noop.txt')
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write('before\n'))
    handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()
    vim.bo[file_buf].modifiable = false

    api.open_chat()
    api.set_prompt('noop write through nomodifiable buffer')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        content = 'before\n',
    })

    assert.is_nil(response.error)
    assert.are.same({ 'before' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
    assert.is_true(vim.bo[file_buf].modified)
    assert.is_false(vim.bo[file_buf].modifiable)
    assert.are.equal('before\n', read_file(path))
end)

it('allows empty fs/write_text_file content for an empty loaded buffer outside allowed roots', function()
    local path = temp_path('write-empty-buffer-noop.txt')
    local handle = assert(io.open(path, 'wb'))
    assert(handle:write(''))
    handle:close()

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()
    vim.bo[file_buf].modifiable = false

    api.open_chat()
    api.set_prompt('noop write through empty loaded buffer')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        content = '',
    })

    assert.is_nil(response.error)
    assert.are.same({ '' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
    assert.is_false(vim.bo[file_buf].modified)
    assert.is_false(vim.bo[file_buf].modifiable)
    assert.are.equal('', read_file(path))
end)

it('accepts Windows-style absolute paths before root validation', function()
    os.remove('C:\\temp\\acp-fs-outside-write.txt')
    api.open_chat()
    api.set_prompt('windows absolute path validation')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = 'C:\\temp\\acp-fs-outside-write.txt',
        content = 'outside\n',
    })

    os.remove('C:\\temp\\acp-fs-outside-write.txt')

    assert.is_not_nil(response.error)
    assert.is_true(response.error.message:match('allowed workspace root') ~= nil)
    assert.is_false(response.error.message:match('must be absolute') ~= nil)
end)

it('accepts Windows UNC descendants within the workspace root', function()
    os.remove([[\\server\share\folder\file.txt]])

    api.open_chat()
    api.set_prompt('windows unc path validation')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        cwd = '\\\\server\\share',
        path = '\\\\server\\share\\folder\\file.txt',
        content = 'inside\n',
    })

    os.remove([[\\server\share\folder\file.txt]])

    assert.is_nil(response.error)
end)

it('accepts fs/write_text_file at the workspace root with a trailing separator', function()
    local path = '/tmp/acp-fs-root-trailing-slash'
    os.remove(path)

    api.open_chat()
    api.set_prompt('workspace root trailing slash validation')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        cwd = '/tmp/acp-fs-root-trailing-slash',
        path = '/tmp/acp-fs-root-trailing-slash/',
        content = 'root\n',
    })

    os.remove(path)

    assert.is_nil(response.error)
end)

it('accepts a Windows UNC workspace root with a trailing separator', function()
    os.remove([[\\server\share\]])

    api.open_chat()
    api.set_prompt('windows unc root trailing slash validation')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        cwd = [[\\server\share]],
        path = [[\\server\share\]],
        content = 'root\n',
    })

    os.remove([[\\server\share\]])

    assert.is_nil(response.error)
end)

it('rejects fs/write_text_file outside allowed roots', function()
    local path = '/tmp/acp-fs-outside-write.txt'
    os.remove(path)

    api.open_chat()
    api.set_prompt('reject outside write')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        content = 'outside\n',
    })

    assert.is_not_nil(response.error)
    assert.is_true(response.error.message:match('allowed workspace root') ~= nil)
    assert.is_false(vim.uv.fs_stat(path) ~= nil)
end)

it('reads fs/read_text_file from a loaded buffer outside allowed roots', function()
    local path = '/tmp/acp-fs-outside-read.txt'
    vim.fn.writefile({ 'outside read' }, path)

    api.open_chat()
    api.set_prompt('read outside through loaded buffer')
    api.submit_prompt()

    local file_buf = vim.fn.bufadd(path)
    vim.fn.bufload(file_buf)
    vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'unsaved outside read' })
    vim.bo[file_buf].modified = true

    local response = fake_client:emit_request('fs/read_text_file', {
        sessionId = 'sess_123',
        path = path,
    })

    vim.api.nvim_buf_delete(file_buf, { force = true })
    os.remove(path)

    assert.is_nil(response.error)
    assert.are.equal('unsaved outside read\n', response.result.content)
end)

it('writes fs/write_text_file to a loaded buffer outside allowed roots when the buffer is synchronized', function()
    local path = '/tmp/acp-fs-outside-loaded-write.txt'
    vim.fn.writefile({ 'outside write' }, path)

    api.open_chat()
    api.set_prompt('reject outside loaded write')
    api.submit_prompt()

    local file_buf = vim.fn.bufadd(path)
    vim.fn.bufload(file_buf)

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        content = 'mutated outside\n',
    })

    vim.api.nvim_buf_delete(file_buf, { force = true })
    local disk_lines = vim.fn.readfile(path)
    os.remove(path)

    assert.is_nil(response.error)
    assert.are.same({ 'mutated outside' }, disk_lines)
end)

it('creates a terminal and returns captured output', function()
    api.open_chat()
    api.set_prompt('run terminal command')
    api.submit_prompt()

    local created = fake_client:emit_request('terminal/create', {
        sessionId = 'sess_123',
        command = 'sh',
        args = { '-c', 'printf hello' },
        outputByteLimit = 1024,
    })

    assert.is_nil(created.error)
    assert.is_not_nil(created.result.terminalId)

    local output
    wait_until(function()
        output = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        return output.result ~= nil and output.result.output == 'hello' and output.result.exitStatus ~= nil
    end)

    assert.are.equal(false, output.result.truncated)
    assert.are.same({
        exitCode = 0,
        signal = nil,
    }, output.result.exitStatus)
end)

it('waits for terminal exit', function()
    api.open_chat()
    api.set_prompt('wait for terminal')
    api.submit_prompt()

    local created = fake_client:emit_request('terminal/create', {
        sessionId = 'sess_123',
        command = 'sh',
        args = { '-c', 'sleep 0.05; printf done' },
    })

    local waited = fake_client:emit_request('terminal/wait_for_exit', {
        sessionId = 'sess_123',
        terminalId = created.result.terminalId,
    })

    assert.is_nil(waited.error)
    assert.are.same({
        exitCode = 0,
        signal = nil,
    }, waited.result)
end)

it('kills a running terminal without invalidating it', function()
    api.open_chat()
    api.set_prompt('kill terminal')
    api.submit_prompt()

    local created = fake_client:emit_request('terminal/create', {
        sessionId = 'sess_123',
        command = 'sh',
        args = { '-c', 'printf start; sleep 10' },
    })

    wait_until(function()
        local output = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        return output.result ~= nil and string.find(output.result.output, 'start', 1, true) ~= nil
    end)

    local killed = fake_client:emit_request('terminal/kill', {
        sessionId = 'sess_123',
        terminalId = created.result.terminalId,
    })
    local waited = fake_client:emit_request('terminal/wait_for_exit', {
        sessionId = 'sess_123',
        terminalId = created.result.terminalId,
    })
    local output = fake_client:emit_request('terminal/output', {
        sessionId = 'sess_123',
        terminalId = created.result.terminalId,
    })

    assert.is_nil(killed.error)
    assert.are.same({}, killed.result)
    assert.is_nil(waited.error)
    assert.is_not_nil(waited.result.signal)
    assert.is_nil(waited.result.exitCode)
    assert.is_nil(output.error)
    assert.are.equal(waited.result.signal, output.result.exitStatus.signal)
end)

it('releases a terminal and invalidates its id', function()
    api.open_chat()
    api.set_prompt('release terminal')
    api.submit_prompt()

    local created = fake_client:emit_request('terminal/create', {
        sessionId = 'sess_123',
        command = 'sh',
        args = { '-c', 'printf hello' },
    })

    local released = fake_client:emit_request('terminal/release', {
        sessionId = 'sess_123',
        terminalId = created.result.terminalId,
    })
    local output = fake_client:emit_request('terminal/output', {
        sessionId = 'sess_123',
        terminalId = created.result.terminalId,
    })

    assert.is_nil(released.error)
    assert.are.same({}, released.result)
    assert.is_not_nil(output.error)
end)

it('routes terminal requests through terminal-manager when configured', function()
    local terminal_manager = setup_terminal_manager()

    plugin.setup({
        terminal_backend = 'terminal_manager',
    })
    api.open_chat()
    api.set_prompt('run terminal-manager backend')
    api.submit_prompt()

    local created = fake_client:emit_request('terminal/create', {
        sessionId = 'sess_123',
        command = 'sh',
        args = { '-c', 'printf "$ACP_TERMINAL_MANAGER_VALUE"' },
        env = {
            {
                name = 'ACP_TERMINAL_MANAGER_VALUE',
                value = 'tm',
            },
        },
    })
    local output

    wait_until(function()
        output = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        return output.result ~= nil and output.result.output == 'tm' and output.result.exitStatus ~= nil
    end)

    local terminal = terminal_manager.api.get(created.result.terminalId)

    assert.is_nil(created.error)
    assert.is_not_nil(terminal)
    assert.are.equal('acp', terminal.namespace)
    assert.are.equal('terminal_manager', api.terminal_backend_name())
    assert.are.same({
        exitCode = 0,
        signal = nil,
    }, output.result.exitStatus)

    local released = fake_client:emit_request('terminal/release', {
        sessionId = 'sess_123',
        terminalId = created.result.terminalId,
    })

    assert.is_nil(released.error)
    assert.is_not_nil(terminal_manager.api.get(created.result.terminalId))

    local output_after_release = fake_client:emit_request('terminal/output', {
        sessionId = 'sess_123',
        terminalId = created.result.terminalId,
    })

    assert.is_not_nil(output_after_release.error)
end)

it('applies outputByteLimit in the terminal-manager backend', function()
    setup_terminal_manager()

    plugin.setup({
        terminal_backend = 'terminal_manager',
    })
    api.open_chat()
    api.set_prompt('truncate terminal-manager backend')
    api.submit_prompt()

    local created = fake_client:emit_request('terminal/create', {
        sessionId = 'sess_123',
        command = 'sh',
        args = { '-c', 'printf abcdef' },
        outputByteLimit = 4,
    })
    local output

    wait_until(function()
        output = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        return output.result ~= nil and output.result.exitStatus ~= nil
    end)

    assert.is_nil(output.error)
    assert.are.equal(true, output.result.truncated)
    assert.are.equal('cdef', output.result.output)
end)

it('truncates retained terminal output when outputByteLimit is exceeded', function()
    api.open_chat()
    api.set_prompt('truncate output')
    api.submit_prompt()

    local created = fake_client:emit_request('terminal/create', {
        sessionId = 'sess_123',
        command = 'sh',
        args = { '-c', 'printf abcdef' },
        outputByteLimit = 4,
    })

    local output
    wait_until(function()
        output = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        return output.result ~= nil and output.result.exitStatus ~= nil
    end)

    assert.is_nil(output.error)
    assert.are.equal(true, output.result.truncated)
    assert.are.equal('cdef', output.result.output)
end)

it('keeps terminal truncation sticky across later UTF-8 output chunks', function()
    api.open_chat()
    api.set_prompt('truncate utf8 output')
    api.submit_prompt()

    local created = fake_client:emit_request('terminal/create', {
        sessionId = 'sess_123',
        command = 'sh',
        args = { '-c', "printf 'éé'; sleep 0.05; printf 'a'" },
        outputByteLimit = 3,
    })

    local output
    wait_until(function()
        output = fake_client:emit_request('terminal/output', {
            sessionId = 'sess_123',
            terminalId = created.result.terminalId,
        })

        return output.result ~= nil and output.result.exitStatus ~= nil
    end)

    assert.is_nil(output.error)
    assert.are.equal(true, output.result.truncated)
    assert.are.equal('éa', output.result.output)
end)

it('preserves the existing open-buffer state when fs/write_text_file fails', function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local path = root .. '/write-open-buffer-failure.txt'

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'draft change' })

    chmod(root, '0555')

    api.open_chat()
    api.set_prompt('fail to write through buffer')
    api.submit_prompt()

    local response = fake_client:emit_request('fs/write_text_file', {
        sessionId = 'sess_123',
        path = path,
        content = 'after\nvalue\n',
    })

    chmod(root, '0755')

    assert.is_not_nil(response.error)
    assert.are.same({ 'draft change' }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
    assert.is_true(vim.bo[file_buf].modified)
    assert.is_false(vim.uv.fs_stat(path) ~= nil)
end)

it('cancels stale permission requests after a turn has already completed', function()
    api.open_chat()
    api.set_prompt('finish then stale permission')
    api.submit_prompt()
    fake_client:resolve({
        stopReason = 'end_turn',
    })

    local response = fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_done',
        },
        options = {
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    assert.are.equal('cancelled', response.result.outcome.outcome)
    assert.is_nil(response.result.outcome.optionId)
end)

it('fails closed when the configured permission default is unavailable', function()
    plugin.setup({
        permission_default = 'reject_once',
    })
    api.open_chat()
    api.set_prompt('need permission')
    api.submit_prompt()

    local response = fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_2',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
        },
    })

    assert.are.equal('cancelled', response.result.outcome.outcome)
    assert.is_nil(response.result.outcome.optionId)
end)

it('sends session/cancel for an active remote prompt', function()
    api.open_chat()
    api.set_prompt('cancel me')
    local current_session = api.submit_prompt()

    api.cancel_prompt()

    assert.are.equal('cancelled', current_session.status)
    assert.are.equal('session/cancel', fake_client.notifications[1].method)
    assert.are.equal('sess_123', fake_client.notifications[1].params.sessionId)
end)

it('cancels stale permission requests after a prompt is cancelled', function()
    api.open_chat()
    api.set_prompt('cancel permissions')
    api.submit_prompt()
    api.cancel_prompt()

    local response = fake_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_3',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    assert.are.equal('cancelled', response.result.outcome.outcome)
    assert.is_nil(response.result.outcome.optionId)
end)

it('accepts config_option_update notifications after local cancellation', function()
    local bufnr = api.open_chat()

    api.set_prompt('cancel then update config')
    local current_session = api.submit_prompt()
    api.cancel_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'config_option_update',
            configOptions = {
                {
                    id = 'mode',
                    name = 'Mode',
                    category = 'mode',
                    type = 'select',
                    currentValue = 'code',
                    options = {
                        {
                            value = 'ask',
                            name = 'Ask',
                        },
                        {
                            value = 'code',
                            name = 'Code',
                        },
                    },
                },
            },
        },
    })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('cancelled', current_session.status)
    assert.are.equal('code', current_session.config_options[1].currentValue)
    assert.is_false(vim.tbl_contains(lines, '## Config Options'))
end)

it('cancels a pending inline approval when the prompt is cancelled', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('cancel interactive permissions')
    api.submit_prompt()
    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_4',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    assert.is_nil(response())
    assert.are.equal('call_4', api.pending_approval().tool_call_id)

    api.cancel_prompt()

    assert.are.equal('cancelled', response().result.outcome.outcome)
    assert.is_nil(response().result.outcome.optionId)
    assert.is_nil(api.pending_approval())
    assert.is_false(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '## Approval Needed'))
end)

it('cancels a pending inline approval when the transport is cleared', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('close stale approval')
    api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'call_stale_picker',
            title = 'Edit file',
            status = 'pending',
            kind = 'edit',
        },
    })

    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_stale_picker',
            title = 'Edit file',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    assert.is_nil(response())
    assert.are.equal('call_stale_picker', api.pending_approval().tool_call_id)

    transport.clear()

    assert.are.equal('cancelled', response().result.outcome.outcome)
    assert.is_nil(response().result.outcome.optionId)
    assert.is_nil(api.pending_approval())
    assert.is_false(vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '## Approval Needed'))
end)

it('switches to the cancelled waiting session when cancelling from another local session', function()
    api.open_chat()
    api.set_prompt('cancel from background')
    local first = api.submit_prompt()

    api.new_session()
    api.set_prompt('keep this draft')

    local cancelled = api.cancel_prompt()

    assert.are.equal(first.id, cancelled.id)
    assert.are.equal('cancelled', first.status)
    assert.are.equal(first.id, api.current_session().id)
    assert.are.equal('cancel from background', api.get_prompt())
end)

it('allows creating a new session while another session prompt is still running', function()
    api.open_chat()
    api.set_prompt('hold this turn')
    api.submit_prompt()

    local current_session = api.new_session()

    assert.are.equal('acp:2', current_session.id)
    assert.are.equal('idle', current_session.status)
end)

it('blocks config changes on another local session while a turn is still running', function()
    api.open_chat()
    api.set_prompt('hold this turn')
    local first = api.submit_prompt()
    local second = api.new_session()

    assert.has_error(function()
        api.set_config_option('mode', 'code', second.id)
    end)
    assert.are.equal('waiting', first.status)
    assert.are.equal('sess_123', first.remote_id)
    assert.are.equal(3, #fake_client.sync_calls)
end)

it('rejects submitting a second prompt while a turn is still running', function()
    api.open_chat()
    api.set_prompt('first prompt')
    api.submit_prompt()
    api.set_prompt('second prompt')

    assert.has_error(function()
        api.submit_prompt()
    end)
    assert.are.equal(1, #fake_client.async_calls)
end)

it('uses a fresh remote session for the next prompt turn on the same local session', function()
    local bufnr = api.open_chat()

    api.set_prompt('first turn')
    local current_session = api.submit_prompt()
    local first_client = fake_client
    fake_client:resolve({
        stopReason = 'end_turn',
    })

    api.set_prompt('second turn')
    api.submit_prompt()
    local second_client = fake_client

    first_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'agent_message_chunk',
            content = {
                type = 'text',
                text = 'stale old turn',
            },
        },
    })

    local response = first_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'old_turn',
        },
        options = {
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.is_true(first_client.closed)
    assert.are.equal(3, #second_client.sync_calls)
    assert.are.equal('sess_124', current_session.remote_id)
    assert.are.equal('sess_124', second_client.async_calls[1].params.sessionId)
    assert.are.equal(2, #second_client.async_calls[1].params.prompt)
    assert.is_not_nil(
        string.find(
            second_client.async_calls[1].params.prompt[1].text,
            'Previous conversation transcript for context:',
            1,
            true
        )
    )
    assert.is_not_nil(string.find(second_client.async_calls[1].params.prompt[1].text, '### User\nfirst turn', 1, true))
    assert.is_true(second_client.async_calls[1].params.prompt[2].text:match('second turn%s*$') ~= nil)
    assert.are.equal('cancelled', response.result.outcome.outcome)
    assert.is_false(vim.tbl_contains(lines, 'stale old turn'))
end)

it('uses the active session cwd for fs/read_text_file when process cwd differs', function()
    local workspace = vim.fn.tempname()
    vim.fn.mkdir(workspace, 'p')
    local nested = workspace .. '/nested'
    vim.fn.mkdir(nested, 'p')
    local file_path = workspace .. '/inside.txt'

    api.open_chat()
    api.set_prompt('read from session cwd')
    api.submit_prompt()

    local original_cwd = vim.fn.getcwd()
    vim.cmd('cd ' .. vim.fn.fnameescape(nested))

    local response = fake_client:emit_request('fs/read_text_file', {
        sessionId = 'sess_123',
        path = file_path,
        cwd = workspace,
    })

    vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))

    assert.is_nil(response.error)
    assert.are.same({
        content = '',
    }, response.result)
end)

it('loads an existing remote session for a follow-up turn when the agent supports session/load', function()
    local bufnr = api.open_chat()

    fake_supports_load = true
    fake_on_load = function(client, params)
        client:emit_notification('session/update', {
            sessionId = params.sessionId,
            update = {
                sessionUpdate = 'agent_message_chunk',
                content = {
                    type = 'text',
                    text = 'duplicate history from load',
                },
            },
        })
    end

    api.set_prompt('first turn')
    local current_session = api.submit_prompt()
    local first_client = fake_client

    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'agent_message_chunk',
            content = {
                type = 'text',
                text = 'First answer',
            },
        },
    })
    fake_client:resolve({
        stopReason = 'end_turn',
    })

    api.set_prompt('second turn')
    api.submit_prompt()
    local second_client = fake_client
    first_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'agent_message_chunk',
            content = {
                type = 'text',
                text = 'stale resumed turn',
            },
        },
    })
    local response = first_client:emit_request('session/request_permission', {
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'stale_resume',
        },
        options = {
            {
                optionId = 'allow-once',
                name = 'Allow once',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.is_true(first_client.closed)
    assert.are.equal(3, #second_client.sync_calls)
    assert.are.equal('session/load', second_client.sync_calls[3].method)
    assert.are.equal('sess_123', second_client.sync_calls[3].params.sessionId)
    assert.are.equal('sess_123', current_session.remote_id)
    assert.are.equal('sess_123', second_client.async_calls[1].params.sessionId)
    assert.are.equal(1, #second_client.async_calls[1].params.prompt)
    assert.is_true(second_client.async_calls[1].params.prompt[1].text:match('second turn%s*$') ~= nil)
    assert.are.equal('cancelled', response.result.outcome.outcome)
    assert.is_false(vim.tbl_contains(lines, 'duplicate history from load'))
    assert.is_false(vim.tbl_contains(lines, 'stale resumed turn'))
    assert.is_true(vim.tbl_contains(lines, 'first turn'))
    assert.is_true(vim.tbl_contains(lines, 'First answer'))
end)

it('keeps tool rows coherent after cancellation while still ignoring late chat updates', function()
    local bufnr = api.open_chat()

    api.set_prompt('cancel race')
    local current_session = api.submit_prompt()
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call',
            toolCallId = 'tool_cancel',
            title = 'Run command',
            status = 'in_progress',
            kind = 'execute',
        },
    })
    api.cancel_prompt()

    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'agent_message_chunk',
            content = {
                type = 'text',
                text = 'too late',
            },
        },
    })
    fake_client:emit_notification('session/update', {
        sessionId = 'sess_123',
        update = {
            sessionUpdate = 'tool_call_update',
            toolCallId = 'tool_cancel',
            status = 'completed',
        },
    })
    fake_client:resolve({
        stopReason = 'end_turn',
    })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.are.equal('cancelled', current_session.status)
    assert.are.equal(nil, current_session.stop_reason)
    assert.is_false(vim.tbl_contains(lines, 'too late'))
    assert.is_true(vim.tbl_contains(lines, '✓ Run command'))
    assert.is_false(vim.tbl_contains(lines, '◔ Run command'))
end)

it('routes registered ACP extension requests through the extension registry', function()
    api.open_chat()
    api.set_prompt('extension request')
    api.submit_prompt()

    local seen = nil
    require('acp.handlers').register_request('_vendor/echo', function(_, params, respond)
        seen = vim.deepcopy(params)
        respond({
            echoed = params.value,
        })
    end)

    local response = fake_client:emit_request('_vendor/echo', {
        value = 'hello',
    })

    assert.are.same({
        value = 'hello',
    }, seen)
    assert.are.same({
        echoed = 'hello',
    }, response.result)
    assert.is_nil(response.error)
end)

it('routes registered ACP extension notifications through the extension registry', function()
    api.open_chat()
    api.set_prompt('extension notification')
    api.submit_prompt()

    local seen = nil
    require('acp.handlers').register_notification('_vendor/did_echo', function(_, params)
        seen = vim.deepcopy(params)
    end)

    fake_client:emit_notification('_vendor/did_echo', {
        value = 'hello',
    })

    assert.are.same({
        value = 'hello',
    }, seen)
end)

it('rejects non-extension ACP method names for registry registration', function()
    local handler_registry = require('acp.handlers')

    assert.has_error(function()
        handler_registry.register_request('session/update', function() end)
    end, 'ACP extension methods must begin with `_`: session/update')
    assert.has_error(function()
        handler_registry.register_notification('terminal/create', function() end)
    end, 'ACP extension methods must begin with `_`: terminal/create')
end)

it('returns method-not-found for unregistered ACP extension requests and ignores notifications', function()
    api.open_chat()
    api.set_prompt('unregistered extension')
    api.submit_prompt()

    local response = fake_client:emit_request('_vendor/missing', {
        value = 'hello',
    })

    fake_client:emit_notification('_vendor/ignored', {
        value = 'hello',
    })

    assert.is_nil(response.result)
    assert.are.same({
        code = -32601,
        message = 'Unsupported ACP request: _vendor/missing',
    }, response.error)
end)

it('returns controlled errors for non-string ACP method names', function()
    api.open_chat()
    api.set_prompt('invalid method type')
    api.submit_prompt()

    local active = fake_client:emit_request(false, {})

    assert.is_nil(active.result)
    assert.are.same({
        code = -32601,
        message = 'Unsupported ACP request: false',
    }, active.error)

    fake_client:resolve({
        stopReason = 'cancelled',
    })

    local inactive = fake_client:emit_request(42, {})

    assert.is_nil(inactive.result)
    assert.are.same({
        code = -32000,
        message = 'ACP request is no longer active',
    }, inactive.error)

    fake_client:emit_notification({}, {
        value = 'hello',
    })
end)

it('clears registered ACP extension handlers when transport state is reset', function()
    api.open_chat()
    api.set_prompt('clear extension registry')
    api.submit_prompt()

    local count = 0
    local handler_registry = require('acp.handlers')

    handler_registry.register_request('_vendor/echo', function(_, _, respond)
        count = count + 1
        respond({
            ok = true,
        })
    end)

    local first = fake_client:emit_request('_vendor/echo', {})

    fake_client:resolve({
        stopReason = 'cancelled',
    })
    transport.clear()

    local stale = fake_client:emit_request('_vendor/echo', {})
    local second = handler_registry.extension_request_handler('_vendor/echo')

    assert.are.equal(1, count)
    assert.are.same({
        ok = true,
    }, first.result)
    assert.is_nil(first.error)
    assert.is_nil(stale.result)
    assert.are.same({
        code = -32000,
        message = 'ACP request is no longer active',
    }, stale.error)
    assert.is_nil(second)
end)

it('prefers exact numeric option ids over numeric index parsing', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('numeric option id')
    api.submit_prompt()

    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_numeric_id',
            title = 'Run command',
        },
        options = {
            {
                optionId = 'zero',
                name = 'Zero',
                kind = 'reject_once',
            },
            {
                optionId = '1',
                name = 'One by id',
                kind = 'allow_once',
            },
        },
    })

    api.select_approval_option('1')

    assert.are.equal('selected', response().result.outcome.outcome)
    assert.are.equal('1', response().result.outcome.optionId)
end)

it('keeps an existing pending approval when another request queues behind it', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('first pending approval')
    api.submit_prompt()

    local first_response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_first_session',
            title = 'First command',
        },
        options = {
            {
                optionId = 'allow-first',
                name = 'Allow first',
                kind = 'allow_once',
            },
        },
    })

    local second_response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_second_session',
            title = 'Second command',
        },
        options = {
            {
                optionId = 'allow-second',
                name = 'Allow second',
                kind = 'allow_once',
            },
        },
    })

    assert.is_nil(first_response())
    assert.are.equal('call_first_session', api.pending_approval().tool_call_id)
    assert.are.equal(2, #api.pending_approvals())
    assert.is_nil(second_response())
end)

it('renders pending approval options without embedding raw option ids in command guidance', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('escaped approval display')
    api.submit_prompt()

    begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_escaped_display',
            title = 'Run command',
        },
        options = {
            {
                optionId = '1`\n2',
                name = 'Allow`\nnow',
                kind = 'allow_`\nonce',
            },
        },
    })

    local lines = require('acp.status_message').pending_approval_lines(api.current_session(), api.pending_approval())
    assert.are.equal(
        [[Allow\` now [allow_\` once] (`1\` 2`)  ->  select with `g1`, `:ACPSelectApprovalOption 1`, or use the inline action]],
        lines[5]
    )
end)

it('resolves numeric command selections by index when option ids contain special characters', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    api.open_chat()
    api.set_prompt('escaped approval selection')
    api.submit_prompt()

    local response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_escaped_selection',
            title = 'Run command',
        },
        options = {
            {
                optionId = '1`\n2',
                name = 'Allow`\nnow',
                kind = 'allow_once',
            },
            {
                optionId = 'reject-once',
                name = 'Reject',
                kind = 'reject_once',
            },
        },
    })

    vim.cmd('ACPSelectApprovalOption 1')

    assert.are.equal('selected', response().result.outcome.outcome)
    assert.are.equal('1`\n2', response().result.outcome.optionId)
end)

it('resolves inline approval keymaps using request-qualified selections', function()
    plugin.setup({
        permission_strategy = 'select',
    })
    local bufnr = api.open_chat()
    api.set_prompt('queued inline approval selection')
    api.submit_prompt()

    begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_first_inline',
            title = 'First command',
        },
        options = {
            {
                optionId = 'allow-first',
                name = 'Allow first',
                kind = 'allow_once',
            },
        },
    })

    local second_response = begin_permission_request({
        sessionId = 'sess_123',
        toolCall = {
            toolCallId = 'call_second_inline',
            title = 'Second command',
        },
        options = {
            {
                optionId = 'allow-second',
                name = 'Allow second',
                kind = 'allow_once',
            },
        },
    })

    assert.is_true(vim.tbl_contains(approval_virtual_lines(bufnr), 'g1 Allow first'))

    vim.api.nvim_feedkeys(vim.keycode('g1'), 'xt', false)

    assert.is_true(vim.wait(1000, function()
        return api.pending_approval() ~= nil and api.pending_approval().tool_call_id == 'call_second_inline'
    end, 10))
    assert.is_nil(second_response())
    assert.are.equal('call_second_inline', api.pending_approval().tool_call_id)

    vim.api.nvim_feedkeys(vim.keycode('g1'), 'xt', false)

    assert.is_true(vim.wait(1000, function()
        return second_response() ~= nil
    end, 10))
    assert.are.equal('selected', second_response().result.outcome.outcome)
    assert.are.equal('allow-second', second_response().result.outcome.optionId)
    assert.is_nil(api.pending_approval())
end)
