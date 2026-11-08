local FighterPresentation = require(game.ReplicatedStorage.Combat.Modules.FighterPresentation)
local Motion = {}
local MAX_DELTA_SECONDS = 0.1 -- Clamp visual time steps so a hitch cannot fling the additive pose.
local MOVEMENT_THRESHOLD = 0.1
local MAX_GAIT_SPEED = 20
local GAIT_FREQUENCY = 0.9
local FULL_STRIDE_SPEED = 16
local RECOIL_DECAY = 18 -- Fade about 95% of recoil in 0.17 seconds.
local SETTLE_EPSILON = 0.0001
local RECOIL_EPSILON = 0.001
local GAIT_RESPONSE = 18
local POSE_RESPONSE = 26
local DODGE_STARTUP_FRAMES = 3
local DODGE_RECOVERY_START = 13
local DODGE_RECOVERY_FRAMES = 12
local BLOCK_RECOIL_SCALE = 0.35 -- Keep blocked reactions smaller than clean-hit reactions.
local DODGE_PITCH_DEGREES = 10
local STRIDE_PITCH_DEGREES = -1.2
local STRIDE_ROLL_DEGREES = 1.8
local DODGE_ROLL_DEGREES = 12
local STRIDE_SHIFT = 0.025
local DODGE_SHIFT = 0.5
local DODGE_DIP = 0.22
local DODGE_RETREAT = 0.16
local FOOT_LIFT = 0.16
local FOOT_SHIFT = 0.1
local FORWARD_STEP_DEGREES = 18
local SIDE_STEP_DEGREES = 14
local DODGE_STANCE_DEGREES = 6
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MoveDefinitions = require(game:GetService("ReplicatedStorage").Combat.Modules.MoveDefinitions)
local Cinematics = require(script.Parent.Cinematics)

