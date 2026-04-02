---@class acp.ConfigOptionValueChoice
---@field value acp.SessionConfigOptionValue
---@field group_name? string

---@class acp.ConfigOptionModule
local M = {}

---Flatten ACP select-option values, including grouped selectors, into chooser-friendly entries.
---@param option acp.SessionConfigOption
---@return acp.ConfigOptionValueChoice[]
function M.choices(option)
    local values = {}

    for _, entry in ipairs(option.options or {}) do
        if entry.value ~= nil then
            table.insert(values, {
                value = entry,
            })
        elseif entry.options ~= nil then
            for _, value in ipairs(entry.options) do
                table.insert(values, {
                    value = value,
                    group_name = entry.name,
                })
            end
        end
    end

    return values
end

return M
