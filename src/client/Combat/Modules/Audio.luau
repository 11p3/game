local Audio = {}
local DEFAULT_REFERENCE_VOLUME = 0.5
local REFERENCE_VOLUMES = {PerfectDodge = 0.65}
local AUDIO_DEDUP_SECONDS = 8 -- Keep sound identities longer than rollback history to suppress correction repeats.
local ONE_SHOT_LIFETIME_SECONDS = 6 -- Fallback cleanup for one-shots whose Ended event never arrives.
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local sounds
local effect_sounds = {}
local played_audio = {}
local active_count_sound

function Audio.Play(name: string, volume: number, speed: number, event_id: string?, channel: string?)
    local template = sounds:FindFirstChild(name)

    if not template or not template:IsA("Sound") then
        return
    end

    local now = os.clock()

    for key, expires in played_audio do
        if expires <= now then
            played_audio[key] = nil
        end
    end

    if event_id then
        -- Ignore corrected outcome suffixes so one contact cannot stack another sound.
        local event_key = string.match(event_id, "^([^:]+:[^:]+:[^:]+:[^:]+)") or event_id
        local key = (channel or name) .. ":" .. event_key

        if played_audio[key] then
            return
        end
        played_audio[key] = now + AUDIO_DEDUP_SECONDS
    end

    local sound = template:Clone()

    sound.Volume = template.Volume * volume / (REFERENCE_VOLUMES[name] or DEFAULT_REFERENCE_VOLUME)
    sound.PlaybackSpeed = template.PlaybackSpeed * speed
    sound.Looped = false
    sound.Parent = SoundService
    effect_sounds[sound] = true
    sound.Destroying:Once(function() effect_sounds[sound] = nil end)
    sound.Ended:Once(function() sound:Destroy() end)

    sound:Play()
    Debris:AddItem(sound, ONE_SHOT_LIFETIME_SECONDS)

    return sound
end

function Audio.Initialize()
    local shared = game:GetService("ReplicatedStorage"):WaitForChild("Combat")
    local folder = script.Parent.Parent
    local arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    local combat_effects = folder:WaitForChild("CombatEffects")
    local rollback_effects = folder:WaitForChild("RollbackEffects")
    sounds = shared:WaitForChild("Sounds")

    task.spawn(function()
        local assets = {}
        for _, sound in sounds:GetChildren() do
            if sound:IsA("Sound") and sound.SoundId ~= "" then
                table.insert(assets, sound)
            end
        end
        game:GetService("ContentProvider"):PreloadAsync(assets)
    end)

    local previous_match_phase
    local last_count_played = 0

    local function UpdateCount()
        local phase = arena:GetAttribute("MatchState")

        if phase ~= previous_match_phase then
            if phase == "Knockdown" then
                last_count_played = 0
            end

            if phase == "Fighting" or phase == "Finished" then
                if active_count_sound then
                    active_count_sound:Stop()
                    active_count_sound = nil
                end
            end

            previous_match_phase = phase
        end
        if phase == "Knockdown" then
            local count = arena:GetAttribute("Count") or 0
            if count > 0 and count ~= last_count_played then
                last_count_played = count
                if active_count_sound then
                    active_count_sound:Stop()
                end
            end
        end
    end

    arena:GetAttributeChangedSignal("MatchState"):Connect(UpdateCount)
    arena:GetAttributeChangedSignal("Count"):Connect(UpdateCount)
    UpdateCount()

    rollback_effects.Event:Connect(function(valid)
        if next(valid) == nil then
            for sound in effect_sounds do
                sound:Stop(); sound:Destroy()
            end
            table.clear(played_audio)
        end
    end)

    combat_effects.Event:Connect(function(event)
        if event.kind == "Count" then
            if active_count_sound then
                active_count_sound:Stop()
            end
            active_count_sound = Audio.Play("CountTick", 0.5, 1, event.key)
        elseif (event.kind == "GetUp" and not event.silent) or event.kind == "Finished" or event.kind == "Start" then
            if active_count_sound then
                active_count_sound:Stop()
            end
            Audio.Play("Bell", 0.55, 1, event.key)
        elseif event.kind == "Knockdown" then
            Audio.Play("Knockdown", 0.65, 1, event.key)
        end
    end)
end

return Audio
