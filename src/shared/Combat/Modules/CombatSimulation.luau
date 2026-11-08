local MoveDefinitions = require(script.Parent.MoveDefinitions)
local Pairing = require(script.Parent.PairedActions).New(MoveDefinitions)

local CombatSimulation = {VERSION = 10, Pairing = Pairing}
local SIMULATION_HZ = 60
local STAMINA_REST_DELAY = 45
local STAMINA_RECOVERY_DELAY = 30
local EXHAUSTION_RECOVERY_STAMINA = 40
local MIN_PERFECT_WINDOW = 5
local PERFECT_WINDOW_RATIO = 0.67
local PERFECT_DODGE_VISUAL_FRAMES = 60
local MAX_RESOURCE = 100
local BASE_JAB = MoveDefinitions.Boxing.moves.Jab
local OPENING_STARTUP = BASE_JAB.timeline.startup[1]
local JAB_ACTIVE = BASE_JAB.timeline.active
local WHIFF_RECOVERY = BASE_JAB.timeline.recovery.Whiff
local COUNTER_DAMAGE = 4
local MOMENTUM_MAX = 3
local BLOCKSTUN = 9
local DODGE_STARTUP = 3
local DODGE_ACTIVE = 10
local DODGE_RECOVERY = 12
local DODGE_COOLDOWN = 60
local INPUT_BUFFER = 6
local HIT_CHAIN_RECOVERY = BASE_JAB.cancels.Hit.attack
local HIT_REACTION = 9
local DODGE_STAMINA = 18
local STAMINA_REGEN = 18 / SIMULATION_HZ
local BLOCK_REGEN = 8 / SIMULATION_HZ
local BLOCK_REGEN_DELAY = 120
local EXHAUSTION_STUN = 60
local GUARD_BREAK_STUN = 72
local PERFECT_DODGE_STUN = 120
local GET_UP_FRAMES = 60
local CLINCH_ESCAPE_MAX = 1000


local function StunFighter(fighter, duration: number, reason: string)
    if fighter.stun_until > fighter.frame + duration then
        duration = fighter.stun_until - fighter.frame
        reason = fighter.stun_reason
    end

    fighter.chain_count = 0
    fighter.chain_until = 0
    fighter.reaction_until = 0
    fighter.stun_until = fighter.frame + duration
    fighter.stun_reason = reason
    fighter.state = "Stunned"
    fighter.attack_started = nil
    fighter.dodge_started = nil
    fighter.guard_held = false
    fighter.guard_pressed_at = -1
    fighter.jab_buffer_until = 0
    fighter.dodge_buffer_until = 0
    fighter.queued_special = false
    fighter.queued_kick = false
    fighter.queued_technique = false
    fighter.queued_clinch = ""
end

local function SpendStamina(fighter, amount: number, committed: boolean?)
    fighter.stamina = math.max(0, fighter.stamina - amount)
    fighter.stamina_regen_at = fighter.frame + STAMINA_REST_DELAY

    if fighter.stamina <= 0 then
        if committed or fighter.attack_started or fighter.dodge_started or fighter.exhaustion_pending or (fighter.paired_action and fighter.frame < fighter.paired_action.until_frame) then
            fighter.exhaustion_pending = true
            if fighter.attack_started then
                fighter.exhaustion_ready = fighter.attack_started + fighter.attack_startup + fighter.attack_active + fighter.attack_recovery
            elseif fighter.dodge_started then
                fighter.exhaustion_ready = fighter.dodge_started + DODGE_STARTUP + DODGE_ACTIVE + DODGE_RECOVERY
            end
            return true
        end
        StunFighter(fighter, EXHAUSTION_STUN, "Exhausted")

        return false
    end

    return true
end

CombatSimulation.StunFighter = StunFighter
CombatSimulation.GetUpFrames = GET_UP_FRAMES
CombatSimulation.OpeningStartup = OPENING_STARTUP
CombatSimulation.JabActiveFrames = JAB_ACTIVE
CombatSimulation.HitChainRecovery = HIT_CHAIN_RECOVERY
CombatSimulation.JabActiveEnd = (OPENING_STARTUP + JAB_ACTIVE) / SIMULATION_HZ
CombatSimulation.JabChainDelay = (OPENING_STARTUP + JAB_ACTIVE + HIT_CHAIN_RECOVERY) / SIMULATION_HZ
CombatSimulation.JabDuration = (OPENING_STARTUP + JAB_ACTIVE + WHIFF_RECOVERY) / SIMULATION_HZ
CombatSimulation.InputBufferDuration = INPUT_BUFFER / SIMULATION_HZ
CombatSimulation.ClinchEscapeMax = CLINCH_ESCAPE_MAX