function Motion.Bind(character, root, animation_state, find_opponent)
    local player = Players.LocalPlayer
    local is_player = character == player.Character
    local folder = script.Parent.Parent
    local arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    local combat_effects = folder:WaitForChild("CombatEffects")
    local rollback_effects = folder:WaitForChild("RollbackEffects")
    local character_connections = {}
    local alive = true
    local torso = character:FindFirstChild("Torso")
    local root_joint = root:FindFirstChild("RootJoint")
    local neck = torso and torso:FindFirstChild("Neck")
    local hips = {torso and torso:FindFirstChild("Left Hip"), torso and torso:FindFirstChild("Right Hip")}
    local hip_offsets = {CFrame.identity, CFrame.identity}
    local shoulders = {torso and torso:FindFirstChild("Left Shoulder"), torso and torso:FindFirstChild("Right Shoulder")}
    local shoulder_offsets = {CFrame.identity, CFrame.identity}
    local leg_weight = 0
    local dodge_side = 1
    local root_offset = CFrame.identity
    local neck_offset = CFrame.identity
    local motion_pose = CFrame.identity
    local step_phase = 0
    local stride_weight = 0
    local step_travel = Vector3.zero
    local recoil_age = math.huge
    local recoil_strength = 0
    local recoil_side = 0
    local recoil_blocked = false
    local recoil_event_id
    local paired_correction = Vector3.zero
    local motion_sleeping = false
    local offsets_applied = false

    -- Remove the last overlay before Animator evaluates, so joint offsets cannot accumulate.
    table.insert(character_connections, RunService.PreAnimation:Connect(function()
        if not offsets_applied then return end
        offsets_applied = false
        if root_joint and root_joint.Parent then
            root_joint.Transform *= root_offset:Inverse()
        end

        if neck and neck.Parent then
            neck.Transform *= neck_offset:Inverse()
        end

        for index, hip in hips do
            if hip and hip.Parent then
                hip.Transform *= hip_offsets[index]:Inverse()
            end
            hip_offsets[index] = CFrame.identity
        end

        for index, shoulder in shoulders do
            if shoulder and shoulder.Parent then
                shoulder.Transform *= shoulder_offsets[index]:Inverse()
            end
            shoulder_offsets[index] = CFrame.identity
        end

        root_offset = CFrame.identity
        neck_offset = CFrame.identity
    end))

    -- Apply visual layers after Animator without moving simulated combat roots.
    table.insert(character_connections, RunService.PreSimulation:Connect(function(delta_time)
        if not root_joint or not root_joint.Parent then
            return
        end

        local state = character:GetAttribute("CombatState") or "Idle"
        local fighting = arena:GetAttribute("MatchState") == "Fighting"
        local paired_track = animation_state.paired_track
        local paired_visual = paired_track and (paired_track.IsPlaying or paired_track.WeightCurrent > 0.001)
        local taken_down = state == "Stunned" and character:GetAttribute("StunReason") == "Takedown"
        local active = fighting and state ~= "GettingUp" and not paired_visual and not taken_down and state ~= "Knockdown" and state ~= "Knockout" and state ~= "BoutOver"
        local speed = if active and (character:GetAttribute("ClinchRole") or "") == "" then character:GetAttribute("CombatMoveSpeed") or 0 else 0
        local dodging = active and state:sub(1, 5) == "Dodge"
        local recoil_pending = active and math.abs(recoil_strength * math.exp(-RECOIL_DECAY * recoil_age)) > RECOIL_EPSILON
        if motion_sleeping and speed <= MOVEMENT_THRESHOLD and not dodging and not paired_visual and not recoil_pending then return end
        offsets_applied = true
        local step_time = math.min(delta_time, MAX_DELTA_SECONDS) * Cinematics.TimeScale

        if speed > MOVEMENT_THRESHOLD then
            step_phase = (step_phase + step_time * math.min(speed, MAX_GAIT_SPEED) * GAIT_FREQUENCY) % (math.pi * 2)
        end
        recoil_age += step_time

        local recoil = if active then recoil_strength * math.exp(-RECOIL_DECAY * recoil_age) else 0

        stride_weight += (math.clamp(speed / FULL_STRIDE_SPEED, 0, 1) - stride_weight) * (1 - math.exp(-GAIT_RESPONSE * step_time))

        local active_move = MoveDefinitions.Get(character:GetAttribute("FighterId") or "Boxing", animation_state.active_kind)
        local leg_attack = state == "GettingUp" or paired_visual or taken_down or (character:GetAttribute("ClinchRole") or "") ~= "" or (animation_state.active_track and animation_state.active_track.IsPlaying and active_move and active_move.uses_legs)
        local stride = if leg_attack then 0 else stride_weight
        local dodge_age = character:GetAttribute("DodgeAgeFrames") or 0
        local dodge_weight = if not dodging then 0 elseif state == "DodgeStartup" then math.clamp(dodge_age / DODGE_STARTUP_FRAMES, 0, 1) elseif state == "DodgeRecovery" then math.clamp(1 - (dodge_age - DODGE_RECOVERY_START) / DODGE_RECOVERY_FRAMES, 0, 1) else 1
        local body_recoil = recoil * (if recoil_blocked then BLOCK_RECOIL_SCALE else 1)
        local pitch = math.rad(dodge_weight * DODGE_PITCH_DEGREES + stride * animation_state.move_direction * STRIDE_PITCH_DEGREES)
        local roll = math.rad(math.sin(step_phase) * stride * STRIDE_ROLL_DEGREES - dodge_side * dodge_weight * DODGE_ROLL_DEGREES)
        local target = CFrame.new(math.sin(step_phase) * stride * STRIDE_SHIFT + dodge_side * dodge_weight * DODGE_SHIFT, -DODGE_DIP * dodge_weight, DODGE_RETREAT * dodge_weight) * CFrame.Angles(pitch, 0, roll)

        motion_pose = if paired_visual or state == "GettingUp" then CFrame.identity else motion_pose:Lerp(target, 1 - math.exp(-POSE_RESPONSE * step_time))
        local base_root = root_joint.Transform
        local impact_pose = CFrame.Angles(math.rad(body_recoil), 0, math.rad(body_recoil * recoil_side * 0.3))
        root_offset = root_joint.C1:Inverse() * motion_pose * impact_pose * root_joint.C1
        root_joint.Transform *= root_offset

        if paired_visual then
            if character:GetAttribute("PairedRole") == "Victim" then
                paired_correction = character:GetAttribute("PairedRootOffset") or Vector3.zero
            end
            local weight = paired_track.WeightCurrent
            local shift = root_joint.C0:VectorToObjectSpace(root.CFrame:VectorToObjectSpace(paired_correction * weight))
            local posed = root_joint.Transform
            root_joint.Transform = CFrame.new(posed.Position + shift) * posed.Rotation
            root_offset = base_root:ToObjectSpace(root_joint.Transform)
        else
            paired_correction = Vector3.zero
        end

        local velocity = character:GetAttribute("CombatMoveVelocity") or Vector3.zero
        local local_velocity = root.CFrame:VectorToObjectSpace(velocity)
        local desired_travel = if active and local_velocity.Magnitude > MOVEMENT_THRESHOLD then local_velocity.Unit else Vector3.zero

        step_travel = step_travel:Lerp(desired_travel, 1 - math.exp(-GAIT_RESPONSE * step_time))

        local travel = step_travel
        local legs_active = active and not leg_attack and (speed > MOVEMENT_THRESHOLD or dodging) and state ~= "Stunned"

        if leg_attack then
            leg_weight = 0
        else
            leg_weight += ((if legs_active then 1 else 0) - leg_weight) * (1 - math.exp(-GAIT_RESPONSE * step_time))
        end

        for index, hip in hips do
            if hip and hip.Parent then
                local phase = step_phase + (index - 1) * math.pi
                local swing = math.sin(phase) * stride
                local lift = math.max(0, math.cos(phase)) * stride * FOOT_LIFT
                local stance = if index == 1 then -1 else 1
                local leg_pose = CFrame.new(travel.X * swing * FOOT_SHIFT, lift + 0.12 * dodge_weight, travel.Z * swing * FOOT_SHIFT) * CFrame.Angles(-travel.Z * swing * math.rad(FORWARD_STEP_DEGREES), 0, -travel.X * swing * math.rad(SIDE_STEP_DEGREES) + stance * math.rad(DODGE_STANCE_DEGREES) * dodge_weight)
                local joint_rotation = root.CFrame.Rotation:Inverse() * torso.CFrame.Rotation * hip.C0.Rotation
                local desired = joint_rotation:Inverse() * leg_pose * joint_rotation
                local base = hip.Transform
                local adjustment = CFrame.identity:Lerp(desired, leg_weight)
                local blended = CFrame.new(base.Position + adjustment.Position) * adjustment.Rotation * base.Rotation

                hip_offsets[index] = base:ToObjectSpace(blended)
                hip.Transform = blended
            end
        end

        for index, shoulder in shoulders do
            if shoulder and shoulder.Parent then
                local amount = if recoil_blocked then recoil else 0
                local direction = if index == 1 then -1 else 1
                local rotation = shoulder.C0.Rotation

                shoulder_offsets[index] = rotation:Inverse() * CFrame.Angles(math.rad(amount * 1.4), 0, math.rad(direction * amount * 0.4)) * rotation
                shoulder.Transform *= shoulder_offsets[index]
            end
        end

        if neck and neck.Parent then
            neck_offset = neck.C1:Inverse() * CFrame.Angles(-pitch * 0.25 + (if recoil_blocked then 0 else math.rad(recoil * 0.4)), 0, -roll * 0.25) * neck.C1
            neck.Transform *= neck_offset
        end
        local _, pose_angle = motion_pose:ToAxisAngle()
        motion_sleeping = speed <= MOVEMENT_THRESHOLD and not dodging and not paired_visual and not recoil_pending and stride_weight < SETTLE_EPSILON and leg_weight < SETTLE_EPSILON and step_travel.Magnitude < SETTLE_EPSILON and motion_pose.Position.Magnitude < SETTLE_EPSILON and math.abs(pose_angle) < SETTLE_EPSILON
        if motion_sleeping then
            motion_pose = CFrame.identity
            stride_weight, leg_weight = 0, 0
            step_travel = Vector3.zero
        end
    end))

    table.insert(character_connections, FighterPresentation.Observe(character, "HitSerial", function()
        local dodged = character:GetAttribute("LastHitDodged")
        local blocked = character:GetAttribute("LastHitBlocked")
        local event_id = character:GetAttribute("LastHitPresentationEventId")
        if not dodged then
            recoil_age = 0
            local kind = character:GetAttribute("LastHitKind") or "Jab"
            local feedback = MoveDefinitions.GetFeedback(character:GetAttribute("LastHitFighterId") or "Boxing", kind, {Counter = character:GetAttribute("LastHitCounter"), WallSplat = character:GetAttribute("LastHitWallSplat"), Blocked = blocked, Caught = character:GetAttribute("LastHitCaught")})
            recoil_strength = feedback.recoil
            recoil_blocked = blocked == true
            recoil_event_id = event_id

            local other = if is_player then find_opponent() else player.Character
            local other_root = other and other:FindFirstChild("HumanoidRootPart")

            recoil_side = if other_root then math.clamp(root.CFrame:VectorToObjectSpace(other_root.Position - root.Position).X / 3, -1, 1) else 0
        end
    end))

    table.insert(character_connections, combat_effects.Event:Connect(function(event)
        if event.kind ~= "Dodge" or event.fighter ~= (if is_player then (folder:GetAttribute("FighterSlot") or 2) else 3 - (folder:GetAttribute("FighterSlot") or 2)) then return end
        local other = if is_player then find_opponent() else player.Character
        local other_root = other and other:FindFirstChild("HumanoidRootPart")
        local variant = if other then other:GetAttribute("JabVariant") or 1 else 1
        local arm = other and other:FindFirstChild(if variant % 2 == 1 then "Right Arm" else "Left Arm")
        local fist = if arm then arm.CFrame:PointToWorldSpace(Vector3.new(0, -arm.Size.Y * 0.5, 0)) elseif other_root then other_root.Position else nil

        if other then
            local head_position = (character:FindFirstChild("Head") or root).Position
            local nearest = if fist then (fist - head_position).Magnitude else math.huge

            for _, name in {"Left Arm", "Right Arm"} do
                local candidate = other:FindFirstChild(name)

                if candidate then
                    local tip = candidate.CFrame:PointToWorldSpace(Vector3.new(0, -candidate.Size.Y * 0.5, 0))
                    local distance = (tip - head_position).Magnitude

                    if distance < nearest - 0.1 then
                        fist = tip
                        nearest = distance
                    end
                end
            end
        end

        if fist then
            local punch_side = root.CFrame:PointToObjectSpace(fist).X

            dodge_side = if punch_side >= 0 then -1 else 1
        end
    end))

    table.insert(character_connections, rollback_effects.Event:Connect(function(valid)
        if next(valid) == nil then
            recoil_strength = 0
        end
        if recoil_event_id and not valid[recoil_event_id] then
            recoil_strength = 0; recoil_event_id = nil
        end
    end))

    return function()
        if not alive then
            return
        end
        alive = false
        for _, connection in character_connections do
            connection:Disconnect()
        end
        if root_joint and root_joint.Parent then
            root_joint.Transform *= root_offset:Inverse()
        end

        if neck and neck.Parent then
            neck.Transform *= neck_offset:Inverse()
        end

        for index, hip in hips do if hip and hip.Parent then hip.Transform *= hip_offsets[index]:Inverse() end end

        for index, shoulder in shoulders do if shoulder and shoulder.Parent then shoulder.Transform *= shoulder_offsets[index]:Inverse() end end
    end
end

return Motion
