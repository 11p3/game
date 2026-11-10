local CombatSimulation = require(script.Parent.CombatSimulation)
local MoveDefinitions = require(script.Parent.MoveDefinitions)
local TrainingSimulation = require(script.Parent.TrainingSimulation)
local AISimulation = require(script.Parent.AISimulation)

local MatchSimulation = {VERSION = 7}
local Pairing = CombatSimulation.Pairing
local SIMULATION_HZ = 60
local BACKPEDAL_SPEED_MULTIPLIER = 0.6 -- Slow retreat to keep passive spacing from matching forward pressure.
local GUARD_SPEED_MULTIPLIER = 0.55 -- Trade footwork speed for the protection of holding guard.
local ADVANCE_BUFFER_FRAMES = 3
local DEFAULT_RING_LIMIT = 17
-- Round to 0.0001 studs and 0.000001 radians at simulation boundaries.
local POSITION_PRECISION = 10000
local YAW_PRECISION = 1000000
local KNOCKDOWNS_TO_LOSE = 3
-- Three seconds down first, then five seconds; the third knockdown loses.
local FIRST_COUNT_FRAMES = 180
local SECOND_COUNT_FRAMES = 300
local GETUP_RETREAT_MARGIN = 0.25
local RETREAT_SPEED = 9
local STEP = 1 / SIMULATION_HZ
local TAU = math.pi * 2
local MATCH_DURATION_FRAMES = 180 * SIMULATION_HZ
local WALL_SPLAT_STUN = 42
local WALL_SPLAT_COOLDOWN = 180 -- Three seconds between splats to prevent repeated wall locks.
local WALL_SPLAT_RECOVERY = 10

local function ClampPosition(config, x, z)
    x = math.clamp(x, config.left_limit, config.right_limit)
    z = math.clamp(z, config.back_limit or -DEFAULT_RING_LIMIT, config.front_limit or DEFAULT_RING_LIMIT)

    if config.ring_shape == "Octagon" then
        local center_x = (config.left_limit + config.right_limit) * 0.5
        local center_z = ((config.back_limit or -DEFAULT_RING_LIMIT) + (config.front_limit or DEFAULT_RING_LIMIT)) * 0.5
        local radius = math.min((config.right_limit - config.left_limit) * 0.5, ((config.front_limit or DEFAULT_RING_LIMIT) - (config.back_limit or -DEFAULT_RING_LIMIT)) * 0.5)
        local dx, dz = x - center_x, z - center_z
        local excess = math.max(0, math.abs(dx) + math.abs(dz) - radius * math.sqrt(2)) * 0.5

        x -= math.sign(dx) * excess
        z -= math.sign(dz) * excess
    end

    return math.round(x * POSITION_PRECISION) / POSITION_PRECISION, math.round(z * POSITION_PRECISION) / POSITION_PRECISION
end

local function CreateFighter(index, x, config, previous, restore_health)
    local fighter = CombatSimulation.CreateFighter()

    fighter.x = x
    fighter.y = 4
    fighter.z = if previous then previous.z else config.lane_z
    fighter.target = if index == 1 then 2 else 1
    fighter.fighter_id = if previous then previous.fighter_id elseif index == 1 then (config.npc_fighter_id or "Boxing") else (config.player_fighter_id or "Boxing")
    fighter.facing = if index == 1 then -1 else 1
    fighter.yaw = if fighter.facing > 0 then -math.pi * 0.5 else math.pi * 0.5
    fighter.side = if index == 1 then 1 else -1
    fighter.knockdowns = if previous then previous.knockdowns else 0
    fighter.getup_serial = if previous then previous.getup_serial + (if restore_health then 1 else 0) else 0
    fighter.jab_sequence = if previous then previous.jab_sequence else 0
    fighter.stats = if previous then table.clone(previous.stats) else {thrown = 0, landed = 0, damage_tenths = 0, perfect_dodges = 0}
    fighter.attack_id = 0
    fighter.attack_match_frame = 0
    fighter.hit_serial = if previous then previous.hit_serial else 0
    fighter.last_hit = if previous then previous.last_hit else {id = "", frame = 0, blocked = false, dodged = false, perfect = false, counter = false, momentum = false, opening = false}
    fighter.sidestep_until = 0
    fighter.sidestep_ready = 0
    fighter.sidestep_side = 0

    if previous and not restore_health then
        fighter.health = previous.health
    end

    if previous then
        local exhausted = previous.stun_reason == "Exhausted" and previous.frame < previous.stun_until
        if previous.exhaustion_pending or exhausted then
            fighter.stamina = previous.stamina
            fighter.exhaustion_pending = true
            fighter.exhaustion_ready = 0
            fighter.exhaustion_stun_frames = if exhausted then math.max(1, previous.stun_until - previous.frame) else previous.exhaustion_stun_frames or fighter.exhaustion_stun_frames
        end
    end

    return fighter
