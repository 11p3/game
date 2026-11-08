local FighterPresentation = require(game.ReplicatedStorage.Combat.Modules.FighterPresentation)
local Animations = {}
local SIMULATION_HZ = 60
local TRACK_END_EPSILON = 0.001
local TRACK_WEIGHT_EPSILON = 0.001
local CONTACT_SEEK_TOLERANCE = 0.012
local RESUME_SEEK_TOLERANCE = 0.12
local RunService = game:GetService("RunService")
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Combat")
local MoveDefinitions = require(shared.Modules.MoveDefinitions)
local CombatSimulation = require(shared.Modules.CombatSimulation)
local Audio = require(script.Parent.Audio)
local Cinematics = require(script.Parent.Cinematics)
local animations = shared:WaitForChild("Animations")
local universal_animations = animations:WaitForChild("Universal")
local UNIVERSAL_ACTIONS = {
    Knockdown = true,
    KnockedOut = true,
    GetUp = true,
    Stun = true,
    ClinchGrab = true,
    ClinchHold = true,
    ClinchHeld = true,
    ClinchEscape = true,
    ClinchRelease = true,
    TakedownReaction = true
}
local PERFECT_HOLD = Cinematics.PERFECT_HOLD
local KNOCKDOWN_BLEND = 0.12
local FALL_LOAD_TIMEOUT = 1.5
local KNOCKED_OUT_LOAD_TIMEOUT = 1.5
local KNOCKED_OUT_RETRY_SECONDS = 0.5
local MAX_KNOCKED_OUT_RETRIES = 3
local DEFAULT_KNOCKED_OUT_ANIMATION_ID = "rbxassetid://114741358713606"
local ANIMATION_STALL_SECONDS = 0.15
local MIN_FOLLOWTHROUGH_SPEED = 0.2

local function GetContactTime(track)
    if not track or track.Animation:GetAttribute("TimingAssetId") ~= track.Animation.AnimationId then
        return nil
    end
    local contact = track.Animation:GetAttribute("ContactTime")
    if typeof(contact) ~= "number" or contact ~= contact or contact <= 0 or contact == math.huge then
        return nil
    end
    return if track.Length > 0 then math.min(contact, math.max(0.001, track.Length - TRACK_END_EPSILON)) else contact
end

local function GetKnockedOutTime(track)
    if not track then return 0 end
    if track.Length <= 0 then return FALL_LOAD_TIMEOUT end
    local earliest = math.max(0, track.Length - KNOCKDOWN_BLEND)
    local landing = track.Animation:GetAttribute("KnockdownMotionEnd")
    if track.Animation:GetAttribute("KnockdownMotionAssetId") == track.Animation.AnimationId and typeof(landing) == "number" and landing == landing and landing >= 0 and landing < math.huge then
        earliest = math.clamp(landing, 0, track.Length)
    end
    local time = track.Animation:GetAttribute("KnockedOutBlendAt")
    if track.Animation:GetAttribute("TransitionAssetId") == track.Animation.AnimationId and typeof(time) == "number" and time == time and time >= 0 and time < math.huge then
        return math.clamp(time, earliest, track.Length)
    end
    return earliest
end

function Animations.Initialize()
    task.spawn(function()
        local assets = {}
        for _, profile in animations:GetChildren() do
            for _, name in {"IdleAnimation", "GuardAnimation"} do
                local animation = profile:FindFirstChild(name)
                if animation and animation:IsA("Animation") and animation.AnimationId ~= "" then
                    table.insert(assets, animation)
                end
            end
        end
        for _, name in {"KnockdownAnimation", "KnockedOutAnimation", "GetUpAnimation", "StunAnimation"} do
            local animation = universal_animations:FindFirstChild(name)
            if animation and animation.AnimationId ~= "" then
                table.insert(assets, animation)
            end
        end
        game:GetService("ContentProvider"):PreloadAsync(assets)
    end)
end

local function LoadTracks(fighter_id, animator)
    local tracks, jab_tracks = {}, {}
    local profile = animations:FindFirstChild(fighter_id) or animations.Boxing

    local action_names = {
        "Idle",
        "Move",
        "Sidestep",
        "Guard",
        "Dodge",
        "Knockdown",
        "KnockedOut",
        "GetUp",
        "Stun",
        "ClinchHold",
        "ClinchHeld",
        "ClinchEscape",
        "ClinchRelease",
        "TakedownReaction"
    }
    local moves = (MoveDefinitions[fighter_id] or MoveDefinitions.Boxing).moves

    local victim_names = {}
    for _, definition in MoveDefinitions do
        if type(definition) ~= "table" or not definition.moves then
            continue
        end
        for _, move in definition.moves do
            local victim = move.pairing and move.pairing.victim
            if victim then
                victim_names[victim.animation] = true
            end
        end
    end

    for _, move in moves do
        if move.animation ~= "Jab" and not table.find(action_names, move.animation) then
            table.insert(action_names, move.animation)
        end
    end

    for _, name in action_names do
        local universal = UNIVERSAL_ACTIONS[name] == true
        local animation = if universal then universal_animations:FindFirstChild(name .. "Animation") else profile:FindFirstChild(name .. "Animation")

        if not universal and (not animation or animation.AnimationId == "") then
            animation = animations.Boxing:FindFirstChild(name .. "Animation")
        end

        if not animation or animation.AnimationId == "" then
            continue
        end

        local success, track = pcall(function()
            return animator:LoadAnimation(animation)
        end)

        if success then
            track.Priority = if name == "Idle" then Enum.AnimationPriority.Idle elseif name == "Move" then Enum.AnimationPriority.Movement else Enum.AnimationPriority.Action
            track.Looped = name == "KnockedOut" or name == "Guard" or name == "Idle" or name == "Move" or name == "Stun" or name == "ClinchHold" or name == "ClinchHeld"
            tracks[name] = track
        end
    end

    for name in victim_names do
        local animation = universal_animations:FindFirstChild(name .. "Animation")
        if not animation or not animation:IsA("Animation") or animation.AnimationId == "" then
            continue
        end
        local loaded, track = pcall(function()
            return animator:LoadAnimation(animation)
        end)
        if loaded then
            track.Priority = Enum.AnimationPriority.Action3
            track.Looped = false
            tracks["Victim:" .. name] = track
        end
    end

    local jab_folder = profile:FindFirstChild("JabAnimations") or animations.Boxing:FindFirstChild("JabAnimations")

    if jab_folder and jab_folder ~= animations.Boxing.JabAnimations then
        local configured = false

        for _, clip in jab_folder:GetChildren() do
            if clip:IsA("Animation") and clip.AnimationId ~= "" then
                configured = true break
            end
        end

        if not configured then
            jab_folder = animations.Boxing.JabAnimations
        end
    end

    if jab_folder then
        local clips = jab_folder:GetChildren()

        table.sort(clips, function(left, right)
            return left.Name < right.Name
        end)

        for _, animation in clips do
            if not animation:IsA("Animation") or animation.AnimationId == "" then
                continue
            end

            local success, track = pcall(function()
                return animator:LoadAnimation(animation)
            end)

            if success then
                track.Priority = Enum.AnimationPriority.Action
                track.Looped = false
                tracks["Jab:" .. animation.Name] = track
                table.insert(jab_tracks, track)
            end
        end
    end

    return tracks, jab_tracks
