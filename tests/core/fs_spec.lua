local config = require('legate.config')
local fs = require('legate.core.fs')
local is_windows = vim.fn.has('win32') == 1

describe('acp filesystem boundaries', function()
    local root
    local outside

    local function write_file(path, content)
        local handle = assert(io.open(path, 'wb'))
        assert(handle:write(content))
        handle:close()
    end

    local function read_file(path)
        local handle = assert(io.open(path, 'rb'))
        local content = assert(handle:read('*a'))
        handle:close()
        return content
    end

    local function create_symlink(target, path)
        local created, err = vim.uv.fs_symlink(target, path)

        if not created then
            pending(string.format('symlink creation is unavailable: %s', err or 'unknown error'))
        end

        return created
    end

    before_each(function()
        root = vim.fn.tempname()
        outside = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        vim.fn.mkdir(outside, 'p')
        config.set({ cwd = root })
    end)

    after_each(function()
        config.reset()
        vim.fn.delete(root, 'rf')
        vim.fn.delete(outside, 'rf')
    end)

    it('rejects reads through a symlink that escapes the workspace', function()
        write_file(vim.fs.joinpath(outside, 'secret.txt'), 'secret\n')
        create_symlink(outside, vim.fs.joinpath(root, 'escape'))

        local result, err = fs.read_text_file({
            path = vim.fs.joinpath(root, 'escape', 'secret.txt'),
        })

        assert.is_nil(result)
        assert.is_true(err.message:match('resolves outside') ~= nil)
        assert.is_true(err.message:match('symbolic link') ~= nil)
    end)

    it('rejects new files whose nearest existing parent escapes through a symlink', function()
        create_symlink(outside, vim.fs.joinpath(root, 'escape'))

        local result, err = fs.write_text_file({
            path = vim.fs.joinpath(root, 'escape', 'new', 'file.txt'),
            content = 'unsafe\n',
        })

        assert.is_nil(result)
        assert.is_true(err.message:match('resolves outside') ~= nil)
        assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(outside, 'new', 'file.txt')))
    end)

    it('does not let a loaded buffer bypass a detected symlink escape', function()
        local outside_path = vim.fs.joinpath(outside, 'secret.txt')
        local escaped_path = vim.fs.joinpath(root, 'escape', 'secret.txt')
        write_file(outside_path, 'secret\n')
        create_symlink(outside, vim.fs.joinpath(root, 'escape'))

        local bufnr = vim.fn.bufadd(escaped_path)
        vim.fn.bufload(bufnr)

        local read_result, read_error = fs.read_text_file({ path = escaped_path })
        local write_result, write_error = fs.write_text_file({
            path = escaped_path,
            content = 'changed\n',
        })

        assert.is_nil(read_result)
        assert.is_true(read_error.message:match('resolves outside') ~= nil)
        assert.is_nil(write_result)
        assert.is_true(write_error.message:match('resolves outside') ~= nil)
        assert.are.equal('secret\n', read_file(outside_path))
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('allows symlinks that resolve within the workspace', function()
        local target = vim.fs.joinpath(root, 'target')
        vim.fn.mkdir(target, 'p')
        write_file(vim.fs.joinpath(target, 'inside.txt'), 'inside\n')
        create_symlink(target, vim.fs.joinpath(root, 'inside-link'))

        local result, err = fs.read_text_file({
            path = vim.fs.joinpath(root, 'inside-link', 'inside.txt'),
        })

        assert.is_nil(err)
        assert.are.equal('inside\n', result.content)
    end)

    it('rejects broken final symlinks explicitly', function()
        local path = vim.fs.joinpath(root, 'broken-link')
        create_symlink(vim.fs.joinpath(root, 'missing'), path)

        local result, err = fs.read_text_file({ path = path })

        assert.is_nil(result)
        assert.is_true(err.message:match('unresolved symbolic link') ~= nil)
    end)

    it('allows a symlink target inside another allowed canonical root', function()
        local target = vim.fs.joinpath(outside, 'shared.txt')
        write_file(target, 'shared\n')
        create_symlink(outside, vim.fs.joinpath(root, 'shared-root'))

        local result, err = fs.read_text_file({
            path = vim.fs.joinpath(root, 'shared-root', 'shared.txt'),
            cwd = outside,
        })

        assert.is_nil(err)
        assert.are.equal('shared\n', result.content)
    end)

    it('blocks a later write after the authorized symlink target is retargeted', function()
        local safe = vim.fs.joinpath(root, 'safe.txt')
        local victim = vim.fs.joinpath(outside, 'victim.txt')
        local link = vim.fs.joinpath(root, 'link.txt')
        write_file(safe, 'safe\n')
        write_file(victim, 'victim\n')
        create_symlink(safe, link)

        local result, err = fs.write_text_file({
            path = link,
            content = 'agent\n',
        })
        local bufnr = vim.fn.bufnr(link)

        assert.is_nil(err)
        assert.are.same({}, result)
        assert.is_truthy(vim.uv.fs_unlink(link))
        create_symlink(victim, link)

        local write_ok, write_error = pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd('silent write!')
        end)

        assert.is_false(write_ok)
        assert.is_true(tostring(write_error):match('ACP write authorization target changed') ~= nil)
        assert.are.equal('victim\n', read_file(victim))
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('blocks a later write after an authorized symlink parent is retargeted', function()
        local safe_parent = vim.fs.joinpath(root, 'safe-parent')
        local link_parent = vim.fs.joinpath(root, 'linked-parent')
        vim.fn.mkdir(safe_parent, 'p')
        local safe = vim.fs.joinpath(safe_parent, 'file.txt')
        local victim = vim.fs.joinpath(outside, 'file.txt')
        write_file(safe, 'safe\n')
        write_file(victim, 'victim\n')
        create_symlink(safe_parent, link_parent)

        local path = vim.fs.joinpath(link_parent, 'file.txt')
        local result, err = fs.write_text_file({
            path = path,
            content = 'agent\n',
        })
        local bufnr = vim.fn.bufnr(path)

        assert.is_nil(err)
        assert.are.same({}, result)
        assert.is_truthy(vim.uv.fs_unlink(link_parent))
        create_symlink(outside, link_parent)

        local write_ok = pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd('silent write!')
        end)

        assert.is_false(write_ok)
        assert.are.equal('victim\n', read_file(victim))
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    if is_windows then
        it('accepts an actual Windows absolute path inside the configured root', function()
            local path = vim.fs.joinpath(root, 'windows.txt')
            local result, err = fs.write_text_file({
                path = path,
                content = 'windows\n',
            })

            assert.is_nil(err)
            assert.are.same({}, result)
            vim.api.nvim_buf_delete(vim.fn.bufnr(path), { force = true })
        end)
    else
        it('rejects foreign Windows paths instead of treating them as local paths', function()
            config.set({ cwd = [[C:\workspace]] })

            local result, err = fs.write_text_file({
                path = [[C:\workspace\file.txt]],
                content = 'foreign\n',
            })

            assert.is_nil(result)
            assert.is_true(err.message:match('unsupported on this platform') ~= nil)
        end)
    end
end)
