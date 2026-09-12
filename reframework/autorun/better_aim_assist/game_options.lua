-- Runtime ownership of RE4's three controller aim-assist options.
-- No saved option values are replaced. Overrides are suspended during save/load.
local M = {}

function M.install(is_enabled, get_follow)
    local manager_type = assert(sdk.find_type_definition("chainsaw.OptionManager"), "OptionManager unavailable")
    local enum_type = assert(sdk.find_type_definition("chainsaw.option.OptionID"), "OptionID unavailable")
    local function option(name)
        local field = assert(enum_type:get_field(name), "Missing option " .. name)
        return field:get_data(nil)
    end
    local mode_id = option("ControllerAimAssist")
    local speed_id = option("ControllerAimAssistMaxSpeed")
    local slowdown_id = option("CameraAimAssistLevel")
    local controlled = { [mode_id] = true, [speed_id] = true, [slowdown_id] = true }
    local names = { [mode_id] = "Aim assist mode", [speed_id] = "Aim assist maximum speed",
        [slowdown_id] = "Reticle deceleration" }
    local defaults, raw_values = {}, {}
    local suspended = {}
    local stats = { reads = 0, grayed_queries = 0, blocked_requests = 0, hooks = 0 }
    local manager
    local previous_enabled, previous_follow

    local function method(name, count, result)
        local m = manager_type:get_method(name)
        assert(m and m:get_num_params() == count and not m:is_static()
            and m:get_return_type():get_full_name() == result, "Unsupported OptionManager." .. name)
        return m
    end
    local get_value = method("getCurrentOptionValue", 1, "System.Int32")
    local get_default = method("getDefaultOptionValue", 1, "System.Int32")
    local is_editable = method("getIsEnableOption", 1, "System.Boolean")
    local request_value = method("requestSetCurrentOptionValue", 2, "System.Void")
    local save_data = method("saveSystemSaveData", 0, "share.SaveDataBase")
    local load_data = method("loadSystemSaveData", 1, "System.Void")
    local refresh_menu = method("set_NeedToUpdateOptionDisplayMenu", 1, "System.Void")
    local aim_enum = assert(sdk.find_type_definition("chainsaw.PlayerDefine.AimAssistType"))
    local high = assert(aim_enum:get_field("High")):get_data(nil)
    local low = assert(aim_enum:get_field("Low")):get_data(nil)

    local function active()
        return is_enabled() and not suspended[thread.get_hash()]
    end
    local function integer(pointer)
        local value = sdk.to_int64(pointer) & 0xFFFFFFFF
        return value >= 0x80000000 and value - 0x100000000 or value
    end
    local function value_for(id, owner)
        if id == mode_id then return get_follow() and high or low end
        if defaults[id] == nil then
            -- Fixed, game-defined baselines: users' saved sliders never feed
            -- the mod's strength calculation, and values stay within its range.
            local baseline = get_default:call(owner, id)
            assert(type(baseline) == "number" and baseline == math.floor(baseline),
                "Native option default is unavailable: " .. tostring(id))
            defaults[id] = baseline
        end
        return defaults[id]
    end
    local function add(m, pre, post)
        sdk.hook(m, pre, post)
        stats.hooks = stats.hooks + 1
    end

    -- Preserve the real options during serialization and game initialization.
    for _, m in ipairs({ save_data, load_data }) do
        add(m, function()
            local key = thread.get_hash()
            suspended[key] = (suspended[key] or 0) + 1
            thread.get_hook_storage().baa_option_scope = key
        end, function(retval)
            local key = thread.get_hook_storage().baa_option_scope
            local count = (suspended[key] or 1) - 1
            suspended[key] = count > 0 and count or nil
            return retval
        end)
    end

    add(get_value, function(args)
        local storage = thread.get_hook_storage()
        local id = integer(args[3])
        if not controlled[id] then return end
        storage.baa_option_id = id
        storage.baa_option_owner = sdk.to_managed_object(args[2])
        manager = storage.baa_option_owner
    end, function(retval)
        local storage = thread.get_hook_storage()
        local id = storage.baa_option_id
        if not id then return retval end
        raw_values[id] = integer(retval)
        if not active() then return retval end
        local ok, value = pcall(value_for, id, storage.baa_option_owner)
        if not ok then
            if not stats.error then log.error("[Better Aim Assist] Option override: " .. tostring(value)) end
            stats.error = tostring(value)
            return retval
        end
        stats.reads = stats.reads + 1
        return sdk.to_ptr(value)
    end)

    -- This is the option-menu editability query, not the player's aim-enable query.
    add(is_editable, function(args)
        thread.get_hook_storage().baa_managed_option = controlled[integer(args[3])] == true
    end, function(retval)
        if active() and thread.get_hook_storage().baa_managed_option then
            stats.grayed_queries = stats.grayed_queries + 1
            return sdk.to_ptr(0)
        end
        return retval
    end)

    -- Block UI requests as well; leave the internal setCurrentOptionValue alone
    -- so loading the player's saved preferences continues to work normally.
    add(request_value, function(args)
        if active() and controlled[integer(args[3])] then
            stats.blocked_requests = stats.blocked_requests + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end, function(retval) return retval end)

    function M.update()
        local enabled, follow = is_enabled(), get_follow()
        if enabled == previous_enabled and follow == previous_follow then return end
        if not manager then manager = sdk.get_managed_singleton("chainsaw.OptionManager") end
        if not manager then return end
        local ok, err = pcall(function() refresh_menu:call(manager, true) end)
        if ok then previous_enabled, previous_follow = enabled, follow
        else stats.refresh_error = tostring(err) end
    end

    function M.status()
        local options = {}
        for id, name in pairs(names) do
            options[#options + 1] = { id = id, name = name, saved_value = raw_values[id],
                forced_value = id == mode_id and (get_follow() and high or low) or defaults[id] }
        end
        return { enabled = is_enabled(), options = options, reads = stats.reads,
            grayed_queries = stats.grayed_queries, blocked_requests = stats.blocked_requests,
            error = stats.error, refresh_error = stats.refresh_error }
    end

    return stats.hooks
end

return M
