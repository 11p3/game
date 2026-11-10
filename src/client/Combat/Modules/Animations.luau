local FighterPresentation = require(game.ReplicatedStorage.Combat.Modules.FighterPresentation)
local Animations = {}

type PlaybackMode = "Natural" | "Phased" | "Feint"
type PlaybackState = {active_kind: string, move_direction: number, waiting_action: boolean, active_track: AnimationTrack?, paired_track: AnimationTrack?}
type ActionState = {
    active_jab_mode: PlaybackMode,
    active_jab_startup: number,
    active_action_start: number,
    active_jab_event: string?,
    jab_sound_event: string?,
    jab_sound_pending: boolean,
    resume_attack: boolean,
    resume_dodge: boolean,
    perfect_action_until: number,
    perfect_action_speed: number,
    perfect_action_track: AnimationTrack?,
    previous_state: string,
    takedown_event: string?,
    dodge_event: string?
}
type PairState = {paired_key: string?, finished_pair_key: string?, paired_track: AnimationTrack?}
type DownedState = {
    knocked_out_started: boolean,
    knocked_out_pair_key: string?,
    knocked_out_load_age: number,
    knocked_out_retries: number,
    knockdown_active: boolean,
    knockdown_age: number,
    fall_load_age: number,
    getup_active: boolean,
    getup_serial: number
}
type PlaybackClock = {last_attack_age: number, attack_stall_age: number, last_paired_age: number, paired_stall_age: number, last_getup_age: number, getup_stall_age: number, paired_load_age: number}
type Binding = {
    character: Model,
    animator: Animator,
    player: Player,
    humanoid: Humanoid,
    folder: Instance,
    arena: Instance,
    combat_effects: BindableEvent,
    rollback_effects: BindableEvent,
    is_player: boolean,
    alive: boolean,
    tracks: {[string]: AnimationTrack?},
    jab_tracks: {AnimationTrack},
    character_connections: {RBXScriptConnection | FighterPresentation.Connection},
    playback: PlaybackState,
    action: ActionState,
    pair: PairState,
    downed: DownedState,
    clock: PlaybackClock,
    clinch: {last_escape: number, clinch_tracks: {[string]: AnimationTrack?}}
}

local SIMULATION_HZ = 60
local TRACK_END_EPSILON = 0.001 -- Seek just inside a clip so reaching its exact endpoint does not stop the track.
local TRACK_WEIGHT_EPSILON = 0.001
local CONTACT_SEEK_TOLERANCE = 0.012 -- Ignore tiny contact-time differences to avoid jittering authored playback.
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
local FALL_LOAD_TIMEOUT = 1.5 -- Bound loading waits so a missing fall clip cannot freeze the downed transition.
local KNOCKED_OUT_LOAD_TIMEOUT = 1.5
local KNOCKED_OUT_RETRY_SECONDS = 0.5
local MAX_KNOCKED_OUT_RETRIES = 3 -- Retry delayed assets without starting an endless loading loop.
local ANIMATION_STALL_SECONDS = 0.15 -- Allow a short replication gap before treating logical playback as stalled.
local MIN_FOLLOWTHROUGH_SPEED = 0.2
local INTERRUPT_ACTION_STATES = table.freeze({GettingUp = true, Hitstun = true, Knockout = true, Knockdown = true, Waiting = true, BoutOver = true, Stunned = true, HitReact = true, Retreating = true, Sidestep = true, ClinchHeld = true, ClinchEscape = true, DodgeStartup = true, DodgeActive = true, DodgeRecovery = true})

local function NumberAttribute(character: Model, name: string, fallback: number): number
    local value = character:GetAttribute(name)
    return if type(value) == "number" then value else fallback
end

local function StringAttribute(character: Model, name: string): string?
    local value = character:GetAttribute(name)
    return if type(value) == "string" then value else nil
end

