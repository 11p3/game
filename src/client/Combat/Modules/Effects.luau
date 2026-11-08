local FighterPresentation = require(game.ReplicatedStorage.Combat.Modules.FighterPresentation)
local Effects = {}
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Audio = require(script.Parent.Audio)
local Cinematics = require(script.Parent.Cinematics)
local MoveDefinitions = require(game:GetService("ReplicatedStorage").Combat.Modules.MoveDefinitions)

function Effects.Bind(character, root)
    local player = Players.LocalPlayer
    local is_player = character == player.Character
    local folder = script.Parent.Parent
    local arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    local camera_shake = folder:WaitForChild("CameraShake")
    local rollback_effects = folder:WaitForChild("RollbackEffects")
    local combat_effects = folder:WaitForChild("CombatEffects")
    local character_connections = {}
    local alive = true
    -- Share the hit flash and attack outline instead of stacking highlights.
    local flash = Instance.new("Highlight")

    flash.Name = "ImpactFeedback"
    flash.Adornee = character
    flash.FillTransparency = 1
    flash.OutlineTransparency = 1
    flash.DepthMode = Enum.HighlightDepthMode.Occluded
    flash.Parent = character

    local cue

    if not is_player then
        cue = flash
        cue.OutlineColor = Color3.fromRGB(255, 35, 35)
    end

    local flash_tween
    local flash_event_id

    if cue then
        table.insert(character_connections, RunService.RenderStepped:Connect(function()
            local root = character:FindFirstChild("HumanoidRootPart")
            local local_root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            local now = workspace:GetServerTimeNow()
            local window_at = character:GetAttribute("PerfectWindowAt") or math.huge
            local release_at = character:GetAttribute("PunchActiveAt") or 0
            local attacking = root and local_root and character:GetAttribute("CombatState") == "AttackStartup" and arena:GetAttribute("MatchState") == "Fighting" and now < release_at

            local transparency = if attacking then (if now >= window_at then 0 else 0.35) else 1
            if cue.OutlineTransparency ~= transparency then cue.OutlineTransparency = transparency end
        end))
    end

    table.insert(character_connections, combat_effects.Event:Connect(function(event)
        local slot = folder:GetAttribute("FighterSlot") or 2
        local target_slot = if is_player then slot else 3 - slot
        if event.kind == "Capture" and event.attack_kind == "Shoot" and event.target == target_slot then
            camera_shake:Fire(0.34, 0.2, event.key)
        end
    end))

    table.insert(character_connections, FighterPresentation.Observe(character, "HitSerial", function()
        local dodged = character:GetAttribute("LastHitDodged")
        local blocked = character:GetAttribute("LastHitBlocked")
        local event_id = character:GetAttribute("LastHitPresentationEventId")
        local perfect = character:GetAttribute("LastHitPerfect")
        local feedback = MoveDefinitions.GetFeedback(character:GetAttribute("LastHitFighterId") or "Boxing", character:GetAttribute("LastHitKind") or "Jab", {Opening = character:GetAttribute("LastHitOpening"), Counter = character:GetAttribute("LastHitCounter"), Momentum = character:GetAttribute("LastHitMomentum"), WallSplat = character:GetAttribute("LastHitWallSplat"), Blocked = blocked, Perfect = perfect, Caught = character:GetAttribute("LastHitCaught")})

        if feedback.fov_time > 0 and not dodged and not blocked then
            folder.Cinematic:Fire(feedback.fov_time, event_id)
        end
        if not dodged then camera_shake:Fire(if is_player then feedback.shake_taken else feedback.shake_dealt, feedback.shake_time, event_id) end

        if perfect then
            Cinematics.PlayPerfect(event_id)

        end

        if not dodged or perfect then
            flash_event_id = event_id
            if flash_tween then
                flash_tween:Cancel()
            end

            flash.FillColor = Color3.fromRGB(table.unpack(feedback.flash))
            flash.FillTransparency = feedback.flash_alpha
            flash_tween = TweenService:Create(flash, TweenInfo.new(feedback.flash_time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {FillTransparency = 1})
            flash_tween:Play()
            if not dodged then
                Audio.Play(feedback.sound, feedback.volume, feedback.pitch, event_id, "Impact")

                if not blocked then
                    for index, layer in feedback.layers or {} do
                        Audio.Play(layer.sound, layer.volume, layer.pitch, event_id, "ImpactLayer" .. index)
                    end
                end
            end
        end

    end))
    local function PlayStun()
        if character:GetAttribute("CombatState") ~= "Stunned" then
            return
        end

        local event_id = character:GetAttribute("StunEventId")
        if not event_id or event_id == "" then
            return
        end

        local reason = character:GetAttribute("StunReason")
        if reason == "Exhausted" then
            Audio.Play("Knockdown", 0.25, 0.7, event_id, "Stun")
        elseif reason == "GuardBreak" then
            Audio.Play("PunchImpact", 0.65, 0.6, event_id, "Stun")
        end
    end

    for _, field in {"CombatState", "StunReason", "StunEventId"} do
        table.insert(character_connections, FighterPresentation.Observe(character, field, PlayStun))
    end

    table.insert(character_connections, rollback_effects.Event:Connect(function(valid)
        if flash_event_id and not valid[flash_event_id] then
            if flash_tween then
                flash_tween:Cancel()
            end
            flash.FillTransparency = 1
            flash_event_id = nil
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
        if flash_tween then
            flash_tween:Cancel()
        end
        flash:Destroy()
    end
end

return Effects
