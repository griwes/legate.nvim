local buffer = require('legate.ui.buffer')

---@class legate.FileSystemModule
local M = {}

local REQUEST_ERROR_CODE = -32000
local write_guard_group = vim.api.nvim_create_augroup('legate-acp-fs-write-guard', {
    clear = true,
})

---@class legate.FileWriteAuthorization
---@field canonical_target string
---@field canonical_roots string[]
---@field allow_outside_roots boolean

---@type table<integer, legate.FileWriteAuthorization>
local write_authorizations = {}
---@type table<integer, boolean>
local guarded_buffers = {}

---@class legate.FileSnapshot
---@field lines string[]
---@field endofline boolean

---@param path string
---@return boolean
local function is_absolute_path(path)
    if type(path) ~= 'string' then
        return false
    end

    return path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil or path:match('^[/\\][/\\]') ~= nil
end

---@param message string
---@return table
local function request_error(message)
    return {
        code = REQUEST_ERROR_CODE,
        message = message,
    }
end

---@param path string
---@return string
local function normalize_path(path)
    if type(path) == 'string' and (path:match('^%a:[/\\]') ~= nil or path:match('^[/\\][/\\]') ~= nil) then
        return vim.fs.normalize(path)
    end

    return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

---@param path string
---@return integer?
local find_loaded_buffer

---@param path string
---@return integer?
local find_buffer

---@param cwd? string
---@return string[]
local function allowed_roots(cwd)
    local roots = {}
    local seen = {}

    local function add_root(path)
        if type(path) ~= 'string' or path == '' then
            return
        end

        local normalized = normalize_path(path)

        if not seen[normalized] then
            seen[normalized] = true
            table.insert(roots, normalized)
        end
    end

    add_root(require('legate.config').get().cwd)
    add_root(cwd)
    add_root(vim.fn.getcwd())

    return roots
end

---@param path string
---@param root string
---@return boolean
local function is_within_root(path, root)
    local normalized_path = path:gsub('\\', '/')
    local normalized_root = root:gsub('\\', '/')

    if vim.fn.has('win32') == 1 then
        normalized_path = normalized_path:lower()
        normalized_root = normalized_root:lower()
    end

    if normalized_path ~= '/' then
        normalized_path = normalized_path:gsub('/+$', '')
    end

    if normalized_root ~= '/' then
        normalized_root = normalized_root:gsub('/+$', '')
    end

    return normalized_path == normalized_root or vim.startswith(normalized_path, normalized_root .. '/')
end

---@param path string
---@return boolean
local function is_foreign_windows_path(path)
    if vim.fn.has('win32') == 1 then
        return false
    end

    return path:match('^%a:[/\\]') ~= nil or path:sub(1, 2) == '\\\\'
end

---@param left string
---@param right string
---@return boolean
local function paths_equal(left, right)
    if vim.fn.has('win32') == 1 then
        return left:lower() == right:lower()
    end

    return left == right
end

---@param path string
---@return string?, string?
local function canonical_existing_path(path)
    local resolved = vim.uv.fs_realpath(path)

    if resolved ~= nil then
        return normalize_path(resolved), nil
    end

    if vim.uv.fs_lstat(path) ~= nil then
        return nil, string.format('ACP file path contains an unresolved symbolic link: %s', path)
    end

    return nil, nil
end

---@param path string
---@return string?, string?
local function canonical_missing_path(path)
    local candidate = path
    local suffix = {}

    while candidate ~= nil and candidate ~= '' do
        local resolved, resolution_error = canonical_existing_path(candidate)

        if resolution_error ~= nil then
            return nil, resolution_error
        end

        if resolved ~= nil then
            for index = #suffix, 1, -1 do
                resolved = vim.fs.joinpath(resolved, suffix[index])
            end

            return normalize_path(resolved), nil
        end

        table.insert(suffix, vim.fs.basename(candidate))
        local next_candidate = vim.fs.dirname(candidate)

        if next_candidate == candidate then
            break
        end

        candidate = next_candidate
    end

    return nil, string.format('ACP file path has no existing parent: %s', path)
end

---@param path string
---@return string?, string?
local function canonical_path(path)
    local canonical, canonical_error = canonical_existing_path(path)

    if canonical ~= nil or canonical_error ~= nil then
        return canonical, canonical_error
    end

    return canonical_missing_path(path)
end

---@param cwd? string
---@return string[], string?
local function canonical_allowed_roots(cwd)
    local roots = {}
    local seen = {}
    local first_error = nil

    for _, root in ipairs(allowed_roots(cwd)) do
        if is_foreign_windows_path(root) then
            first_error = first_error
                or string.format('Windows ACP file paths are unsupported on this platform: %s', root)
        else
            local canonical_root, canonical_error = canonical_path(root)

            if canonical_root ~= nil and not seen[canonical_root] then
                seen[canonical_root] = true
                table.insert(roots, canonical_root)
            else
                first_error = first_error or canonical_error
            end
        end
    end

    return roots, first_error