local function GetContactTime(track: AnimationTrack?): number?
    -- Ignore contact metadata left over from a different animation asset.
    if not track or track.Animation:GetAttribute("TimingAssetId") ~= track.Animation.AnimationId then
        return nil
    end
    local contact = track.Animation:GetAttribute("ContactTime")
    if typeof(contact) ~= "number" or contact ~= contact or contact <= 0 or contact == math.huge then
        return nil
    end
    return if track.Length > 0 then math.min(contact, math.max(0.001, track.Length - TRACK_END_EPSILON)) else contact
end

local function GetKnockedOutTime(track: AnimationTrack?): number
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

local function LoadTracks(fighter_id: string, animator: Animator): ({[string]: AnimationTrack}, {AnimationTrack})
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
                configured = true
                break
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

local function StopAttack(binding: Binding, fade: number)
    binding.playback.waiting_action = false
    binding.action.resume_attack = false
    binding.action.jab_sound_pending = false
    local track = binding.playback.active_track
    if track and track.IsPlaying then
        track:Stop(fade)
    end
end

local function PlayKnockedOut(binding: Binding)
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

    local animation = universal_animations:FindFirstChild("KnockedOutAnimation")
    if not animation or not animation:IsA("Animation") or animation.AnimationId == "" then return end

    binding.downed.knocked_out_retries += 1
    binding.downed.knocked_out_load_age = 0
    local loaded, replacement = pcall(function() return binding.animator:LoadAnimation(animation) end)
    if loaded then
        binding.tracks.KnockedOut = replacement
        replacement.Priority = Enum.AnimationPriority.Action3
        replacement.Looped = true
        replacement:Play(KNOCKDOWN_BLEND, 1, Cinematics.TimeScale)
    end
end

local function UpdateClinch(binding: Binding)
    local role = StringAttribute(binding.character, "ClinchRole") or ""
    local escaping = NumberAttribute(binding.character, "ClinchEscapeUntil", 0)
    local fighting = binding.arena:GetAttribute("MatchState") == "Fighting"

    local clinch_profile = animations:FindFirstChild(StringAttribute(binding.character, "ClinchFighterId") or "")

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

local function UpdatePaired(binding: Binding)
    local key = StringAttribute(binding.character, "PairedAnimationEventId") or ""
    if key ~= "" and key == binding.pair.finished_pair_key then return end
    if binding.downed.knocked_out_started then
        if key == "" or key == binding.downed.knocked_out_pair_key then return end
        binding.downed.knocked_out_started = false
        if binding.tracks.KnockedOut then binding.tracks.KnockedOut:Stop(KNOCKDOWN_BLEND) end
    end
    local name = StringAttribute(binding.character, "PairedAnimation") or ""
    local age = NumberAttribute(binding.character, "PairedAnimationAgeFrames", -1)

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

local function PlayPunchRelease(binding: Binding)
    if not binding.action.jab_sound_pending then
        return
    end

    local state = StringAttribute(binding.character, "CombatState")
    local age = NumberAttribute(binding.character, "AttackAgeFrames", -1)

    if state ~= "AttackStartup" and state ~= "AttackActive" and state ~= "AttackRecovery" then
        binding.action.jab_sound_pending = false

        return
    end

    if age >= binding.action.active_jab_startup then
        binding.action.jab_sound_pending = false

        if age <= binding.action.active_jab_startup + (NumberAttribute(binding.character, "AttackActiveFrames", CombatSimulation.JabActiveFrames)) + 6 then
            local move = MoveDefinitions.Get(StringAttribute(binding.character, "FighterId") or "Boxing", binding.playback.active_kind)
            local release = move and move.feedback.Release
            if release then
                Audio.Play(release.sound, release.volume, release.pitch, binding.action.jab_sound_event)
            end
        end
    end
end

