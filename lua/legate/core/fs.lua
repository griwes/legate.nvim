local buffer = require('legate.ui.buffer')

---@class legate.FileSystemModule
local M = {}

local REQUEST_ERROR_CODE = -32000

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

    if normalized_path ~= '/' then
        normalized_path = normalized_path:gsub('/+$', '')
    end

    if normalized_root ~= '/' then
        normalized_root = normalized_root:gsub('/+$', '')
    end

    return normalized_path == normalized_root or vim.startswith(normalized_path, normalized_root .. '/')
end

---@param path string
---@param cwd? string
---@param opts? { allow_loaded_buffer_read: boolean, allow_loaded_buffer_write: boolean }
---@return string?, table?
local function validate_absolute_path(path, cwd, opts)
    if not is_absolute_path(path) then
        return nil, request_error(string.format('ACP file path must be absolute: %s', path))
    end

    local normalized_path = normalize_path(path)

    for _, root in ipairs(allowed_roots(cwd)) do
        if is_within_root(normalized_path, root) then
            return normalized_path, nil
        end
    end

    if opts ~= nil then
        local allow_loaded_buffer = opts.allow_loaded_buffer_read == true or opts.allow_loaded_buffer_write == true

        if allow_loaded_buffer and find_loaded_buffer(normalized_path) ~= nil then
            return normalized_path, nil
        end
    end

    return nil, request_error(string.format('ACP file path must stay within an allowed workspace root: %s', path))
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

---@param bufnr integer
---@return table?
local function reload_buffer_from_disk(bufnr)
    local target_win = vim.fn.bufwinid(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    local ok, reload_error = pcall(function()
        buffer.with_mutation(bufnr, function()
            if target_win ~= -1 then
                vim.fn.win_execute(target_win, 'silent keepalt keepjumps lockmarks edit!')
                return
            end

            local snapshot, read_error = read_disk_snapshot(path)

            if snapshot == nil then
                error(read_error and read_error.message or string.format('Failed to read file: %s', path))
            end

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, snapshot.lines)
            vim.bo[bufnr].endofline = snapshot.endofline

            local fileformat = 'unix'
            if snapshot.endofline then
                local handle, open_error = io.open(path, 'rb')

                if handle == nil then
                    error(open_error or string.format('Failed to read file: %s', path))
                end

                local ok_read, content = pcall(handle.read, handle, '*a')
                handle:close()

                if not ok_read then
                    error(string.format('Failed to read file: %s', path))
                end

                if content:find('\r\n', 1, true) ~= nil then
                    fileformat = 'dos'
                end
            end

            vim.bo[bufnr].fileformat = fileformat
            vim.bo[bufnr].modified = false
        end)
    end)

    if not ok then
        return request_error(tostring(reload_error))
    end

    return nil
end

---@param bufnr integer
---@return table?
local function validate_hidden_buffer_sync(bufnr)
    if vim.fn.bufwinid(bufnr) ~= -1 then
        return nil
    end

    local snapshot = read_buffer_snapshot(bufnr)
    local ok, sync_error = pcall(function()
        buffer.with_mutation(bufnr, function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, snapshot.lines)
            vim.bo[bufnr].endofline = snapshot.endofline
        end)
    end)

    if not ok then
        return request_error(tostring(sync_error))
    end

    return nil
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

---@param path string
---@param content string
---@return table?
local function write_disk(path, content)
    local parent = vim.fn.fnamemodify(path, ':h')

    if parent ~= '' then
        local mkdir_ok, ok = pcall(vim.fn.mkdir, parent, 'p')

        if not mkdir_ok then
            return request_error(ok or string.format('Failed to create parent directory: %s', parent))
        end

        if ok == 0 and vim.fn.isdirectory(parent) == 0 then
            return request_error(string.format('Failed to create parent directory: %s', parent))
        end
    end

    local handle, open_error = io.open(path, 'wb')

    if handle == nil then
        return request_error(open_error or string.format('Failed to write file: %s', path))
    end

    local ok, write_error = handle:write(content)
    handle:close()

    if not ok then
        return request_error(write_error or string.format('Failed to write file: %s', path))
    end

    return nil
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

---Write text into the ACP client file source and keep Neovim buffers synchronized.
---@param params legate.WriteTextFileRequest
---@return legate.WriteTextFileResponse?, table?
function M.write_text_file(params)
    local path, path_error = validate_absolute_path(params.path, params.cwd, {
        allow_loaded_buffer_write = true,
    })

    if path == nil then
        return nil, path_error
    end

    if type(params.content) ~= 'string' then
        return nil, request_error('content must be a string')
    end

    local requested_snapshot = decode_content(params.content)
    local requested_content = encode_snapshot(requested_snapshot.lines, requested_snapshot.endofline)
    local bufnr = find_loaded_buffer(path)
    local current_snapshot = bufnr ~= nil and read_buffer_snapshot(bufnr) or nil

    if current_snapshot ~= nil then
        if vim.bo[bufnr].modified then
            return nil, request_error(string.format('Cannot synchronize modified buffer for file: %s', path))
        end

        if vim.bo[bufnr].modifiable == false then
            local buftype = vim.api.nvim_get_option_value('buftype', {
                buf = bufnr,
            })

            if buftype ~= '' or vim.fn.bufwinid(bufnr) ~= -1 then
                return nil, request_error(string.format('Cannot synchronize non-modifiable buffer for file: %s', path))
            end
        end

        local sync_error = validate_hidden_buffer_sync(bufnr)

        if sync_error ~= nil then
            return nil, sync_error
        end

        if encode_snapshot(current_snapshot.lines, current_snapshot.endofline) == requested_content then
            return {}, nil
        end
    end

    local write_error = write_disk(path, requested_content)

    if write_error ~= nil then
        return nil, write_error
    end

    if bufnr ~= nil then
        local sync_error = reload_buffer_from_disk(bufnr)

        if sync_error ~= nil then
            return {
                sync_error = sync_error.message,
            }, nil
        end
    end

    return {}, nil
end

return M
