local MoveDefinitions = require(script.Parent.MoveDefinitions)

local AISimulation = {VERSION = 2}
AISimulation.DifficultyOrder = {"Easy", "Normal", "Hard"}
AISimulation.Difficulties = {
    Easy = {reaction_frames = 24, hit_reaction = 10, action_delay = 1.45, escape_delay = 16, max_chain = 1, guard_cycle = 180, guard_frames = 16},
    Normal = {reaction_frames = 12, hit_reaction = 6, action_delay = 1, escape_delay = 10, max_chain = 3, guard_cycle = 150, guard_frames = 24},
    Hard = {reaction_frames = 8, hit_reaction = 4, action_delay = 0.8, escape_delay = 8, max_chain = 3, guard_cycle = 120, guard_frames = 30},
}
local function CanUse(fighter, action, distance)
    local profile = MoveDefinitions[fighter.fighter_id] or MoveDefinitions.Boxing
    local name = if action == "clinch" then "ClinchGrab" else profile.inputs[action]
    local move = name and profile.moves[name]
    if not move or fighter.stamina <= move.stamina + 3 or fighter.momentum < (move.momentum or 0) then
        return false
    end
    if move.cooldown_key and fighter.frame < (fighter[move.cooldown_key] or 0) then
        return false
    end
    if move.clinch_only and fighter.clinch_holder ~= 1 then
        return false
    end
    -- Include lunge travel so grapplers can initiate before reaching grab range.
    local range = move.hitbox.range + (if move.lunge then move.lunge.distance else 0)
    return distance <= range - 0.15
end

local function Choose(fighter, command, action, now, delay)
    command[action] = true
    command.guard, command.axis, command.strafe = false, 0, 0
    fighter.ai.decision += 1
    fighter.ai.next_action = now + math.ceil(delay * fighter.ai.action_delay)
    return command
end