local function PlayJab(binding: Binding, sequence: number, resuming: boolean?)
    local event_id = StringAttribute(binding.character, "AttackEventId")
    if event_id and event_id == binding.action.active_jab_event then
        return
    end

    local kind = StringAttribute(binding.character, "AttackKind") or "Jab"
    local move = MoveDefinitions.Get(StringAttribute(binding.character, "FighterId") or "Boxing", kind)
    local track = move and (binding.tracks[move.animation] or binding.tracks[move.animation_fallback])

    if not track and move and (move.animation == "Jab" or move.animation_fallback == "Jab") and #binding.jab_tracks > 0 then
        track = binding.jab_tracks[(sequence - 1) % #binding.jab_tracks + 1]
    end

    StopAttack(binding, 0.03)

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
    binding.action.active_jab_startup = NumberAttribute(binding.character, "JabStartupFrames", CombatSimulation.OpeningStartup)
    local contact = GetContactTime(track)
    local timed_action = binding.action.active_jab_mode == "Natural" and contact and move and not move.victim_animation
    binding.action.active_action_start = if timed_action and not move.lunge then math.max(0, binding.action.active_jab_startup / SIMULATION_HZ - contact) else 0
    binding.playback.waiting_action = (timed_action and not move.lunge and binding.action.active_action_start > 0) or (not contact and move ~= nil and move.clinch_only == true and move.takedown == true and not move.victim_animation)
    if not binding.playback.waiting_action then
        binding.playback.active_track:Play(0.025, 1, if move and (binding.action.active_jab_mode == "Phased" or binding.action.active_jab_mode == "Feint") then 0 else Cinematics.TimeScale)
        if move and move.victim_animation and binding.playback.active_track.Length > 0 then
            binding.playback.active_track.TimePosition = math.clamp((NumberAttribute(binding.character, "PairedAnimationAgeFrames", 0)) / SIMULATION_HZ, 0, binding.playback.active_track.Length - TRACK_END_EPSILON)
        end
    end
    binding.action.jab_sound_pending = not (move and move.feint) and (not resuming or (NumberAttribute(binding.character, "AttackAgeFrames", 0)) < binding.action.active_jab_startup)
    binding.action.jab_sound_event = event_id
    PlayPunchRelease(binding)

    if move and (binding.action.active_jab_mode == "Phased" or binding.action.active_jab_mode == "Feint") and binding.playback.active_track.Length > 0 then
        binding.playback.active_track:AdjustSpeed((GetContactTime(binding.playback.active_track) or binding.playback.active_track.Length * 0.4) / (binding.action.active_jab_startup / SIMULATION_HZ) * Cinematics.TimeScale)
    end
end

local function UpdateStun(binding: Binding)
    local track = binding.tracks.Stun
    if not track then
        return
    end

    local state = StringAttribute(binding.character, "CombatState")
    local reason = StringAttribute(binding.character, "StunReason")
    local exhausted = state == "Stunned" and reason == "Exhausted"
    local followthrough = reason == "PerfectDodge" and os.clock() < binding.action.perfect_action_until and binding.action.perfect_action_track and binding.action.perfect_action_track.IsPlaying
    local reaction = FighterPresentation.Reaction(state, reason, binding.pair.paired_key ~= nil and binding.pair.paired_track ~= nil)
    local stunned = reaction == "Stun" and not followthrough

    if exhausted then
        StopAttack(binding, 0.05)
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

local function UpdateDowned(binding: Binding, delta_time, logical_paired_age)
    if binding.pair.paired_key and binding.pair.paired_track then
        binding.clock.paired_load_age += delta_time
        local length = binding.pair.paired_track.Length
        local elapsed = logical_paired_age / SIMULATION_HZ
        local ended = length > 0 and (elapsed >= length - TRACK_END_EPSILON or (not binding.pair.paired_track.IsPlaying and binding.pair.paired_track.TimePosition >= length - TRACK_END_EPSILON))
        local unavailable = length <= 0 and binding.clock.paired_load_age >= FALL_LOAD_TIMEOUT
        if ended or unavailable then
            binding.pair.finished_pair_key = binding.pair.paired_key
            local state = StringAttribute(binding.character, "CombatState")
            if binding.downed.knockdown_active or (state == "Stunned" and StringAttribute(binding.character, "StunReason") == "Takedown") then
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
    elseif binding.downed.knocked_out_started and StringAttribute(binding.character, "CombatState") == "Stunned" and StringAttribute(binding.character, "StunReason") == "Takedown" then
        PlayKnockedOut(binding)
    end

end

local function UpdateAttackPlayback(binding: Binding, track: AnimationTrack, move, now: number, seek_attack: boolean?): number
    local base_speed = 1

    if track.Length > 0 and move and binding.action.active_jab_mode == "Natural" and not move.victim_animation and binding.clock.attack_stall_age < ANIMATION_STALL_SECONDS and now >= binding.action.perfect_action_until then
        local contact = GetContactTime(track)
        local age = (NumberAttribute(binding.character, "AttackAgeFrames", -1)) / SIMULATION_HZ
        if contact and age >= 0 then
            local windup = binding.action.active_jab_startup / SIMULATION_HZ
            local position: number
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

    if track.Length > 0 and move and (binding.action.active_jab_mode == "Phased" or binding.action.active_jab_mode == "Feint") then
        local state = StringAttribute(binding.character, "CombatState")

        if binding.clock.attack_stall_age < ANIMATION_STALL_SECONDS and now >= binding.action.perfect_action_until and (state == "AttackStartup" or state == "AttackActive" or state == "AttackRecovery") then
            local age = (NumberAttribute(binding.character, "AttackAgeFrames", 0)) / SIMULATION_HZ
            local windup = binding.action.active_jab_startup / SIMULATION_HZ
            local release = (NumberAttribute(binding.character, "AttackActiveFrames", CombatSimulation.JabActiveFrames)) / SIMULATION_HZ
            local recovery = math.clamp((NumberAttribute(binding.character, "AttackRecoveryFrames", 18)) / SIMULATION_HZ, 0.08, 0.32)
            local contact = GetContactTime(track) or track.Length * 0.4
            local release_end = math.min(track.Length - TRACK_END_EPSILON, contact + math.min(1 / 30, math.max(0, track.Length - contact) * 0.5))
            local position: number

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
            local return_start = windup + (if binding.action.active_jab_mode == "Feint" then 0 else release)
            local returning = math.clamp((age - return_start) / recovery, 0, 1)
            track:AdjustWeight(1 - returning * returning * (3 - 2 * returning), 0.025)

            if seek_attack or math.abs(track.TimePosition - target) > CONTACT_SEEK_TOLERANCE then
                track.TimePosition = target
            end
        end
    end

    return base_speed
end

local function UpdatePlayback(binding: Binding, now: number, movement_speed: number, logical_paired_age: number, seek_attack: boolean?)
    local move = MoveDefinitions.Get(StringAttribute(binding.character, "FighterId") or "Boxing", binding.playback.active_kind)

    for name, track in binding.tracks do
        if track and track.IsPlaying then
            local base_speed = if name == "Move" then (if movement_speed <= 0.1 then 0 elseif binding.playback.move_direction < 0 then -1 else 1) else 1

            if track == binding.pair.paired_track then
                local age = logical_paired_age / SIMULATION_HZ
                if binding.pair.paired_key and binding.clock.paired_stall_age < ANIMATION_STALL_SECONDS and age >= 0 and track.Length > 0 and age < track.Length - TRACK_END_EPSILON and math.abs(track.TimePosition - age) > RESUME_SEEK_TOLERANCE then
                    track.TimePosition = age
                end
            elseif track == binding.playback.active_track and move and move.victim_animation and track.Length > 0 then
                local age = (NumberAttribute(binding.character, "PairedAnimationAgeFrames", -1)) / SIMULATION_HZ
                if binding.clock.paired_stall_age < ANIMATION_STALL_SECONDS and age >= 0 and age < track.Length - TRACK_END_EPSILON and math.abs(track.TimePosition - age) > RESUME_SEEK_TOLERANCE then
                    track.TimePosition = math.clamp(age, 0, track.Length - TRACK_END_EPSILON)
                end
            end

            if track == binding.playback.active_track then
                base_speed = UpdateAttackPlayback(binding, track, move, now, seek_attack)
            end

            if name == "GetUp" and StringAttribute(binding.character, "CombatState") == "GettingUp" and track.Length > 0 and binding.clock.getup_stall_age < ANIMATION_STALL_SECONDS then
                local duration = math.max(0.1, (NumberAttribute(binding.character, "GetUpDurationFrames", CombatSimulation.GetUpFrames)) / SIMULATION_HZ - 0.05)
                local age = math.max(0, NumberAttribute(binding.character, "GetUpAgeFrames", 0)) / SIMULATION_HZ
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

local function UpdateLocomotion(binding: Binding, state, movement_speed)
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
        elseif track and track.IsPlaying then
            track:AdjustSpeed(0)
            track:Stop(0.08)
        end
    end

    if binding.tracks.Idle and not binding.tracks.Idle.IsPlaying then
        binding.tracks.Idle:Play(0.08)
    end
end

local function UpdateGetUp(binding: Binding, state: string, rewound: boolean?)
    local getting_up = state == "GettingUp"
    local getup_serial = NumberAttribute(binding.character, "GetUpSerial", 0)
    if getting_up and (not binding.downed.getup_active or getup_serial ~= binding.downed.getup_serial or (rewound and binding.tracks.GetUp and not binding.tracks.GetUp.IsPlaying)) then
        binding.downed.knockdown_age, binding.downed.fall_load_age = 0, 0
        binding.downed.knocked_out_load_age, binding.downed.knocked_out_retries = 0, 0
        binding.pair.finished_pair_key = nil
        if binding.tracks.GetUp then
            binding.tracks.GetUp:Play(0.05, 1, Cinematics.TimeScale)
        end
    elseif not getting_up and binding.downed.getup_active and binding.tracks.GetUp then
        binding.tracks.GetUp:Stop(0.08)
    end
    binding.downed.getup_active = getting_up
    binding.downed.getup_serial = getup_serial
end

local function UpdateAnimations(binding: Binding, delta_time)
    delta_time = math.clamp(delta_time or 0, 0, 0.1)
    local movement_speed = NumberAttribute(binding.character, "CombatMoveSpeed", 0)

    if movement_speed > 0.1 then
        binding.playback.move_direction = NumberAttribute(binding.character, "CombatMoveDirection", 1)
    end

    local logical_attack_age = NumberAttribute(binding.character, "AttackAgeFrames", -1)
    local logical_paired_age = NumberAttribute(binding.character, "PairedAnimationAgeFrames", -1)
    local logical_getup_age = NumberAttribute(binding.character, "GetUpAgeFrames", -1)
    if logical_getup_age >= 0 and logical_getup_age < binding.clock.last_getup_age then
        UpdateGetUp(binding, StringAttribute(binding.character, "CombatState") or "Idle", true)
    end
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
            local age = math.max(0, NumberAttribute(binding.character, "AttackAgeFrames", 0)) / SIMULATION_HZ
            if age < waiting_track.Length then waiting_track.TimePosition = age else waiting_track:Stop(0) end
        end
        binding.action.resume_attack = false
    end

    if binding.action.resume_dodge and binding.tracks.Dodge and binding.tracks.Dodge.Length > 0 then
        local age = math.max(0, NumberAttribute(binding.character, "DodgeAgeFrames", 0)) / SIMULATION_HZ
        if age < binding.tracks.Dodge.Length then binding.tracks.Dodge.TimePosition = age else binding.tracks.Dodge:Stop(0) end
        binding.action.resume_dodge = false
    end

    if waiting_track and binding.playback.waiting_action then
        local age = (NumberAttribute(binding.character, "AttackAgeFrames", -1)) / SIMULATION_HZ
        if binding.clock.attack_stall_age >= ANIMATION_STALL_SECONDS and age >= 0 then age += binding.clock.attack_stall_age end
        local contact = GetContactTime(waiting_track)
        local start_at = if contact then binding.action.active_action_start else math.max(0, binding.action.active_jab_startup / SIMULATION_HZ - waiting_track.Length)

        if waiting_track.Length > 0 and ((age >= 0 and age >= start_at) or (age < 0 and StringAttribute(binding.character, "JabResult") == "Hit")) then
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

    local state = StringAttribute(binding.character, "CombatState")
    UpdateStun(binding)
    UpdateLocomotion(binding, state, movement_speed)
end

local function UpdateDownedState(binding: Binding, state)
    local down = state == "Knockdown" or state == "Knockout" or (state == "BoutOver" and (binding.downed.knockdown_active or (NumberAttribute(binding.character, "CombatHealth", 1)) <= 0))
    if down and not binding.downed.knockdown_active then
        binding.downed.knockdown_age = math.max(0, NumberAttribute(binding.character, "KnockdownAgeFrames", 0)) / SIMULATION_HZ
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

    UpdateGetUp(binding, state)
end

local function UpdateState(binding: Binding)
    local state = StringAttribute(binding.character, "CombatState") or "Idle"
    UpdateDownedState(binding, state)

    local perfect_stun = state == "Stunned" and StringAttribute(binding.character, "StunReason") == "PerfectDodge"

    local active_track = binding.playback.active_track
    local preserve_punch = perfect_stun and active_track and (active_track.IsPlaying or binding.playback.waiting_action)

    if preserve_punch and active_track then
        if binding.playback.waiting_action then
            binding.playback.waiting_action = false
            active_track:Play(0.025, 1, Cinematics.TimeScale)
        end
        -- Let the missed punch follow through before blending into its stun pose.
        binding.action.perfect_action_until = os.clock() + PERFECT_HOLD
        binding.action.perfect_action_track = active_track
        binding.action.perfect_action_speed = math.max(MIN_FOLLOWTHROUGH_SPEED, (active_track.Length - active_track.TimePosition) / PERFECT_HOLD)
    end

    if binding.tracks.ClinchRelease then
        local move = MoveDefinitions.Get(StringAttribute(binding.character, "FighterId") or "Boxing", binding.playback.active_kind)
        local finishing_grapple = binding.playback.active_track and (binding.playback.active_track.IsPlaying or binding.playback.waiting_action) and move and (move.shove or move.takedown) and StringAttribute(binding.character, "JabResult") == "Hit"
        if state == "ClinchRelease" and not finishing_grapple then
            StopAttack(binding, 0.04)
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

    if INTERRUPT_ACTION_STATES[state] then
        if state:sub(1, 5) ~= "Dodge" and binding.tracks.Dodge then
            binding.tracks.Dodge:Stop(0.03)
        end

        if not preserve_punch then
            StopAttack(binding, 0.03)
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

local function Cleanup(binding: Binding)
    if not binding.alive then
        return
    end
    binding.alive = false
    for _, connection in binding.character_connections do
        connection:Disconnect()
    end
    for _, track in binding.tracks do
        if track then
            track:Stop(0)
            track:Destroy()
        end
    end
    binding.playback.active_track = nil
end

local function OnAttack(binding: Binding)
    local sequence = NumberAttribute(binding.character, "JabSequence", 0)

    if sequence > 0 then
        PlayJab(binding, NumberAttribute(binding.character, "JabVariant", sequence))
    end
end

local function OnHit(binding: Binding)
    if binding.tracks.TakedownReaction and not binding.character:GetAttribute("LastHitDodged") and not binding.pair.paired_key then
        if binding.character:GetAttribute("LastHitTakedown") and StringAttribute(binding.character, "CombatState") ~= "Knockdown" then
            binding.action.takedown_event = StringAttribute(binding.character, "LastHitPresentationEventId")
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

local function OnCombatEvent(binding: Binding, event)
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

local function CorrectAnimations(binding: Binding, valid)
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
        binding.downed.getup_active = false
        binding.downed.getup_serial = 0
        binding.downed.knocked_out_started = false
        binding.downed.knocked_out_load_age, binding.downed.knocked_out_retries = 0, 0
        binding.downed.knockdown_age, binding.downed.fall_load_age = 0, 0

        for name, track in binding.tracks do
            if name ~= "Idle" and track then
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
        StopAttack(binding, 0.05)
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

function Animations.Bind(character: Model, animator: Animator)
    local player = game:GetService("Players").LocalPlayer
    local folder = script.Parent.Parent
    local tracks, jab_tracks = LoadTracks(StringAttribute(character, "FighterId") or "Boxing", animator)
    local binding: Binding = {
        character = character,
        animator = animator,
        player = player,
        folder = folder,
        arena = workspace:WaitForChild("Combat"):WaitForChild("Arena"),
        humanoid = assert(character:FindFirstChildOfClass("Humanoid"), "Fighter is missing its Humanoid"),
        combat_effects = folder:WaitForChild("CombatEffects") :: BindableEvent,
        rollback_effects = folder:WaitForChild("RollbackEffects") :: BindableEvent,
        is_player = character == player.Character,
        alive = true,
        tracks = tracks,
        jab_tracks = jab_tracks,
        character_connections = {},
        playback = {active_kind = "Jab", move_direction = 1, waiting_action = false},
        action = {
            active_jab_mode = "Phased",
            active_jab_startup = CombatSimulation.OpeningStartup,
            active_action_start = 0,
            jab_sound_pending = false,
            resume_attack = false,
            resume_dodge = false,
            perfect_action_until = 0,
            perfect_action_speed = 1,
            previous_state = StringAttribute(character, "CombatState") or "Idle"
        },
        pair = {},
        downed = {knockdown_active = false, knockdown_age = 0, fall_load_age = 0, knocked_out_started = false, knocked_out_load_age = 0, knocked_out_retries = 0, getup_active = false, getup_serial = 0},
        clock = {paired_load_age = 0, last_attack_age = -1, attack_stall_age = 0, last_paired_age = -1, paired_stall_age = 0, last_getup_age = -1, getup_stall_age = 0},
        clinch = {last_escape = 0, clinch_tracks = {}}
    }
    local callbacks = {}
    callbacks.UpdateClinch = function() UpdateClinch(binding) end
    callbacks.UpdatePaired = function() UpdatePaired(binding) end
    callbacks.PlayPunchRelease = function() PlayPunchRelease(binding) end
    callbacks.UpdateAnimations = function(delta_time) UpdateAnimations(binding, delta_time) end
    callbacks.UpdateState = function() UpdateState(binding) end
    local animate = binding.character:FindFirstChild("Animate")

    if animate then
        animate.Disabled = true
    end

    for _, track in binding.animator:GetPlayingAnimationTracks() do
        if track.Priority == Enum.AnimationPriority.Core or track.Priority == Enum.AnimationPriority.Idle or track.Priority == Enum.AnimationPriority.Movement then
            track:Stop(0)
        end
    end

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

    table.insert(binding.character_connections, FighterPresentation.Observe(binding.character, "GetUpSerial", callbacks.UpdateState))

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

    local initial_state = StringAttribute(binding.character, "CombatState") or "Idle"

    if initial_state == "AttackStartup" or initial_state == "AttackActive" or initial_state == "AttackRecovery" then
        PlayJab(binding, NumberAttribute(binding.character, "JabVariant", NumberAttribute(binding.character, "JabSequence", 1)), true)
    elseif initial_state:sub(1, 5) == "Dodge" and binding.tracks.Dodge then
        binding.tracks.Dodge:Play(0.02, 1, Cinematics.TimeScale)
        binding.action.resume_dodge = true
    end

    UpdateState(binding)
    UpdateAnimations(binding)

    return binding.playback, function() Cleanup(binding) end
end

return Animations
