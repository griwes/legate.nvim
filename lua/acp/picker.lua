---@class acp.PickerModule
local M = {}

---@param value string?
---@return string
local function text(value)
    if value == nil then
        return ''
    end

    return tostring(value)
end

---@param value string
---@param width integer
---@return string
local function pad(value, width)
    if #value >= width then
        return value
    end

    return value .. string.rep(' ', width - #value)
end

---@param rows string[][]
---@return integer[]
local function widths(rows)
    local measured = {}

    for _, row in ipairs(rows) do
        for index, value in ipairs(row) do
            measured[index] = math.max(measured[index] or 0, #text(value))
        end
    end

    return measured
end

---@generic T
---@param items T[]
---@param columns fun(item: T): string[]
---@return fun(item: T): string
function M.make_formatter(items, columns)
    local rows = {}
    local labels = setmetatable({}, {
        __mode = 'k',
    })

    for _, item in ipairs(items) do
        table.insert(rows, columns(item))
    end

    local measured = widths(rows)

    for index, item in ipairs(items) do
        local row = rows[index]
        local parts = {}

        for column_index, value in ipairs(row) do
            local formatted = text(value)

            if column_index < #row then
                formatted = pad(formatted, measured[column_index] or #formatted)
            end

            table.insert(parts, formatted)
        end

        labels[item] = table.concat(parts, '  ')
    end

    return function(item)
        return labels[item] or ''
    end
end

return M