end

---@param path string
---@param cwd? string
---@return legate.FileWriteAuthorization?, string?
local function canonical_authorization(path, cwd)
    local canonical_target, target_error = canonical_path(path)

    if canonical_target == nil then
        return nil, target_error
    end

    local canonical_roots, roots_error = canonical_allowed_roots(cwd)

    for _, root in ipairs(canonical_roots) do
        if is_within_root(canonical_target, root) then
            return {
                canonical_target = canonical_target,
                canonical_roots = canonical_roots,
                allow_outside_roots = false,
            },
                nil
        end
    end

    if #canonical_roots == 0 and roots_error ~= nil then
        return nil, roots_error
    end

    return nil,
        string.format('ACP file path resolves outside an allowed workspace root through a symbolic link: %s', path)
end

---@param path string
---@param cwd? string
---@param opts? { allow_loaded_buffer_read: boolean, allow_loaded_buffer_write: boolean }
---@return string?, table?, legate.FileWriteAuthorization?
local function validate_absolute_path(path, cwd, opts)
    if not is_absolute_path(path) then
        return nil, request_error(string.format('ACP file path must be absolute: %s', path))
    end

    local normalized_path = normalize_path(path)

    if is_foreign_windows_path(normalized_path) then
        return nil,
            request_error(string.format('Windows ACP file paths are unsupported on this platform: %s', path)),
            nil
    end

    local lexically_allowed = false

    for _, root in ipairs(allowed_roots(cwd)) do
        if is_within_root(normalized_path, root) then
            lexically_allowed = true
            break
        end
    end

    if lexically_allowed then
        local authorization, authorization_error = canonical_authorization(normalized_path, cwd)

        if authorization ~= nil then
            return normalized_path, nil, authorization
        end

        return nil, request_error(authorization_error), nil
    end

    if opts ~= nil then
        local allow_loaded_buffer = opts.allow_loaded_buffer_read == true or opts.allow_loaded_buffer_write == true

        if allow_loaded_buffer and find_loaded_buffer(normalized_path) ~= nil then
            local canonical_target, canonical_error = canonical_path(normalized_path)

            if canonical_target == nil then
                return nil, request_error(canonical_error), nil
            end

            return normalized_path,
                nil,
                {
                    canonical_target = canonical_target,
                    canonical_roots = {},
                    allow_outside_roots = true,
                }
        end
    end

    return nil, request_error(string.format('ACP file path must stay within an allowed workspace root: %s', path)), nil
end

---@param bufnr integer
local function attach_write_guard(bufnr)
    if guarded_buffers[bufnr] then
        return
    end

    guarded_buffers[bufnr] = true

    vim.api.nvim_create_autocmd('BufWritePre', {
        group = write_guard_group,
        buffer = bufnr,
        callback = function(args)
            local authorization = write_authorizations[args.buf]

            if authorization == nil then
                return
            end

            local target = args.file ~= '' and normalize_path(args.file) or vim.api.nvim_buf_get_name(args.buf)

            if is_foreign_windows_path(target) then
                error(string.format('ACP write authorization rejected a foreign Windows path: %s', target))
            end

            local canonical_target, canonical_error = canonical_path(target)

            if canonical_target == nil then
                error(canonical_error)
            end

            if not paths_equal(canonical_target, authorization.canonical_target) then
                error(
                    string.format(
                        'ACP write authorization target changed from %s to %s',
                        authorization.canonical_target,
                        canonical_target
                    )
                )
            end

            if not authorization.allow_outside_roots then
                local contained = false

                for _, root in ipairs(authorization.canonical_roots) do
                    if is_within_root(canonical_target, root) then
                        contained = true
                        break
                    end
                end

                if not contained then
                    error(string.format('ACP write authorization target left its allowed roots: %s', canonical_target))
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd('BufWritePost', {
        group = write_guard_group,
        buffer = bufnr,
        callback = function(args)
            write_authorizations[args.buf] = nil
        end,
    })

    vim.api.nvim_create_autocmd('BufWipeout', {
        group = write_guard_group,
        buffer = bufnr,
        once = true,
        callback = function(args)
            write_authorizations[args.buf] = nil
            guarded_buffers[args.buf] = nil
        end,
    })
end

---@param path string
---@return integer?
find_loaded_buffer = function(path)
    local target = normalize_path(path)

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)

            if name ~= '' and normalize_path(name) == target then
                return bufnr
            end
        end
    end

    return nil
end

---@param path string
---@return integer?
find_buffer = function(path)
    local target = normalize_path(path)

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)

            if name ~= '' and normalize_path(name) == target then
                return bufnr
            end
        end
    end

    return nil
end