function CombatSimulation.PerfectWindowFrames(startup: number)
    return math.min(startup - 1, math.max(MIN_PERFECT_WINDOW, math.ceil(startup * PERFECT_WINDOW_RATIO)))
end

function CombatSimulation.CreateFighter()
    return {
        frame = 0,
        advance_until = 0,
        attack_advancing = false,
        getup_started = 0,
        getup_until = 0,
        protected = false,
        wall_splat_ready = 0,
        health = MAX_RESOURCE,
        momentum = 0,
        fighter_id = "Boxing",
        kick_ready = 0,
        special_requested = false,
        kick_requested = false,
        queued_special = false,
        queued_kick = false,
        queued_technique = false,
        technique_requested = false,
        clinch_requested = false,
        queued_clinch = "",
        clinch_holder = 0,
        clinch_started = 0,
        clinch_reversals = 0,
        clinch_until = 0,
        clinch_ready = 0,
        clinch_escape_until = 0,
        clinch_escape_ready = 0,
        clinch_escape_progress = 0,
        clinch_escape_started = false,
        clinch_escape_press = 0,
        clinch_release_until = 0,
        attack_counter = false,
        attack_special = false,
        attack_kind = "Jab",
        attack_active = 3,
        attack_range = 5,
        attack_width = 2.2,
        attack_height = 2.5,
        attack_damage = 8,
        attack_block_cost = 25,
        attack_hit_recovery = 7,
        attack_whiff_recovery = 18,
        attack_dodge_recovery = 18,
        attack_block_recovery = 20,
        attack_chain_recovery = 4,
        attack_target_stun = 0,
        attack_perfect_frames = 13,
        x = 0,
        y = 4,
        z = 0,
        facing = 1,
        attack_facing = 1,
        state = "Idle",
        guard_held = false,
        guard_input_held = false,
        guard_pressed_at = -1,
        guard_response_ready = 0,
        jab_requested = false,
        busy = false,
        block_until = 0,
        connected = false,
        dodge_requested = false,
        dodge_ready = 0,
        jab_buffer_until = 0,
        dodge_buffer_until = 0,
        attack_result = "None",
        attack_recovery = WHIFF_RECOVERY,
        jab_ready = 0,
        stamina = MAX_RESOURCE,
        exhaustion_pending = false,
        exhaustion_ready = 0,
        exhaustion_stun_frames = EXHAUSTION_STUN,
        block_meter = MAX_RESOURCE,
        stamina_regen_at = 0,
        block_regen_at = 0,
        stun_until = 0,
        stun_reason = "",
        attack_startup = OPENING_STARTUP,
        chain_count = 0,
        chain_until = 0,
        reaction_until = 0
    }
end

CombatSimulation.ReleaseClinch = Pairing.Release