end

local function Emit(state, kind, fighter, data)
    local event = data or {}

    event.id = tostring(state.frame) .. ":" .. kind .. ":" .. tostring(fighter)
    event.frame = state.frame
    event.kind = kind
    event.fighter = fighter
    table.insert(state.events, event)

    return event
end

local function FinishBout(state, loser, reason)
    state.phase = "Finished"
    state.finished_frame = state.frame
    state.finish_reason = reason
    state.result = if loser == 0 then "Draw" elseif loser == 1 then "You win — " .. reason else "You lose — " .. reason
    state.downed = loser
    state.count = 0

    for index in state.fighters do
        CombatSimulation.ReleaseClinch(state.fighters, index)
    end

    for _, fighter in state.fighters do
        fighter.state = "BoutOver"
        fighter.guard_held = false
        fighter.attack_started = nil
        fighter.dodge_started = nil
        fighter.jab_buffer_until = 0
        fighter.dodge_buffer_until = 0
        fighter.busy = false
        fighter.sidestep_until = 0
    end

    Emit(state, "Finished", if loser == 0 then 1 else loser, {reason = reason})
end

local function JudgeBout(state)
    local first, second = state.fighters[1], state.fighters[2]
    local loser = 0

    if first.knockdowns ~= second.knockdowns then
        loser = if first.knockdowns > second.knockdowns then 1 else 2
    elseif first.stats.damage_tenths ~= second.stats.damage_tenths then
        loser = if first.stats.damage_tenths < second.stats.damage_tenths then 1 else 2
    end

    FinishBout(state, loser, "Decision")
end

local function Turn(fighter, other, response, frame)
    if frame < (fighter.throw_facing_until or 0) or frame < (fighter.getup_until or 0) then
        return
    end

    local target = math.atan2(fighter.x - other.x, fighter.z - other.z)
    local difference = (target - fighter.yaw + math.pi) % TAU - math.pi

    fighter.yaw = math.round(((fighter.yaw + difference * (1 - math.exp(-response * STEP)) + math.pi) % TAU - math.pi) * YAW_PRECISION) / YAW_PRECISION
end