end

local function PlayKnockedOut(binding)
    if not binding.downed.knocked_out_started then
        binding.downed.knocked_out_started = true
        binding.downed.knocked_out_pair_key = binding.pair.paired_key or binding.pair.finished_pair_key
        binding.pair.finished_pair_key = binding.downed.knocked_out_pair_key
        if binding.pair.paired_track then binding.pair.paired_track:Stop(KNOCKDOWN_BLEND) end
        binding.pair.paired_key = nil
        binding.downed.knocked_out_load_age = KNOCKED_OUT_RETRY_SECONDS
    end

    local track = binding.tracks.KnockedOut
    if track and track.Length > 0 then
        if not track.IsPlaying then
            track.Priority = Enum.AnimationPriority.Action3
            track.Looped = true
            track:Play(KNOCKDOWN_BLEND, 1, Cinematics.TimeScale)
        end
        return
    end
    if track then
        if not track.IsPlaying then track:Play(KNOCKDOWN_BLEND, 1, Cinematics.TimeScale) end
        if binding.downed.knocked_out_load_age < KNOCKED_OUT_LOAD_TIMEOUT then return end
        track:Stop(KNOCKDOWN_BLEND)
        track:Destroy()
        binding.tracks.KnockedOut = nil
    end
    if binding.downed.knocked_out_retries >= MAX_KNOCKED_OUT_RETRIES or binding.downed.knocked_out_load_age < KNOCKED_OUT_RETRY_SECONDS then return end

    binding.downed.knocked_out_retries += 1
    binding.downed.knocked_out_load_age = 0
    if not binding.downed.fallback_knocked_out then
        binding.downed.fallback_knocked_out = Instance.new("Animation")
        binding.downed.fallback_knocked_out.Name = "KnockedOutAnimation"
        binding.downed.fallback_knocked_out.AnimationId = DEFAULT_KNOCKED_OUT_ANIMATION_ID
    end
    local loaded, replacement = pcall(function() return binding.animator:LoadAnimation(binding.downed.fallback_knocked_out) end)
    if loaded then
        binding.tracks.KnockedOut = replacement
        replacement.Priority = Enum.AnimationPriority.Action3
        replacement.Looped = true
        replacement:Play(KNOCKDOWN_BLEND, 1, Cinematics.TimeScale)
    end
end

local function UpdateClinch(binding)
    local role = binding.character:GetAttribute("ClinchRole") or ""
    local escaping = binding.character:GetAttribute("ClinchEscapeUntil") or 0
    local fighting = binding.arena:GetAttribute("MatchState") == "Fighting"

    local clinch_profile = animations:FindFirstChild(binding.character:GetAttribute("ClinchFighterId") or "")

    for name, wanted in {ClinchHold = "Control", ClinchHeld = "Held"} do
        local track

        if fighting and role == wanted and not (binding.pair.paired_track and binding.pair.paired_track.IsPlaying) then
            track = binding.tracks[name]
            local animation = if name == "ClinchHold" and clinch_profile then clinch_profile:FindFirstChild("ClinchHoldAnimation") else nil

            if animation and animation:IsA("Animation") and animation.AnimationId ~= "" then
                local key = name .. ":" .. clinch_profile.Name .. ":" .. animation.AnimationId
                local custom = binding.tracks[key]

                if not custom then
                    local loaded, result = pcall(function() return binding.animator:LoadAnimation(animation) end)

                    if loaded then
                        custom = result
                        custom.Priority = Enum.AnimationPriority.Action
                        custom.Looped = true
                        binding.tracks[key] = custom
                    end
                end

                track = custom or track
            end
        end

        local previous = binding.clinch.clinch_tracks[name]
        if previous and previous ~= track and previous.IsPlaying then
            previous:Stop(0.08)
        end
        binding.clinch.clinch_tracks[name] = track
        if track and not track.IsPlaying then
            track:Play(0.08)
        end
    end

    if binding.tracks.ClinchEscape then
        if fighting and role == "Held" and escaping > 0 and escaping ~= binding.clinch.last_escape then
            binding.tracks.ClinchEscape.Priority = Enum.AnimationPriority.Action2
            binding.tracks.ClinchEscape:Play(0.04)
        elseif not fighting or role ~= "Held" or escaping == 0 then
            binding.tracks.ClinchEscape:Stop(0.08)
        end
    end

    if role ~= "" and binding.tracks.ClinchRelease and binding.tracks.ClinchRelease.IsPlaying then
        binding.tracks.ClinchRelease:Stop(0.06)
    end

    binding.clinch.last_escape = escaping
end

