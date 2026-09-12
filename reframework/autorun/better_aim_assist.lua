-- Better Aim Assist 1.5.7 -- RE4 / Chainsaw Demo, REFramework.
-- Uses native target selection, visibility checks and camera rotation.
-- Method signatures and via.Range layout verified against the demo's TDB 71.
-- Open F10 > Script Generated UI > Better Aim Assist.

local VERSION = "1.5.7"
-- Resolve modules while REFramework's script-loading search path is active.
local diagnostics_ok, diagnostics_module = pcall(require, "better_aim_assist.diagnostics")
local options_ok, game_options = pcall(require, "better_aim_assist.game_options")
local precision_ok, precision = pcall(require, "better_aim_assist.precision")
local CONFIG_FILE = "better_aim_assist.json"
local defaults = { enabled = true, follow = true, strength = 12.0, area = 1.8, distance = 35.0,
    hud = true, hud_opacity = 0.18, prefer_head = true, steady_head = true, collect_data = true,
    stick_switch = true, stick_threshold = 0.65 }
local settings = {}
local state = { ready = false, error = nil, last_tracking = -100, last_lock = -100,
    in_game = false, aiming = false, native_enabled = false, last_status_poll = -100,
    tracking_calls = 0, selection_calls = 0, volume_checks = 0, hooks = 0,
    head_comparisons = 0, head_preferences = 0, steady_calls = 0, last_sample = -100,
    rotation_calls = 0, selector_calls = 0, gameplay_observed = false }