local function KnockDown(state, index, config)
    local fighter = state.fighters[index]

    local other_index = if index == 1 then 2 else 1
    local opponent = state.fighters[other_index]
    state.double_down = opponent.health <= 0

    CombatSimulation.ReleaseClinch(state.fighters, fighter.clinch_holder or 0)

    fighter.knockdowns += 1
    fighter.state = "Knockdown"

    if state.double_down then
        opponent.knockdowns += 1
        opponent.state = "Knockdown"
    end

    if fighter.knockdowns >= KNOCKDOWNS_TO_LOSE or (state.double_down and opponent.knockdowns >= KNOCKDOWNS_TO_LOSE) then
        local loser = if fighter.knockdowns >= KNOCKDOWNS_TO_LOSE then index else other_index
        local draw = state.double_down and fighter.knockdowns >= KNOCKDOWNS_TO_LOSE and opponent.knockdowns >= KNOCKDOWNS_TO_LOSE
        FinishBout(state, if draw then 0 else loser, "TKO")

        return
    end

    state.phase = "Knockdown"
    state.downed = index
    state.knockdown_started = state.frame
    state.knockdown_duration = if fighter.knockdowns == 1 then FIRST_COUNT_FRAMES else SECOND_COUNT_FRAMES
    if state.double_down and opponent.knockdowns >= 2 then
        state.knockdown_duration = SECOND_COUNT_FRAMES
    end
    state.count = 1

    if state.double_down then
        for _, other in state.fighters do
            other.guard_held = false
            other.attack_started = nil
            other.dodge_started = nil
            other.jab_buffer_until = 0
            other.dodge_buffer_until = 0
        end

        Emit(state, "Knockdown", index)
        Emit(state, "Count", index, {count = 1})
        return
    end

    local standing = state.fighters[if index == 1 then 2 else 1]
    local best_distance = -1

    local targets = {}

    if config.ring_shape == "Octagon" then
        local center_x = (config.left_limit + config.right_limit) * 0.5
        local center_z = ((config.back_limit or -DEFAULT_RING_LIMIT) + (config.front_limit or DEFAULT_RING_LIMIT)) * 0.5
        local radius = math.min((config.right_limit - config.left_limit) * 0.5, ((config.front_limit or DEFAULT_RING_LIMIT) - (config.back_limit or -DEFAULT_RING_LIMIT)) * 0.5) / math.cos(math.pi / 8)

        for vertex = 0, 7 do
            local angle = math.pi / 8 + vertex * math.pi / 4

            table.insert(targets, {center_x + math.cos(angle) * radius, center_z + math.sin(angle) * radius})
        end
    else
        for _, x in {config.left_limit, config.right_limit} do
            for _, z in {config.back_limit or -DEFAULT_RING_LIMIT, config.front_limit or DEFAULT_RING_LIMIT} do
                table.insert(targets, {x, z})
            end
        end
    end

    for _, target in targets do
        local x, z = ClampPosition(config, target[1], target[2])
        local distance = (x - standing.x)^2 + (z - standing.z)^2

        if distance > best_distance then
            best_distance = distance
            state.retreat_target = x
            state.retreat_z = z
        end
    end

    state.retreat_speed = math.max(RETREAT_SPEED, math.sqrt(best_distance) / (state.knockdown_duration / SIMULATION_HZ - GETUP_RETREAT_MARGIN))

    for _, other in state.fighters do
        other.guard_held = false
        other.jab_requested = false
        other.dodge_requested = false
        other.jab_buffer_until = 0
        other.dodge_buffer_until = 0
        other.busy = false
        other.sidestep_until = 0
    end

    standing.state = "Retreating"
    Emit(state, "Knockdown", index)
    Emit(state, "Count", index, {count = 1})
end

function MatchSimulation.Create(config)
    return {
        frame = 0,
        fight_frames = 0,
        duration_frames = if config.training and not config.pvp then 0 else config.duration_frames or MATCH_DURATION_FRAMES,
        phase = "Fighting",
        count = 0,
        result = "",
        finish_reason = "",
        downed = 0,
        double_down = false,
        knockdown_started = 0,
        knockdown_duration = 0,
        retreat_target = 0,
        retreat_speed = RETREAT_SPEED,
        finished_frame = 0,
        opponent_turn_at = 0,
        fighters = {CreateFighter(1, if config.training and not config.pvp then 3 else 10, config), CreateFighter(2, if config.training and not config.pvp then -3 else -10, config)},
        training = if config.training and not config.pvp then TrainingSimulation.Create(config.npc_fighter_id) else nil,
        events = {}
    }
end

