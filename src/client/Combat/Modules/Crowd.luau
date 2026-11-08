local Crowd = {}
local AMBIENCE_PEAK_MULTIPLIER = 2.2 -- Cap reactive peaks relative to the authored ambience volume.
local CHEER_REFERENCE_VOLUME = 0.4
local AMBIENCE_RISE_SECONDS = 0.12
local AMBIENCE_SETTLE_SECONDS = 1.2 -- Let the crowd settle more slowly than it rises.

function Crowd.Initialize()
    local SoundService = game:GetService("SoundService")
    local TweenService = game:GetService("TweenService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local cheer_template = ReplicatedStorage:WaitForChild("Combat"):WaitForChild("Sounds"):WaitForChild("CrowdCheer")
    local cheer_sound = cheer_template:Clone()

    cheer_sound.Parent = SoundService

    local cheer_layer = cheer_sound:Clone()

    cheer_layer.Name = "CrowdCheerLayer"
    cheer_layer.Parent = SoundService

    local ambience_template = ReplicatedStorage.Combat.Sounds:WaitForChild("CrowdAmbience")
    local ambience = ambience_template:Clone()
    ambience.Name = "CrowdAmbience"
    ambience.Looped = true
    ambience.Volume = 0
    ambience.PlaybackSpeed = 1
    ambience.Parent = SoundService
    local ambience_tween
    local ambience_version = 0
    local ambience_audible = false

    local cheer_voices = {cheer_sound, cheer_layer}
    local cheer_levels = {}
    local next_voice = 1
    local next_crowd_sound = 0
    local last_crowd_sound = -math.huge
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")

    local player = Players.LocalPlayer
    local combat = workspace:WaitForChild("Combat")
    local arena = combat:WaitForChild("Arena")
    local crowd = combat:WaitForChild("Stadium"):WaitForChild("Crowd")

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

    local random = Random.new()
    local spectators = {}
    local camera_shake = script.Parent.Parent:WaitForChild("CameraShake")
    local combat_effects = script.Parent.Parent:WaitForChild("CombatEffects")
    local rollback_effects = script.Parent.Parent:WaitForChild("RollbackEffects")
    local watched_fighters = {}

    local function UpdateAmbience(boost)
        local phase = arena:GetAttribute("MatchState")
        local arena_map = (script.Parent.Parent:GetAttribute("MapId") or "Arena") == "Arena"
        ambience_audible = arena_map and (phase == "Fighting" or phase == "Knockdown")
        ambience_version += 1
        local version = ambience_version

        if ambience_tween then ambience_tween:Cancel() end
        if not ambience_audible then
            ambience:Stop()
            ambience.Volume = 0
            if not arena_map then
                for _, voice in cheer_voices do voice:Stop() end
            end
            return
        end

        if not ambience.IsPlaying then ambience:Play() end
        local volume = ambience_template.Volume
        ambience_tween = TweenService:Create(ambience, TweenInfo.new(if boost then AMBIENCE_RISE_SECONDS else AMBIENCE_SETTLE_SECONDS), {Volume = volume * (if boost then AMBIENCE_PEAK_MULTIPLIER else 1)})
        if boost then
            ambience_tween.Completed:Once(function(playback_state)
                if playback_state == Enum.PlaybackState.Completed and ambience_audible and version == ambience_version then
                    UpdateAmbience(false)
                end
            end)
        end
        ambience_tween:Play()
    end

    arena:GetAttributeChangedSignal("MatchState"):Connect(function() UpdateAmbience(false) end)
    script.Parent.Parent:GetAttributeChangedSignal("MapId"):Connect(function() UpdateAmbience(false) end)
    ambience_template:GetPropertyChangedSignal("Volume"):Connect(function() UpdateAmbience(false) end)
    cheer_template:GetPropertyChangedSignal("Volume"):Connect(function()
        for _, voice in cheer_voices do
            voice.Volume = (cheer_levels[voice] or 0) * cheer_template.Volume
        end
    end)
    UpdateAmbience(false)

    local function AddSpectator(model: Model)
        if spectators[model] then
            return
        end

        local humanoid = model:WaitForChild("Humanoid", 10)
        local root = model:WaitForChild("HumanoidRootPart", 10)

        if not humanoid or not root or model.Parent ~= crowd then
            return
        end

        local animator = humanoid:FindFirstChildOfClass("Animator")

        if animator then
            for _, track in animator:GetPlayingAnimationTracks() do
                track:Stop(0)
            end
        end

        spectators[model] = {root = root, base_cframe = root.CFrame, starts_at = 0, ends_at = 0, next_reaction = 0, started = false, height = 0, frequency = 1}
    end

    local function React(kind: string, event_id: string?)
        local now = os.clock()

        if (script.Parent.Parent:GetAttribute("MapId") or "Arena") ~= "Arena" then
            return
        end

        local big = kind == "Counter" or kind == "WallSplat" or kind == "Perfect" or kind == "Special" or kind == "Momentum" or kind == "Knockdown" or kind == "Finished"

        if big then UpdateAmbience(true) end

        if now >= next_crowd_sound or (big and now - last_crowd_sound >= 0.25) then
            local sound
            local volume = if kind == "Finished" then 1.35 elseif big then 1.1 elseif kind == "Block" then 0.4 else 0.75

            volume /= CHEER_REFERENCE_VOLUME

            for offset = 0, #cheer_voices - 1 do
                local index = (next_voice + offset - 1) % #cheer_voices + 1
                local candidate = cheer_voices[index]

                if not candidate.IsPlaying then
                    sound = candidate
                    next_voice = index % #cheer_voices + 1
                    break
                end
            end

            if sound then
                cheer_levels[sound] = volume
                sound.Volume = volume * cheer_template.Volume
                sound.PlaybackSpeed = random:NextNumber(0.94, 1.06)
                sound:SetAttribute("RollbackEvent", event_id)
                sound:Play()
            elseif big then
                for _, voice in cheer_voices do
                    cheer_levels[voice] = math.max(cheer_levels[voice] or 0, volume)
                    voice.Volume = cheer_levels[voice] * cheer_template.Volume
                end
            end
            camera_shake:Fire(if big then 0.16 else 0.08, if big then 0.4 else 0.22)
            last_crowd_sound = now
            next_crowd_sound = now + (if big then 0.65 else 0.4)
        end

        local duration = if kind == "Finished" then 4 elseif kind == "Knockdown" then 3 elseif kind == "Perfect" then 2.4 else 1.2
        local height = if kind == "Finished" then 0.9 elseif big then 0.65 else 0.4

        for _, record in spectators do
            if now >= record.next_reaction and random:NextNumber() < (if big then 1 else 0.8) then
                if now >= record.ends_at then
                    record.starts_at = now + random:NextNumber(0, 0.15)
                    record.height = height * random:NextNumber(0.7, 1)
                    record.frequency = random:NextNumber(1.2, 1.8)
                    record.started = false
                else
                    record.height = math.max(record.height, height * 0.8)
                end

                record.event_id = event_id
                record.ends_at = now + duration
                record.next_reaction = now + (if big then 0.5 else 0.3)
            end
        end
    end

    local function WatchFighter(character: Model)
        if watched_fighters[character] then
            return
        end

        local connection = character:GetAttributeChangedSignal("HitSerial"):Connect(function()
            if arena:GetAttribute("MatchState") ~= "Fighting" then
                return
            end

            if character:GetAttribute("LastHitPerfect") then
                React("Perfect", character:GetAttribute("LastHitPresentationEventId"))
            elseif character:GetAttribute("LastHitWallSplat") then
                React("WallSplat", character:GetAttribute("LastHitPresentationEventId"))
            elseif character:GetAttribute("LastHitSpecial") and not character:GetAttribute("LastHitBlocked") and not character:GetAttribute("LastHitDodged") then
                React("Special", character:GetAttribute("LastHitPresentationEventId"))
            elseif character:GetAttribute("LastHitCounter") and not character:GetAttribute("LastHitBlocked") and not character:GetAttribute("LastHitDodged") then
                React("Counter", character:GetAttribute("LastHitPresentationEventId"))
            elseif character:GetAttribute("LastHitMomentum") then
                React("Momentum", character:GetAttribute("LastHitPresentationEventId"))
            elseif character:GetAttribute("LastHitDodged") then
                React("Dodge", character:GetAttribute("LastHitPresentationEventId"))
            elseif character:GetAttribute("LastHitBlocked") then
                React("Block", character:GetAttribute("LastHitPresentationEventId"))
            else
                React("Hit", character:GetAttribute("LastHitPresentationEventId"))
            end
        end)

        watched_fighters[character] = connection
        character.Destroying:Once(function()
            connection:Disconnect()
            watched_fighters[character] = nil
        end)
    end

    crowd.ChildAdded:Connect(function(model)
        if model:IsA("Model") then
            task.spawn(AddSpectator, model)
        end
    end)

    crowd.ChildRemoved:Connect(function(model)
        local record = spectators[model]

        if record then
            spectators[model] = nil
        end
    end)

    for _, model in crowd:GetChildren() do
        if model:IsA("Model") then
            task.spawn(AddSpectator, model)
        end
    end

    local watched_opponent

    local function WatchOpponent()
        if watched_opponent and watched_opponent ~= player.Character then
            local connection = watched_fighters[watched_opponent]

            if connection then
                connection:Disconnect() watched_fighters[watched_opponent] = nil
            end
        end

        watched_opponent = FindOpponent()

        if watched_opponent then
            WatchFighter(watched_opponent)
        end
    end

    local arenas = combat:WaitForChild("Arenas")

    arenas.DescendantAdded:Connect(function(model)
        if model.Name == "NPC" and model.Parent and model.Parent.Name == script.Parent.Parent:GetAttribute("ArenaId") then
            WatchOpponent()
        end
    end)

    arenas.DescendantRemoving:Connect(function(model)
        if model == watched_opponent then
            local connection = watched_fighters[model]
            if connection then
                connection:Disconnect() watched_fighters[model] = nil
            end
            watched_opponent = nil
        end
    end)

    script.Parent.Parent:GetAttributeChangedSignal("ArenaId"):Connect(WatchOpponent)
    script.Parent.Parent:GetAttributeChangedSignal("OpponentUserId"):Connect(WatchOpponent)
    WatchOpponent()
    player.CharacterAdded:Connect(WatchFighter)

    if player.Character then
        WatchFighter(player.Character)
    end

    combat_effects.Event:Connect(function(event)
        if event.kind == "Knockdown" or event.kind == "Finished" then
            React(event.kind, event.key)
        end
    end)

    rollback_effects.Event:Connect(function(valid)
        if next(valid) == nil then
            for _, sound in cheer_voices do
                sound:Stop()
            end
            UpdateAmbience(false)
            next_voice = 1
            next_crowd_sound = 0
            last_crowd_sound = -math.huge
        end

        for _, record in spectators do
            if record.event_id and not valid[record.event_id] then
                record.ends_at = 0
                record.started = false
                record.root.CFrame = record.base_cframe
            end
        end
    end)

    RunService.RenderStepped:Connect(function()
        local now = os.clock()
        for model, record in spectators do
            if not model.Parent then
                continue
            end

            if now >= record.starts_at and now < record.ends_at then
                if not record.started then
                    record.started = true
                end

                local age = now - record.starts_at
                local fade = math.min(1, age / 0.15, (record.ends_at - now) / 0.25)
                local bounce = math.sin(age * math.pi * record.frequency) ^ 2 * record.height * fade

                record.root.CFrame = record.base_cframe + Vector3.new(0, bounce, 0)
            elseif record.started then
                record.root.CFrame = record.base_cframe
                record.started = false
            end
        end
    end)
end

return Crowd
