local Controller = {}
local MAX_SHAKE_STRENGTH = 0.65
local MIN_SHAKE_SECONDS = 0.05
local MAX_SHAKE_SECONDS = 0.6
local SHAKE_X_FREQUENCY = 24
local SHAKE_Y_FREQUENCY = 28
local SHAKE_ROLL_FREQUENCY = 22
local SHAKE_ROLL_SCALE = 0.025
local FOV_RESPONSE = 12
local MAX_SIDE_FOV = 80
local IMPACT_FOV_SHIFT = 6
local OCCLUSION_INTERVAL = 1 / 15
local BEHIND_DISTANCE = 8
local BEHIND_SHOULDER_OFFSET = 1.8

function Controller.Initialize()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")

    local player = Players.LocalPlayer
    local arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")

    local function FindOpponent()
        local id = script.Parent.Parent:GetAttribute("OpponentUserId") or 0
        local other = if id ~= 0 then Players:GetPlayerByUserId(id) else nil

        if id ~= 0 then
            return other and other.Character
        end

        local arenas = workspace.Combat:FindFirstChild("Arenas")
        local active = arenas and arenas:FindFirstChild(script.Parent.Parent:GetAttribute("ArenaId") or "")

        return active and active:FindFirstChild("NPC")
    end

    local faded_parts = {}
    local camera_players = {}
    local player_listeners = {}
    local cast_parts = {}
    local cast_listeners = {}
    local cast_points = {}
    local ignored = {}
    local occlusion_dirty = true
    local occlusion_elapsed = OCCLUSION_INTERVAL
    local cast_character
    local cast_opponent

    local function WatchPlayer(viewer)
        camera_players[viewer] = true
        local function Changed() occlusion_dirty = true end
        player_listeners[viewer] = {viewer.CharacterAdded:Connect(Changed), viewer.CharacterRemoving:Connect(Changed)}
        Changed()
    end

    Players.PlayerAdded:Connect(WatchPlayer)
    Players.PlayerRemoving:Connect(function(viewer)
        for _, connection in player_listeners[viewer] or {} do connection:Disconnect() end
        player_listeners[viewer] = nil
        camera_players[viewer] = nil
        occlusion_dirty = true
    end)
    for _, viewer in Players:GetPlayers() do WatchPlayer(viewer) end
    local SIDE_FIELD_OF_VIEW = 45
    local MIN_SIDE_DISTANCE = 20
    local MAX_SIDE_DISTANCE = 30
    local COMBAT_CAMERA_LIMIT = 40
    local BEHIND_FIELD_OF_VIEW = 65
    local field_of_view = BEHIND_FIELD_OF_VIEW
    local folder = script.Parent.Parent

    local CAMERA_RESPONSE = 20
    local MIN_TURN_DISTANCE = 2
    local cinematic_until = 0
    local cinematic_duration = 0.3
    local cinematic_event

    script.Parent.Parent:WaitForChild("Cinematic").Event:Connect(function(duration, event_id)
        cinematic_duration = math.clamp(duration, 0.1, 1)
        cinematic_until = os.clock() + cinematic_duration
        cinematic_event = event_id
    end)

    script.Parent.Parent:WaitForChild("RollbackEffects").Event:Connect(function(valid)
        if cinematic_event and not valid[cinematic_event] then
            cinematic_until = 0
        end
    end)

    local character
    local root
    local camera_ready = false
    local camera_cframe = CFrame.identity
    local side_direction
    local behind_direction
    local camera_opponent
    local side_control_sign = 1
    local shake_events = {}
    local shake_serial = 0
    local camera_shake = script.Parent.Parent:WaitForChild("CameraShake")

    camera_shake.Event:Connect(function(strength: number, duration: number, event_id: string?)
        shake_serial += 1
        local key = event_id or shake_serial
        if shake_events[key] then
            return
        end
        shake_events[key] = {
            started_at = os.clock(),
            strength = math.clamp(strength, 0, MAX_SHAKE_STRENGTH),
            duration = math.clamp(duration, MIN_SHAKE_SECONDS, MAX_SHAKE_SECONDS),
            event_id = event_id
        }
    end)

    folder.RollbackEffects.Event:Connect(function(valid)
        for key, shake in shake_events do
            if next(valid) == nil or (shake.event_id and not valid[shake.event_id]) then
                shake_events[key] = nil
            end
        end
    end)

    local function ResetView()
        occlusion_elapsed = OCCLUSION_INTERVAL
        camera_ready = false
        side_direction = nil
        behind_direction = nil
        side_control_sign = 1
        folder:SetAttribute("SideControlSign", 1)
    end

    local function WatchCharacter(model)
        local new_root = model:WaitForChild("HumanoidRootPart", 10)

        if player.Character ~= model or not model.Parent or not new_root then
            return
        end
        character = model
        root = new_root
        ResetView()
    end

    player.CharacterRemoving:Connect(function(model)
        if model ~= character then
            return
        end
        for _, connection in cast_listeners do connection:Disconnect() end
        table.clear(cast_listeners)
        table.clear(cast_parts)
        cast_character, cast_opponent = nil, nil
        occlusion_dirty = true
        root = nil
        character = nil
        ResetView()

        for part, transparency in faded_parts do
            if part.Parent then
                part.LocalTransparencyModifier = transparency
            end
        end

        table.clear(faded_parts)
    end)

    player:GetAttributeChangedSignal("MatchStatus"):Connect(function()
        if player:GetAttribute("MatchStatus") ~= "Fighting" then
            cinematic_until = 0
            cinematic_event = nil
            table.clear(shake_events)
            ResetView()
        end
    end)

    folder:GetAttributeChangedSignal("ArenaId"):Connect(function()
        ResetView()
        table.clear(shake_events)
        cinematic_until = 0
    end)

    folder:GetAttributeChangedSignal("CameraMode"):Connect(ResetView)
    player.CharacterAdded:Connect(WatchCharacter)

    if player.Character then
        task.spawn(WatchCharacter, player.Character)
    end

    RunService:BindToRenderStep("CombatCamera", Enum.RenderPriority.Camera.Value + 1, function(delta_time)
        local npc = FindOpponent()
        local dummy_root = npc and npc:FindFirstChild("HumanoidRootPart")
        local camera = workspace.CurrentCamera

        if not camera or not root or not root.Parent then
            return
        end

        delta_time = math.clamp(delta_time, 0, 0.1)

        if dummy_root ~= camera_opponent then
            camera_opponent = dummy_root
            ResetView()
        end

        if camera.CameraType ~= Enum.CameraType.Scriptable then camera.CameraType = Enum.CameraType.Scriptable end
        if folder:GetAttribute("FightTransition") == "Out" then
            return
        end

        local cinematic = math.clamp(1 - (cinematic_until - os.clock()) / cinematic_duration, 0, 1)
        local impact_weight = if cinematic < 0.15 then cinematic / 0.15 else ((1 - cinematic) / 0.85)^2
        local side_view = folder:GetAttribute("CameraMode") == "Side"
        local position = root.Position
        local opponent_position = if dummy_root then dummy_root.Position else Vector3.new(arena:GetAttribute("LobbyX"), 4, arena:GetAttribute("LobbyZ"))
        local midpoint = (position + opponent_position) * 0.5
        local focus_y = math.max(4, (position.Y + opponent_position.Y) * 0.5)
        local aspect_ratio = camera.ViewportSize.X / math.max(camera.ViewportSize.Y, 1)
        local half_width = if dummy_root then Vector3.new(position.X - opponent_position.X, 0, position.Z - opponent_position.Z).Magnitude * 0.5 + 5 else 15
        local half_height = math.max(6, math.abs(position.Y - opponent_position.Y) * 0.5 + 4)
        local half_fov_tangent = math.tan(math.rad(SIDE_FIELD_OF_VIEW * 0.5))
        local distance = math.clamp(math.max(half_width / (half_fov_tangent * aspect_ratio), half_height / half_fov_tangent), MIN_SIDE_DISTANCE, MAX_SIDE_DISTANCE)
        local focus = Vector3.new(midpoint.X, focus_y, midpoint.Z)
        local separation = opponent_position - position
        local horizontal = Vector3.new(separation.X, 0, separation.Z)
        local candidate = if dummy_root and horizontal.Magnitude > 0.1 then Vector3.new(-horizontal.Z, 0, horizontal.X).Unit else Vector3.zAxis
        if side_direction and candidate:Dot(side_direction) < 0 then
            candidate = -candidate
        end
        if not side_direction or horizontal.Magnitude > 0.1 then
            side_direction = candidate
        end

        local camera_position = focus + side_direction * distance + Vector3.new(0, 5, 0)

        if not side_view and dummy_root then
            local facing = root.CFrame.LookVector
            local forward = Vector3.new(facing.X, 0, facing.Z)
            forward = if forward.Magnitude > 0.1 then forward.Unit else behind_direction or Vector3.xAxis
            behind_direction = forward

            local right = forward:Cross(Vector3.yAxis)

            camera_position = position - forward * BEHIND_DISTANCE + right * BEHIND_SHOULDER_OFFSET + Vector3.new(0, 3, 0)
            focus = position + forward * math.max(5, math.min((opponent_position - position).Magnitude, 16)) + Vector3.new(0, 1.8, 0)
        end

        local camera_limit = if dummy_root then COMBAT_CAMERA_LIMIT else 103
        camera_position = Vector3.new(math.clamp(camera_position.X, -camera_limit, camera_limit), camera_position.Y, math.clamp(camera_position.Z, -camera_limit, camera_limit))

        local target_fov = if side_view then SIDE_FIELD_OF_VIEW else BEHIND_FIELD_OF_VIEW

        if side_view and dummy_root then
            local framing_distance = math.max(1, (camera_position - focus).Magnitude)
            local framing_ratio = math.max(half_width / (framing_distance * aspect_ratio), half_height / framing_distance)
            target_fov = math.clamp(math.deg(2 * math.atan(framing_ratio)), SIDE_FIELD_OF_VIEW, MAX_SIDE_FOV)
        end

        field_of_view += (target_fov - field_of_view) * (1 - math.exp(-FOV_RESPONSE * delta_time))
        camera.FieldOfView = field_of_view - impact_weight * IMPACT_FOV_SHIFT

        local target = CFrame.lookAt(camera_position, focus)

        camera_cframe = if camera_ready and not dummy_root then camera_cframe:Lerp(target, 1 - math.exp(-CAMERA_RESPONSE * delta_time)) else target

        if side_view and dummy_root and horizontal.Magnitude >= MIN_TURN_DISTANCE then
            local screen_direction = horizontal.Unit:Dot(camera_cframe.RightVector)
            if screen_direction > 0.15 then side_control_sign = 1 elseif screen_direction < -0.15 then side_control_sign = -1 end
        end
        if folder:GetAttribute("SideControlSign") ~= side_control_sign then folder:SetAttribute("SideControlSign", side_control_sign) end

        local now = os.clock()
        local strength = 0
        for key, shake in shake_events do
            local weight = 1 - (now - shake.started_at) / shake.duration
            if weight <= 0 then
                shake_events[key] = nil
            else
                strength += shake.strength * weight * weight
            end
        end
        strength = math.min(strength, MAX_SHAKE_STRENGTH)
        local offset_x = math.noise(now * SHAKE_X_FREQUENCY, 0, 0) * strength
        local offset_y = math.noise(0, now * SHAKE_Y_FREQUENCY, 0) * strength
        local roll = math.noise(0, 0, now * SHAKE_ROLL_FREQUENCY) * strength * SHAKE_ROLL_SCALE

        camera.CFrame = camera_cframe * CFrame.new(offset_x, offset_y, 0) * CFrame.Angles(0, 0, roll)
        camera.Focus = CFrame.new(focus)
        camera_ready = true

        occlusion_elapsed += delta_time
        if occlusion_dirty or cast_character ~= character or cast_opponent ~= npc then
            for _, connection in cast_listeners do connection:Disconnect() end
            table.clear(cast_listeners)
            table.clear(cast_parts)
            table.clear(ignored)
            table.insert(ignored, arena.Canvas)
            for viewer in camera_players do
                if viewer.Character then table.insert(ignored, viewer.Character) end
            end
            if npc then table.insert(ignored, npc) end
            for _, fighter in {character, npc} do
                if fighter then
                    for _, part in fighter:GetChildren() do
                        if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then table.insert(cast_parts, part) end
                    end
                    local function Changed() occlusion_dirty = true end
                    table.insert(cast_listeners, fighter.ChildAdded:Connect(Changed))
                    table.insert(cast_listeners, fighter.ChildRemoved:Connect(Changed))
                end
            end
            cast_character, cast_opponent = character, npc
            occlusion_dirty = false
            occlusion_elapsed = OCCLUSION_INTERVAL
        end

        if occlusion_elapsed < OCCLUSION_INTERVAL then return end
        occlusion_elapsed = 0
        table.clear(cast_points)
        for _, part in cast_parts do
            if part.Parent then table.insert(cast_points, part.Position) end
        end
        local obstructing = {}

        for _, part in camera:GetPartsObscuringTarget(cast_points, ignored) do
            obstructing[part] = true

            if faded_parts[part] == nil then
                faded_parts[part] = part.LocalTransparencyModifier
                part.LocalTransparencyModifier = 1
            end
        end

        for part, transparency in faded_parts do
            if not obstructing[part] then
                if part.Parent then
                    part.LocalTransparencyModifier = transparency
                end

                faded_parts[part] = nil
            end
        end
    end)
end

return Controller