local selection_threads = {}
local locked_selection_threads = {}
local dirty_at = nil
local save_error = nil
local history = {}
local tracked_history = {}
local last_record = -100
local metadata_pending = true
local session_started = os.date("!%Y-%m-%dT%H:%M:%SZ")
local prior_gameplay
local previous_ok, previous = pcall(json.load_file, "better_aim_assist_runtime.json")
if previous_ok and type(previous) == "table" then
    if previous.status and (previous.status.gameplay_observed
        or (previous.status.tracking_calls or 0) > 0
        or (type(previous.lock_samples) == "table" and #previous.lock_samples > 0)) then
        prior_gameplay = { version = previous.version, session_started = previous.session_started,
            updated_at = previous.updated_at, status = previous.status, lock_samples = previous.lock_samples }
    else
        prior_gameplay = previous.previous_gameplay
    end
end

local function head_error(message)
    if state.head_error then return end
    state.head_error = tostring(message)
    log.error("[Better Aim Assist] Head identification needs inspection: " .. state.head_error)
end

local function point_head_info(point)
    if not point then return false, "none" end
    local ok, name = pcall(function()
        local joint = point:get_field("_Joint")
        return joint and joint:call("get_Name") or "none"
    end)
    if not ok or type(name) ~= "string" then
        head_error(ok and "The joint name was not a string." or name)
        return false, "unavailable"
    end
    -- Accept Head, Head_00, c_head, etc.; do not classify Neck or Spine as head.
    for part in name:lower():gmatch("[a-z]+") do
        if part == "head" then return true, name end
    end
    return false, name
end

-- RE4 distinguishes actively adjusting aim from holding aim with a resting
-- stick (HoldIdle). Both keep the weapon raised and must keep tracking.
local function aim_held(context)
    if not context then return false, false, false end
    local active = context:call("get_IsAiming") == true
    local idle = context:call("get_IsHoldIdle") == true
    return active or idle, active, idle
end

local function vector_data(value)
    if not value then return nil end
    return { x = value.x, y = value.y, z = value.z }
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local loaded_ok, loaded = pcall(json.load_file, CONFIG_FILE)
if not loaded_ok or type(loaded) ~= "table" then loaded = {} end
for key, value in pairs(defaults) do
    if type(loaded[key]) == type(value) then settings[key] = loaded[key]
    else settings[key] = value end
    if type(value) == "number" and not finite(settings[key]) then settings[key] = value end
end
settings.strength = clamp(settings.strength, 1, 20)
settings.area = clamp(settings.area, 1, 3)
settings.distance = clamp(settings.distance, 5, 60)
settings.hud_opacity = clamp(settings.hud_opacity, 0, 0.8)
settings.stick_threshold = clamp(settings.stick_threshold, 0.2, 0.9)

local function save()
    local ok, result = pcall(json.dump_file, CONFIG_FILE, settings)
    save_error = (not ok or not result) and "Could not save settings. Check folder write access." or nil
    dirty_at = nil
    if save_error then log.error("[Better Aim Assist] " .. save_error) end
end

local function reset_defaults()
    for key, value in pairs(defaults) do settings[key] = value end
    save()
end

local function fail(message)
    if state.error then return end
    state.error = tostring(message)
    log.error("[Better Aim Assist] Assistance stopped: " .. state.error)
end

local function enabled()
    return state.ready and settings.enabled and not state.error
end

-- Each field edit is restored by the matching native method's post hook.
-- Save scalar components: a value type may be exposed as a live memory view.
local function patch_number(changes, object, field, value)
    local original = object:get_field(field)
    if not finite(original) or not finite(value) then error("Invalid number: " .. field) end
    if original == value then return end
    changes[#changes + 1] = { object = object, field = field, value = original }
    object:set_field(field, value)
end

local function patch_range(changes, object, field, start, width)
    local range = object:get_field(field)
    if not range then error("Missing range: " .. field) end
    local original_start, original_width = range:get_field("s"), range:get_field("r")
    if not finite(original_start) or not finite(original_width) or not finite(start) or not finite(width) then
        error("Invalid range: " .. field)
    end
    if original_start == start and original_width == width then return end
    changes[#changes + 1] = { object = object, field = field, s = original_start, r = original_width }
    range:set_field("s", start)
    range:set_field("r", width)
    object:set_field(field, range)
end

local function widen_range(changes, object, field)
    local range = object:get_field(field)
    if not range then error("Missing range: " .. field) end
    local start, width = range:get_field("s"), range:get_field("r")
    if not finite(start) or not finite(width) or width < 0 then error("Invalid range: " .. field) end
    local new_width = width * settings.area
    patch_range(changes, object, field, start + (width - new_width) * 0.5, new_width)
end

local function restore(changes)
    for index = #changes, 1, -1 do
        local change = changes[index]
        local ok, err = pcall(function()
            if change.s ~= nil then
                local range = change.object:get_field(change.field)
                range:set_field("s", change.s)
                range:set_field("r", change.r)
                change.object:set_field(change.field, range)
            else
                change.object:set_field(change.field, change.value)
            end
        end)
        if not ok then fail("Could not restore " .. change.field .. ": " .. tostring(err)) end
    end
end

local function require_type(name)
    local td = sdk.find_type_definition(name)
    if not td then error("This game build does not expose " .. name) end
    return td
end

local function require_method(td, name, count, returns)
    local method = td:get_method(name)
    if not method or method:get_num_params() ~= count or method:is_static()
        or method:get_return_type():get_full_name() ~= returns then
        error("Unsupported method: " .. td:get_full_name() .. "." .. name)
    end
    return method
end

local function require_field(td, name, expected_type)
    local field = td:get_field(name)
    if not field or field:get_type():get_full_name() ~= expected_type then
        error("Unsupported field: " .. td:get_full_name() .. "." .. name)
    end
end

local function install()
    local game = reframework:get_game_name()
    if game ~= "re4" and game ~= "re4demo" then error("This script requires Resident Evil 4.") end
    if not thread or not thread.get_hook_storage or not thread.get_hash then
        error("Update REFramework: the thread hook-storage API is required.")
    end

    local player_type = require_type("chainsaw.PlayerBaseContext")
    local camera_type = require_type("chainsaw.PlayerCameraController")
    local twirler_type = require_type("chainsaw.TwirlerCameraControllerRoot")
    local selector_type = require_type("chainsaw.PlayerAimAssistTargetSelector")
    local volume_type = require_type("chainsaw.ViewVolume")
    local field_type = require_type("chainsaw.ViewingFieldParam")
    local common_type = require_type("chainsaw.PlayerCommonParamUserData")
    local aim_param_type = require_type("chainsaw.CameraAimAssistParam")
    local high = require_type("chainsaw.PlayerDefine.AimAssistType"):get_field("High")
    if not high then error("The native tracking mode is unavailable.") end
    local high_value = high:get_data(nil)
    if not finite(high_value) or high_value <= 0 then error("Invalid native tracking mode.") end

    -- Validate the whole interface before installing any hook.
    local mode = require_method(player_type, "get_AimAssistType", 0, "chainsaw.PlayerDefine.AimAssistType")
    require_method(player_type, "get_IsEnableAimAssist", 0, "System.Boolean")
    require_method(player_type, "get_IsAiming", 0, "System.Boolean")
    require_method(player_type, "get_IsHoldIdle", 0, "System.Boolean")
    local yaw = require_method(twirler_type, "updateYaw(System.Single, System.Single)", 2, "System.Void")
    local pitch = require_method(twirler_type, "updatePitch(System.Single, System.Single)", 2, "System.Void")
    local max_yaw = require_method(twirler_type, "get_TwirlMaxAimAssistSpeedYaw", 0, "System.Single")
    local max_pitch = require_method(twirler_type, "get_TwirlMaxAimAssistSpeedPitch", 0, "System.Single")
    local select_update = require_method(selector_type, "update", 0, "System.Void")
    local volume_check = require_method(field_type, "checkIntoViewVolume", 4, "System.Boolean")
    local point_compare = require_method(selector_type, "compareNoticePointPriority", 3, "System.Int32")
    local target_compare = require_method(selector_type, "compareTargetPriority", 3, "System.Int32")
    local shake_rate = require_method(camera_type, "getHandShakeRate", 0, "System.Single")
    require_method(camera_type, "get_IsControlEnable", 0, "System.Boolean")
    require_field(twirler_type, "_AimAssistParam", "chainsaw.CameraAimAssistParam")
    require_field(aim_param_type, "Speed", "System.Single")
    require_field(aim_param_type, "IsAimAssist", "System.Boolean")
    require_field(aim_param_type, "Target", "chainsaw.NoticePoint")
    require_field(selector_type, "_PlayerHead", "chainsaw.PlayerHeadUpdater")
    require_field(common_type, "_AimSelectMaxDistance", "System.Single")
    require_field(common_type, "_AimSelectHorizontalScreenRange", "via.Range")
    local point_type = require_type("chainsaw.NoticePoint")
    require_field(point_type, "_Joint", "via.Joint")
    require_field(point_type, "_IsEnable", "System.Boolean")
    local target_type = require_type("chainsaw.AimAssistTargetInfo")
    require_field(target_type, "IsHeadCast", "System.Boolean")
    require_field(target_type, "IsShielding", "System.Boolean")
    require_field(target_type, "GameObject", "via.GameObject")
    require_field(target_type, "NoticePointController", "chainsaw.NoticePointController")
    require_field(target_type, "CastRayEndPosition", "via.vec3")
    require_field(selector_type, "AssistPointCastRay", "chainsaw.AsyncCastRay")
    for _, field in ipairs({ "_YawRange", "_PitchRange", "_Distance" }) do
        require_field(volume_type, field, "via.Range")
    end
    local range_type = require_type("via.Range")
    require_field(range_type, "s", "System.Single")
    require_field(range_type, "r", "System.Single")

    local function assisting(camera)
        if not enabled() or not camera or not camera:get_type_definition():is_a(camera_type) then return nil end
        local param = camera:get_field("_AimAssistParam")
        if not param or not param:get_field("IsAimAssist") or not param:get_field("Target") then return nil end
        local context = camera:call("get_TargetContext")
        if not aim_held(context) or not context:call("get_IsEnableAimAssist") then return nil end
        if not camera:call("get_IsControlEnable") then return nil end
        -- Never fabricate a target or bypass native activation/visibility checks.
        return param
    end

    local function add_hook(method, pre, post)
        sdk.hook(method, pre, post)
        state.hooks = state.hooks + 1
    end

    add_hook(mode, nil, function(retval)
        -- Preserve OFF, including any native restrictions represented by OFF.
        local original = sdk.to_int64(retval) & 0xFFFFFFFF
        state.native_mode = original
        if enabled() and settings.follow and original > 0 then return sdk.to_ptr(high_value) end
        return retval
    end)

    local function preference_hook(method, choose)
        add_hook(method, function(args)
            local storage = thread.get_hook_storage()
            storage.baa_preference = 0
            if not enabled() or not settings.prefer_head then return end
            local read_ok, result = pcall(function()
                local selector = sdk.to_managed_object(args[2])
                local head = selector and selector:get_field("_PlayerHead")
                local context = head and head:call("get_Context")
                if not context or not context:call("get_IsEnableAimAssist") then return 0 end
                state.head_comparisons = state.head_comparisons + 1
                return choose(sdk.to_managed_object(args[4]), sdk.to_managed_object(args[5]))
            end)
            if read_ok then storage.baa_preference = result else head_error(result) end
        end, function(retval)
            local preference = thread.get_hook_storage().baa_preference or 0
            if enabled() and settings.prefer_head and preference ~= 0 then
                state.head_preferences = state.head_preferences + 1
                return sdk.to_ptr(preference)
            end
            return retval
        end)
    end

    preference_hook(point_compare, function(a, b)
        if not a or not b then return 0 end
        local a_head = a:get_field("_IsEnable") and point_head_info(a)
        local b_head = b:get_field("_IsEnable") and point_head_info(b)
        if a_head and not b_head then return -1 end
        if b_head and not a_head then return 1 end
        return 0
    end)

    preference_hook(target_compare, function(a, b)
        if not a or not b then return 0 end
        local a_owner, b_owner = a:get_field("GameObject"), b:get_field("GameObject")
        -- Prefer the visible head sample of the SAME enemy. Do not retarget a
        -- different enemy merely because its head ranks ahead of a body point.
        if not a_owner or not b_owner or a_owner:get_address() ~= b_owner:get_address() then return 0 end
        local a_head, b_head = a:get_field("IsHeadCast"), b:get_field("IsHeadCast")
        if a_head and not b_head and not a:get_field("IsShielding") then return -1 end
        if b_head and not a_head and not b:get_field("IsShielding") then return 1 end
        return 0
    end)

    add_hook(shake_rate, function(args)
        local storage = thread.get_hook_storage()
        storage.baa_steady = false
        if not enabled() or not settings.steady_head then return end
        local read_ok, result = pcall(function()
            local camera = sdk.to_managed_object(args[2])
            if settings.follow and precision_ok and precision.target then
                local target = precision.target(camera)
                return target and target.is_head or false
            end
            local param = assisting(camera)
            return param and point_head_info(param:get_field("Target")) or false
        end)
        if read_ok then storage.baa_steady = result else head_error(result) end
    end, function(retval)
        if enabled() and settings.steady_head and thread.get_hook_storage().baa_steady then
            state.steady_calls = state.steady_calls + 1
            return sdk.float_to_ptr(0)
        end
        return retval
    end)

    local function rotation_hook(method, axis)
        add_hook(method, function(args)
            local changes = {}
            thread.get_hook_storage().baa_changes = changes
            state.rotation_calls = state.rotation_calls + 1
            if not enabled() then return end
            local ok, err = pcall(function()
                local camera = sdk.to_managed_object(args[2])
                if precision_ok and precision.input
                    and precision.input(camera, axis, args[3] and sdk.to_float(args[3]) or 0) then
                    args[3] = sdk.float_to_ptr(0)
                end
                if settings.follow then return end
                local param = assisting(camera)
                if not param then
                    if camera and camera:get_type_definition():is_a(camera_type) then state.last_lock = -100 end
                    return
                end
                -- A target remains locked when already centered (zero correction).
                state.last_lock = os.clock()
                state.gameplay_observed = true
                local point = param:get_field("Target")
                state.target_is_head, state.target_joint = point_head_info(point)
                local speed = param:get_field("Speed")
                if not finite(speed) then error("Invalid native tracking speed.") end
                if settings.collect_data and os.clock() - state.last_sample >= 0.2 then
                    state.last_sample = os.clock()
                    local sample_ok, sample = pcall(function()
                        return {
                            joint = state.target_joint, is_head = state.target_is_head, native_speed = speed,
                            target = vector_data(point:call("getPosition")),
                            target_offset = vector_data(point:get_field("_OffsetPosition")),
                            camera = vector_data(camera:get_field("_CameraPosition")),
                            yaw = camera:get_field("_Yaw"), pitch = camera:get_field("_Pitch"),
                        }
                    end)
                    if sample_ok then state.sample = sample else state.sample_error = tostring(sample) end
                end
                if speed <= 0 then return end
                patch_number(changes, param, "Speed", speed * settings.strength)
                state.last_tracking = os.clock()
                state.tracking_calls = state.tracking_calls + 1
                state.native_speed = speed
            end)
            if not ok then
                restore(changes)
                thread.get_hook_storage().baa_changes = {}
                fail(err)
            end
        end, function(retval)
            restore(thread.get_hook_storage().baa_changes or {})
            return retval
        end)
    end
    rotation_hook(yaw, "x")
    rotation_hook(pitch, "y")

    -- Boost the cap without altering the normal right-stick speed settings.
    -- Some builds share the two getters; avoid multiplying a shared hook twice.
    local cap_functions = {}
    for _, method in ipairs({ max_yaw, max_pitch }) do
        local address = tostring(method:get_function())
        if not cap_functions[address] then
            cap_functions[address] = true
            add_hook(method, function(args)
                local storage = thread.get_hook_storage()
                storage.baa_boost = false
                if not enabled() then return end
                local ok, param = pcall(function() return assisting(sdk.to_managed_object(args[2])) end)
                if not ok then fail(param) else storage.baa_boost = param ~= nil end
            end, function(retval)
                if enabled() and thread.get_hook_storage().baa_boost then
                    local original = sdk.to_float(retval)
                    if finite(original) and original > 0 then
                        return sdk.float_to_ptr(original * math.sqrt(settings.strength))
                    end
                end
                return retval
            end)
        end
    end

    add_hook(select_update, function(args)
        local storage = thread.get_hook_storage()
        storage.baa_changes = {}
        storage.baa_selector = sdk.to_managed_object(args[2])
        state.selector_calls = state.selector_calls + 1
        if not enabled() then return end
        local ok, err = pcall(function()
            local selector = sdk.to_managed_object(args[2])
            local head = selector and selector:get_field("_PlayerHead")
            local context = head and head:call("get_Context")
            if not context or not context:call("get_IsEnableAimAssist") then return end
            local key = thread.get_hash()
            selection_threads[key] = (selection_threads[key] or 0) + 1
            storage.baa_selection_key = key
            local locked = precision_ok and precision.is_locked and precision.is_locked(selector)
            if locked then
                locked_selection_threads[key] = (locked_selection_threads[key] or 0) + 1
                storage.baa_locked_selection_key = key
            end
            local data = head:call("get_ParamUserData")
            if data then
                patch_number(storage.baa_changes, data, "_AimSelectMaxDistance", settings.distance)
                if locked then
                    -- The ordinary acquisition strip excludes side targets even
                    -- after collectTarget. Use the full horizontal screen while
                    -- locked; native scope, obstruction and distance checks remain.
                    patch_range(storage.baa_changes, data, "_AimSelectHorizontalScreenRange", 0, 1)
                end
            end
            state.selection_calls = state.selection_calls + 1
        end)
        if not ok then
            restore(storage.baa_changes)
            storage.baa_changes = {}
            fail(err)
        end
    end, function(retval)
        local storage = thread.get_hook_storage()
        if precision_ok and precision.observe and storage.baa_selector then
            local observed, observe_error = pcall(function()
                precision.observe(storage.baa_selector)
            end)
            if not observed then fail(observe_error) end
        end
        restore(storage.baa_changes or {})
        local key = storage.baa_selection_key
        if key ~= nil then
            local depth = (selection_threads[key] or 1) - 1
            selection_threads[key] = depth > 0 and depth or nil
        end
        local locked_key = storage.baa_locked_selection_key
        if locked_key ~= nil then
            local depth = (locked_selection_threads[locked_key] or 1) - 1
            locked_selection_threads[locked_key] = depth > 0 and depth or nil
        end
        return retval
    end)

    add_hook(volume_check, function(args)
        local changes = {}
        thread.get_hook_storage().baa_changes = changes
        if not enabled() or not selection_threads[thread.get_hash()] then return end
        local ok, err = pcall(function()
            -- Instance args: this, world matrix, volume, position, distance.
            local volume = sdk.to_managed_object(args[4])
            if not volume then return end
            if locked_selection_threads[thread.get_hash()] then
                -- Native view-volume angles are radians (atan2/asin in TDB 71).
                patch_range(changes, volume, "_YawRange", -math.pi * 0.5, math.pi)
            else
                widen_range(changes, volume, "_YawRange")
            end
            widen_range(changes, volume, "_PitchRange")
            local distance = volume:get_field("_Distance")
            local start = distance:get_field("s")
            patch_range(changes, volume, "_Distance", start, math.max(0, settings.distance - start))
            state.volume_checks = state.volume_checks + 1
        end)
        if not ok then
            restore(changes)
            thread.get_hook_storage().baa_changes = {}
            fail(err)
        end
    end, function(retval)
        restore(thread.get_hook_storage().baa_changes or {})
        -- Keep the engine's visibility, screen bounds, shield and rejection result.
        return retval
    end)

    if not options_ok then error("Cannot load game-options module: " .. tostring(game_options)) end
    state.hooks = state.hooks + game_options.install(enabled, function() return settings.follow end)
    if not precision_ok then error("Cannot load precision module: " .. tostring(precision)) end
    state.hooks = state.hooks + precision.install(settings, enabled, function(sample, precision_error)
        if precision_error then fail(precision_error) end
        if not sample then state.last_lock = -100; return end
        local now = os.clock()
        state.last_lock, state.last_tracking = now, now
        state.gameplay_observed = true
        state.target_is_head, state.target_joint = sample.is_head, sample.joint
        state.tracking_calls = state.tracking_calls + 1
        if settings.collect_data then
            state.last_sample, state.sample = now, sample
        end
    end, point_head_info, aim_held)
    state.ready = true
    log.info("[Better Aim Assist] v" .. VERSION .. " ready; " .. state.hooks .. " hooks registered, TDB " .. sdk.get_tdb_version())
end

local ok, err = pcall(install)
if not ok then fail(err) end

-- Read gameplay state on the engine thread. Rendering uses only these cached
-- values, so the transparent HUD never takes controller or mouse focus.
re.on_pre_application_entry("UpdateBehavior", function()
    local now = os.clock()
    if now - state.last_status_poll < 0.1 then return end
    state.last_status_poll = now
    state.in_game, state.aiming, state.native_enabled = false, false, false
    state.native_aiming, state.hold_idle = false, false
    if not state.ready or state.error then return end
    local read_ok, read_error = pcall(function()
        game_options.update()
        local manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
        local context = manager and manager:call("getPlayerContextRef")
        state.manager_found = manager ~= nil
        state.player_found = context ~= nil
        if not context then return end
        state.in_game = true
        state.gameplay_observed = true
        state.aiming, state.native_aiming, state.hold_idle = aim_held(context)
        state.native_enabled = context:call("get_IsEnableAimAssist") == true
    end)
    state.status_error = not read_ok and tostring(read_error) or nil
end)

local function hud_status()
    if state.error then return "ERROR", "Open the mod settings for details", 0xFF7373FF end
    if not settings.enabled then return "DISABLED", "Normal game aiming", 0xFFC1B8B0 end
    if not state.ready then return "UNAVAILABLE", "Open the mod settings for details", 0xFF7373FF end
    if state.status_error then return "READY", "Gameplay status is unavailable", 0xFF70CAFF end
    if not state.in_game then return "STANDBY", "Waiting for gameplay", 0xFFC1B8B0 end
    if not state.aiming then return "READY", "Hold LT / L2 to lock on", 0xFFFFC686 end
    if not state.native_enabled then
        return "WAITING", "Use controller input to activate aiming", 0xFF70CAFF
    end
    if os.clock() - state.last_lock < 0.35 then
        if state.target_is_head then return "HEAD LOCK", "Following the head while you hold aim", 0xFF98E65C end
        return "LOCKED", "Following target while you hold aim", 0xFF98E65C
    end
    return "SEARCHING", "Aim toward a visible enemy", 0xFF70CAFF
end

local function draw_hud()
    if not settings.hud then return end
    local display = imgui.get_display_size()
    if not display or display.x <= 0 or display.y <= 0 then return end
    local status, detail, color = hud_status()
    local title = "BETTER AIM ASSIST"
    local title_size = imgui.calc_text_size(title)
    local detail_size = imgui.calc_text_size(detail)
    local status_size = imgui.calc_text_size(status)
    local line_height = math.max(title_size.y, 13)
    local padding = math.max(12, line_height * 0.65)
    local width = math.max(title_size.x, detail_size.x, status_size.x) + padding * 2
    local height = line_height * 3 + padding * 2 + 8
    local margin = math.max(18, line_height)
    local x, y = math.max(0, display.x - width - margin), margin
    if settings.hud_opacity > 0 then
        local alpha = math.floor(settings.hud_opacity * 255 + 0.5)
        draw.filled_rect(x, y, width, height, (alpha << 24) | 0x151515)
    end
    local function label(text, row, tint)
        local tx, ty = x + padding, y + padding + row * (line_height + 4)
        draw.text(text, tx + 1, ty + 1, 0xB0000000)
        draw.text(text, tx, ty, tint)
    end
    label(title, 0, 0xFFF0F0F0)
    label(status, 1, color)
    label(detail, 2, 0xFFE0E0E0)
end

local function diagnostic_status()
    local hud, detail = hud_status()
    return {
        version = VERSION, ready = state.ready, error = state.error,
        in_game = state.in_game, aiming = state.aiming, native_enabled = state.native_enabled,
        native_aiming = state.native_aiming, hold_idle = state.hold_idle, hud = hud, hud_detail = detail,
        native_mode = state.native_mode, settings = settings, hooks = state.hooks,
        tracking_calls = state.tracking_calls, selection_calls = state.selection_calls,
        volume_checks = state.volume_checks, head_comparisons = state.head_comparisons,
        head_preferences = state.head_preferences, steady_calls = state.steady_calls,
        head_error = state.head_error, status_error = state.status_error, sample_error = state.sample_error,
        rotation_calls = state.rotation_calls, selector_calls = state.selector_calls,
        manager_found = state.manager_found, player_found = state.player_found,
        gameplay_observed = state.gameplay_observed, recording_error = state.recording_error,
        game_options = options_ok and game_options.status and game_options.status() or nil,
        precision = precision_ok and precision.status and precision.status() or nil,
    }
end

local function write_api_report()
    local written, result = pcall(function()
        if not diagnostics_ok then error("Cannot load diagnostics module: " .. tostring(diagnostics_module)) end
        return diagnostics_module.write(diagnostic_status())
    end)
    if written and result then
        state.recording_error = nil
        return true
    end
    local reason = written and "json.dump_file returned false" or tostring(result)
    state.recording_error = "API diagnostics: " .. reason
    log.error("[Better Aim Assist] " .. state.recording_error)
    return false
end

local function record_runtime()
    if not settings.collect_data then return end
    if metadata_pending then
        metadata_pending = false
        write_api_report()
    end
    local now = os.clock()
    if precision_ok and precision.sample_screen then
        precision.sample_screen(state.sample, now - state.last_sample, state.aiming)
    end
    if now - last_record < 1 then return end
    last_record = now
    local status = diagnostic_status()
    local sample = { time = now, timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"), aiming = state.aiming, native_enabled = state.native_enabled,
        native_aiming = state.native_aiming, hold_idle = state.hold_idle,
        locked = state.aiming and now - state.last_lock < 0.35, joint = state.target_joint,
        is_head = state.target_is_head, tracking_calls = state.tracking_calls }
    if state.sample and now - state.last_sample < 0.5 then
        sample.target_data_age_seconds = now - state.last_sample
        sample.target_data = state.sample
        local target = state.sample.target
        if target and Vector3f and draw.world_to_screen then
            local projected, position = pcall(function()
                return draw.world_to_screen(Vector3f.new(target.x, target.y, target.z))
            end)
            if projected and position then
                local display = imgui.get_display_size()
                sample.target_from_screen_center_px = { x = position.x - display.x * 0.5,
                    y = position.y - display.y * 0.5 }
            end
        end
        -- Keep useful lock evidence after the player releases aim or pauses.
        tracked_history[#tracked_history + 1] = sample
        if #tracked_history > 45 then table.remove(tracked_history, 1) end
    end
    history[#history + 1] = sample
    if #history > 45 then table.remove(history, 1) end
    local written, result = pcall(json.dump_file, "better_aim_assist_runtime.json", {
        version = VERSION, updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), status = status,
        session_started = session_started, samples = history, lock_samples = tracked_history,
        previous_gameplay = prior_gameplay,
    })
    if not written or not result then
        local reason = written and "json.dump_file returned false" or tostring(result)
        state.recording_error = "Runtime diagnostics: " .. reason
    end
end

re.on_frame(function()
    if dirty_at and os.clock() - dirty_at >= 0.4 then save() end
    if precision_ok and precision.align_screen then precision.align_screen() end
    draw_hud()
    record_runtime()
end)
re.on_config_save(save)

re.on_draw_ui(function()
    if not imgui.tree_node("Better Aim Assist") then return end
    imgui.text("Near lock-on controller assistance | v" .. VERSION)
    local changed, value = imgui.checkbox("Enabled", settings.enabled)
    if changed then settings.enabled = value; dirty_at = os.clock() end
    if imgui.button("Reset to defaults") then reset_defaults() end

    if state.error then
        imgui.text("Assistance stopped: " .. state.error)
        imgui.text("Use Write diagnostics below, then check the REFramework log.")
    elseif not settings.enabled then
        imgui.text("Disabled. Normal game aiming is restored.")
    else
        local status, detail = hud_status()
        imgui.text(status .. ": " .. detail)
    end

    if imgui.button("Near lock-on preset") then
        settings.strength, settings.area, settings.distance, settings.follow = 12, 1.8, 35, true
        settings.prefer_head, settings.steady_head = true, true
        dirty_at = os.clock()
    end
    imgui.same_line()
    if imgui.button("Softer preset") then
        settings.strength, settings.area, settings.distance, settings.follow = 3, 1.25, 25, true
        dirty_at = os.clock()
    end

    changed, value = imgui.slider_float("Tracking strength", settings.strength, 1, 20, "%.1fx")
    if changed then settings.strength = value; dirty_at = os.clock() end
    changed, value = imgui.slider_float("Target search area", settings.area, 1, 3, "%.2fx")
    if changed then settings.area = value; dirty_at = os.clock() end
    changed, value = imgui.slider_float("Maximum target distance", settings.distance, 5, 60, "%.0f m")
    if changed then settings.distance = value; dirty_at = os.clock() end
    changed, value = imgui.checkbox("Continuous lock while holding aim", settings.follow)
    if changed then settings.follow = value; dirty_at = os.clock() end
    changed, value = imgui.checkbox("Prefer the head", settings.prefer_head)
    if changed then settings.prefer_head = value; dirty_at = os.clock() end
    changed, value = imgui.checkbox("Reduce camera sway during head lock", settings.steady_head)
    if changed then settings.steady_head = value; dirty_at = os.clock() end
    changed, value = imgui.checkbox("Right-stick target switching", settings.stick_switch)
    if changed then settings.stick_switch = value; dirty_at = os.clock() end
    changed, value = imgui.slider_float("Stick switching threshold", settings.stick_threshold, 0.2, 0.9, "%.2f")
    if changed then settings.stick_threshold = value; dirty_at = os.clock() end
    imgui.text("Push right stick firmly toward another enemy to switch.")
    imgui.text("Small movements or no suitable enemy keep the current lock.")
    imgui.text("Center for another switch, or push firmly in the opposite direction.")
    imgui.text("Release aim to disengage.")
    imgui.text("Lower strength if tracking feels too abrupt. You still control firing.")
    imgui.text("All three game aim options are managed here.")
    imgui.text("Disable this mod to use your game settings.")
    changed, value = imgui.checkbox("Show status at top-right", settings.hud)
    if changed then settings.hud = value; dirty_at = os.clock() end
    changed, value = imgui.slider_float("Status background opacity", settings.hud_opacity, 0, 0.8, "%.2f")
    if changed then settings.hud_opacity = value; dirty_at = os.clock() end
    imgui.text(save_error or "Settings save automatically.")

    if imgui.tree_node("Diagnostics") then
        imgui.text(string.format("Hooks: %d | Tracking updates: %d | Searches: %d | Cone checks: %d",
            state.hooks, state.tracking_calls, state.selection_calls, state.volume_checks))
        imgui.text(string.format("Head comparisons: %d | Head preferences: %d | Sway reductions: %d",
            state.head_comparisons, state.head_preferences, state.steady_calls))
        if state.head_error then imgui.text("Head identification: " .. state.head_error) end
        if precision_ok and precision.status then
            local tracking = precision.status()
            imgui.text(string.format("Target handoffs: %d / %d requests | Camera confirmed: %d%s", tracking.target_switches,
                tracking.switch_requests, tracking.confirmed_switches, tracking.pending and " | Checking visibility" or ""))
            imgui.text(string.format("Last sampled stick: %.2f, %.2f | Gate: %s", tracking.raw_stick_x or 0,
                tracking.raw_stick_y or 0, tracking.input_gate or "No lock yet"))
            if tracking.last_request then imgui.text("Last switch result: " .. tracking.last_request.result) end
            if tracking.last_request and tracking.last_request.tracking_result then
                imgui.text("Tracking after handoff: " .. tracking.last_request.tracking_result)
            end
            if tracking.switch_error then imgui.text("Target switching: " .. tracking.switch_error) end
            if tracking.screen_error then imgui.text("Screen diagnostics: " .. tracking.screen_error) end
        end
        if options_ok and game_options.status then
            local option_status = game_options.status()
            imgui.text(string.format("Game options: %d overrides | %d disabled-menu checks",
                option_status.reads, option_status.grayed_queries))
            if option_status.error then imgui.text("Option override: " .. option_status.error) end
        end
        changed, value = imgui.checkbox("Record local diagnostics", settings.collect_data)
        if changed then settings.collect_data = value; dirty_at = os.clock() end
        imgui.text(state.recording_error or "Capture: reframework/data/better_aim_assist_runtime.json")
        if imgui.button("Write diagnostics") then
            state.report_message = write_api_report() and "Saved: reframework/data/better_aim_assist_diagnostics.json"
                or state.recording_error
        end
        if state.report_message then imgui.text(state.report_message) end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

if not next(loaded) then save() end