function AISimulation.Decide(fighter, opponent, now, difficulty_id)
    local difficulty = AISimulation.Difficulties[difficulty_id] or AISimulation.Difficulties.Normal
    local ai = fighter.ai
    if not ai then
        ai = {decision = 0, next_action = now + 18, rest_until = 0, guard_until = 0, responded = -1, countered = -1, chain_requested = -1, escape_at = 0, observations = {}}
        fighter.ai = ai
    end

    ai.action_delay = difficulty.action_delay
    -- Store delayed observations in fighter state so rollback repeats AI decisions.
    local index = now % difficulty.reaction_frames + 1
    local seen = ai.observations[index]
    local observed_move = opponent.attack_started and MoveDefinitions.Get(opponent.fighter_id, opponent.attack_kind)
    ai.observations[index] = {frame = now, guard_tag = observed_move and observed_move.guard_tag, age = opponent.attack_started and opponent.frame - opponent.attack_started - (opponent.attack_stage_offset or 0) or -1, startup = opponent.attack_stage_startup or opponent.attack_startup, state = opponent.state, attack = (opponent.attack_started or 0) * 8 + (opponent.attack_hit_index or 0), x = opponent.x, z = opponent.z}
    if seen then
        ai.seen = seen
    end
    seen = seen or ai.seen or {state = "Idle", attack = 0, x = opponent.x, z = opponent.z}
    local dx, dz = opponent.x - fighter.x, opponent.z - fighter.z
    local distance = math.sqrt(dx * dx + dz * dz)
    local profile = MoveDefinitions[fighter.fighter_id] or MoveDefinitions.Boxing
    local plan = profile.ai or MoveDefinitions.Boxing.ai
    local command = {axis = 0, strafe = 0, guard = false}

    if fighter.health <= 0 or fighter.frame < fighter.stun_until or now < (fighter.getup_until or 0) then
        return command
    end

    if fighter.frame < fighter.reaction_until then
        if ai.hit_react_until ~= fighter.reaction_until then
            ai.hit_react_until, ai.hit_guard_at = fighter.reaction_until, now + difficulty.hit_reaction
        end
        command.guard = fighter.block_meter > 30 and now >= ai.hit_guard_at
        return command
    end

    if (fighter.clinch_holder or 0) > 0 then
        if fighter.clinch_holder ~= 1 then
            command.guard = fighter.block_meter > 35
            if fighter.frame >= fighter.clinch_escape_ready and now >= ai.escape_at then
                command.clinch = true
                ai.escape_at = now + difficulty.escape_delay
            end
            return command
        end
        if fighter.attack_started then
            return command
        end
        if fighter.stamina < 22 then
            command.clinch = true; return command
        end
        local held = fighter.frame - (fighter.clinch_started or fighter.frame)
        local delay = plan.clinch_delays[ai.decision % #plan.clinch_delays + 1]
        if not fighter.attack_started and fighter.frame >= fighter.jab_ready and held >= delay and now >= ai.next_action then
            if profile.grappler and CanUse(fighter, "special", distance) then
                return Choose(fighter, command, "special", now, 48)
            end
            local move = profile.moves[profile.clinch_attack]
            if move and fighter.stamina > move.stamina + 3 then
                return Choose(fighter, command, "jab", now, plan.clinch_recovery)
            end
        end
        return command
    end

    if fighter.attack_started then
        if fighter.attack_result == "Hit" and fighter.state == "AttackRecovery" then
            local move = profile.moves[fighter.attack_kind]
            local followup = move.cancels and move.cancels.Hit and move.cancels.Hit.followups and move.cancels.Hit.followups[profile.inputs.special]
            local recovery_age = fighter.frame - fighter.attack_started - fighter.attack_startup - fighter.attack_active
            if difficulty.max_chain > 1 and followup and recovery_age >= followup.after and recovery_age < followup.after + followup.window and CanUse(fighter, "special", distance) then
                return Choose(fighter, command, "special", now, 42)
            end
            local max_chain = math.min(difficulty.max_chain, if ai.decision % 3 == 0 then 3 else 2)
            if move.advance_chain and fighter.chain_count < max_chain and ai.chain_requested ~= fighter.attack_started and fighter.frame >= fighter.jab_ready - 4 and CanUse(fighter, "jab", distance) then
                ai.chain_requested = fighter.attack_started
                return Choose(fighter, command, "jab", now, 36)
            end
        end
        return command
    end

    if fighter.dodge_started or fighter.frame < fighter.block_until or fighter.frame < (fighter.clinch_release_until or 0) then
        return command
    end

    local response = profile.guard_response
    if response and seen.state == "AttackStartup" and seen.guard_tag and response.tags[seen.guard_tag] and seen.attack ~= ai.catch_attempted and now >= fighter.guard_response_ready and now >= (fighter.clinch_ready or 0) and fighter.stamina >= response.stamina and fighter.block_meter > 0 and not fighter.exhaustion_pending and not fighter.guard_input_held and distance <= 6.5 then
        local remaining = seen.startup - (seen.age + now - seen.frame)
        if remaining >= 0 and remaining < response.window_frames then
            ai.catch_attempted = seen.attack
            ai.guard_until = now + response.window_frames
            command.guard = true
            return command
        elseif remaining >= response.window_frames then
            return command
        end
    end

    local special = profile.inputs.special and profile.moves[profile.inputs.special]
    local reserve = if fighter.momentum >= 3 and special then (if plan.special_reserve > 0 then plan.special_reserve else special.stamina + 12) else 28
    if fighter.stamina < reserve and not ai.resting then
        ai.resting = true
        ai.rest_until = now + 48
    end
    if ai.resting and fighter.stamina >= math.max(50, reserve + 10) and now >= ai.rest_until then
        ai.resting = false
    end
    if ai.resting then
        command.axis = if distance < 6.2 then -1 else 0
        command.guard = seen.state == "AttackStartup" and fighter.block_meter > 35 and distance < 6
        return command
    end

    local observed_distance = math.sqrt((seen.x - fighter.x)^2 + (seen.z - fighter.z)^2)
    if seen.state == "AttackStartup" and seen.attack ~= ai.responded and observed_distance < 6.5 then
        ai.responded = seen.attack
        local reaction_choice = (ai.decision + (if difficulty_id == "Easy" then 2 else 0)) % 5
        if reaction_choice == 2 and fighter.stamina > 23 and fighter.frame >= fighter.dodge_ready then
            return Choose(fighter, command, "dodge", now, 30)
        elseif reaction_choice ~= 4 and fighter.block_meter > 30 then
            ai.guard_until = now + 18
        end
    end

    if now < ai.guard_until then
        command.guard = fighter.block_meter > 25
        command.axis = if distance < plan.distance then -1 else 0
        return command
    end

    if seen.state == "GettingUp" or seen.state == "Knockdown" or seen.state == "BoutOver" then
        return command
    end

    if distance > plan.distance + 0.4 then command.axis = 1 elseif distance < plan.distance - 0.45 then command.axis = -1 end
    if command.axis == 0 and math.floor(now / 30) % 4 == 1 then command.strafe = if ai.decision % 2 == 0 then 1 else -1 end
    command.guard = fighter.block_meter > 40 and distance < 6 and now % difficulty.guard_cycle < difficulty.guard_frames

    if not profile.grappler and fighter.momentum >= 3 and special and distance > special.hitbox.range - 0.15 then
        command.axis = 1
        return command
    end

    if difficulty.max_chain > 1 and seen.state == "AttackRecovery" and seen.attack ~= ai.countered then
        local action
        for _, candidate in plan.counters do if CanUse(fighter, candidate, distance) then action = candidate; break end end
        if action then
            ai.countered = seen.attack
            return Choose(fighter, command, action, now, 42)
        end
    end

    if now < ai.next_action then
        return command
    end

    if not profile.grappler and fighter.momentum >= 3 and seen.state ~= "Guard" and CanUse(fighter, "special", distance) then
        return Choose(fighter, command, "special", now, 48)
    end
    if plan.guard_pressure and seen.state == "Guard" and CanUse(fighter, plan.guard_pressure, distance) then
        return Choose(fighter, command, plan.guard_pressure, now, 42)
    end

    for offset = 0, #plan.pattern - 1 do
        local action = plan.pattern[(ai.decision + offset) % #plan.pattern + 1]
        if CanUse(fighter, action, 0) then
            if not CanUse(fighter, action, distance) then
                command.axis = 1; return command
            end
            ai.decision += offset
            return Choose(fighter, command, action, now, 36 + ai.decision % 3 * 6)
        end
    end

    ai.next_action = now + 6
    return command
end

return AISimulation
