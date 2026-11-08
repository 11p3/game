local PairedActions = {}
local SIMULATION_HZ = 60
local INPUT_BUFFER_FRAMES = 6

function PairedActions.New(definitions)
    local Pairing = {}

    local function Profile(fighter)
        return definitions[fighter.fighter_id] or definitions.Boxing
    end

    local function Rules(fighters, index)
        local holder = fighters[index]
        local profile = Profile(holder)
        local move = profile.moves[holder.clinch_kind or ""]
        return move and move.pairing and move.pairing.control or profile.control
    end

    function Pairing.Release(fighters, holder_index)
        local holder = fighters[holder_index]
        if not holder or (holder.clinch_holder or 0) == 0 then
            return
        end

        local control = Rules(fighters, holder_index)

        for _, fighter in fighters do
            if fighter.clinch_holder == holder_index then
                local release_at = fighter.frame + control.release_frames
                if fighter.attack_started then
                    release_at = math.max(release_at, fighter.attack_started + fighter.attack_startup + fighter.attack_active + fighter.attack_recovery)
                end

                if not fighter.paired_action or not fighter.paired_action.confirmed then
                    fighter.paired_action = nil
                    fighter.throw_facing_until = 0
                end

                fighter.clinch_started = 0
                fighter.clinch_kind = nil
                fighter.clinch_reversals = 0
                fighter.clinch_holder = 0
                fighter.clinch_until = 0
                fighter.clinch_escape_until = 0
                fighter.clinch_escape_ready = 0
                fighter.clinch_escape_progress = 0
                fighter.clinch_escape_started = false
                fighter.clinch_escape_press = 0
                fighter.clinch_ready = math.max(fighter.clinch_ready or 0, fighter.frame + control.regrab_delay)
                fighter.attack_started = nil
                fighter.dodge_started = nil
                fighter.jab_buffer_until = 0
                fighter.dodge_buffer_until = 0
                fighter.queued_special = false
                fighter.queued_kick = false
                fighter.queued_technique = false
                fighter.queued_clinch = ""
                fighter.clinch_release_until = release_at
                fighter.state = if fighter.health <= 0 then "Knockout" elseif fighter.frame < fighter.stun_until then "Stunned" elseif fighter.frame < fighter.reaction_until then "HitReact" else "ClinchRelease"
            end
        end
    end

    function Pairing.Capture(fighters, holder_index, kind, duration, reversals)
        local holder = fighters[holder_index]
        local profile = Profile(holder)
        local move = profile.moves[kind]
        local control = move and move.pairing and move.pairing.control or profile.control
        for index, fighter in fighters do
            if index ~= holder_index and index ~= holder.target then
                continue
            end
            if index ~= holder_index then
                fighter.stun_until = 0
                fighter.stun_reason = ""
            end
            fighter.clinch_started = fighter.frame
            fighter.clinch_holder = holder_index
            fighter.clinch_kind = kind
            fighter.clinch_reversals = reversals or 0
            fighter.clinch_until = fighter.frame + (duration or control.duration)
            fighter.clinch_escape_until = 0
            fighter.clinch_escape_ready = fighter.frame + control.escape_delay
            fighter.clinch_escape_progress = 0
            fighter.clinch_escape_started = false
            fighter.clinch_escape_press = 0
            fighter.clinch_release_until = 0
            fighter.jab_ready = fighter.frame + control.action_delay
            fighter.attack_started = nil
            fighter.dodge_started = nil
            fighter.jab_buffer_until = 0
            fighter.dodge_buffer_until = 0
            fighter.queued_clinch = ""
            fighter.chain_count = 0
            fighter.chain_until = 0
            fighter.state = if fighter == holder then "ClinchControl" elseif fighter.guard_held then "Guard" else "ClinchHeld"
        end
    end

    function Pairing.Control(fighters, index, special, spend_stamina)
        local fighter = fighters[index]
        local profile = Profile(fighter)
        local frame = fighter.frame
        local controlling = fighter.clinch_holder == index
        local control = Rules(fighters, fighter.clinch_holder)
        local strike = fighter.jab_requested
        local release = fighter.dodge_requested or fighter.clinch_requested
        local clinch_special = fighter.special_requested and special and special.pairing and special.pairing.requires_control
        fighter.jab_requested, fighter.special_requested, fighter.kick_requested, fighter.technique_requested, fighter.dodge_requested = false, false, false, false, false
        if not controlling then
            fighter.jab_buffer_until = 0
        end
        fighter.dodge_buffer_until = 0

        if controlling then
            if release then
                Pairing.Release(fighters, index)
            elseif clinch_special then
                fighter.special_requested = true
            elseif strike and (not fighter.attack_started or (fighter.state == "AttackRecovery" and fighter.attack_started + fighter.attack_startup + fighter.attack_active + fighter.attack_recovery - frame <= INPUT_BUFFER_FRAMES)) then
                fighter.queued_clinch = profile.clinch_attack
                fighter.jab_requested = true
                fighter.guard_held = false
            end
        else
            if fighter.clinch_escape_until == 0 then
                fighter.clinch_escape_progress = math.max(0, fighter.clinch_escape_progress - control.escape_decay)
            end
            local fresh = frame - fighter.clinch_escape_press >= control.escape_tap_interval or (frame >= fighter.clinch_escape_ready and fighter.clinch_escape_press < fighter.clinch_escape_ready)
            if (release or strike) and fighter.clinch_escape_until == 0 and fresh and frame >= fighter.reaction_until and frame >= fighter.stun_until then
                fighter.clinch_escape_started, fighter.clinch_escape_press = true, frame
                if frame >= fighter.clinch_escape_ready then
                    fighter.clinch_escape_progress = math.min(control.escape_max, fighter.clinch_escape_progress + control.escape_gain)
                    if fighter.clinch_escape_progress == control.escape_max and spend_stamina(fighter, control.escape_cost) then
                        fighter.clinch_escape_until = frame + control.escape_startup
                    end
                end
            end
        end
    end

    function Pairing.ResolveCaptures(fighters, contacts, stun_fighter)
        for _, contact in contacts do
            if not contact.grab or contact.dodged or contact.blocked then
                continue
            end
            local attacker, target = fighters[contact.attacker], fighters[contact.target]
            local clash = false
            for _, other in contacts do
                if other.grab and not other.dodged and not other.blocked and other.attacker == contact.target then
                    clash = true
                end
            end
            if clash then
                attacker.attack_result = "Clash"
            elseif attacker.attack_started and attacker.health > 0 and target.health > 0 and attacker.frame >= attacker.stun_until and not target.protected and (attacker.clinch_holder or 0) == 0 and (target.clinch_holder or 0) == 0 then
                local guarding = target.state == "Guard" or target.state == "Blockstun"
                local kind = attacker.attack_kind
                Pairing.Capture(fighters, contact.attacker, kind)
                local control = Rules(fighters, contact.attacker)
                if guarding then
                    target.block_meter = math.max(0, target.block_meter - attacker.attack_block_cost)
                    target.block_regen_at = target.frame + control.block_regen_delay
                    if target.block_meter <= 0 then
                        stun_fighter(target, control.guard_break_stun, "GuardBreak")
                    end
                end
            end
        end
    end

    function Pairing.Step(fighters, spend_stamina)
        local processed
        for index, holder in fighters do
            if holder.clinch_holder ~= index or processed and processed[index] then
                continue
            end
            processed = processed or {}
            processed[index], processed[holder.target] = true, true
            local target = fighters[holder.target]
            local control = Rules(fighters, index)
            local interrupted = holder.health <= 0 or target.health <= 0 or (control.interrupt_holder_stun and holder.frame < holder.stun_until) or (control.interrupt_target_stun and target.frame < target.stun_until)
            local escaped = target.clinch_escape_until > 0 and target.frame >= target.clinch_escape_until
            local timed_out = holder.frame >= holder.clinch_until
            if not interrupted and not escaped and not timed_out then
                local holding = spend_stamina(holder, control.holder_drain / SIMULATION_HZ)
                local resisting = spend_stamina(target, control.held_drain / SIMULATION_HZ)
                interrupted = not holding or not resisting
            end
            if interrupted or escaped or timed_out then
                local escape = Profile(target).escape
                local reversals = holder.clinch_reversals or 0
                local reverse = escaped and not interrupted and escape.outcome == "Reverse" and reversals < escape.max_reversals
                Pairing.Release(fighters, index)
                if reverse then
                    Pairing.Capture(fighters, holder.target, "ClinchGrab", escape.reverse_duration, reversals + 1)
                end
            end
        end
    end

    function Pairing.EscapeProgress(fighters, index)
        local fighter = fighters[index]
        local holder = fighter.clinch_holder or 0
        if holder == 0 then
            return 0
        end
        return math.clamp(fighter.clinch_escape_progress / Rules(fighters, holder).escape_max, 0, 1)
    end

    function Pairing.InterruptEscape(fighters, index)
        local fighter = fighters[index]
        local holder = fighter.clinch_holder or 0
        if holder == 0 then
            return
        end
        fighter.clinch_escape_until = 0
        fighter.clinch_escape_progress = math.max(0, fighter.clinch_escape_progress - Rules(fighters, holder).escape_hit_penalty)
    end

    function Pairing.Begin(fighters, index, move, frame)
        local fighter = fighters[index]
        local pair = move.pairing
        if not pair or not pair.victim or fighter.clinch_holder ~= index then
            return
        end
        local target = fighters[fighter.target]
        local until_frame = frame + fighter.attack_startup + fighter.attack_active + math.max(fighter.attack_target_stun, fighter.attack_recovery)
        target.paired_action = {attacker = index, kind = fighter.attack_kind, animation = pair.victim.animation, started = frame, until_frame = until_frame, origin_x = target.x, origin_z = target.z, confirmed = false}
        if pair.victim.lock_facing then
            target.yaw = math.atan2(fighter.attack_forward_x, fighter.attack_forward_z)
            target.throw_facing_until = until_frame
            fighter.throw_facing_until = frame + fighter.attack_startup + fighter.attack_active + fighter.attack_hit_recovery
        end
    end

    function Pairing.Confirm(fighters, contact, move, frame)
        local attacker, target = fighters[contact.attacker], fighters[contact.target]
        local pair = move.pairing
        if not pair then
            return
        end
        if target.paired_action and target.paired_action.attacker == contact.attacker and target.paired_action.kind == attacker.attack_kind then
            target.paired_action.confirmed = true
            target.paired_action.until_frame = frame + math.max(attacker.attack_target_stun, attacker.attack_hit_recovery)
            if pair.victim.lock_facing then
                target.throw_facing_until = target.paired_action.until_frame
            end
        end
        if pair.on_hit == "Release" then
            Pairing.Release(fighters, contact.attacker)
        end
    end

    function Pairing.Allows(fighter, action)
        if not fighter.attack_started then
            return fighter.state == "Idle" or fighter.state == "Guard"
        end
        local move = Profile(fighter).moves[fighter.attack_kind]
        local stage = definitions.Phase(fighter.frame - fighter.attack_started, fighter.attack_startup, fighter.attack_active, move)
        local phase = if stage == "AttackStartup" then "startup" elseif stage == "AttackActive" then "active" else "recovery"
        return move.permissions[phase][action] == true
    end

    function Pairing.Align(fighters, config, clamp_position)
        local holder_index = fighters[1].clinch_holder or 0
        if holder_index == 0 then
            return
        end
        local first, second = fighters[1], fighters[2]
        local dx, dz = second.x - first.x, second.z - first.z
        local distance = math.sqrt(dx * dx + dz * dz)
        local spacing = Rules(fighters, holder_index).distance
        if distance > spacing then
            local shift = (distance - spacing) * 0.5
            first.x, first.z = clamp_position(config, first.x + dx / distance * shift, first.z + dz / distance * shift)
            second.x, second.z = clamp_position(config, second.x - dx / distance * shift, second.z - dz / distance * shift)
        end
    end

    function Pairing.MoveEntries(state, config, clamp_position)
        for _, fighter in state.fighters do
            local move = fighter.attack_started and definitions.Get(fighter.fighter_id, fighter.attack_kind)
            local lunge = move and move.pairing and move.pairing.entry_motion
            if not lunge and move and fighter.attack_advancing then
                lunge = move.advance
            end

            if lunge and fighter.health > 0 and fighter.frame >= fighter.stun_until and fighter.frame >= fighter.reaction_until and (fighter.clinch_holder or 0) == 0 and (fighter.state == "AttackStartup" or fighter.state == "AttackActive") then
                local age = fighter.frame + 1 - fighter.attack_started
                local frames = if fighter.attack_advancing then math.min(lunge.frames, fighter.attack_startup) else lunge.frames
                local progress = math.clamp(age / frames, 0, 1)
                local previous = math.clamp((age - 1) / frames, 0, 1)
                local travel = lunge.distance * (progress * progress * (3 - 2 * progress) - previous * previous * (3 - 2 * previous))
                local forward_x, forward_z = fighter.lunge_forward_x, fighter.lunge_forward_z
                local other = state.fighters[fighter.target]
                local dx, dz = other.x - fighter.x, other.z - fighter.z
                local projected = dx * forward_x + dz * forward_z
                local lateral_squared = math.max(0, dx * dx + dz * dz - projected * projected)

                if projected > 0 and lateral_squared < config.spacing * config.spacing then
                    travel = math.min(travel, math.max(0, projected - math.sqrt(config.spacing * config.spacing - lateral_squared)))
                end

                fighter.x, fighter.z = clamp_position(config, fighter.x + forward_x * travel, fighter.z + forward_z * travel)
            end
        end
    end

    function Pairing.MoveThrows(state, config, clamp_position)
        for _, fighter in state.fighters do
            local motion = fighter.throw_motion

            if motion then
                local progress = math.clamp((state.frame - motion.started) / motion.frames, 0, 1)
                local eased = progress * progress * (3 - 2 * progress)
                fighter.x, fighter.z = clamp_position(config, motion.from_x + (motion.to_x - motion.from_x) * eased, motion.from_z + (motion.to_z - motion.from_z) * eased)

                if progress >= 1 then
                    fighter.throw_motion = nil
                end
            end
        end
    end

    return Pairing
end

return PairedActions