local function UpdatePaired(binding)
    local key = binding.character:GetAttribute("PairedAnimationEventId") or ""
    if key ~= "" and key == binding.pair.finished_pair_key then return end
    if binding.downed.knocked_out_started then
        if key == "" or key == binding.downed.knocked_out_pair_key then return end
        binding.downed.knocked_out_started = false
        if binding.tracks.KnockedOut then binding.tracks.KnockedOut:Stop(KNOCKDOWN_BLEND) end
    end
    local name = binding.character:GetAttribute("PairedAnimation") or ""
    local age = binding.character:GetAttribute("PairedAnimationAgeFrames") or -1

    if key == "" or name == "" then
        binding.pair.finished_pair_key = nil
        if binding.pair.paired_key and binding.pair.paired_track then
            binding.pair.paired_track:Stop(0.1)
        end
        binding.pair.paired_key = nil
        UpdateClinch(binding)
        return
    end

    if key == binding.pair.paired_key then
        return
    end

    binding.pair.finished_pair_key = nil
    binding.clock.paired_load_age = 0
    binding.clock.paired_stall_age = 0
    binding.clock.last_paired_age = -1
    if binding.pair.paired_track then
        binding.pair.paired_track:Stop(0.04)
    end
    binding.pair.paired_track = binding.tracks["Victim:" .. name]
    binding.playback.paired_track = binding.pair.paired_track
    binding.pair.paired_key = if binding.pair.paired_track then key else nil

    if binding.pair.paired_track then
        binding.pair.paired_track.Priority = Enum.AnimationPriority.Action3
        binding.pair.paired_track:Play(0.025, 1, Cinematics.TimeScale)
        if binding.pair.paired_track.Length > 0 then
            binding.pair.paired_track.TimePosition = math.clamp(age / SIMULATION_HZ, 0, binding.pair.paired_track.Length - TRACK_END_EPSILON)
        end
    end

    UpdateClinch(binding)
end

local function PlayPunchRelease(binding)
    if not binding.action.jab_sound_pending then
        return
    end

    local state = binding.character:GetAttribute("CombatState")
    local age = binding.character:GetAttribute("AttackAgeFrames") or -1

    if state ~= "AttackStartup" and state ~= "AttackActive" and state ~= "AttackRecovery" then
        binding.action.jab_sound_pending = false

        return
    end

    if age >= binding.action.active_jab_startup then
        binding.action.jab_sound_pending = false

        if age <= binding.action.active_jab_startup + (binding.character:GetAttribute("AttackActiveFrames") or CombatSimulation.JabActiveFrames) + 6 then
            local move = MoveDefinitions.Get(binding.character:GetAttribute("FighterId") or "Boxing", binding.playback.active_kind)
            local release = move and move.feedback.Release
            if release then
                Audio.Play(release.sound, release.volume, release.pitch, binding.action.jab_sound_event)
            end
        end
    end
end