---@param path string
---@return integer?, table?
local function ensure_loaded_buffer(path)
    local normalized = normalize_path(path)
    local bufnr = find_buffer(normalized)

    if bufnr == nil then
        bufnr = vim.fn.bufadd(normalized)

        if bufnr == 0 then
            return nil, request_error(string.format('Failed to create buffer for path: %s', normalized))
        end
    end

    if not vim.api.nvim_buf_is_loaded(bufnr) then
        local ok, load_err = pcall(vim.fn.bufload, bufnr)

        if not ok then
            return nil, request_error(string.format('Failed to load buffer %d: %s', bufnr, tostring(load_err)))
        end
    end

    return bufnr, nil
end

---@param lines string[]
---@param endofline boolean
---@return string
local function encode_snapshot(lines, endofline)
    if #lines == 0 then
        return ''
    end

    local content = table.concat(lines, '\n')

    if endofline and #lines > 0 then
        return content .. '\n'
    end

    return content
end

---@param text string
---@return legate.FileSnapshot
local function decode_content(text)
    if text == '' then
        return {
            lines = {},
            endofline = false,
        }
    end

    local endofline = text:sub(-1) == '\n'
    local lines = vim.split(text, '\n', {
        plain = true,
    })

    if endofline then
        table.remove(lines, #lines)
    end

    if #lines == 0 then
        lines = { '' }
    end

    return {
        lines = lines,
        endofline = endofline,
    }
end

---@param bufnr integer
---@return legate.FileSnapshot
local function read_buffer_snapshot(bufnr)
    return {
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        endofline = vim.bo[bufnr].endofline,
    }
end

---@param bufnr integer
---@param snapshot legate.FileSnapshot
---@return table?
local function write_buffer_snapshot(bufnr, snapshot)
    local ok, write_error = pcall(function()
        buffer.with_mutation(bufnr, function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, snapshot.lines)
            vim.bo[bufnr].endofline = snapshot.endofline
        end)
    end)

    if not ok then
        return request_error(tostring(write_error))
    end

    return nil
end

---@param path string
---@return legate.FileSnapshot?, table?
local function read_disk_snapshot(path)
    local handle, open_error = io.open(path, 'rb')

    if handle == nil then
        local stat = vim.uv.fs_stat(path)
        local missing_file = stat == nil and vim.uv.fs_lstat(path) == nil

        if missing_file then
            return {
                lines = {},
                endofline = false,
            }, nil
        end

        return nil, request_error(open_error or string.format('Failed to read file: %s', path))
    end

    local ok, content = pcall(handle.read, handle, '*a')
    handle:close()

    if not ok then
        return nil, request_error(string.format('Failed to read file: %s', path))
    end

    return decode_content(content)
end

---@param snapshot legate.FileSnapshot
---@param start_line integer
---@param limit integer?
---@return string
local function slice_snapshot(snapshot, start_line, limit)
    local total_lines = #snapshot.lines

    if total_lines == 0 then
        return ''
    end

    if start_line > total_lines then
        return ''
    end

    if limit ~= nil and limit <= 0 then
        return ''
    end

    local last_line = total_lines

    if limit ~= nil then
        last_line = math.min(total_lines, start_line + limit - 1)
    end

    local lines = {}

    for index = start_line, last_line do
        table.insert(lines, snapshot.lines[index])
    end

    local trailing_newline = last_line < total_lines or snapshot.endofline
    return encode_snapshot(lines, trailing_newline)
end

---@param path string
---@param cwd? string
---@return legate.FileSnapshot?, table?
local function effective_snapshot(path, cwd)
    local valid_path, path_error = validate_absolute_path(path, cwd, {
        allow_loaded_buffer_read = true,
    })

    if valid_path == nil then
        return nil, path_error
    end

    local bufnr = find_loaded_buffer(valid_path)

    if bufnr ~= nil then
        return read_buffer_snapshot(bufnr)
    end

    return read_disk_snapshot(valid_path)
end

---Read text from the effective ACP client file source.
---@param params legate.ReadTextFileRequest
---@return legate.ReadTextFileResponse?, table?
function M.read_text_file(params)
    local snapshot, snapshot_error = effective_snapshot(params.path, params.cwd)

    if snapshot == nil then
        return nil, snapshot_error
    end

    local start_line = math.max(params.line or 1, 1)
    local content = slice_snapshot(snapshot, start_line, params.limit)

    return {
        content = content,
    }, nil
end

---Write text into the ACP client file source through a Neovim buffer.
---@param params legate.WriteTextFileRequest
---@return legate.WriteTextFileResponse?, table?
function M.write_text_file(params)
    local path, path_error, authorization = validate_absolute_path(params.path, params.cwd, {
        allow_loaded_buffer_write = true,
    })

    if path == nil then
        return nil, path_error
    end

    if type(params.content) ~= 'string' then
        return nil, request_error('content must be a string')
    end

    local requested_snapshot = decode_content(params.content)
    local bufnr, load_error = ensure_loaded_buffer(path)

    if load_error ~= nil then
        return nil, load_error
    end

    local write_error = write_buffer_snapshot(bufnr, requested_snapshot)

    if write_error ~= nil then
        return nil, write_error
    end

    write_authorizations[bufnr] = authorization
    attach_write_guard(bufnr)

    return {}, nil
end

return M
