-- Continuous correction toward a target accepted by RE4's own selector.
-- Angles are radians; the yaw/pitch convention was confirmed in live captures.
local M = {}

function M.install(settings, enabled, notify, point_head_info, aim_held)
    local player_camera = assert(sdk.find_type_definition("chainsaw.PlayerCameraController"))
    local root = assert(sdk.find_type_definition("chainsaw.TwirlerCameraControllerRoot"))
    local update = assert(player_camera:get_method("onCameraUpdate"))
    local set_angles = assert(root:get_method("setYawPitch(System.Single, System.Single)"))
    local apply_angles = assert(root:get_method("applyYawPitch"))
    assert(update:get_num_params() == 0 and update:get_return_type():get_full_name() == "System.Void")
    assert(set_angles:get_num_params() == 2 and set_angles:get_return_type():get_full_name() == "System.Void")
    assert(apply_angles:get_num_params() == 0 and apply_angles:get_return_type():get_full_name() == "System.Void")
    for _, name in ipairs({ "get_IsReverseYaw", "get_IsReversePitch" }) do
        local getter = assert(player_camera:get_method(name))
        assert(getter:get_num_params() == 0 and not getter:is_static()
            and getter:get_return_type():get_full_name() == "System.Boolean")
    end
    local selector_type = assert(sdk.find_type_definition("chainsaw.PlayerAimAssistTargetSelector"))
    local function method(name, count, result)
        local found = selector_type:get_method(name)
        assert(found and found:get_num_params() == count and not found:is_static()
            and found:get_return_type():get_full_name() == result, "Unsupported selector." .. name)
        return found
    end
    method("get_InViewTargetListArray", 0, "System.Collections.Generic.List`1<chainsaw.AimAssistTargetInfo>")
    method("collectTarget", 0, "System.Void")
    method("get_TargetCastRayList", 0, "chainsaw.AsyncCastRay[]")
    method("set_TargetCastRayList", 1, "System.Void")
    local sort_targets = method("sortInViewTarget", 0, "System.Void")
    method("set_AssistTarget", 1, "System.Void")
    method("set_AssistPoint", 1, "System.Void")
    method("sortNoticePoint", 0, "System.Void")
    method("get_TargetNoticePointArray", 0, "System.Collections.Generic.List`1<chainsaw.NoticePoint>")
    method("set_TargetNoticePointArray", 1, "System.Void")
    local on_screen = method("checkScreenPositioin(via.vec3)", 1, "System.Boolean")
    method("checkSelectDistance", 1, "System.Boolean")
    local point_controller = assert(sdk.find_type_definition("chainsaw.NoticePointController"))
    local get_points = assert(point_controller:get_method("getEnableNoticePointList(chainsaw.NoticeDefine.Type)"))
    assert(get_points:get_num_params() == 1 and not get_points:is_static()
        and get_points:get_return_type():get_full_name() == "System.Collections.Generic.List`1<chainsaw.NoticePoint>")
    local aim_point_type = assert(sdk.find_type_definition("chainsaw.NoticeDefine.Type")):get_field("Aim"):get_data(nil)
    local targets, last_time, inputs, switches, motion_samples, target_rejections = {}, {}, {}, {}, {}, {}
    local render_sample, measured_sample, screen_feedback, render_timing
    local stats = { updates = 0, accepted = 0, corrections = 0, rejected = {},
        switch_requests = 0, target_switches = 0, no_directional_target = 0,
        retained_locks = 0, consumed_inputs = 0, refresh_requests = 0,
        visibility_wait_frames = 0, prevented_reselections = 0,
        handoff_attempts = 0, handoff_failures = 0, candidate_rejections = {},
        handoff_rejections = {}, switch_history = {}, pending = false,
        direction_rearms = 0, blocked_push_frames = 0, lock_sessions = 0,
        confirmed_switches = 0, unconfirmed_handoffs = 0, events = {},
        tracking = { rejected = {}, history = {} },
        head_alignment = { measured_frames = 0, centered_frames = 0, applied_frames = 0,
            precise_frames = 0,
            estimated_centered_frames = 0, outlier_frames = 0, rejected = {}, history = {}, outliers = {},
            motion = { refreshed_frames = 0, predicted_frames = 0, rejected = {}, refresh_history = {} } } }
    local function clear_alignment(key)
        if render_sample and render_sample.camera_key == key then render_sample = nil end
        if screen_feedback and screen_feedback.camera_key == key then screen_feedback = nil end
        if render_timing and render_timing.camera_key == key then render_timing = nil end
        motion_samples[key] = nil
    end
    local function finite(value)
        return type(value) == "number" and value == value and math.abs(value) < math.huge
    end

    local function reject(reason)
        stats.rejected[reason] = (stats.rejected[reason] or 0) + 1
        return nil, reason
    end
    local function wrap(angle)
        return (angle + math.pi) % (2 * math.pi) - math.pi
    end
    local function valid_position(position)
        return position and finite(position.x) and finite(position.y) and finite(position.z)
    end
    local function position_data(position)
        if valid_position(position) then return { x = position.x, y = position.y, z = position.z } end
    end
    local function event(kind, detail)
        if not settings.collect_data then return end
        detail = detail or {}
        detail.kind, detail.time, detail.timestamp = kind, os.clock(), os.date("!%Y-%m-%dT%H:%M:%SZ")
        stats.events[#stats.events + 1] = detail
        if #stats.events > 64 then table.remove(stats.events, 1) end
    end
    local function input_gate(switching, gate)
        stats.input_gate, stats.armed = gate, switching.armed
        if switching.gate == gate then return end
        switching.gate = gate
        event("input_gate", { gate = gate, armed = switching.armed, entity_id = switching.entity_id,
            lock_session = switching.session, raw_x = stats.raw_stick_x, raw_y = stats.raw_stick_y,
            x = stats.stick_x, y = stats.stick_y, threshold = settings.stick_threshold })
    end
    local function finish_confirmation(switching, result)
        local confirmation = switching and switching.confirmation
        if not confirmation then return end
        local request = confirmation.request
        request.tracking_result = result
        request.tracking_elapsed_seconds = os.clock() - confirmation.time
        if result == "confirmed" then stats.confirmed_switches = stats.confirmed_switches + 1
        else stats.unconfirmed_handoffs = stats.unconfirmed_handoffs + 1 end
        event("camera_confirmation", { result = result, from = request.from, to = request.to,
            lock_session = switching.session, frames = request.camera_frames,
            yaw_error_degrees = request.camera_yaw_error_degrees,
            pitch_error_degrees = request.camera_pitch_error_degrees })
        switching.confirmation = nil
    end
    local function entity_id(info)
        local owner = info and info:get_field("GameObject")
        return owner and tostring(owner:get_address()) or nil
    end
    local function count_reason(counts, reason)
        counts[reason] = (counts[reason] or 0) + 1
    end

    local function tracking_gate(gate, key, target)
        local tracking = stats.tracking
        if gate ~= "tracking" then count_reason(tracking.rejected, gate) end
        if tracking.gate == gate and tracking.camera_id == tostring(key) then return end
        tracking.gate, tracking.camera_id, tracking.time = gate, tostring(key), os.clock()
        if not settings.collect_data then return end
        tracking.history[#tracking.history + 1] = { gate = gate, time = tracking.time,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"), camera_id = tracking.camera_id,
            entity_id = target and target.entity_id }
        if #tracking.history > 32 then table.remove(tracking.history, 1) end
    end

    -- Predict only the short sampling/render delay, not projectile travel time.
    -- A fresh pair from the same point is required; stops and reversals replace
    -- the old velocity immediately. Never carry motion across a target change.
    local function moving_head(key, target, observed, observed_time, now, dt, alpha, distance)
        local previous = motion_samples[key]
        local velocity = { x = 0, y = 0, z = 0 }
        local reason, speed = "new_point", 0
        if previous and previous.point_id == target.point_id and previous.entity_id == target.entity_id
            and previous.joint == target.joint then
            local elapsed = observed_time - previous.time
            if elapsed >= 0.001 and elapsed <= 0.05 and now - observed_time <= 0.05 then
                local x, y, z = (observed.x - previous.x) / elapsed,
                    (observed.y - previous.y) / elapsed, (observed.z - previous.z) / elapsed
                speed = math.sqrt(x * x + y * y + z * z)
                if speed <= 12 then velocity, reason = { x = x, y = y, z = z }, "tracking"
                else reason = "position_jump" end
            else reason = "sample_gap" end
        end
        motion_samples[key] = { x = observed.x, y = observed.y, z = observed.z, time = observed_time,
            point_id = target.point_id, entity_id = target.entity_id, joint = target.joint }
        if reason ~= "tracking" then count_reason(stats.head_alignment.motion.rejected, reason) end
        local delay = 0
        if render_timing and render_timing.camera_key == key and now >= render_timing.time
            and now - render_timing.time <= 0.1 then delay = render_timing.delay end
        -- The existing exponential follow also introduces a small motion lag.
        local follow_delay = dt * (1 - alpha) / alpha
        local horizon = math.min(math.max(now - observed_time + delay + follow_delay, 0), 0.035)
        local x, y, z = velocity.x * horizon, velocity.y * horizon, velocity.z * horizon
        local lead = math.sqrt(x * x + y * y + z * z)
        local limit = math.min(0.1, distance * math.tan(math.rad(0.75)))
        local scale = lead > limit and limit / lead or 1
        if lead > 0.00001 then stats.head_alignment.motion.predicted_frames = stats.head_alignment.motion.predicted_frames + 1 end
        return { x = observed.x + x * scale, y = observed.y + y * scale, z = observed.z + z * scale },
            { reason = reason, speed_mps = speed, velocity = velocity, observation_time = observed_time,
                observation_age_seconds = now - observed_time, render_delay_seconds = delay,
                follow_delay_seconds = follow_delay, lead_seconds = horizon,
                lead_meters = lead * scale, limited = scale < 1 }
    end
    local function eligible(selector, info, reasons)
        local reason
        if not info or not info:get_field("EnemyContext") then reason = "not_enemy"
        elseif not info:call("get_IsValid") then reason = "invalid_target"
        elseif info:get_field("IsShielding") then reason = "obstructed"
        elseif selector:call("checkAssistTargetDisable", info) then reason = "outside_target_limits" end
        if reason and reasons then count_reason(reasons, reason) end
        return reason == nil, reason
    end

    -- Capture the stick before consuming its camera rotation during a valid
    -- lock. Gyro is a separate argument and is left alone.
    function M.input(camera, axis, value)
        if not camera or not camera:get_type_definition():is_a(player_camera) then return false end
        local key = camera:get_address()
        local input = inputs[key] or {}
        input[axis], input[axis .. "_time"] = finite(value) and value or 0, os.clock()
        inputs[key] = input
        if (input.x or 0) ^ 2 + (input.y or 0) ^ 2 < (settings.stick_threshold * 0.55) ^ 2 then
            input.push_x, input.push_y = nil, nil
        end
        if settings.stick_switch and M.target(camera) then
            stats["input_peak_" .. axis] = math.max(stats["input_peak_" .. axis] or 0, math.abs(input[axis]))
            stats.consumed_inputs = stats.consumed_inputs + 1
            return true
        end
        return false
    end

    -- Native updateNoticePointList reuses its old list when the previous point's
    -- name also exists on the new enemy. Fetch this enemy's points explicitly.
    -- Restore the exact old list and ray on failure; do not run that cache updater.
    local function handoff(selector, info)
        if not eligible(selector, info) then return false, "candidate_became_invalid" end
        stats.handoff_attempts = stats.handoff_attempts + 1
        local old_info, old_point = selector:call("get_AssistTarget"), selector:call("get_AssistPoint")
        local old_points = selector:call("get_TargetNoticePointArray")
        local old_ray = selector:get_field("AssistPointCastRay")
        local reason = "no_usable_point"
        local ok, selected = pcall(function()
            local controller = info:get_field("NoticePointController")
            local points = controller and get_points:call(controller, aim_point_type)
            if not points or points:call("get_Count") == 0 then reason = "no_points"; return false end
            selector:call("set_AssistTarget", info)
            selector:call("set_TargetNoticePointArray", points)
            -- Also creates a fresh native visibility ray for the new aim point.
            selector:call("sortNoticePoint")
            points = selector:call("get_TargetNoticePointArray")
            for index = 0, (points and points:call("get_Count") or 0) - 1 do
                local point = points:call("get_Item", index)
                local owner = point and point:call("get_Owner")
                local is_head = point and point_head_info(point)
                if not owner or tostring(owner:get_address()) ~= entity_id(info) then reason = "wrong_point_owner"
                elseif not point:get_field("_IsEnable") then reason = "disabled_point"
                elseif is_head ~= info:get_field("IsHeadCast") then reason = "unvalidated_body_part"
                else
                    local position = point:call("getPosition")
                    if not valid_position(position) then reason = "invalid_point_position"
                    elseif not selector:call("checkSelectDistance", position) then reason = "point_too_far"
                    elseif not on_screen:call(selector, position) then reason = "point_offscreen"
                    else
                        selector:call("set_AssistPoint", point)
                        local actual = selector:call("get_AssistPoint")
                        if entity_id(selector:call("get_AssistTarget")) == entity_id(info)
                            and actual and actual:get_address() == point:get_address() then return true end
                        reason = "handoff_not_applied"
                        return false
                    end
                end
            end
            return false
        end)
        if ok and selected then return true end
        selector:call("set_AssistTarget", old_info)
        selector:call("set_TargetNoticePointArray", old_points)
        selector:call("set_AssistPoint", old_point)
        selector:set_field("AssistPointCastRay", old_ray)
        if not ok then
            reason = "native_error"
            if not stats.switch_error then
                log.error("[Better Aim Assist] Kept previous target: " .. tostring(selected))
            end
            stats.switch_error = tostring(selected)
        end
        stats.handoff_failures = stats.handoff_failures + 1
        count_reason(stats.handoff_rejections, reason)
        return false, reason
    end

    local function candidates(selector, request)
        local result = {}
        local list = selector:call("get_InViewTargetListArray")
        local count = list and list:call("get_Count") or 0
        if request then request.native_candidates, request.rejections = count, {} end
        for index = 0, count - 1 do
            local info = list:call("get_Item", index)
            local id = entity_id(info)
            local accepted, reason = eligible(selector, info, stats.candidate_rejections)
            if request and reason then count_reason(request.rejections, reason) end
            if id and accepted then
                local previous = result[id]
                if not previous or (settings.prefer_head and info:get_field("IsHeadCast")
                    and not previous:get_field("IsHeadCast")) then result[id] = info end
            end
        end
        if request then
            request.eligible_enemies = 0
            for _ in pairs(result) do request.eligible_enemies = request.eligible_enemies + 1 end
        end
        return result
    end

    local function directional_candidates(camera, target, available, x, y, request)
        local position = camera:get_field("_CameraPosition")
        if not valid_position(position) then return {} end
        local function angles(point)
            if not valid_position(point) then return end
            local dx, dy, dz = point.x - position.x, point.y - position.y, point.z - position.z
            local horizontal = math.sqrt(dx * dx + dz * dz)
            local distance = math.sqrt(horizontal * horizontal + dy * dy)
            if distance < 0.1 or distance > settings.distance then return end
            return math.atan(dx, dz), math.atan(dy, horizontal), distance
        end
        local from_yaw, from_pitch = angles(target)
        local camera_yaw = camera:get_field("_Yaw")
        if not from_yaw or not finite(camera_yaw) then return {} end
        local magnitude = math.sqrt(x * x + y * y)
        x, y = x / magnitude, y / magnitude
        local ranked = {}
        if request and settings.collect_data then request.candidates = {} end
        for id, info in pairs(available) do
            local sample = info:get_field("CastRayEndPosition")
            local detail = { entity_id = id, position = position_data(sample),
                is_head = info:get_field("IsHeadCast"), reason = "current_target" }
            if id ~= target.entity_id then
                -- get_Position is the enemy's root, often near its feet. Rank
                -- the head/body position actually checked by the native ray.
                local yaw, pitch, distance = angles(sample)
                detail.distance = distance
                detail.reason = yaw and "outside_camera_view" or "invalid_or_out_of_range"
                if yaw and math.abs(wrap(yaw - camera_yaw)) < math.pi * 0.5 then
                    local dx, dy = wrap(yaw - from_yaw), pitch - from_pitch
                    local separation = math.sqrt(dx * dx + dy * dy)
                    local forward = dx * x + dy * y
                    detail.yaw_delta_degrees, detail.pitch_delta_degrees = math.deg(dx), math.deg(dy)
                    detail.reason = "outside_stick_direction"
                    if forward > math.rad(1) and forward >= separation * 0.5 then
                        detail.reason, detail.score = "directional_candidate", separation * (1 + 2 * (1 - forward / separation))
                        ranked[#ranked + 1] = { info = info, id = id,
                            score = detail.score }
                    end
                end
            end
            if request and request.candidates and #request.candidates < 8 then
                request.candidates[#request.candidates + 1] = detail
            end
        end
        table.sort(ranked, function(a, b)
            return a.score < b.score or (a.score == b.score and a.id < b.id)
        end)
        return ranked
    end

    local function finish_request(switching, result, to)
        local request = switching.pending
        if not request then return end
        request.result, request.to = result, to
        request.elapsed_seconds = os.clock() - request.time
        request.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
        stats.last_request = request
        if settings.collect_data then
            stats.switch_history[#stats.switch_history + 1] = request
            if #stats.switch_history > 12 then table.remove(stats.switch_history, 1) end
        end
        event("switch_result", { result = result, from = request.from, to = to,
            lock_session = switching.session, native_candidates = request.native_candidates,
            directional_candidates = request.directional_candidates, elapsed_seconds = request.elapsed_seconds })
        switching.pending, stats.pending, stats.pending_request = nil, false, nil
    end

    local function cancel_request(selector, switching, reason)
        if not switching or not switching.pending then return end
        -- Prevent a late async result from replacing the lock after cancellation.
        selector:call("set_TargetCastRayList", nil)
        finish_request(switching, reason)
    end

    -- A manual refresh still uses native ray checks and obstruction filtering.
    -- Only suppress their automatic first-target assignment, which also clears
    -- the current point. observe() performs the directional handoff afterwards.
    sdk.hook(sort_targets, function(args)
        local selector = sdk.to_managed_object(args[2])
        local camera = selector and selector:get_field("_PlayerCamera")
        local switching = camera and switches[camera:get_address()]
        if switching and switching.pending then
            if settings.stick_switch and M.target(camera)
                and entity_id(selector:call("get_AssistTarget")) == switching.entity_id then
                switching.pending.ready = true
            end
            -- A canceled/disabled request must not apply the native default
            -- selection either. observe() retires it after this update.
            stats.prevented_reselections = stats.prevented_reselections + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end, nil)

    function M.is_locked(selector)
        return settings.stick_switch and M.target(selector:get_field("_PlayerCamera")) ~= nil
    end

    local function read_target(selector)
        local info, point = selector:call("get_AssistTarget"), selector:call("get_AssistPoint")
        if not info or not point then return reject("no_target") end
        if not info:get_field("EnemyContext") then return reject("not_enemy") end
        if info:get_field("IsShielding") then return reject("obstructed") end
        if selector:call("checkAssistTargetDisable", info) then return reject("invalid_target") end
        if not point:get_field("_IsEnable") then return reject("disabled_point") end
        local position = point:call("getPosition")
        if not valid_position(position) then return reject("invalid_position") end
        local is_head, joint = point_head_info(point)
        return { x = position.x, y = position.y, z = position.z, time = os.clock(),
            is_head = is_head, joint = joint, entity_id = entity_id(info), point_id = point:get_address(),
            offset = settings.collect_data and position_data(point:get_field("_OffsetPosition")) or nil }
    end

    local function switch_target(selector, camera, target)
        local key, now = camera:get_address(), os.clock()
        local input = inputs[key] or {}
        local raw_x = now - (input.x_time or -100) <= 0.1 and (input.x or 0) or 0
        local raw_y = now - (input.y_time or -100) <= 0.1 and (input.y or 0) or 0
        -- updateYaw applies -yawInput normally and +yawInput when reversed;
        -- updatePitch does the opposite. These inputs precede native inversion.
        -- This function only runs after M.target has validated the gameplay camera.
        local reverse_yaw, reverse_pitch = camera:call("get_IsReverseYaw"), camera:call("get_IsReversePitch")
        local x, y = reverse_yaw and raw_x or -raw_x, reverse_pitch and -raw_y or raw_y
        local magnitude = math.sqrt(x * x + y * y)
        stats.raw_stick_x, stats.raw_stick_y = raw_x, raw_y
        stats.reverse_yaw, stats.reverse_pitch = reverse_yaw, reverse_pitch
        stats.stick_x, stats.stick_y = x, y
        stats.input_sample_time = now
        local switching = switches[key]
        if not switching then
            -- A push already present on the acquisition frame is still a valid
            -- request. Requiring neutral here discarded it for the entire lock.
            stats.lock_sessions = stats.lock_sessions + 1
            switching = { armed = input.push_x == nil, entity_id = target.entity_id, session = stats.lock_sessions,
                push_x = input.push_x, push_y = input.push_y, trigger = "new_lock" }
            switches[key] = switching
            event("lock_acquired", { entity_id = target.entity_id, lock_session = switching.session,
                camera_id = tostring(key), selector_id = tostring(selector:get_address()),
                position = position_data(target), raw_x = raw_x, raw_y = raw_y })
        end
        local available
        if switching.entity_id and switching.entity_id ~= target.entity_id then
            cancel_request(selector, switching, "lock_changed")
            available = candidates(selector)
            local previous = available[switching.entity_id]
            if previous and handoff(selector, previous) then
                target = read_target(selector)
                stats.retained_locks = stats.retained_locks + 1
            end
            switching.entity_id = target.entity_id
        end
        if magnitude < settings.stick_threshold * 0.55 then
            switching.armed = true
            input.push_x, input.push_y = nil, nil
            switching.trigger = "centered"
            cancel_request(selector, switching, "stick_centered")
        end
        if magnitude < settings.stick_threshold then
            cancel_request(selector, switching, "stick_below_threshold")
            input_gate(switching, switching.armed and "ready_below_threshold" or "waiting_for_new_push")
            return target
        end
        if not switching.armed and input.push_x == nil then
            -- The input hooks may see a brief neutral frame between selector
            -- updates. Preserve that new gesture instead of discarding it.
            switching.armed, switching.trigger = true, "centered_between_updates"
        end
        -- A quick reversal can cross center between selector updates. Treat a
        -- strong turn into the opposite half-plane as a new deliberate push.
        -- A held direction and small directional drift remain latched.
        if not switching.armed and switching.push_x
            and x * switching.push_x + y * switching.push_y <= 0 then
            cancel_request(selector, switching, "direction_changed")
            switching.armed, switching.trigger = true, "direction_changed"
            stats.direction_rearms = stats.direction_rearms + 1
        end
        if not switching.pending then
            if not switching.armed then
                stats.blocked_push_frames = stats.blocked_push_frames + 1
                input_gate(switching, "holding_same_push")
                return target
            end
            finish_confirmation(switching, "superseded_by_next_push")
            switching.armed = false
            switching.push_x, switching.push_y = x / magnitude, y / magnitude
            input.push_x, input.push_y = switching.push_x, switching.push_y
            stats.switch_requests = stats.switch_requests + 1
            switching.pending = { from = target.entity_id, x = x, y = y, raw_x = raw_x, raw_y = raw_y, magnitude = magnitude,
                threshold = settings.stick_threshold, time = now, trigger = switching.trigger,
                lock_session = switching.session, camera_id = tostring(key), selector_id = tostring(selector:get_address()),
                from_position = position_data(target), camera_position = position_data(camera:get_field("_CameraPosition")),
                camera_yaw = camera:get_field("_Yaw"), camera_pitch = camera:get_field("_Pitch"),
                reverse_yaw = reverse_yaw, reverse_pitch = reverse_pitch }
            stats.pending, stats.pending_request = true, switching.pending
            input_gate(switching, "searching")
            -- checkCollectTarget returns false while AssistTarget is valid.
            -- collectTarget itself refreshes the candidate list without releasing
            -- that target; requestCollectTarget would clear it and must not be used.
            stats.refresh_requests = stats.refresh_requests + 1
            local ok, err = pcall(function() selector:call("collectTarget") end)
            if not ok then
                stats.switch_error = tostring(err)
                cancel_request(selector, switching, "refresh_error")
                return target
            end
        end
        local request = switching.pending
        if selector:call("get_TargetCastRayList") then
            stats.visibility_wait_frames = stats.visibility_wait_frames + 1
            input_gate(switching, "waiting_for_visibility")
            if now - request.time > 0.6 then cancel_request(selector, switching, "visibility_timeout") end
            return target
        end
        available = candidates(selector, request)
        if not request.ready then
            finish_request(switching, request.native_candidates == 0 and "no_candidates" or "visibility_unconfirmed")
            stats.no_directional_target = stats.no_directional_target + 1
            return target
        end
        request.selection_x, request.selection_y = x, y
        local ranked = directional_candidates(camera, target, available, x, y, request)
        request.directional_candidates = #ranked
        for _, candidate in ipairs(ranked) do
            local applied, reason = handoff(selector, candidate.info)
            if applied then
                switching.entity_id = candidate.id
                stats.target_switches = stats.target_switches + 1
                stats.last_switch = { from = target.entity_id, to = candidate.id, x = x, y = y }
                finish_request(switching, "switched", candidate.id)
                request.tracking_result, request.camera_frames = "awaiting_camera", 0
                switching.confirmation = { request = request, time = now }
                return read_target(selector)
            end
            if settings.collect_data then
                request.handoff_rejections = request.handoff_rejections or {}
                request.handoff_rejections[#request.handoff_rejections + 1] = { entity_id = candidate.id, reason = reason }
            end
        end
        stats.no_directional_target = stats.no_directional_target + 1
        finish_request(switching, #ranked > 0 and "no_usable_point" or "no_directional_target")
        return target
    end

    -- Called after the native selector has updated. Store only copied scalar
    -- data; no managed enemy/scene object is kept alive across scene changes.
    function M.observe(selector)
        local camera = selector:get_field("_PlayerCamera")
        if not camera then return end
        local key = camera:get_address()
        targets[key] = nil
        if not enabled() or not settings.follow then
            clear_alignment(key)
            cancel_request(selector, switches[key], "disabled")
            finish_confirmation(switches[key], "disabled")
            switches[key] = nil
            return
        end
        targets[key], target_rejections[key] = read_target(selector)
        local accepted, reason = M.target(camera)
        if not accepted then
            target_rejections[key] = reason
            clear_alignment(key)
            cancel_request(selector, switches[key], "lock_lost")
            finish_confirmation(switches[key], "aim_or_lock_lost")
            if switches[key] then
                event("lock_lost", { entity_id = switches[key].entity_id, lock_session = switches[key].session })
            end
            switches[key] = nil; targets[key] = nil; return
        end
        if settings.stick_switch then targets[key] = switch_target(selector, camera, targets[key])
        else
            cancel_request(selector, switches[key], "disabled")
            finish_confirmation(switches[key], "disabled")
            switches[key] = nil
        end
        stats.accepted = stats.accepted + 1
    end

    function M.target(camera)
        if not enabled() then return nil, "disabled" end
        if not settings.follow then return nil, "snap_only" end
        if not camera or not camera:get_type_definition():is_a(player_camera) then return nil, "not_player_camera" end
        -- The title menu also updates a PlayerCameraController, before its
        -- pause/control dependencies exist. Reject it using our scalar cache
        -- before invoking any gameplay-dependent camera getter.
        local key = camera:get_address()
        local target = targets[key]
        if not target then return nil, target_rejections[key] or "no_target" end
        if os.clock() - target.time > 0.1 then return nil, "stale_target" end
        local context = camera:call("get_TargetContext")
        if not context then return nil, "no_player_context" end
        if not aim_held(context) then return nil, "aim_released" end
        if not context:call("get_IsEnableAimAssist") then return nil, "native_assist_inactive" end
        if not camera:call("get_IsControlEnable") then return nil, "camera_control_disabled" end
        return target
    end

    sdk.hook(update, function(args)
        thread.get_hook_storage().baa_precision_camera = sdk.to_managed_object(args[2])
    end, function(retval)
        local camera = thread.get_hook_storage().baa_precision_camera
        if not camera then return retval end
        stats.updates = stats.updates + 1
        local ok, err = pcall(function()
            local key = camera:get_address()
            local target, reason = M.target(camera)
            if not target then
                tracking_gate(reason, key)
                clear_alignment(key)
                finish_confirmation(switches[key], "aim_or_lock_lost")
                if switches[key] and not switches[key].pending then switches[key] = nil end
                last_time[key] = nil
                if settings.follow then notify(nil) end
                return
            end
            local position = position_data(camera:get_field("_CameraPosition"))
            local yaw, pitch = camera:get_field("_Yaw"), camera:get_field("_Pitch")
            if not position or not finite(position.x) or not finite(position.y) or not finite(position.z)
                or not finite(yaw) or not finite(pitch) then
                clear_alignment(key)
                tracking_gate("invalid_camera_pose", key, target)
                reject("invalid_camera_pose"); notify(nil); return
            end
            local now = os.clock()
            local observed, observed_time, observation_source = position_data(target), target.time, "selector"
            if target.is_head then
                -- The camera's current native point may have moved since the
                -- selector ran. Read it here without retaining managed objects.
                local native_point
                local fresh_ok, fresh, reason = pcall(function()
                    local param = camera:get_field("_AimAssistParam")
                    local point = param and param:get_field("Target")
                    native_point = point
                    if not point or point:get_address() ~= target.point_id then return nil, "different_native_point" end
                    if not point:get_field("_IsEnable") then return nil, "disabled_native_point" end
                    return point:call("getPosition"), "invalid_native_position"
                end)
                if fresh_ok and valid_position(fresh) then
                    observed, observed_time, observation_source = position_data(fresh), now, "camera"
                    stats.head_alignment.motion.refreshed_frames = stats.head_alignment.motion.refreshed_frames + 1
                else
                    count_reason(stats.head_alignment.motion.rejected, fresh_ok and reason or "refresh_error")
                    if not fresh_ok then stats.head_alignment.motion.last_error = tostring(fresh) end
                end
                local motion_stats = stats.head_alignment.motion
                local previous = motion_stats.last_refresh
                if settings.collect_data and (not previous or now - previous.time >= 0.1
                    or previous.selected_point_id ~= target.point_id) then
                    local detail = { time = now, timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                        selected_point_id = target.point_id, selected_entity_id = target.entity_id,
                        selected_joint = target.joint, source = observation_source,
                        reason = observation_source == "camera" and "matched" or (fresh_ok and reason or "refresh_error") }
                    -- Record why the native point cannot be used; never substitute
                    -- a different enemy's point or retain its managed object.
                    local captured, capture_error = pcall(function()
                        if not native_point then return end
                        detail.native_point_id = native_point:get_address()
                        local owner = native_point:call("get_Owner")
                        detail.native_entity_id = owner and tostring(owner:get_address()) or nil
                        detail.same_enemy = detail.native_entity_id ~= nil and detail.native_entity_id == target.entity_id
                        local joint = native_point:get_field("_Joint")
                        if joint and joint:call("get_Valid") then detail.native_joint = joint:call("get_Name") end
                    end)
                    if not captured then detail.error = tostring(capture_error) end
                    motion_stats.last_refresh = detail
                    motion_stats.refresh_history[#motion_stats.refresh_history + 1] = detail
                    if #motion_stats.refresh_history > 16 then table.remove(motion_stats.refresh_history, 1) end
                end
            end
            local dx, dy, dz = observed.x - position.x, observed.y - position.y, observed.z - position.z
            local horizontal = math.sqrt(dx * dx + dz * dz)
            local distance = math.sqrt(horizontal * horizontal + dy * dy)
            if distance < 0.1 or distance > settings.distance then
                clear_alignment(key); tracking_gate("outside_distance", key, target); notify(nil); return
            end
            local desired_yaw = math.atan(dx, dz)
            local desired_pitch = math.atan(dy, horizontal)
            local yaw_error, pitch_error = wrap(desired_yaw - yaw), desired_pitch - pitch
            -- The native selector controls acquisition; this also rejects a
            -- stale point that has moved behind the camera between updates.
            if math.abs(yaw_error) > math.pi * 0.5 then
                clear_alignment(key); tracking_gate("behind_camera", key, target); notify(nil); return
            end
            local dt = math.min(math.max(now - (last_time[key] or (now - 1 / 60)), 0), 0.05)
            last_time[key] = now
            if dt <= 0 then return end
            local bias_yaw, bias_pitch = 0, 0
            local feedback = screen_feedback
            if target.is_head and feedback and feedback.camera_key == key
                and feedback.entity_id == target.entity_id and feedback.joint == target.joint
                and feedback.point_id == target.point_id
                and now >= feedback.time and now - feedback.time <= 0.1
                and math.abs(wrap(desired_yaw - feedback.target_yaw)) <= math.rad(10)
                and math.abs(desired_pitch - feedback.target_pitch) <= math.rad(10) then
                bias_yaw, bias_pitch = feedback.yaw, feedback.pitch
                stats.head_alignment.applied_frames = stats.head_alignment.applied_frames + 1
            end
            -- Native camera updates can disturb the previous correction every
            -- frame. Exponential follow then leaves a persistent small error.
            -- Finish the last two degrees of a head lock exactly, retaining the
            -- existing turn-rate limit and smoothing for larger acquisitions.
            local precise_head = target.is_head
                and math.abs(wrap(desired_yaw + bias_yaw - yaw)) <= math.rad(2)
                and math.abs(desired_pitch + bias_pitch - pitch) <= math.rad(2)
            local alpha = precise_head and 1 or 1 - math.exp(-settings.strength * 12 * dt)
            local aim_target, motion = observed, nil
            if target.is_head then
                aim_target, motion = moving_head(key, target, observed, observed_time, now, dt, alpha, distance)
                motion.source = observation_source
                motion.selector_age_seconds = now - target.time
                motion.refresh_displacement_meters = math.sqrt((observed.x - target.x) ^ 2
                    + (observed.y - target.y) ^ 2 + (observed.z - target.z) ^ 2)
                motion.time, motion.entity_id, motion.distance = now, target.entity_id, distance
                if settings.collect_data then stats.head_alignment.motion.last = motion end
                dx, dy, dz = aim_target.x - position.x, aim_target.y - position.y, aim_target.z - position.z
                desired_yaw, desired_pitch = math.atan(dx, dz), math.atan(dy, math.sqrt(dx * dx + dz * dz))
            end
            local nominal_yaw, nominal_pitch = desired_yaw, desired_pitch
            desired_yaw, desired_pitch = wrap(nominal_yaw + bias_yaw), nominal_pitch + bias_pitch
            yaw_error, pitch_error = wrap(desired_yaw - yaw), desired_pitch - pitch
            local max_step = math.rad(180 + settings.strength * 45) * dt
            local function step(error)
                return math.max(-max_step, math.min(max_step, error * alpha))
            end
            local next_yaw = wrap(yaw + step(yaw_error))
            local next_pitch = math.max(-math.pi * 0.495, math.min(math.pi * 0.495, pitch + step(pitch_error)))
            set_angles:call(camera, next_yaw, next_pitch)
            apply_angles:call(camera)
            tracking_gate("tracking", key, target)
            if precise_head then stats.head_alignment.precise_frames = stats.head_alignment.precise_frames + 1 end
            local switching = switches[key]
            local confirmation = switching and switching.confirmation
            if confirmation then
                local request = confirmation.request
                request.camera_frames = request.camera_frames + 1
                request.camera_entity_id = target.entity_id
                request.camera_target = position_data(target)
                request.camera_yaw_error_degrees = math.deg(wrap(desired_yaw - camera:get_field("_Yaw")))
                request.camera_pitch_error_degrees = math.deg(desired_pitch - camera:get_field("_Pitch"))
                if target.entity_id ~= request.to then finish_confirmation(switching, "different_target")
                elseif math.abs(request.camera_yaw_error_degrees) <= 1
                    and math.abs(request.camera_pitch_error_degrees) <= 1 then
                    confirmation.settled_since = confirmation.settled_since or now
                    if request.camera_frames >= 3 and now - confirmation.settled_since >= 0.1 then
                        finish_confirmation(switching, "confirmed")
                    end
                else confirmation.settled_since = nil end
                if switching.confirmation and now - confirmation.time > 1 then
                    finish_confirmation(switching, "camera_did_not_settle")
                end
            end
            stats.corrections = stats.corrections + 1
            local sample = { joint = target.joint, is_head = target.is_head, entity_id = target.entity_id,
                point_id = target.point_id, target = observed, aim_target = aim_target, motion = motion,
                camera = { x = position.x, y = position.y, z = position.z },
                camera_object = settings.collect_data and position_data(camera:get_field("_CameraObjectPosition")) or nil,
                target_offset = target.offset, distance = distance,
                aim_distance = math.sqrt(dx * dx + dy * dy + dz * dz),
                time = now, delta_time = dt, camera_key = key, camera_id = tostring(key),
                nominal_yaw = nominal_yaw, nominal_pitch = nominal_pitch,
                screen_bias_yaw = bias_yaw, screen_bias_pitch = bias_pitch,
                precise_head = precise_head, follow_alpha = alpha,
                input_yaw_error_degrees = math.deg(yaw_error), input_pitch_error_degrees = math.deg(pitch_error),
                yaw = next_yaw, pitch = next_pitch, source = "continuous",
                selector_sample_age_seconds = now - target.time,
                yaw_error_degrees = math.deg(wrap(desired_yaw - next_yaw)),
                pitch_error_degrees = math.deg(desired_pitch - next_pitch) }
            if target.is_head then render_sample = sample else clear_alignment(key) end
            notify(sample)
        end)
        if not ok then
            clear_alignment(camera:get_address())
            tracking_gate("camera_error", camera:get_address())
            stats.error = tostring(err)
            notify(nil, err)
        end
        return retval
    end)

    -- Controller yaw/pitch can settle before the final rendered head is centered.
    -- Measure the local projection instead of assuming a fixed FOV, axis sign or
    -- pixel offset. Only copied scalar data crosses into the render callback;
    -- the next gameplay update applies a small, target-specific angular bias.
    function M.align_screen()
        if not enabled() or not settings.follow then screen_feedback = nil; return end
        local sample = render_sample
        if not sample or sample == measured_sample then return end
        measured_sample = sample
        local now, alignment = os.clock(), stats.head_alignment
        local function skip(reason, keep_feedback)
            count_reason(alignment.rejected, reason)
            if settings.collect_data then
                alignment.last_rejected = { reason = reason, time = now, entity_id = sample.entity_id,
                    distance = sample.distance, sample_age_seconds = now - sample.time,
                    yaw_error_degrees = sample.yaw_error_degrees, pitch_error_degrees = sample.pitch_error_degrees,
                    motion = sample.motion }
            end
            if not keep_feedback then screen_feedback = nil end
        end
        local target = targets[sample.camera_key]
        if not target or not target.is_head or target.entity_id ~= sample.entity_id
            or target.joint ~= sample.joint or target.point_id ~= sample.point_id or now - target.time > 0.1 then
            skip("target_changed"); return
        end
        if now < sample.time or now - sample.time > 0.05 then skip("stale_sample"); return end
        render_timing = { camera_key = sample.camera_key, time = now, delay = now - sample.time }
        -- The projection solve subtracts the known controller error. Permit the
        -- small residual of a moving head instead of requiring a static lock.
        if math.abs(sample.yaw_error_degrees) > 0.5 or math.abs(sample.pitch_error_degrees) > 0.5 then
            skip("controller_settling", true); return
        end
        if not Vector3f or not draw.world_to_screen then skip("projection_unavailable"); return end
        local ok, err = pcall(function()
            local display = imgui.get_display_size()
            if not display or not finite(display.x) or not finite(display.y)
                or display.x <= 0 or display.y <= 0 then skip("invalid_display"); return end
            local function project(position)
                local point = draw.world_to_screen(Vector3f.new(position.x, position.y, position.z))
                if point and finite(point.x) and finite(point.y) then return point end
            end
            local point = project(sample.aim_target)
            if not point or point.x < 0 or point.x > display.x or point.y < 0 or point.y > display.y then
                skip("head_not_on_screen"); return
            end
            local epsilon = math.rad(0.1)
            local function ray(yaw, pitch)
                local horizontal = math.cos(pitch) * sample.aim_distance
                return { x = sample.camera.x + math.sin(yaw) * horizontal,
                    y = sample.camera.y + math.sin(pitch) * sample.aim_distance,
                    z = sample.camera.z + math.cos(yaw) * horizontal }
            end
            local yaw_point = project(ray(sample.nominal_yaw + epsilon, sample.nominal_pitch))
            local pitch_point = project(ray(sample.nominal_yaw, sample.nominal_pitch + epsilon))
            if not yaw_point or not pitch_point then skip("projection_unavailable"); return end
            local xx, yx = (yaw_point.x - point.x) / epsilon, (yaw_point.y - point.y) / epsilon
            local xy, yy = (pitch_point.x - point.x) / epsilon, (pitch_point.y - point.y) / epsilon
            local determinant = xx * yy - xy * yx
            local scale = math.sqrt((xx * xx + yx * yx) * (xy * xy + yy * yy))
            if not finite(scale) or scale < 1 or math.abs(determinant) < scale * 0.1 then
                skip("unstable_projection"); return
            end
            local error_x, error_y = point.x - display.x * 0.5, point.y - display.y * 0.5
            local delta_yaw = (error_x * yy - error_y * xy) / determinant
            local delta_pitch = (error_y * xx - error_x * yx) / determinant
            local bias_yaw = wrap(sample.yaw - sample.nominal_yaw + delta_yaw)
            local bias_pitch = sample.pitch - sample.nominal_pitch + delta_pitch
            if not finite(bias_yaw) or not finite(bias_pitch)
                or math.abs(bias_yaw) > math.rad(2) or math.abs(bias_pitch) > math.rad(2) then
                skip("correction_too_large"); return
            end
            local elapsed = now - (screen_feedback and screen_feedback.time or now - sample.delta_time)
            local same_point = screen_feedback and screen_feedback.camera_key == sample.camera_key
                and screen_feedback.entity_id == sample.entity_id and screen_feedback.point_id == sample.point_id
                and screen_feedback.joint == sample.joint and elapsed >= 0 and elapsed <= 0.1
            -- The first valid, bounded calibration can be used immediately;
            -- subsequent measurements are smoothed to follow camera movement.
            local alpha = same_point and 1 - math.exp(-48 * math.min(elapsed, 0.05)) or 1
            screen_feedback = { camera_key = sample.camera_key, entity_id = sample.entity_id, joint = sample.joint,
                point_id = sample.point_id,
                time = now, target_yaw = sample.nominal_yaw, target_pitch = sample.nominal_pitch,
                yaw = sample.screen_bias_yaw + alpha * wrap(bias_yaw - sample.screen_bias_yaw),
                pitch = sample.screen_bias_pitch + alpha * (bias_pitch - sample.screen_bias_pitch) }
            alignment.measured_frames = alignment.measured_frames + 1
            local observed_point = project(sample.target)
            local observed_error = observed_point and { x = observed_point.x - display.x * 0.5,
                y = observed_point.y - display.y * 0.5 }
            local estimated_error
            if sample.motion then
                local velocity, age = sample.motion.velocity, math.min(now - sample.motion.observation_time, 0.05)
                local estimated = project({ x = sample.target.x + velocity.x * age,
                    y = sample.target.y + velocity.y * age, z = sample.target.z + velocity.z * age })
                if estimated then estimated_error = { x = estimated.x - display.x * 0.5, y = estimated.y - display.y * 0.5 } end
            end
            if observed_error and observed_error.x ^ 2 + observed_error.y ^ 2 <= 1 then
                alignment.centered_frames = alignment.centered_frames + 1
            end
            if estimated_error and estimated_error.x ^ 2 + estimated_error.y ^ 2 <= 1 then
                alignment.estimated_centered_frames = alignment.estimated_centered_frames + 1
            end
            local outlier = estimated_error and estimated_error.x ^ 2 + estimated_error.y ^ 2 > 9
            if outlier then alignment.outlier_frames = alignment.outlier_frames + 1 end
            if settings.collect_data then
                local detail = { time = now, timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                    camera_id = sample.camera_id, entity_id = sample.entity_id, distance = sample.distance,
                    sample_age_seconds = now - sample.time, error_px = observed_error,
                    aim_error_px = { x = error_x, y = error_y }, estimated_render_error_px = estimated_error,
                    motion = sample.motion, target = sample.target, aim_target = sample.aim_target,
                    precise_head = sample.precise_head, follow_alpha = sample.follow_alpha,
                    input_yaw_error_degrees = sample.input_yaw_error_degrees,
                    input_pitch_error_degrees = sample.input_pitch_error_degrees,
                    yaw_error_degrees = sample.yaw_error_degrees, pitch_error_degrees = sample.pitch_error_degrees,
                    correction_yaw_degrees = math.deg(screen_feedback.yaw),
                    correction_pitch_degrees = math.deg(screen_feedback.pitch),
                    applied_yaw_degrees = math.deg(sample.screen_bias_yaw),
                    applied_pitch_degrees = math.deg(sample.screen_bias_pitch) }
                alignment.last = detail
                local previous = alignment.history[#alignment.history]
                if not previous or previous.entity_id ~= detail.entity_id or now - previous.time >= 0.1 then
                    alignment.history[#alignment.history + 1] = detail
                    if #alignment.history > 32 then table.remove(alignment.history, 1) end
                end
                local previous_outlier = alignment.outliers[#alignment.outliers]
                if outlier and (not previous_outlier or previous_outlier.entity_id ~= detail.entity_id
                    or now - previous_outlier.time >= 0.1) then
                    alignment.outliers[#alignment.outliers + 1] = detail
                    if #alignment.outliers > 16 then table.remove(alignment.outliers, 1) end
                end
            end
        end)
        if not ok then alignment.last_error = tostring(err); skip("projection_error") end
    end

    -- Render-thread evidence uses copied positions only. Capture the projection
    -- of both the old target and candidates, plus the currently tracked point;
    -- controller angles alone cannot prove which enemy the user saw centered.
    function M.sample_screen(sample, sample_age, aiming)
        if not settings.collect_data or not Vector3f or not draw.world_to_screen then return end
        local request = stats.pending_request or stats.last_request
        local now = os.clock()
        if not request or now - request.time > 1
            or now - (request.last_render_time or -100) < 0.05 then return end
        request.render_samples = request.render_samples or {}
        if #request.render_samples >= 12 then return end
        request.last_render_time = now
        local ok, err = pcall(function()
            local display = imgui.get_display_size()
            if not display or display.x <= 0 or display.y <= 0 then return end
            local function project(position)
                if not valid_position(position) then return end
                local point = draw.world_to_screen(Vector3f.new(position.x, position.y, position.z))
                if not point or not finite(point.x) or not finite(point.y) then return end
                return { x = point.x - display.x * 0.5, y = point.y - display.y * 0.5,
                    on_screen = point.x >= 0 and point.x <= display.x and point.y >= 0 and point.y <= display.y }
            end
            local previous = project(request.from_position)
            if request.candidates and not request.screen_candidates then
                request.screen_candidates = {}
                request.screen_size = { width = display.x, height = display.y }
                for _, candidate in ipairs(request.candidates) do
                    local point = project(candidate.position)
                    request.screen_candidates[#request.screen_candidates + 1] = {
                        entity_id = candidate.entity_id, from_center_px = point,
                        from_previous_target_px = point and previous and { x = point.x - previous.x, y = point.y - previous.y } or nil,
                        reason = candidate.reason }
                end
            end
            request.render_samples[#request.render_samples + 1] = {
                time = now, aiming = aiming, sample_age_seconds = sample_age,
                entity_id = sample and sample.entity_id, from_target_px = previous,
                tracked_target_px = sample and sample_age < 0.1 and project(sample.target) or nil }
        end)
        if not ok then stats.screen_error = tostring(err) end
    end

    function M.status() return stats end
    return 2
end

return M