local function PlayJab(binding, sequence: number, resuming: boolean?)
    local event_id = binding.character:GetAttribute("AttackEventId")
    if event_id and event_id == binding.action.active_jab_event then
        return
    end

    local kind = binding.character:GetAttribute("AttackKind") or "Jab"
    local move = MoveDefinitions.Get(binding.character:GetAttribute("FighterId") or "Boxing", kind)
    local track = move and (binding.tracks[move.animation] or binding.tracks[move.animation_fallback])

    if not track and move and (move.animation == "Jab" or move.animation_fallback == "Jab") and #binding.jab_tracks > 0 then
        track = binding.jab_tracks[(sequence - 1) % #binding.jab_tracks + 1]
    end

    if binding.playback.active_track then
        binding.playback.active_track:Stop(0.03)
    end

    if binding.tracks.ClinchRelease then
        binding.tracks.ClinchRelease:Stop(0.04)
    end
    binding.playback.active_track = track
    binding.playback.active_kind = kind
    binding.action.active_jab_mode = if move and not binding.tracks[move.animation] then move.fallback_animation_mode or move.animation_mode elseif move then move.animation_mode else "Natural"
    binding.action.active_jab_event = event_id
    binding.action.resume_attack = resuming == true

    if not binding.playback.active_track then
        return
    end
    binding.playback.active_track.Priority = if move and (move.grab or move.clinch_only) then Enum.AnimationPriority.Action2 else Enum.AnimationPriority.Action
    binding.action.active_jab_startup = binding.character:GetAttribute("JabStartupFrames") or CombatSimulation.OpeningStartup
    local contact = GetContactTime(track)
    local timed_action = binding.action.active_jab_mode == "Natural" and contact and move and not move.victim_animation
    binding.action.active_action_start = if timed_action and not move.lunge then math.max(0, binding.action.active_jab_startup / SIMULATION_HZ - contact) else 0
    binding.playback.waiting_action = (timed_action and not move.lunge and binding.action.active_action_start > 0) or (not contact and move ~= nil and move.clinch_only == true and move.takedown == true and not move.victim_animation)
    if not binding.playback.waiting_action then
        binding.playback.active_track:Play(0.025, 1, if move and (binding.action.active_jab_mode == "Phased" or binding.action.active_jab_mode == "Feint") then 0 else Cinematics.TimeScale)
        if move and move.victim_animation and binding.playback.active_track.Length > 0 then
            binding.playback.active_track.TimePosition = math.clamp((binding.character:GetAttribute("PairedAnimationAgeFrames") or 0) / SIMULATION_HZ, 0, binding.playback.active_track.Length - TRACK_END_EPSILON)
        end
    end
    binding.action.jab_sound_pending = not (move and move.feint) and (not resuming or (binding.character:GetAttribute("AttackAgeFrames") or 0) < binding.action.active_jab_startup)
    binding.action.jab_sound_event = event_id
    PlayPunchRelease(binding)

    if move and (binding.action.active_jab_mode == "Phased" or binding.action.active_jab_mode == "Feint") and binding.playback.active_track.Length > 0 then
        binding.playback.active_track:AdjustSpeed((GetContactTime(binding.playback.active_track) or binding.playback.active_track.Length * 0.4) / (binding.action.active_jab_startup / SIMULATION_HZ) * Cinematics.TimeScale)
    end
end

local function UpdateStun(binding)
    local track = binding.tracks.Stun
    if not track then
        return
    end

    local state = binding.character:GetAttribute("CombatState")
    local reason = binding.character:GetAttribute("StunReason")
    local exhausted = state == "Stunned" and reason == "Exhausted"
    local followthrough = reason == "PerfectDodge" and os.clock() < binding.action.perfect_action_until and binding.action.perfect_action_track and binding.action.perfect_action_track.IsPlaying
    local reaction = FighterPresentation.Reaction(state, reason, binding.pair.paired_key ~= nil and binding.pair.paired_track ~= nil)
    local stunned = reaction == "Stun" and not followthrough

    if exhausted then
        binding.playback.waiting_action = false
        if binding.playback.active_track and binding.playback.active_track.IsPlaying then
            binding.playback.active_track:Stop(0.05)
        end
        if binding.pair.paired_track and binding.pair.paired_track.IsPlaying then
            binding.pair.paired_track:Stop(0.05)
        end
        binding.pair.paired_key = nil
        if binding.tracks.TakedownReaction and binding.tracks.TakedownReaction.IsPlaying then
            binding.tracks.TakedownReaction:Stop(0.05)
        end
        if binding.tracks.KnockedOut and binding.tracks.KnockedOut.IsPlaying then
            binding.tracks.KnockedOut:Stop(0.05)
        end
        binding.downed.knocked_out_started = false
    end

    if stunned and not track.IsPlaying then
        track:Play(0.03)
    elseif not stunned and track.IsPlaying then
        track:Stop(0.1)
    end
end

local function UpdateDowned(binding, delta_time, logical_paired_age)
    if binding.pair.paired_key and binding.pair.paired_track then
        binding.clock.paired_load_age += delta_time
        local length = binding.pair.paired_track.Length
        local elapsed = logical_paired_age / SIMULATION_HZ
        local ended = length > 0 and (elapsed >= length - TRACK_END_EPSILON or (not binding.pair.paired_track.IsPlaying and binding.pair.paired_track.TimePosition >= length - TRACK_END_EPSILON))
        local unavailable = length <= 0 and binding.clock.paired_load_age >= FALL_LOAD_TIMEOUT
        if ended or unavailable then
            binding.pair.finished_pair_key = binding.pair.paired_key
            local state = binding.character:GetAttribute("CombatState")
            if binding.downed.knockdown_active or (state == "Stunned" and binding.character:GetAttribute("StunReason") == "Takedown") then
                PlayKnockedOut(binding)
            else
                binding.pair.paired_track:Stop(KNOCKDOWN_BLEND)
                binding.pair.paired_key = nil
                UpdateClinch(binding)
            end
        end
    end

    if binding.pair.paired_track and not binding.pair.paired_track.IsPlaying and binding.pair.paired_track.WeightCurrent < TRACK_WEIGHT_EPSILON and binding.playback.paired_track then
        binding.playback.paired_track = nil
        UpdateClinch(binding)
    end

    if binding.downed.knockdown_active then
        binding.downed.knockdown_age += delta_time * Cinematics.TimeScale
        binding.downed.fall_load_age += delta_time
        local paired_visual = binding.pair.paired_key or (binding.pair.paired_track and (binding.pair.paired_track.IsPlaying or binding.pair.paired_track.WeightCurrent > TRACK_WEIGHT_EPSILON))
        local down = binding.tracks.Knockdown
        local age = if down and down.Length <= 0 then math.max(binding.downed.fall_load_age, binding.downed.knockdown_age) else binding.downed.knockdown_age
        if binding.downed.knocked_out_started or (not paired_visual and age >= GetKnockedOutTime(down)) then
            PlayKnockedOut(binding)
        elseif not paired_visual and down and not down.IsPlaying and (down.Length <= 0 or binding.downed.knockdown_age < down.Length) then
            down:Play(0.03, 1, Cinematics.TimeScale)
            if down.Length > 0 then down.TimePosition = math.clamp(binding.downed.knockdown_age, 0, down.Length - TRACK_END_EPSILON) end
        end
    elseif binding.downed.knocked_out_started and binding.character:GetAttribute("CombatState") == "Stunned" and binding.character:GetAttribute("StunReason") == "Takedown" then
        PlayKnockedOut(binding)
    end

end

local function UpdatePlayback(binding, now, movement_speed, logical_paired_age, seek_attack)
    for name, track in binding.tracks do
        if track.IsPlaying then
            local base_speed = if name == "Move" then (if movement_speed <= 0.1 then 0 elseif binding.playback.move_direction < 0 then -1 else 1) else 1

            local move = MoveDefinitions.Get(binding.character:GetAttribute("FighterId") or "Boxing", binding.playback.active_kind)


            if track == binding.pair.paired_track then
                local age = logical_paired_age / SIMULATION_HZ
                if binding.pair.paired_key and binding.clock.paired_stall_age < ANIMATION_STALL_SECONDS and age >= 0 and track.Length > 0 and age < track.Length - TRACK_END_EPSILON and math.abs(track.TimePosition - age) > RESUME_SEEK_TOLERANCE then
                    track.TimePosition = age
                end
            elseif track == binding.playback.active_track and move and move.victim_animation and track.Length > 0 then
                local age = (binding.character:GetAttribute("PairedAnimationAgeFrames") or -1) / SIMULATION_HZ
                if binding.clock.paired_stall_age < ANIMATION_STALL_SECONDS and age >= 0 and age < track.Length - TRACK_END_EPSILON and math.abs(track.TimePosition - age) > RESUME_SEEK_TOLERANCE then
                    track.TimePosition = math.clamp(age, 0, track.Length - TRACK_END_EPSILON)
                end
            end

            if track == binding.playback.active_track and track.Length > 0 and move and binding.action.active_jab_mode == "Natural" and not move.victim_animation and binding.clock.attack_stall_age < ANIMATION_STALL_SECONDS and now >= binding.action.perfect_action_until then
                local contact = GetContactTime(track)
                local age = (binding.character:GetAttribute("AttackAgeFrames") or -1) / SIMULATION_HZ
                if contact and age >= 0 then
                    local windup = binding.action.active_jab_startup / SIMULATION_HZ
                    local position
                    if move.lunge then
                        if age < windup then
                            position, base_speed = contact * age / windup, contact / windup
                        else
                            position, base_speed = contact + age - windup, 1
                        end
                    elseif age < windup then
                        base_speed = contact / math.max(0.001, windup - binding.action.active_action_start)
                        position = math.max(0, age - binding.action.active_action_start) * base_speed
                    else
                        position, base_speed = contact + age - windup, 1
                    end
                    position = math.clamp(position, 0, track.Length - TRACK_END_EPSILON)
                    if seek_attack or math.abs(track.TimePosition - position) > CONTACT_SEEK_TOLERANCE then
                        track.TimePosition = position
                    end
                end
            end

            if track == binding.playback.active_track and track.Length > 0 and move and (binding.action.active_jab_mode == "Phased" or binding.action.active_jab_mode == "Feint") then
                local state = binding.character:GetAttribute("CombatState")

                if binding.clock.attack_stall_age < ANIMATION_STALL_SECONDS and now >= binding.action.perfect_action_until and (state == "AttackStartup" or state == "AttackActive" or state == "AttackRecovery") then
                    local age = (binding.character:GetAttribute("AttackAgeFrames") or 0) / SIMULATION_HZ
                    local windup = binding.action.active_jab_startup / SIMULATION_HZ
                    local release = (binding.character:GetAttribute("AttackActiveFrames") or CombatSimulation.JabActiveFrames) / SIMULATION_HZ
                    local recovery = math.clamp((binding.character:GetAttribute("AttackRecoveryFrames") or 18) / SIMULATION_HZ, 0.08, 0.32)
                    local contact = GetContactTime(track) or track.Length * 0.4
                    local release_end = math.min(track.Length - TRACK_END_EPSILON, contact + math.min(1 / 30, math.max(0, track.Length - contact) * 0.5))
                    local position

                    if age < windup then
                        position = contact * age / windup
                        base_speed = contact / windup
                    elseif binding.action.active_jab_mode == "Feint" then
                        local returning = math.clamp((age - windup) / recovery, 0, 1)
                        position = release_end + (track.Length - release_end) * returning
                        base_speed = if returning < 1 then (track.Length - release_end) / recovery else 1
                    elseif age < windup + release then
                        position = contact + (release_end - contact) * (age - windup) / release
                        base_speed = (release_end - contact) / release
                    else
                        local returning = math.clamp((age - windup - release) / recovery, 0, 1)

                        position = release_end + (track.Length - release_end) * returning
                        base_speed = if returning < 1 then (track.Length - release_end) / recovery else 1
                    end

                    local target = math.clamp(position, 0, track.Length - TRACK_END_EPSILON)
                    local returning = math.clamp((age - windup - release) / recovery, 0, 1)
                    track:AdjustWeight(1 - returning * returning * (3 - 2 * returning), 0.025)

                    if seek_attack or math.abs(track.TimePosition - target) > 0.012 then
                        track.TimePosition = target
                    end
                end
            end

            if name == "GetUp" and binding.character:GetAttribute("CombatState") == "GettingUp" and track.Length > 0 and binding.clock.getup_stall_age < ANIMATION_STALL_SECONDS then
                local duration = math.max(0.1, (binding.character:GetAttribute("GetUpDurationFrames") or CombatSimulation.GetUpFrames) / SIMULATION_HZ - 0.05)
                local age = math.max(0, binding.character:GetAttribute("GetUpAgeFrames") or 0) / SIMULATION_HZ
                base_speed = track.Length / duration
                local position = math.clamp(age * base_speed, 0, track.Length - TRACK_END_EPSILON)
                if math.abs(track.TimePosition - position) > 0.04 then
                    track.TimePosition = position
                end
            end

            local cinematic = now < binding.action.perfect_action_until and track == binding.action.perfect_action_track
            local speed = if cinematic then binding.action.perfect_action_speed else base_speed * Cinematics.TimeScale

            if math.abs(track.Speed - speed) > 0.001 then
                track:AdjustSpeed(speed)
            end
        end
    end

end

local function UpdateLocomotion(binding, state, movement_speed)
    local mobile = binding.humanoid.Health > 0 and ((binding.arena:GetAttribute("MatchState") == "Fighting" and (state == "Idle" or state == "Guard" or state == "Blockstun")) or state == "Retreating")
    local moving = mobile and movement_speed > 0.1
    local track = binding.tracks.Move

    if track then
        if moving then
            if not track.IsPlaying then
                local reverse = binding.playback.move_direction < 0
                track:Play(0.1, 1, (if reverse then -1 else 1) * Cinematics.TimeScale)

                if reverse and track.Length > 0 then
                    track.TimePosition = math.max(0, track.Length - TRACK_END_EPSILON)
                end
            end
        elseif track.IsPlaying then
            track:AdjustSpeed(0)
            track:Stop(0.08)
        end
    end

    if binding.tracks.Idle and not binding.tracks.Idle.IsPlaying then
        binding.tracks.Idle:Play(0.08)
    end
end

local function UpdateAnimations(binding, delta_time)
    delta_time = math.clamp(delta_time or 0, 0, 0.1)
    local movement_speed = binding.character:GetAttribute("CombatMoveSpeed") or 0

    if movement_speed > 0.1 then
        binding.playback.move_direction = binding.character:GetAttribute("CombatMoveDirection") or 1
    end

    local logical_attack_age = binding.character:GetAttribute("AttackAgeFrames") or -1
    local logical_paired_age = binding.character:GetAttribute("PairedAnimationAgeFrames") or -1
    local logical_getup_age = binding.character:GetAttribute("GetUpAgeFrames") or -1
    binding.clock.attack_stall_age = if logical_attack_age >= 0 and logical_attack_age == binding.clock.last_attack_age then binding.clock.attack_stall_age + delta_time else 0
    binding.clock.paired_stall_age = if logical_paired_age >= 0 and logical_paired_age == binding.clock.last_paired_age then binding.clock.paired_stall_age + delta_time else 0
    binding.clock.getup_stall_age = if logical_getup_age >= 0 and logical_getup_age == binding.clock.last_getup_age then binding.clock.getup_stall_age + delta_time else 0
    binding.clock.last_attack_age, binding.clock.last_paired_age, binding.clock.last_getup_age = logical_attack_age, logical_paired_age, logical_getup_age
    if binding.downed.knocked_out_started then binding.downed.knocked_out_load_age += delta_time end

    local now = os.clock()
    local waiting_track = binding.playback.active_track
    local seek_attack = binding.action.resume_attack

    if binding.action.resume_attack and waiting_track and waiting_track.Length > 0 then
        if binding.action.active_jab_mode == "Natural" and not GetContactTime(waiting_track) and not binding.playback.waiting_action then
            local age = math.max(0, binding.character:GetAttribute("AttackAgeFrames") or 0) / SIMULATION_HZ
            if age < waiting_track.Length then waiting_track.TimePosition = age else waiting_track:Stop(0) end
        end
        binding.action.resume_attack = false
    end

    if binding.action.resume_dodge and binding.tracks.Dodge and binding.tracks.Dodge.Length > 0 then
        local age = math.max(0, binding.character:GetAttribute("DodgeAgeFrames") or 0) / SIMULATION_HZ
        if age < binding.tracks.Dodge.Length then binding.tracks.Dodge.TimePosition = age else binding.tracks.Dodge:Stop(0) end
        binding.action.resume_dodge = false
    end

    if waiting_track and binding.playback.waiting_action then
        local age = (binding.character:GetAttribute("AttackAgeFrames") or -1) / SIMULATION_HZ
        if binding.clock.attack_stall_age >= ANIMATION_STALL_SECONDS and age >= 0 then age += binding.clock.attack_stall_age end
        local contact = GetContactTime(waiting_track)
        local start_at = if contact then binding.action.active_action_start else math.max(0, binding.action.active_jab_startup / SIMULATION_HZ - waiting_track.Length)

        if waiting_track.Length > 0 and ((age >= 0 and age >= start_at) or (age < 0 and binding.character:GetAttribute("JabResult") == "Hit")) then
            binding.playback.waiting_action = false
            waiting_track:Play(0.015, 1, Cinematics.TimeScale)
            if contact then
                waiting_track.TimePosition = math.clamp(age - start_at, 0, waiting_track.Length - TRACK_END_EPSILON)
            end
        elseif age < 0 then
            binding.playback.waiting_action = false
        end
    end

    UpdateDowned(binding, delta_time, logical_paired_age)

    UpdatePlayback(binding, now, movement_speed, logical_paired_age, seek_attack)

    local state = binding.character:GetAttribute("CombatState")
    UpdateStun(binding)
    UpdateLocomotion(binding, state, movement_speed)
end

local function UpdateState(binding)
    local state = binding.character:GetAttribute("CombatState") or "Idle"
    local down = state == "Knockdown" or state == "Knockout" or (state == "BoutOver" and (binding.downed.knockdown_active or (binding.character:GetAttribute("CombatHealth") or 1) <= 0))
    if down and not binding.downed.knockdown_active then
        binding.downed.knockdown_age = math.max(0, binding.character:GetAttribute("KnockdownAgeFrames") or 0) / SIMULATION_HZ
        binding.downed.knocked_out_started = false
        binding.downed.fall_load_age = 0
        binding.downed.knocked_out_load_age, binding.downed.knocked_out_retries = 0, 0
    elseif not down then
        binding.downed.knocked_out_started = false
        if binding.tracks.KnockedOut and binding.tracks.KnockedOut.IsPlaying then
            binding.tracks.KnockedOut:Stop(0.08)
        end
    end
    if binding.tracks.Knockdown then
        if down and not binding.downed.knockdown_active and not binding.pair.paired_key and binding.downed.knockdown_age < GetKnockedOutTime(binding.tracks.Knockdown) then
            binding.tracks.Knockdown:Play(0.05, 1, Cinematics.TimeScale)
            if binding.tracks.Knockdown.Length > 0 then
                binding.tracks.Knockdown.TimePosition = math.clamp(binding.downed.knockdown_age, 0, binding.tracks.Knockdown.Length - TRACK_END_EPSILON)
            end
        elseif not down and binding.tracks.Knockdown.IsPlaying then
            binding.tracks.Knockdown:Stop(0.08)
        end
    end
    binding.downed.knockdown_active = down

    if binding.tracks.GetUp then
        if state == "GettingUp" and not binding.tracks.GetUp.IsPlaying then
            binding.tracks.GetUp:Play(0.05, 1, 1)
        elseif binding.action.previous_state == "GettingUp" and state ~= "GettingUp" and binding.tracks.GetUp.IsPlaying then
            binding.tracks.GetUp:Stop(0.08)
        end
    end

    local perfect_stun = state == "Stunned" and binding.character:GetAttribute("StunReason") == "PerfectDodge"

    local preserve_punch = perfect_stun and binding.playback.active_track and (binding.playback.active_track.IsPlaying or binding.playback.waiting_action)

    if preserve_punch then
        if binding.playback.waiting_action then
            binding.playback.waiting_action = false
            binding.playback.active_track:Play(0.025, 1, Cinematics.TimeScale)
        end
        binding.action.perfect_action_until = os.clock() + PERFECT_HOLD
        binding.action.perfect_action_track = binding.playback.active_track
        binding.action.perfect_action_speed = math.max(MIN_FOLLOWTHROUGH_SPEED, (binding.playback.active_track.Length - binding.playback.active_track.TimePosition) / PERFECT_HOLD)
        task.delay(PERFECT_HOLD, function()
            if binding.alive and binding.character.Parent and binding.character:GetAttribute("CombatState") == "Stunned" and binding.tracks.Stun then
                UpdateStun(binding)
            end
        end)
    end

    if binding.tracks.ClinchRelease then
        local move = MoveDefinitions.Get(binding.character:GetAttribute("FighterId") or "Boxing", binding.playback.active_kind)
        local finishing_grapple = binding.playback.active_track and (binding.playback.active_track.IsPlaying or binding.playback.waiting_action) and move and (move.shove or move.takedown) and binding.character:GetAttribute("JabResult") == "Hit"
        if state == "ClinchRelease" and not finishing_grapple then
            binding.playback.waiting_action = false
            if binding.playback.active_track then
                binding.playback.active_track:Stop(0.04)
            end
            binding.tracks.ClinchRelease.Priority = Enum.AnimationPriority.Action2
            binding.tracks.ClinchRelease:Play(0.05)
        elseif state == "Stunned" or state == "HitReact" or state == "Knockdown" or state == "Knockout" or state == "BoutOver" then
            binding.tracks.ClinchRelease:Stop(0.05)
        end
    end

    UpdateStun(binding)

    local guarding = state == "Guard" or state == "Blockstun"

    if binding.tracks.Guard then
        if guarding and not binding.tracks.Guard.IsPlaying then
            binding.tracks.Guard:Play(0.05)
        elseif not guarding and binding.tracks.Guard.IsPlaying then
            binding.tracks.Guard:Stop(0.05)
        end
    end

    if state == "GettingUp" or state == "Hitstun" or state == "Knockout" or state == "Knockdown" or state == "Waiting" or state == "BoutOver" or state == "Stunned" or state == "HitReact" or state == "Retreating" or state == "Sidestep" or state == "ClinchHeld" or state == "ClinchEscape" then
        if binding.tracks.Dodge then
            binding.tracks.Dodge:Stop(0.03)
        end

        if not preserve_punch then
            binding.playback.waiting_action = false
            if binding.playback.active_track then binding.playback.active_track:Stop(0.03) end
        end
    end

    if binding.tracks.TakedownReaction and (state == "Knockdown" or state == "Knockout" or state == "BoutOver") then
        binding.tracks.TakedownReaction:Stop(0.05)
    end

    if binding.action.previous_state:sub(1, 5) == "Dodge" and state:sub(1, 5) ~= "Dodge" and binding.tracks.Dodge then
        binding.tracks.Dodge:Stop(0.08)
    end

    binding.action.previous_state = state
end

local function Cleanup(binding)
    if not binding.alive then
        return
    end
    binding.alive = false
    for _, connection in binding.character_connections do
        connection:Disconnect()
    end
    for _, track in binding.tracks do
        track:Stop(0); track:Destroy()
    end
    binding.playback.active_track = nil
    if binding.downed.fallback_knocked_out then binding.downed.fallback_knocked_out:Destroy() end
end

local function OnAttack(binding)
    local sequence = binding.character:GetAttribute("JabSequence") or 0

    if sequence > 0 then
        PlayJab(binding, binding.character:GetAttribute("JabVariant") or sequence)
    end
end

local function OnGetUp(binding)
    if (binding.character:GetAttribute("GetUpSerial") or 0) <= 0 then
        return
    end

    binding.downed.knockdown_active = false
    binding.downed.knockdown_age = 0
    binding.downed.knocked_out_started = false
    binding.pair.finished_pair_key = nil
    binding.downed.fall_load_age = 0
    binding.downed.knocked_out_load_age, binding.downed.knocked_out_retries = 0, 0
    if binding.tracks.KnockedOut then
        binding.tracks.KnockedOut:Stop(0.08)
    end
    if binding.tracks.Knockdown then
        binding.tracks.Knockdown:Stop(0.1)
    end

    if binding.tracks.GetUp and not binding.tracks.GetUp.IsPlaying then
        binding.tracks.GetUp:Play(0.05)
    end
end

local function OnHit(binding)
    if binding.tracks.TakedownReaction and not binding.character:GetAttribute("LastHitDodged") and not binding.pair.paired_key then
        if binding.character:GetAttribute("LastHitTakedown") and binding.character:GetAttribute("CombatState") ~= "Knockdown" then
            binding.action.takedown_event = binding.character:GetAttribute("LastHitPresentationEventId")
            binding.tracks.TakedownReaction.Priority = Enum.AnimationPriority.Action2
            binding.tracks.TakedownReaction:Play(0.03)
        else
            binding.tracks.TakedownReaction:Stop(0.05)
            binding.action.takedown_event = nil
        end
    end

    if binding.character:GetAttribute("LastHitPerfect") then
        if binding.tracks.Dodge then
            binding.action.perfect_action_until = os.clock() + PERFECT_HOLD
            binding.action.perfect_action_track = binding.tracks.Dodge

            if not binding.tracks.Dodge.IsPlaying then
                binding.tracks.Dodge:Play(0.02)
            end

            binding.action.perfect_action_speed = math.max(MIN_FOLLOWTHROUGH_SPEED, (binding.tracks.Dodge.Length - binding.tracks.Dodge.TimePosition) / PERFECT_HOLD)
        end
    end
end

local function OnCombatEvent(binding, event)
    if event.fighter ~= (if binding.is_player then (script.Parent.Parent:GetAttribute("FighterSlot") or 2) else 3 - (script.Parent.Parent:GetAttribute("FighterSlot") or 2)) then return end

    if event.kind == "Dodge" then
        binding.action.dodge_event = event.key

        if binding.tracks.Dodge then
            binding.tracks.Dodge:Play(0.02)
        end
        Audio.Play("Whoosh", 0.3, 1.5, event.key)
    elseif event.kind == "Sidestep" then
        if binding.tracks.Sidestep then
            binding.tracks.Sidestep:Play(0.03)
        end
        Audio.Play("Whoosh", 0.4, 0.9, event.key)
    end
end

local function CorrectAnimations(binding, valid)
    if next(valid) == nil then
        binding.playback.active_track = nil
        binding.playback.waiting_action = false
        binding.action.resume_attack = false
        binding.action.resume_dodge = false
        binding.action.active_jab_event = nil
        binding.action.dodge_event = nil
        binding.action.takedown_event = nil
        binding.pair.paired_key = nil
        binding.pair.finished_pair_key = nil
        binding.pair.paired_track = nil
        binding.playback.paired_track = nil
        binding.action.jab_sound_pending = false
        binding.action.jab_sound_event = nil
        binding.action.perfect_action_until = 0
        binding.action.perfect_action_track = nil
        binding.downed.knockdown_active = false
        binding.downed.knocked_out_started = false
        binding.downed.knocked_out_load_age, binding.downed.knocked_out_retries = 0, 0
        binding.downed.knockdown_age, binding.downed.fall_load_age = 0, 0

        for name, track in binding.tracks do
            if name ~= "Idle" then
                track:Stop(0.05)
            end
        end

        binding.character:SetAttribute("CombatState", "Idle")
        binding.character:SetAttribute("CombatMoveSpeed", 0)
        binding.character:SetAttribute("CombatMoveVelocity", Vector3.zero)
        binding.character:SetAttribute("AttackAgeFrames", -1)
        binding.character:SetAttribute("DodgeAgeFrames", -1)
    end

    if binding.action.active_jab_event and not valid[binding.action.active_jab_event] then
        if binding.playback.active_track then
            binding.playback.active_track:Stop(0.05)
        end
        binding.playback.active_track = nil
        binding.playback.waiting_action = false
        binding.action.active_jab_event = nil
        binding.action.jab_sound_pending = false
        binding.action.jab_sound_event = nil
    end

    if binding.action.dodge_event and not valid[binding.action.dodge_event] then
        if binding.tracks.Dodge then
            binding.tracks.Dodge:Stop(0.05)
        end
        binding.action.dodge_event = nil
    end

    if binding.pair.finished_pair_key and not valid[binding.pair.finished_pair_key] then
        if binding.tracks.KnockedOut and binding.downed.knocked_out_pair_key == binding.pair.finished_pair_key then binding.tracks.KnockedOut:Stop(0.05) end
        binding.downed.knocked_out_started = false
        binding.downed.knocked_out_pair_key = nil
        binding.pair.finished_pair_key = nil
    end

    if binding.pair.paired_key and not valid[binding.pair.paired_key] then
        if binding.pair.paired_track then
            binding.pair.paired_track:Stop(0.05)
        end
        binding.pair.paired_key = nil
    end

    if binding.action.takedown_event and not valid[binding.action.takedown_event] then
        if binding.tracks.TakedownReaction then
            binding.tracks.TakedownReaction:Stop(0.05)
        end
        binding.action.takedown_event = nil
    end

    if Cinematics.PerfectEventId and not valid[Cinematics.PerfectEventId] then
        binding.action.perfect_action_until = 0
        binding.action.perfect_action_track = nil
    end

end

function Animations.Bind(character, animator)
    local binding = {character = character, animator = animator, action = {}, pair = {}, downed = {}, clock = {}, clinch = {}}
    local callbacks = {}
    callbacks.UpdateClinch = function(...) UpdateClinch(binding, ...) end
    callbacks.UpdatePaired = function(...) UpdatePaired(binding, ...) end
    callbacks.PlayPunchRelease = function(...) PlayPunchRelease(binding, ...) end
    callbacks.UpdateAnimations = function(...) UpdateAnimations(binding, ...) end
    callbacks.UpdateState = function(...) UpdateState(binding, ...) end
    binding.player = game:GetService("Players").LocalPlayer
    binding.folder = script.Parent.Parent
    binding.arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    binding.humanoid = binding.character:FindFirstChildOfClass("Humanoid")
    binding.combat_effects = binding.folder:WaitForChild("CombatEffects")
    binding.rollback_effects = binding.folder:WaitForChild("RollbackEffects")
    binding.is_player = binding.character == binding.player.Character
    binding.alive = true
    binding.playback = {active_kind = "Jab", move_direction = 1, waiting_action = false}
    binding.tracks, binding.jab_tracks = LoadTracks(binding.character:GetAttribute("FighterId") or "Boxing", binding.animator)

    binding.action.active_jab_mode = "Phased"
    binding.action.resume_attack = false
    binding.action.resume_dodge = false
    binding.downed.knockdown_active = false
    binding.downed.knockdown_age = 0
    binding.downed.fall_load_age = 0
    binding.downed.knocked_out_started = false

    binding.clock.paired_load_age = 0
    binding.downed.knocked_out_load_age = 0
    binding.downed.knocked_out_retries = 0

    binding.clock.last_attack_age = -1
    binding.clock.attack_stall_age = 0
    binding.clock.last_paired_age = -1
    binding.clock.paired_stall_age = 0
    binding.clock.last_getup_age = -1
    binding.clock.getup_stall_age = 0
    binding.action.jab_sound_pending = false

    binding.action.perfect_action_until = 0

    binding.action.perfect_action_speed = 1
    binding.action.active_jab_startup = CombatSimulation.OpeningStartup
    binding.action.active_action_start = 0
    binding.action.previous_state = binding.character:GetAttribute("CombatState") or "Idle"
    binding.character_connections = {}
    local animate = binding.character:FindFirstChild("Animate")

    if animate then
        animate.Disabled = true
    end

    for _, track in binding.animator:GetPlayingAnimationTracks() do
        if track.Priority == Enum.AnimationPriority.Core or track.Priority == Enum.AnimationPriority.Idle or track.Priority == Enum.AnimationPriority.Movement then
            track:Stop(0)
        end
    end

    binding.clinch.last_escape = 0
    binding.clinch.clinch_tracks = {}

    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "ClinchFighterId", callbacks.UpdateClinch))
    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "ClinchRole", callbacks.UpdateClinch))
    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "ClinchEscapeUntil", callbacks.UpdateClinch))
    table.insert(binding.character_connections, binding.arena:GetAttributeChangedSignal("MatchState"):Connect(callbacks.UpdateClinch))
    UpdateClinch(binding)

    if binding.tracks.Idle then
        binding.tracks.Idle:Play(0)
    end

    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "PairedAnimationEventId", callbacks.UpdatePaired))
    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "PairedAnimationAgeFrames", callbacks.UpdatePaired))
    UpdatePaired(binding)

    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "AttackAgeFrames", callbacks.PlayPunchRelease))

    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "JabSequence", function()
        OnAttack(binding)
    end))

    table.insert(binding.character_connections, RunService.Heartbeat:Connect(callbacks.UpdateAnimations))

    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "GetUpSerial", function()
        OnGetUp(binding)
    end))

    for _, field in {"CombatState", "StunReason"} do
        table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, field, callbacks.UpdateState))
    end

    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "HitSerial", function()
        OnHit(binding)
    end))

    table.insert(binding.character_connections, binding.combat_effects.Event:Connect(function(event)
        OnCombatEvent(binding, event)
    end))

    table.insert(binding.character_connections, binding.rollback_effects.Event:Connect(function(valid)
        CorrectAnimations(binding, valid)
    end))

    local initial_state = binding.character:GetAttribute("CombatState") or "Idle"

    if initial_state == "AttackStartup" or initial_state == "AttackActive" or initial_state == "AttackRecovery" then
        PlayJab(binding, binding.character:GetAttribute("JabVariant") or binding.character:GetAttribute("JabSequence") or 1, true)
    elseif initial_state:sub(1, 5) == "Dodge" and binding.tracks.Dodge then
        binding.tracks.Dodge:Play(0.02, 1, Cinematics.TimeScale)
        binding.action.resume_dodge = true
    end

    UpdateState(binding)
    UpdateAnimations(binding)

    return binding.playback, function() Cleanup(binding) end
end

return Animations