local function BeginAttack(fighters, index, fighter, profile, frame, presentation_frame, followup_startup)
    if fighter.jab_buffer_until >= frame and frame >= fighter.jab_ready and frame >= fighter.stun_until and not fighter.attack_started and not fighter.dodge_started then
        local kind = if fighter.queued_clinch ~= "" then fighter.queued_clinch elseif fighter.queued_special then profile.inputs.special elseif fighter.queued_technique then profile.inputs.technique elseif fighter.queued_kick then profile.inputs.kick else profile.inputs.jab
        local move = profile.moves[kind]
        local timeline = move.timeline
        local recovery = timeline.recovery

        local chained = move.advance_chain and fighter.attack_result == "Hit" and frame <= fighter.chain_until
        local chain_count = if chained then math.min(fighter.chain_count + 1, #timeline.startup) else move.chain_start or 0
        local stamina = if move.chain_stamina then move.chain_stamina[math.clamp(chain_count, 1, #move.chain_stamina)] else move.stamina

        local capture_ready = not move.pairing or move.pairing.on_hit ~= "Capture" or frame >= (fighter.clinch_ready or 0)
        if capture_ready and SpendStamina(fighter, stamina, true) then
            fighter.attack_kind = kind
            fighter.attack_counter = false
            fighter.attack_special = (move.momentum or 0) > 0

            if move.cooldown_key then
                fighter[move.cooldown_key] = frame + move.cooldown_frames
            end
            fighter.queued_special = false
            fighter.queued_kick = false
            fighter.queued_technique = false
            fighter.queued_clinch = ""

            if fighter.attack_special then
                fighter.momentum -= move.momentum
            end

            fighter.chain_count = chain_count
            fighter.attack_startup = followup_startup or timeline.startup[math.clamp(fighter.chain_count, 1, #timeline.startup)]
            fighter.attack_active = timeline.active
            fighter.attack_range = move.hitbox.range
            fighter.attack_width = move.hitbox.half_width
            fighter.attack_height = move.hitbox.height
            fighter.attack_damage = move.damage
            fighter.attack_block_cost = move.block_cost
            fighter.attack_hit_recovery = recovery.Hit
            fighter.attack_whiff_recovery = recovery.Whiff
            fighter.attack_dodge_recovery = recovery.Dodged or recovery.Whiff
            fighter.attack_block_recovery = recovery.Blocked
            fighter.attack_chain_recovery = move.cancels and move.cancels.Hit and move.cancels.Hit.attack or recovery.Hit
            fighter.attack_target_stun = move.target_stun or 0
            fighter.attack_perfect_frames = math.min(fighter.attack_startup - 1, move.perfect_frames or CombatSimulation.PerfectWindowFrames(fighter.attack_startup))
            fighter.jab_buffer_until = 0
            fighter.attack_started = frame
            fighter.attack_hit_index = 0
            fighter.attack_facing = fighter.facing
            fighter.attack_forward_x = -math.sin(fighter.yaw or -fighter.facing * math.pi * 0.5)
            fighter.attack_forward_z = -math.cos(fighter.yaw or -fighter.facing * math.pi * 0.5)
            fighter.attack_advancing = move.advance ~= nil and frame <= fighter.advance_until
            if fighter.attack_advancing then
                local target = fighters[fighter.target]
                if target then
                    local dx, dz = target.x - fighter.x, target.z - fighter.z
                    local distance = math.max(0.001, math.sqrt(dx * dx + dz * dz))
                    fighter.lunge_forward_x, fighter.lunge_forward_z = dx / distance, dz / distance
                else
                    fighter.attack_advancing = false
                end
            elseif move.pairing and move.pairing.entry_motion then
                fighter.lunge_forward_x = fighter.attack_forward_x
                fighter.lunge_forward_z = fighter.attack_forward_z
            end
            fighter.connected = false
            fighter.attack_result = "Pending"
            fighter.attack_recovery = recovery.Whiff

            Pairing.Begin(fighters, index, move, presentation_frame)
            fighter.jab_ready = frame + fighter.attack_startup + fighter.attack_active + fighter.attack_recovery
            if fighter.exhaustion_pending then fighter.exhaustion_ready = fighter.jab_ready end

            if not move.advance_chain then
                fighter.chain_until = 0
            end
        end
    end


end

local function AdvanceRecovery(fighter, active_move, special_followup, frame)
    local followup_startup

    if fighter.dodge_started and frame - fighter.dodge_started >= DODGE_STARTUP + DODGE_ACTIVE + DODGE_RECOVERY and frame >= (fighter.perfect_dodge_until or 0) then
        fighter.dodge_started = nil
    end

    if fighter.attack_started then
        local age = frame - fighter.attack_started

        if age >= fighter.attack_startup + fighter.attack_active and fighter.attack_result == "Pending" then
            fighter.attack_result = if active_move.feint then "Feint" else "Whiff"
            if not active_move.feint then
                fighter.momentum = math.max(0, fighter.momentum - 1)
            end
            fighter.chain_count = 0
            fighter.chain_until = 0
        end

        local move = MoveDefinitions.Get(fighter.fighter_id, fighter.attack_kind)
        local cancels = move.cancels and move.cancels[fighter.attack_result]
        local recovery_age = age - fighter.attack_startup - fighter.attack_active
        local landed = cancels ~= nil
        local phase_cancel = (Pairing.Allows(fighter, "guard") and fighter.guard_held) or (Pairing.Allows(fighter, "dodge") and fighter.dodge_buffer_until >= frame and frame >= fighter.dodge_ready)
        local defensive_cancel = not fighter.exhaustion_pending and (phase_cancel or landed and ((cancels.guard and recovery_age >= cancels.guard and fighter.guard_held) or (cancels.dodge and recovery_age >= cancels.dodge and fighter.dodge_buffer_until >= frame and frame >= fighter.dodge_ready)))
        local jab_cancel = landed and cancels.attack and recovery_age >= cancels.attack and fighter.jab_buffer_until >= frame and not fighter.queued_special
        local followup_cancel = landed and special_followup and fighter.queued_special and fighter.jab_buffer_until >= frame and recovery_age >= special_followup.after and recovery_age < special_followup.after + special_followup.window

        if followup_cancel then
            followup_startup = if fighter.attack_counter and special_followup.counter_startup then special_followup.counter_startup else special_followup.startup
            fighter.jab_ready = frame
        end

        if defensive_cancel or jab_cancel or followup_cancel or age >= fighter.attack_startup + fighter.attack_active + fighter.attack_recovery then
            fighter.attack_started = nil
        end
    end


    return followup_startup
end

local function AdvanceFighter(fighters, index, fighter, match_frame)
    fighter.frame += 1

    local frame = fighter.frame
    local presentation_frame = match_frame or frame
    local profile = MoveDefinitions[fighter.fighter_id] or MoveDefinitions.Boxing
    local response = profile.guard_response
    local fresh_guard = fighter.guard_held and not fighter.guard_input_held
    fighter.guard_input_held = fighter.guard_held == true
    if not fighter.guard_held or fighter.attack_started or fighter.dodge_started or frame < fighter.stun_until or frame < fighter.reaction_until or fighter.protected then
        fighter.guard_pressed_at = -1
    end
    if fresh_guard and response then
        local free = not fighter.attack_started and not fighter.dodge_started and (fighter.clinch_holder or 0) == 0
        local active = fighter.health > 0 and not fighter.protected and not fighter.exhaustion_pending
        local recovered = frame >= fighter.stun_until and frame >= fighter.reaction_until and frame >= fighter.block_until
        local ready = frame >= fighter.guard_response_ready and frame >= (fighter.clinch_ready or 0)
        local released = frame >= (fighter.clinch_release_until or 0) and presentation_frame >= (fighter.getup_until or 0)
        if free and active and recovered and ready and released then
            fighter.guard_pressed_at = frame
            fighter.guard_response_ready = frame + response.cooldown_frames
        end
    end
    if presentation_frame < (fighter.getup_until or 0) then
        fighter.state = "GettingUp"
        fighter.protected = true
        fighter.guard_held = false
        fighter.jab_requested, fighter.special_requested, fighter.kick_requested, fighter.technique_requested, fighter.clinch_requested, fighter.dodge_requested = false, false, false, false, false, false
        fighter.jab_buffer_until, fighter.dodge_buffer_until = 0, 0
        fighter.queued_special, fighter.queued_kick, fighter.queued_technique, fighter.queued_clinch = false, false, false, ""
        return
    elseif (fighter.getup_until or 0) > 0 then
        fighter.getup_until = 0
        fighter.protected = false
        fighter.state = "Idle"
    end
    local paired = fighter.paired_action
    if paired and presentation_frame >= paired.until_frame then
        fighter.paired_action = nil
    end

    local kick = profile.inputs.kick and profile.moves[profile.inputs.kick]
    local special = profile.inputs.special and profile.moves[profile.inputs.special]
    local technique = profile.inputs.technique and profile.moves[profile.inputs.technique]
    local followup_startup
    local active_move = fighter.attack_started and profile.moves[fighter.attack_kind]
    local active_cancels = active_move and active_move.cancels and active_move.cancels[fighter.attack_result]
    local followups = active_cancels and active_cancels.followups
    local special_followup = followups and followups[profile.inputs.special]

    if fighter.stun_until > 0 and frame >= fighter.stun_until then
        if fighter.stun_reason == "Exhausted" then
            fighter.stamina = EXHAUSTION_RECOVERY_STAMINA
        end

        fighter.stun_until = 0
        fighter.stun_reason = ""
        fighter.stamina_regen_at = frame + STAMINA_RECOVERY_DELAY
        fighter.block_regen_at = math.max(fighter.block_regen_at, frame + STAMINA_RECOVERY_DELAY)
    end

    if fighter.health > 0 and frame >= fighter.stun_until then
        if frame >= fighter.stamina_regen_at and (fighter.clinch_holder or 0) == 0 and not fighter.attack_started and not fighter.dodge_started and not fighter.exhaustion_pending then
            fighter.stamina = math.min(MAX_RESOURCE, fighter.stamina + STAMINA_REGEN)
        end

        if frame >= fighter.block_regen_at and not fighter.guard_held then
            fighter.block_meter = math.min(MAX_RESOURCE, fighter.block_meter + BLOCK_REGEN)
        end
    end

    if frame < fighter.reaction_until or fighter.exhaustion_pending then
        fighter.jab_requested = false
        fighter.kick_requested = false
        fighter.technique_requested = false
        fighter.dodge_requested = false
        if fighter.exhaustion_pending then fighter.special_requested, fighter.clinch_requested = false, false end
        fighter.jab_buffer_until = 0
        fighter.dodge_buffer_until = 0
    end

    if frame > fighter.jab_buffer_until then
        fighter.queued_special = false
        fighter.queued_kick = false
        fighter.queued_technique = false
        fighter.queued_clinch = ""
    end

    local clinched = (fighter.clinch_holder or 0) > 0
    local controlling = fighter.clinch_holder == index

    if clinched then
        Pairing.Control(fighters, index, special, SpendStamina)
    elseif fighter.clinch_requested and not fighter.guard_held and not fighter.attack_started and not fighter.dodge_started and (fighter.state == "Idle" or fighter.state == "Guard") and frame >= (fighter.clinch_ready or 0) and frame >= fighter.stun_until and frame >= fighter.reaction_until then
        fighter.queued_clinch = "ClinchGrab"
        fighter.jab_requested = true
    end

    if fighter.kick_requested and kick and frame >= (fighter[kick.cooldown_key] or 0) and not fighter.guard_held and frame >= fighter.stun_until and frame >= fighter.reaction_until then
        fighter.queued_kick = true
        fighter.jab_requested = true
    end

    if fighter.technique_requested and technique and (fighter.state == "Idle" or fighter.state == "Guard") and not fighter.attack_started and not fighter.dodge_started and not fighter.guard_held and frame >= (fighter[technique.cooldown_key] or 0) and frame >= fighter.stun_until and frame >= fighter.reaction_until then
        fighter.queued_technique = true
        fighter.queued_kick = false
        fighter.jab_requested = true
    end

    if fighter.special_requested and special and (not special.clinch_only or controlling) and fighter.momentum >= (special.momentum or 0) and (fighter.state == "Idle" or fighter.state == "Guard" or special_followup or (controlling and special.clinch_only)) and frame >= fighter.stun_until and frame >= fighter.reaction_until then
        fighter.queued_special = true
        fighter.queued_clinch = ""
        fighter.queued_kick = false
        fighter.queued_technique = false
        fighter.jab_requested = true
        fighter.guard_held = false
    end

    if fighter.jab_requested then
        fighter.jab_buffer_until = frame + INPUT_BUFFER
    end

    if fighter.dodge_requested then
        fighter.dodge_input_frame = frame
        fighter.dodge_buffer_until = frame + INPUT_BUFFER

    end

    if fighter.health <= 0 then
        fighter.state = "Knockout"
        fighter.attack_started = nil
        fighter.dodge_started = nil
    elseif frame < fighter.stun_until then
        fighter.state = "Stunned"
    elseif frame < fighter.reaction_until then
        fighter.state = if fighter.guard_held then "Guard" else "HitReact"
    elseif frame < (fighter.clinch_release_until or 0) then
        fighter.state = "ClinchRelease"
    elseif frame < fighter.block_until then
        fighter.state = "Blockstun"
    elseif fighter.busy then
        fighter.state = "Sidestep"
        fighter.attack_started = nil
    else
        followup_startup = AdvanceRecovery(fighter, active_move, special_followup, frame)

        if fighter.dodge_buffer_until >= frame and not fighter.attack_started and not fighter.dodge_started and frame >= fighter.dodge_ready then
            if SpendStamina(fighter, DODGE_STAMINA, true) then
                fighter.chain_count = 0
                fighter.chain_until = 0
                if fighter.exhaustion_pending then fighter.exhaustion_ready = frame + DODGE_STARTUP + DODGE_ACTIVE + DODGE_RECOVERY end
                fighter.dodge_started = frame
                fighter.dodge_ready = frame + DODGE_COOLDOWN
                fighter.dodge_buffer_until = 0
            end
        end

        BeginAttack(fighters, index, fighter, profile, frame, presentation_frame, followup_startup)

        if frame < fighter.stun_until then
            fighter.state = "Stunned"
        elseif fighter.dodge_started then
            local age = frame - fighter.dodge_started

            fighter.state = if frame < (fighter.perfect_dodge_until or 0) then "DodgeActive" elseif age < DODGE_STARTUP then "DodgeStartup" elseif age < DODGE_STARTUP + DODGE_ACTIVE then "DodgeActive" else "DodgeRecovery"
        elseif fighter.attack_started then
            local age = frame - fighter.attack_started

            local move = profile.moves[fighter.attack_kind]
            local phase, hit_index, stage_offset, stage_startup = MoveDefinitions.Phase(age, fighter.attack_startup, fighter.attack_active, move)
            local hit = move.timeline.hits[hit_index]

            if fighter.attack_hit_index ~= hit_index then
                fighter.attack_hit_index = hit_index
                fighter.connected = false
                fighter.attack_result = "Pending"
                fighter.attack_recovery = move.timeline.recovery.Whiff
            end

            fighter.attack_stage_offset = stage_offset
            fighter.attack_stage_startup = stage_startup
            fighter.attack_hit_active = hit.active
            fighter.attack_damage = hit.damage or move.damage
            fighter.attack_block_cost = hit.block_cost or move.block_cost
            fighter.attack_target_stun = if hit.target_stun ~= nil then hit.target_stun else move.target_stun or 0
            local hitbox = hit.hitbox or move.hitbox
            fighter.attack_range = hitbox.range
            fighter.attack_width = hitbox.half_width
            fighter.attack_height = hitbox.height
            fighter.attack_perfect_frames = if move.perfect_dodge == false then 0 else math.max(0, math.min(stage_startup - 1, hit.perfect_frames or move.perfect_frames or CombatSimulation.PerfectWindowFrames(stage_startup)))
            fighter.state = phase
        else
            fighter.state = if fighter.guard_held then "Guard" elseif (fighter.clinch_holder or 0) == index then "ClinchControl" elseif (fighter.clinch_holder or 0) > 0 then (if fighter.clinch_escape_until > 0 then "ClinchEscape" else "ClinchHeld") else "Idle"
        end
    end

    fighter.jab_requested = false
    fighter.special_requested = false
    fighter.kick_requested = false
    fighter.technique_requested = false
    fighter.clinch_requested = false
    fighter.dodge_requested = false
end

local function ResolvePerfectDodges(fighters, contacts)
    for index, fighter in fighters do
        local attacker = fighters[fighter.target]

        if fighter.dodge_started ~= fighter.frame or fighter.dodge_input_frame ~= fighter.frame or not attacker or not attacker.attack_started or attacker.state ~= "AttackStartup" or attacker.health <= 0 or fighter.health <= 0 or fighter.protected then
            continue
        end

        local windup_age = attacker.frame - attacker.attack_started - (attacker.attack_stage_offset or 0)
        local windup = attacker.attack_stage_startup or attacker.attack_startup
        local dx, dz = fighter.x - attacker.x, fighter.z - attacker.z
        local distance = dx * attacker.attack_forward_x + dz * attacker.attack_forward_z
        local lateral = math.abs(dx * attacker.attack_forward_z - dz * attacker.attack_forward_x)
        local perfect_frames = attacker.attack_perfect_frames
        local perfect_window = windup_age >= windup - perfect_frames and windup_age < windup

        if perfect_window and distance > 0 and distance <= attacker.attack_range and lateral <= attacker.attack_width and math.abs(fighter.y - attacker.y) <= (attacker.attack_height or 2.5) then
            fighter.perfect_dodge_until = fighter.frame + PERFECT_DODGE_VISUAL_FRAMES
            attacker.attack_result = "Dodged"
            StunFighter(attacker, PERFECT_DODGE_STUN, "PerfectDodge")
            table.insert(contacts, {attacker = fighter.target, target = index, blocked = false, dodged = true, perfect = true, counter = false})
        end
    end


end

local function CollectContacts(fighters, contacts)
    for index, fighter in fighters do
        local target = fighters[fighter.target]
        if fighter.state ~= "AttackActive" or fighter.connected or not target or target.health <= 0 or target.protected then continue end
        local active_move = MoveDefinitions.Get(fighter.fighter_id, fighter.attack_kind)

        if (active_move.pairing and active_move.pairing.requires_control and fighter.clinch_holder ~= index) or (active_move.pairing and active_move.pairing.on_hit == "Capture" and (target and (target.clinch_holder or 0) > 0)) or active_move.feint then
            continue
        end

        local dx, dz = target.x - fighter.x, target.z - fighter.z
        local distance = dx * fighter.attack_forward_x + dz * fighter.attack_forward_z
        local lateral = math.abs(dx * fighter.attack_forward_z - dz * fighter.attack_forward_x)

        if distance <= 0 or distance > fighter.attack_range or lateral > fighter.attack_width or math.abs(target.y - fighter.y) > (fighter.attack_height or 2.5) then
            continue
        end

        fighter.connected = true

        local blocked = (not active_move.pairing or active_move.pairing.guard ~= "Bypass") and (target.state == "Guard" or target.state == "Blockstun") and (fighter.x - target.x) * -math.sin(target.yaw or -target.facing * math.pi * 0.5) + (fighter.z - target.z) * -math.cos(target.yaw or -target.facing * math.pi * 0.5) > 0
        local dodged = target.state == "DodgeActive"
        local response = (MoveDefinitions[target.fighter_id] or MoveDefinitions.Boxing).guard_response
        local eligible = response and active_move.guard_tag and response.tags[active_move.guard_tag]
        local timed = eligible and target.guard_pressed_at >= 0 and target.frame - target.guard_pressed_at < response.window_frames
        local resources = timed and target.stamina >= response.stamina and not target.exhaustion_pending and target.block_meter > 0
        local recovered = target.frame >= target.stun_until and target.frame >= target.reaction_until and target.frame >= target.block_until
        local unpaired = (target.clinch_holder or 0) == 0 and (fighter.clinch_holder or 0) == 0
        local caught = blocked and not dodged and resources and recovered and unpaired and not target.attack_started and not target.dodge_started

        if caught then
            fighter.attack_result = "Caught"
            fighter.chain_count, fighter.chain_until = 0, 0
            table.insert(contacts, {attacker = index, target = fighter.target, blocked = true, dodged = false, perfect = false, counter = false, caught = true, kind = fighter.attack_kind, capture_move = response.capture_move})
            continue
        end

        fighter.attack_result = if dodged then "Dodged" elseif blocked then "Blocked" else "Hit"

        local move = MoveDefinitions.Get(fighter.fighter_id, fighter.attack_kind)

        if move.refresh_chain and not blocked and not dodged then
            fighter.chain_until = fighter.frame + move.chain_window
        else
            fighter.chain_count = 0
            fighter.chain_until = 0
        end

        fighter.attack_recovery = if blocked then fighter.attack_block_recovery elseif dodged then fighter.attack_dodge_recovery else fighter.attack_hit_recovery
        if fighter.exhaustion_pending then
            fighter.exhaustion_ready = fighter.attack_started + fighter.attack_startup + fighter.attack_active + fighter.attack_recovery
        end
        local outcome_cancels = move.cancels and move.cancels[fighter.attack_result]
        fighter.jab_ready = fighter.attack_started + fighter.attack_startup + fighter.attack_active + (if outcome_cancels and outcome_cancels.attack then outcome_cancels.attack else fighter.attack_recovery)
        fighter.attack_counter = (not active_move.pairing or (active_move.pairing.on_hit ~= "Capture" and not active_move.pairing.requires_control and active_move.pairing.reaction ~= "Takedown")) and not blocked and not dodged and target.state == "AttackStartup" and target.attack_started ~= nil and target.attack_damage > 0
        table.insert(contacts, {attacker = index, target = fighter.target, blocked = blocked, dodged = dodged, perfect = false, special = fighter.attack_special, kind = fighter.attack_kind, opening = move.opening_multiplier ~= nil and fighter.chain_count == 1, counter = fighter.attack_counter, grab = active_move.pairing ~= nil and active_move.pairing.on_hit == "Capture", shove = active_move.pairing ~= nil and (active_move.pairing.shove_frames or 0) > 0, takedown = active_move.pairing ~= nil and active_move.pairing.reaction == "Takedown", displacement = active_move.pairing and active_move.pairing.exit_motion and active_move.pairing.exit_motion.distance, throw_frames = active_move.pairing and active_move.pairing.exit_motion and active_move.pairing.exit_motion.frames})
    end


end

local function ResolveContacts(fighters, contacts, match_frame)
    for _, contact in contacts do
        local target = fighters[contact.target]
        local attacker = fighters[contact.attacker]
        local move = MoveDefinitions.Get(attacker.fighter_id, attacker.attack_kind)

        if contact.caught then
            local response = (MoveDefinitions[target.fighter_id] or MoveDefinitions.Boxing).guard_response
            SpendStamina(target, response.stamina, true)
            Pairing.Capture(fighters, contact.target, response.capture_move)
            target.jab_ready = math.max(target.jab_ready, target.frame + response.recovery_frames)
            target.guard_pressed_at = -1
            if target.exhaustion_pending then target.exhaustion_ready = target.frame + response.recovery_frames end
            continue
        elseif contact.dodged then
            continue
        elseif contact.grab and not contact.blocked then
            continue
        elseif contact.shove then
            Pairing.Confirm(fighters, contact, move, match_frame or attacker.frame)
            target.reaction_until = math.max(target.reaction_until, target.frame + move.pairing.shove_frames)
        elseif contact.blocked then
            target.block_meter = math.max(0, target.block_meter - attacker.attack_block_cost)
            target.block_regen_at = target.frame + BLOCK_REGEN_DELAY

            if target.block_meter <= 0 then
                StunFighter(target, GUARD_BREAK_STUN, "GuardBreak")
            else
                target.block_until = target.frame + BLOCKSTUN
                target.state = "Blockstun"
            end
        else
            contact.momentum = false

            if move.momentum_gain ~= 0 then
                local profile = MoveDefinitions[attacker.fighter_id] or MoveDefinitions.Boxing
                local gain = if contact.counter then profile.counter_momentum or 1 else 1
                attacker.momentum = if contact.special then 0 else math.min(MOMENTUM_MAX, attacker.momentum + gain)
            end

            target.health = math.max(0, target.health - (attacker.attack_damage * (if contact.opening then move.opening_multiplier else 1)) - (if contact.counter then COUNTER_DAMAGE else 0))
            target.attack_started = nil
            target.dodge_started = nil
            target.chain_count = 0
            target.chain_until = 0
            target.attack_result = "Interrupted"
            target.guard_pressed_at = -1
            target.jab_buffer_until = 0
            target.dodge_buffer_until = 0
            target.reaction_until = target.frame + HIT_REACTION
            Pairing.InterruptEscape(fighters, contact.target)
            target.state = if target.health <= 0 then "Knockout" elseif target.frame < target.stun_until then "Stunned" elseif target.guard_held then "Guard" else "HitReact"

            Pairing.Confirm(fighters, contact, move, match_frame or attacker.frame)
            if attacker.attack_target_stun > 0 and target.health > 0 then StunFighter(target, attacker.attack_target_stun, if contact.takedown then "Takedown" else attacker.attack_kind) end
        end
    end


end

local function ResolveExhaustion(fighters, match_frame)
    for _, fighter in fighters do
        if not fighter.exhaustion_pending or fighter.health <= 0 or fighter.attack_started or fighter.dodge_started or fighter.frame < fighter.exhaustion_ready then continue end
        local paired = fighter.paired_action
        if paired and (match_frame or fighter.frame) < paired.until_frame then continue end
        if fighter.frame < fighter.stun_until then continue end
        fighter.exhaustion_pending = false
        fighter.exhaustion_ready = 0
        local duration = fighter.exhaustion_stun_frames or EXHAUSTION_STUN
        fighter.exhaustion_stun_frames = EXHAUSTION_STUN
        StunFighter(fighter, duration, "Exhausted")
        Pairing.Release(fighters, fighter.clinch_holder or 0)
    end


end

function CombatSimulation.Step(fighters, match_frame: number?)
    local contacts = {}

    for index, fighter in fighters do
        AdvanceFighter(fighters, index, fighter, match_frame)
    end

    for _, fighter in fighters do
        if fighter.attack_started and fighter.frame - fighter.attack_started <= (fighter.attack_stage_offset or 0) + (fighter.attack_stage_startup or fighter.attack_startup) then
            fighter.attack_forward_x = -math.sin(fighter.yaw or -fighter.facing * math.pi * 0.5)
            fighter.attack_forward_z = -math.cos(fighter.yaw or -fighter.facing * math.pi * 0.5)
        end
    end

    ResolvePerfectDodges(fighters, contacts)

    CollectContacts(fighters, contacts)

    ResolveContacts(fighters, contacts, match_frame)

    Pairing.ResolveCaptures(fighters, contacts, StunFighter)
    Pairing.Step(fighters, SpendStamina)

    ResolveExhaustion(fighters, match_frame)

    return contacts
end

return CombatSimulation