function MatchSimulation.Step(state, input, config)
    state.frame += 1
    state.events = {}

    local npc = state.fighters[1]
    local player = state.fighters[2]

    local player_input = input or {}
    local dummy_input

    if state.training then
        local reset
        player_input, dummy_input, reset = TrainingSimulation.Step(state.training, player_input, state.phase, math.sqrt((npc.x - player.x)^2 + (npc.z - player.z)^2))

        if reset then
            local settings = table.clone(config)
            settings.npc_fighter_id = state.training.dummy_style
            local fresh = MatchSimulation.Create(settings)

            for key, value in fresh do
                if key ~= "frame" and key ~= "training" and key ~= "events" then
                    state[key] = value
                end
            end

            npc, player = state.fighters[1], state.fighters[2]
        end

        TrainingSimulation.Restore(state.fighters, state.training)
    end

    Pairing.MoveThrows(state, config, ClampPosition)

    if state.phase == "Finished" then
        return state.events
    end

    if state.phase == "Knockdown" then
        local standing_index = if state.downed == 1 then 2 else 1
        local standing = state.fighters[standing_index]
        local downed = state.fighters[state.downed]
        local dx, dz = if state.double_down then 0 else state.retreat_target - standing.x, if state.double_down then 0 else state.retreat_z - standing.z
        local distance = math.sqrt(dx * dx + dz * dz)
        local travel = math.min(distance, state.retreat_speed * STEP)

        if not state.double_down and distance > 0.001 then
            standing.x = math.round((standing.x + dx / distance * travel) * 10000) / 10000
            standing.z = math.round((standing.z + dz / distance * travel) * 10000) / 10000
        end

        if not state.double_down then
            standing.state = if distance > 0.05 then "Retreating" else "Waiting"
            Turn(standing, downed, config.turn_response, state.frame)
        end

        local elapsed = state.frame - state.knockdown_started
        local count = math.min(math.floor(elapsed / SIMULATION_HZ) + 1, state.knockdown_duration / SIMULATION_HZ)

        if count ~= state.count then
            state.count = count
            Emit(state, "Count", state.downed, {count = count})
        end

        if elapsed >= state.knockdown_duration then
            for index, fighter in state.fighters do
                state.fighters[index] = CreateFighter(index, fighter.x, config, fighter, index == state.downed or state.double_down)
                if index == state.downed or state.double_down then
                    local recovering = state.fighters[index]
                    recovering.getup_started = state.frame
                    recovering.getup_until = state.frame + CombatSimulation.GetUpFrames
                    recovering.state = "GettingUp"
                    recovering.protected = true
                end
            end

            npc = state.fighters[1]
            player = state.fighters[2]
            npc.side = if npc.x < player.x then -1 else 1
            player.side = -npc.side
            npc.facing = if player.x >= npc.x then 1 else -1
            player.facing = -npc.facing
            npc.yaw = math.atan2(npc.x - player.x, npc.z - player.z)
            player.yaw = math.atan2(player.x - npc.x, player.z - npc.z)
            Emit(state, "GetUp", state.downed)
            if state.double_down then Emit(state, "GetUp", if state.downed == 1 then 2 else 1, {silent = true}) end
            state.double_down = false
            state.phase = "Fighting"
            state.count = 0
            state.downed = 0
            state.opponent_turn_at = state.frame
        end

        return state.events
    end

    for index, fighter in state.fighters do
        if fighter.health <= 0 then
            KnockDown(state, index, config)

            return state.events
        end
    end

    if not state.training and state.fight_frames >= state.duration_frames then
        JudgeBout(state)
        return state.events
    end

    if not state.training then
        state.fight_frames += 1
    end
    input = player_input

    local function Control(player, npc, input, index, speed_override)
    player.special_requested = input.special == true
    player.kick_requested = input.kick == true
    player.technique_requested = input.technique == true
    player.clinch_requested = input.clinch == true
    player.guard_held = input.guard == true
    player.jab_requested = input.jab == true
    player.dodge_requested = input.dodge == true

    if player.guard_held then
        player.jab_buffer_until = 0
        player.jab_requested = false
    end

    player.busy = false
    player.side = if player.x < npc.x then -1 else 1
    player.facing = -player.side

    local mobile = not player.exhaustion_pending and Pairing.Allows(player, "movement") and (player.clinch_holder or 0) == 0 and player.frame >= (player.clinch_release_until or 0) and player.frame >= player.block_until

    if mobile and player.frame >= player.stun_until and player.frame >= player.reaction_until then
        local dx, dz = npc.x - player.x, npc.z - player.z
        local distance = math.max(0.001, math.sqrt(dx * dx + dz * dz))
        local forward_x, forward_z = dx / distance, dz / distance
        local axis = math.clamp(input.axis or 0, -1, 1)

        local strafe = math.clamp(input.strafe or 0, -1, 1)
        if axis > 0 and not player.guard_held then
            player.advance_until = player.frame + ADVANCE_BUFFER_FRAMES
        elseif axis < 0 then
            player.advance_until = 0
        end

        local retreat = if axis < 0 then BACKPEDAL_SPEED_MULTIPLIER else 1
        local speed = (speed_override or config.walk_speed) * ((MoveDefinitions[player.fighter_id] or MoveDefinitions.Boxing).speed_multiplier or 1) * (if player.guard_held then GUARD_SPEED_MULTIPLIER else 1) * retreat / math.max(1, math.sqrt(axis * axis + strafe * strafe))
        local radius = math.max(config.spacing, distance - axis * speed * STEP)
        local angle = -strafe * speed * STEP / math.max(distance, config.spacing)
        local cosine, sine = math.cos(angle), math.sin(angle)
        local offset_x = -forward_x * radius
        local offset_z = -forward_z * radius

        player.x, player.z = ClampPosition(config, npc.x + offset_x * cosine - offset_z * sine, npc.z + offset_x * sine + offset_z * cosine)
    end

    Turn(player, npc, config.turn_response, state.frame)
    end

    Control(player, npc, input, 2)

    if config.pvp then
        Control(npc, player, {axis = input.axis_one or 0, strafe = input.strafe_one or 0, guard = input.guard_one, jab = input.jab_one, dodge = input.dodge_one, sidestep = input.sidestep_one, special = input.special_one, kick = input.kick_one, technique = input.technique_one, clinch = input.clinch_one}, 1)
    end

    local mode = if state.training then state.training.mode else config.practice_mode
    if dummy_input then
        Control(npc, player, dummy_input, 1)
    end

    if not config.pvp and not dummy_input and state.frame >= state.opponent_turn_at then
        local command = if mode == "Counter" then AISimulation.Decide(npc, player, state.frame, config.ai_difficulty) else {guard = mode == "Guard"}
        Control(npc, player, command, 1, config.npc_speed)
    end

    Pairing.MoveEntries(state, config, ClampPosition)

    for _ = 1, 2 do
        local dx, dz = player.x - npc.x, player.z - npc.z
        local distance = math.sqrt(dx * dx + dz * dz)

        if (player.clinch_holder or 0) == 0 and not player.throw_motion and not npc.throw_motion and distance < config.spacing and distance > 0.001 then
            local correction = (config.spacing - distance) * 0.5

            for index, fighter in state.fighters do
                local direction = if index == 2 then 1 else -1

                fighter.x, fighter.z = ClampPosition(config, fighter.x + dx / distance * correction * direction, fighter.z + dz / distance * correction * direction)
            end
        end
    end

    local old_health = {npc.health, player.health}
    local old_dodges = {npc.dodge_started, player.dodge_started}
    local contacts = CombatSimulation.Step(state.fighters, state.frame)

    Pairing.Align(state.fighters, config, ClampPosition)

    for index, fighter in state.fighters do
        if fighter.attack_started ~= fighter.last_attack or (fighter.attack_started and fighter.attack_hit_index ~= fighter.last_hit_index) then
            fighter.last_attack = fighter.attack_started
            fighter.last_hit_index = fighter.attack_hit_index

            if fighter.attack_started then
                fighter.jab_sequence += 1
                fighter.attack_id = state.frame
                fighter.attack_match_frame = state.frame
                if fighter.attack_damage > 0 then
                    fighter.stats.thrown += 1
                end
                Emit(state, "Attack", index, {attack_kind = fighter.attack_kind, variant = fighter.jab_sequence})
            end
        end

        if fighter.clinch_escape_press == fighter.frame and fighter.clinch_escape_started then
            Emit(state, "ClinchStruggle", index)
        end

        if fighter.dodge_started and fighter.dodge_started ~= old_dodges[index] then
            Emit(state, "Dodge", index)
        end
    end

    for contact_index, contact in contacts do
        if contact.grab and not contact.blocked then
            local attacker, target = state.fighters[contact.attacker], state.fighters[contact.target]
            if not contact.dodged and attacker.clinch_holder == contact.attacker and target.clinch_holder == contact.attacker and attacker.clinch_kind == contact.kind and target.clinch_started == target.frame then
                Emit(state, "Capture", contact.attacker, {target = contact.target, attacker = contact.attacker, attack_kind = contact.kind, fighter_id = attacker.fighter_id})
            end
            continue
        end
        local target = state.fighters[contact.target]
        local attacker = state.fighters[contact.attacker]
        if contact.caught then
            Emit(state, "Capture", contact.target, {target = contact.attacker, attacker = contact.target, attack_kind = contact.capture_move, fighter_id = target.fighter_id, caught = true})
        end
        contact.fighter_id = state.fighters[contact.attacker].fighter_id
        local event = Emit(state, "Contact", contact_index, {target = contact.target, attacker = contact.attacker, contact = contact})

        if contact.perfect then
            target.stats.perfect_dodges += 1
        elseif not contact.blocked and not contact.dodged and attacker.attack_damage > 0 then
            attacker.stats.landed += 1
            attacker.stats.damage_tenths += math.round(math.max(0, old_health[contact.target] - target.health) * 10)
        end

        contact.id = event.id
        contact.frame = state.frame
        target.hit_serial += 1
        target.last_hit = {
            id = event.id,
            frame = state.frame,
            blocked = contact.blocked == true,
            dodged = contact.dodged == true,
            perfect = contact.perfect == true,
            caught = contact.caught == true,
            counter = contact.counter == true,
            momentum = contact.momentum == true,
            opening = contact.opening == true,
            wall_splat = false
        }

        if not contact.dodged then
            local moved = if contact.blocked then attacker else target
            local move = MoveDefinitions.Get(attacker.fighter_id, contact.kind)
            local wall_move = move and move.wall_splat
            local can_splat = wall_move and (config.map_id or "Arena") == "Arena" and not contact.blocked and target.health > 0 and attacker.health > 0 and target.frame >= (target.wall_splat_ready or 0) and not target.throw_motion and not target.paired_action
            local offset = if contact.takedown then contact.displacement or 2 elseif contact.shove then 3.4 elseif contact.blocked then -0.3 else 0.65

            if can_splat then
                offset = wall_move.push
            end
            local desired_x, desired_z = moved.x + attacker.attack_forward_x * offset, moved.z + attacker.attack_forward_z * offset
            local x, z = ClampPosition(config, desired_x, desired_z)
            local wall_pressure = (desired_x - x) * attacker.attack_forward_x + (desired_z - z) * attacker.attack_forward_z

            if can_splat and wall_pressure > 0.15 then
                CombatSimulation.ReleaseClinch(state.fighters, target.clinch_holder or 0)
                CombatSimulation.StunFighter(target, WALL_SPLAT_STUN, "WallSplat")
                target.stun_reason = "WallSplat"
                target.wall_splat_ready = target.frame + WALL_SPLAT_COOLDOWN
                attacker.attack_recovery = math.min(attacker.attack_recovery, WALL_SPLAT_RECOVERY)
                attacker.jab_ready = math.min(attacker.jab_ready, attacker.frame + attacker.attack_active + WALL_SPLAT_RECOVERY)
                attacker.clinch_release_until = math.min(attacker.clinch_release_until or 0, attacker.jab_ready)
                contact.wall_splat = true
                target.last_hit.wall_splat = true
            end

            if contact.throw_frames and not contact.wall_splat then
                moved.throw_motion = {started = state.frame, frames = contact.throw_frames, from_x = moved.x, from_z = moved.z, to_x = x, to_z = z}
                moved.throw_facing_until = math.max(moved.throw_facing_until or 0, state.frame + contact.throw_frames)
                attacker.throw_facing_until = math.max(attacker.throw_facing_until or 0, state.frame + contact.throw_frames)
            else
                moved.x, moved.z = x, z
            end
            if contact.shove then
                attacker.x, attacker.z = ClampPosition(config, attacker.x - attacker.attack_forward_x * 1.4, attacker.z - attacker.attack_forward_z * 1.4)
            end
        end

    end

    if state.training then
        TrainingSimulation.Restore(state.fighters, state.training)
    end

    for index, fighter in state.fighters do
        if fighter.health <= 0 then
            KnockDown(state, index, config)
            break
        end
    end

    if not state.training and state.phase == "Fighting" and state.fight_frames >= state.duration_frames then
        JudgeBout(state)
    end

    return state.events
end

return MatchSimulation
