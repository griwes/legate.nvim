---@class acp.FileSystemModule
local M = {}

local REQUEST_ERROR_CODE = -32000

---@class acp.FileSnapshot
---@field lines string[]
---@field endofline boolean

---@param path string
---@return boolean
local function is_absolute_path(path)
    return type(path) == 'string' and path:sub(1, 1) == '/'
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
---@return string?, table?
local function validate_absolute_path(path)
    if not is_absolute_path(path) then
        return nil, request_error(string.format('ACP file path must be absolute: %s', path))
    end

    return path, nil
end

---@param path string
---@return string
local function normalize_path(path)
    return vim.fn.fnamemodify(path, ':p')
end

---@param path string
---@return integer?
local function find_loaded_buffer(path)
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
---@return acp.FileSnapshot
local function decode_content(text)
    if text == '' then
        return {
            lines = { '' },
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
---@return acp.FileSnapshot
local function read_buffer_snapshot(bufnr)
    return {
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        endofline = vim.bo[bufnr].endofline,
    }
end

---@param bufnr integer
---@param snapshot acp.FileSnapshot
---@param modified boolean
---@return table?
local function apply_buffer_snapshot(bufnr, snapshot, modified)
    local was_modifiable = vim.bo[bufnr].modifiable
    local ok, apply_error = pcall(function()
        if not was_modifiable then
            vim.bo[bufnr].modifiable = true
        end

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, snapshot.lines)
        vim.bo[bufnr].endofline = snapshot.endofline
        vim.bo[bufnr].modified = modified
        vim.bo[bufnr].modifiable = was_modifiable
    end)

    if not ok then
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.bo[bufnr].modifiable = was_modifiable
        end

        return request_error(tostring(apply_error))
    end

    return nil
end

---@param path string
---@return acp.FileSnapshot?, table?
local function read_disk_snapshot(path)
    local handle, open_error = io.open(path, 'rb')

    if handle == nil then
        return nil, request_error(open_error or string.format('Failed to read file: %s', path))
    end

    local ok, content = pcall(handle.read, handle, '*a')
    handle:close()

    if not ok then
        return nil, request_error(string.format('Failed to read file: %s', path))
    end

    return decode_content(content)
end

---@param snapshot acp.FileSnapshot
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
---@return acp.FileSnapshot?, table?
local function effective_snapshot(path)
    local valid_path, path_error = validate_absolute_path(path)

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
        local ok = vim.fn.mkdir(parent, 'p')

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
---@param params acp.ReadTextFileRequest
---@return acp.ReadTextFileResponse?, table?
function M.read_text_file(params)
    local snapshot, snapshot_error = effective_snapshot(params.path)

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
---@param params acp.WriteTextFileRequest
---@return acp.WriteTextFileResponse?, table?
function M.write_text_file(params)
    local path, path_error = validate_absolute_path(params.path)

    if path == nil then
        return nil, path_error
    end

    local write_error = write_disk(path, params.content)

    if write_error ~= nil then
        return nil, write_error
    end

    local bufnr = find_loaded_buffer(path)

    if bufnr ~= nil then
        local sync_error = apply_buffer_snapshot(bufnr, decode_content(params.content), false)

        if sync_error ~= nil then
            return nil, sync_error
        end
    end

    return {}, nil
end

return M
