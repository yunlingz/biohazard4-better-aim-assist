-- Read-only compatibility report for Better Aim Assist.
local M = {}

local type_names = {
    "chainsaw.PlayerAimAssistTargetSelector",
    "chainsaw.AimAssistTargetInfo",
    "chainsaw.CameraAimAssistParam",
    "chainsaw.PlayerDefine.AimAssistType",
    "chainsaw.PlayerCameraController",
    "chainsaw.PlayerCameraController.LockOnState",
    "chainsaw.PlayerHeadUpdater",
    "chainsaw.PlayerContext",
    "chainsaw.PlayerCommonParamUserData",
    "chainsaw.CharacterManager",
    "chainsaw.OptionManager",
    "chainsaw.GameOptionManager",
    "chainsaw.InputManager",
    "chainsaw.InputSystem",
    "chainsaw.PlayerInput",
    "chainsaw.PlayerBaseContext",
    "chainsaw.PlayerCommonParameter",
    "chainsaw.PlayerActionUpdaterInputUnit",
    "chainsaw.TwirlerCameraControllerRoot",
    "chainsaw.CameraControllerRoot",
    "chainsaw.CharacterContext",
    "chainsaw.PlayerBaseInput",
    "chainsaw.InputUnit",
    "chainsaw.InputOrderer",
    "chainsaw.GameInput",
    "chainsaw.ViewingField",
    "chainsaw.ViewingFieldParam",
    "chainsaw.NoticePoint",
    "chainsaw.option.OptionID",
    "chainsaw.option.AimAssistType",
    "chainsaw.PlayerDefine.State",
    "share.hid.Command",
    "share.hid.HIDManager",
    "chainsaw.CharacterHeadUpdater",
    "chainsaw.PlayerSensorParamUserData",
    "chainsaw.ViewVolume",
    "chainsaw.TwirlerCameraSettings.TwirlSpeedParam",
    "via.Range",
    "via.Joint",
    "chainsaw.NoticePointController",
    "chainsaw.NoticeDefine.Type",
    "chainsaw.NoticeDefine.Group",
    "chainsaw.EnemyBaseContext",
    "chainsaw.AsyncCastRay",
    "chainsaw.OptionSingleSettingData",
    "chainsaw.OptionSingleSettingData.SettingData",
    "chainsaw.OptionMenuInfoData",
    "chainsaw.OptionMenuInfoData.DisableConditionType",
    "chainsaw.OptionSwitchItemInfoData",
}

local function describe(name)
    local td = sdk.find_type_definition(name)
    if not td then
        return { available = false }
    end
    local result = { available = true, fields = {}, methods = {} }
    local parent = td:get_parent_type()
    result.parent = parent and parent:get_full_name() or nil
    for _, field in ipairs(td:get_fields()) do
        local field_type = field:get_type()
        local entry = {
            name = field:get_name(),
            type = field_type and field_type:get_full_name() or "?",
            static = field:is_static(),
        }
        if field:is_literal() then
            local ok, value = pcall(function() return field:get_data(nil) end)
            if ok and (type(value) == "boolean" or (type(value) == "number"
                and value == value and math.abs(value) < math.huge)) then
                entry.value = value
            end
        end
        result.fields[#result.fields + 1] = entry
    end
    for _, method in ipairs(td:get_methods()) do
        local params = {}
        local names = method:get_param_names()
        for index, param_type in ipairs(method:get_param_types()) do
            params[#params + 1] = param_type:get_full_name() .. " " .. (names[index] or "")
        end
        local return_type = method:get_return_type()
        result.methods[#result.methods + 1] = {
            name = method:get_name(),
            returns = return_type and return_type:get_full_name() or "?",
            params = params,
            static = method:is_static(),
        }
    end
    return result
end

function M.write(status, extra_types)
    local report = {
        game = reframework:get_game_name(),
        tdb_version = sdk.get_tdb_version(),
        generated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        status = status,
        types = {},
    }
    local function add(name)
        local ok, result = pcall(describe, name)
        report.types[name] = ok and result or { error = tostring(result) }
    end
    for _, name in ipairs(type_names) do add(name) end
    for _, name in ipairs(extra_types or {}) do add(name) end
    return json.dump_file("better_aim_assist_diagnostics.json", report)
end

return M
