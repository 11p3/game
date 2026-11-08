local HIT_FEEDBACK = {
    sound = "PunchImpact",
    volume = 0.65,
    pitch = 1.04,
    shake_dealt = 0.22,
    shake_taken = 0.28,
    shake_time = 0.16,
    recoil = 7,
    flash = {255, 235, 215},
    flash_alpha = 0.45,
    flash_time = 0.12,
    fov_time = 0
}
local COUNTER_FEEDBACK = {
    volume_multiplier = 1.2,
    pitch_multiplier = 0.92,
    shake_multiplier = 1.3,
    recoil_multiplier = 1.25,
    shake_extension = 0.04,
    max_volume = 1.4,
    max_shake = 0.7,
    max_shake_time = 0.35,
    flash_alpha = 0.3,
    flash_time = 0.16
}
local FEEDBACK_OUTCOMES = {
    Opening = {pitch = 0.94},
    Counter = {pitch = 0.95, flash = {255, 185, 120}},
    Momentum = {volume = 0.9, shake_dealt = 0.45, shake_taken = 0.45, shake_time = 0.26, flash = {255, 193, 90}},
    WallSplat = {volume = 1.05, pitch = 0.8, shake_dealt = 0.6, shake_taken = 0.6, shake_time = 0.3, recoil = -10, flash = {255, 218, 155}, flash_time = 0.18},
    Blocked = {
        sound = "BlockImpact",
        volume = 0.42,
        pitch = 1.15,
        shake_dealt = 0.08,
        shake_taken = 0.08,
        shake_time = 0.1,
        recoil = 3.5,
        flash = {125, 180, 230},
        flash_alpha = 0.7,
        fov_time = 0
    },
    Perfect = {flash = {140, 220, 245}},
    Caught = {sound = "BlockImpact", volume = 0.65, pitch = 0.8, shake_dealt = 0.2, shake_taken = 0.2, shake_time = 0.18, recoil = 0, flash = {220, 220, 190}},
}
local DEFAULT_AI = {distance = 3.6, pattern = {"jab", "technique", "jab", "jab", "clinch"}, counters = {"jab"}, clinch_delays = {30}, clinch_recovery = 36, special_reserve = 0}
local FEEDBACK = {
    Punch = {Release = {sound = "Whoosh", volume = 0.22, pitch = 1.3}},
    Feint = {Release = false},
    LeadHook = {
        Hit = {volume = 0.78, pitch = 0.94, shake_dealt = 0.3, shake_taken = 0.32, shake_time = 0.2, recoil = 9},
        Counter = {volume = 0.86, pitch = 0.86, shake_dealt = 0.4, shake_taken = 0.4},
        Release = {sound = "Whoosh", volume = 0.28, pitch = 1.05}
    },
    Gut = {
        Hit = {sound = "BodyImpact", volume = 0.9, pitch = 0.85, shake_dealt = 0.4, shake_taken = 0.4, shake_time = 0.24, recoil = -12, flash = {255, 190, 110}, fov_time = 0.3},
        Counter = {pitch = 0.85},
        Release = {sound = "Whoosh", volume = 0.22, pitch = 0.85}
    },
    LowKick = {Hit = {sound = "BodyImpact", volume = 0.78, pitch = 1.08, shake_dealt = 0.26, shake_taken = 0.26, recoil = 4.5}, Release = {sound = "Whoosh", volume = 0.4, pitch = 0.8}},
    BodyKick = {Hit = {sound = "BodyImpact", volume = 0.78, pitch = 0.9, shake_dealt = 0.34, shake_taken = 0.34, recoil = 9}, Release = {sound = "Whoosh", volume = 0.4, pitch = 0.8}},
    Knee = {Hit = {sound = "BodyImpact", volume = 0.9, pitch = 1, shake_dealt = 0.32, shake_taken = 0.32, recoil = 8, flash = {255, 190, 110}}, Release = {sound = "Whoosh", volume = 0.22, pitch = 0.95}},
    ClinchKnee = {Hit = {sound = "BodyImpact", volume = 0.76, pitch = 1, shake_dealt = 0.32, shake_taken = 0.32, recoil = 8}, Release = {sound = "Whoosh", volume = 0.22, pitch = 0.95}},
    Grapple = {Release = {sound = "Whoosh", volume = 0.28, pitch = 0.7}},
    Takedown = {
        Hit = {sound = "MatImpact", volume = 0.9, pitch = 0.95, shake_dealt = 0.4, shake_taken = 0.4, shake_time = 0.24, recoil = 0},
        WallSplat = {sound = "PunchImpact"},
        Release = {sound = "Whoosh", volume = 0.28, pitch = 0.7}
    },
    Suplex = {Hit = {sound = "MatImpact", volume = 1.3, pitch = 0.68, layers = {{sound = "BodyImpact", volume = 0.65, pitch = 0.8}}, shake_dealt = 0.65, shake_taken = 0.65, shake_time = 0.42, recoil = 0, flash = {255, 190, 110}}, Release = {sound = "Whoosh", volume = 0.28, pitch = 0.7}},
}

local MoveDefinitions = {
    VERSION = 12,
    SIMULATION_VERSION = 8,
    Boxing = {
        inputs = {jab = "Jab", kick = "LeadHook", special = "GutPunch", technique = "Feint"},
        clinch_attack = "ClinchShove",
        counter_momentum = 2,
        speed_multiplier = 1,
        ai = {distance = 3.6, pattern = {"jab", "technique", "jab", "kick", "jab", "clinch"}, counters = {"kick", "jab"}, clinch_delays = {30}, clinch_recovery = 36, special_reserve = 0},
        moves = {
            Jab = {
                advance = {distance = 1.8, frames = 14},
                feedback = FEEDBACK.Punch,
                animation = "Jab", animation_mode = "Phased", animation_fallback = "Jab",
                timeline = {startup = {18, 10, 6}, active = 3, recovery = {Hit = 7, Whiff = 24, Blocked = 24, Dodged = 24}},
                hitbox = {range = 5, half_width = 2.2, height = 2.5},
                damage = 8, stamina = 12, chain_stamina = {12, 13, 14}, block_cost = 25, target_stun = 0,
                chain_start = 1, advance_chain = true, refresh_chain = true, chain_window = 45, opening_multiplier = 1.3,
                cancels = {Hit = {guard = 0, dodge = 0, attack = 4, followups = {GutPunch = {after = 4, window = 3, startup = 6, counter_startup = 4}}}},
            },
            LeadHook = {
                advance = {distance = 1.1, frames = 10},
                feedback = FEEDBACK.LeadHook,
                animation = "LeadHook", animation_mode = "Natural",
                timeline = {startup = {14}, active = 3, recovery = {Hit = 20, Whiff = 32, Blocked = 30, Dodged = 32}},
                hitbox = {range = 5.5, half_width = 3.3, height = 2.5},
                damage = 12, stamina = 20, block_cost = 30, target_stun = 0, perfect_frames = 8,
                cooldown_key = "cooldown_lead_hook", cooldown_frames = 60,
            },
            Feint = {
                feedback = FEEDBACK.Feint,
                animation = "Feint", animation_mode = "Natural", animation_fallback = "Jab", fallback_animation_mode = "Feint", feint = true,
                timeline = {startup = {10}, active = 1, recovery = {Hit = 12, Whiff = 12, Blocked = 12, Dodged = 12}},
                hitbox = {range = 5, half_width = 2.2, height = 2.5},
                damage = 0, stamina = 8, block_cost = 0, target_stun = 0,
                cooldown_key = "feint_ready", cooldown_frames = 72, perfect_dodge = false,
            },
            GutPunch = {
                advance = {distance = 0.9, frames = 8},
                feedback = FEEDBACK.Gut,
                animation = "GutPunch", animation_mode = "Natural", animation_fallback = "Jab", wall_splat = {push = 2.4},
                timeline = {startup = {12}, active = 3, recovery = {Hit = 18, Whiff = 30, Blocked = 30, Dodged = 30}},
                hitbox = {range = 5, half_width = 2.2, height = 2.5},
                damage = 24, stamina = 24, block_cost = 35, target_stun = 60, momentum = 3, perfect_frames = 13,
                chain_start = 1, refresh_chain = true, chain_window = 45,
            },
        },
    },
    MuayThai = {
        inputs = {jab = "Jab", kick = "LowKick", special = "Knee", technique = "BodyKick"},
        clinch_attack = "ClinchKnee",
        speed_multiplier = 0.92,
        ai = {
            distance = 4.8,
            pattern = {"kick", "jab", "technique", "clinch", "jab"},
            counters = {"kick", "jab"},
            guard_pressure = "technique",
            clinch_delays = {30},
            clinch_recovery = 36,
            special_reserve = 0
        },
        moves = {
            Jab = {
                advance = {distance = 2, frames = 16},
                feedback = FEEDBACK.Punch,
                animation = "Jab", animation_mode = "Phased", animation_fallback = "Jab",
                timeline = {startup = {20, 13, 10}, active = 3, recovery = {Hit = 9, Whiff = 22, Blocked = 24, Dodged = 22}},
                hitbox = {range = 5.3, half_width = 2.2, height = 2.5},
                damage = 8, stamina = 12, chain_stamina = {12, 13, 14}, block_cost = 25, target_stun = 0,
                chain_start = 1, advance_chain = true, refresh_chain = true, chain_window = 45, opening_multiplier = 1.3,
                cancels = {Hit = {guard = 0, dodge = 0, attack = 6}},
            },
            BodyKick = {
                advance = {distance = 0.8, frames = 12},
                feedback = FEEDBACK.BodyKick,
                animation = "BodyKick", animation_mode = "Natural", guard_tag = "Kick", animation_fallback = "LowKick", uses_legs = true, wall_splat = {push = 2.8},
                timeline = {startup = {16}, active = 4, recovery = {Hit = 18, Whiff = 34, Blocked = 36, Dodged = 34}},
                hitbox = {range = 6.2, half_width = 2.6, height = 2.5},
                damage = 16, stamina = 24, block_cost = 40, target_stun = 0, perfect_frames = 9,
                cooldown_key = "body_kick_ready", cooldown_frames = 90,
                cancels = {Hit = {followups = {Knee = {after = 8, window = 8, startup = 8}}}},
            },
            LowKick = {
                advance = {distance = 0.6, frames = 8},
                feedback = FEEDBACK.LowKick,
                animation = "LowKick", animation_mode = "Natural", guard_tag = "Kick", uses_legs = true,
                timeline = {startup = {10}, active = 4, recovery = {Hit = 18, Whiff = 28, Blocked = 30, Dodged = 28}},
                hitbox = {range = 6, half_width = 2.4, height = 2.5},
                damage = 10, stamina = 18, block_cost = 24, target_stun = 0, perfect_frames = 8,
                cooldown_key = "kick_ready", cooldown_frames = 72,
                cancels = {Hit = {followups = {Knee = {after = 8, window = 6, startup = 8}}}, Blocked = {attack = 24}},
            },
            Knee = {
                advance = {distance = 0.8, frames = 8},
                feedback = FEEDBACK.Knee,
                animation = "Knee", animation_mode = "Natural", uses_legs = true,
                timeline = {
                    startup = {12},
                    active = 20,
                    hits = {{offset = 0, active = 4, damage = 14, block_cost = 20, target_stun = 0, perfect_frames = 10}, {offset = 16, active = 4, damage = 14, block_cost = 20, target_stun = 45, perfect_frames = 8}},
                    recovery = {Hit = 22, Whiff = 34, Blocked = 36, Dodged = 34}
                },
                hitbox = {range = 5.2, half_width = 2.8, height = 2.5},
                damage = 28, stamina = 28, block_cost = 40, target_stun = 45, momentum = 3, perfect_frames = 10,
            },
        },
    },
    Wrestling = {
        inputs = {jab = "Jab", kick = "SingleLeg", special = "Suplex", technique = "Shoot"},
        clinch_attack = "ClinchTrip",
        grappler = true, clinch_duration = 180, clinch_drain = 6,
        escape = {outcome = "Reverse", reverse_duration = 90, max_reversals = 1},
        speed_multiplier = 1,
        ai = {distance = 3.2, pattern = {"technique", "jab", "kick", "clinch"}, counters = {"jab"}, clinch_delays = {54, 78}, clinch_recovery = 48, special_reserve = 65},
        moves = {
            Jab = {
                advance = {distance = 2.2, frames = 15},
                feedback = FEEDBACK.Punch,
                animation = "Jab", animation_mode = "Phased", animation_fallback = "Jab",
                timeline = {startup = {19, 12, 9}, active = 3, recovery = {Hit = 10, Whiff = 22, Blocked = 24, Dodged = 22}},
                hitbox = {range = 4.6, half_width = 2.2, height = 2.5},
                damage = 6, stamina = 11, chain_stamina = {11, 12, 13}, block_cost = 18, target_stun = 0,
                chain_start = 1, advance_chain = true, refresh_chain = true, chain_window = 45, opening_multiplier = 1.3,
                cancels = {Hit = {guard = 0, dodge = 0, attack = 6}},
            },
            ClinchGrab = {
                advance = {distance = 0.9, frames = 10},
                feedback = FEEDBACK.Punch,
                animation = "ClinchGrab", animation_mode = "Natural", pairing = {on_hit = "Capture", guard = "Bypass"}, perfect_dodge = false,
                timeline = {startup = {14}, active = 3, recovery = {Hit = 12, Whiff = 28, Blocked = 28, Dodged = 28}},
                hitbox = {range = 7, half_width = 3.4, height = 2.5},
                damage = 0, stamina = 14, block_cost = 40, momentum_gain = 0,
                cooldown_key = "clinch_ready", cooldown_frames = 120,
            },
            Shoot = {
                feedback = FEEDBACK.Grapple,
                animation = "Shoot", animation_mode = "Natural", animation_fallback = "ClinchGrab", uses_legs = true, pairing = {on_hit = "Capture", guard = "Block", entry_motion = {distance = 5.4, frames = 16}},
                timeline = {startup = {16}, active = 3, recovery = {Hit = 12, Whiff = 34, Blocked = 34, Dodged = 34}},
                hitbox = {range = 4.2, half_width = 2.8, height = 2.5},
                damage = 0, stamina = 20, block_cost = 40, momentum_gain = 0, perfect_frames = 10,
                cooldown_key = "shoot_ready", cooldown_frames = 150,
            },
            SingleLeg = {
                advance = {distance = 1.2, frames = 12},
                feedback = FEEDBACK.Takedown,
                animation = "SingleLeg", animation_mode = "Natural", animation_fallback = "ClinchGrab", uses_legs = true, pairing = {on_hit = "Release", guard = "Bypass", reaction = "Takedown", exit_motion = {distance = 2.4, frames = 8}}, wall_splat = {push = 2.4},
                timeline = {startup = {18}, active = 3, recovery = {Hit = 22, Whiff = 40, Blocked = 40, Dodged = 40}},
                hitbox = {range = 5.4, half_width = 2.8, height = 2.5},
                damage = 12, stamina = 24, block_cost = 0, target_stun = 36, perfect_frames = 12,
                cooldown_key = "takedown_ready", cooldown_frames = 150,
            },
            ClinchTrip = {
                feedback = FEEDBACK.Takedown,
                animation = "ClinchTrip", animation_mode = "Natural", animation_fallback = "ClinchGrab", uses_legs = true, pairing = {requires_control = true, on_hit = "Release", guard = "Bypass", reaction = "Takedown", exit_motion = {distance = 2, frames = 6}}, wall_splat = {push = 2.8},
                timeline = {startup = {16}, active = 2, recovery = {Hit = 20, Whiff = 28, Blocked = 28, Dodged = 28}},
                hitbox = {range = 4.2, half_width = 2.4, height = 2.5},
                damage = 14, stamina = 16, block_cost = 0, target_stun = 36, perfect_dodge = false,
            },
            Suplex = {
                feedback = FEEDBACK.Suplex,
                animation = "Suplex", animation_mode = "Natural", animation_fallback = "ClinchGrab", uses_legs = true,
                pairing = {requires_control = true, on_hit = "Release", guard = "Bypass", reaction = "Takedown", exit_motion = {distance = -6, frames = 18}, victim = {animation = "SuplexVictim", lock_facing = true}},
                timeline = {startup = {24}, active = 2, recovery = {Hit = 28, Whiff = 38, Blocked = 38, Dodged = 38}},
                hitbox = {range = 4.2, half_width = 2.5, height = 2.5},
                damage = 30, stamina = 30, block_cost = 0, target_stun = 72, momentum = 3, perfect_dodge = false,
            },
        },
    },
}

local CONTROL_DEFAULTS = {
    duration = 150,
    distance = 2.7,
    action_delay = 6,
    release_frames = 12,
    regrab_delay = 90,
    holder_drain = 8,
    held_drain = 2,
    escape_delay = 30, -- Half a second before the held fighter can escape.
    escape_startup = 18,
    escape_cost = 20,
    escape_gain = 400, -- Three paced taps can fill 1000 despite the decay between taps.
    escape_decay = 2,
    escape_max = 1000,
    escape_hit_penalty = 250,
    escape_tap_interval = 6,
    block_regen_delay = 120,
    guard_break_stun = 72,
    interrupt_holder_stun = true,
    interrupt_target_stun = true
}
local LOCKED_PHASE = {movement = false, guard = false, dodge = false}
local MAX_RESOURCE = 100
local MAX_MOMENTUM = 3
local MIN_HITBOX_SIZE = 0.001
-- Cap strike advances to three studs over at most half a second.
local MAX_ADVANCE_DISTANCE = 3
local MAX_ADVANCE_FRAMES = 30
local INPUT_ACTIONS = {jab = true, special = true, kick = true, technique = true}
local ANIMATION_MODES = {Natural = true, Phased = true, Feint = true}
-- Only these fields may receive cooldowns, so a definition cannot overwrite health.
local COOLDOWN_KEYS = {feint_ready = true, body_kick_ready = true, kick_ready = true, shoot_ready = true, takedown_ready = true, clinch_ready = true}

local function PrepareAI(profile)
    if profile.ai ~= nil and type(profile.ai) ~= "table" then
        return nil
    end

    local plan = table.clone(DEFAULT_AI)
    for key, value in profile.ai or {} do
        plan[key] = value
    end

    for _, key in {"pattern", "counters"} do
        if profile.ai and profile.ai[key] ~= nil then
            continue
        end
        local actions = {}
        for _, action in DEFAULT_AI[key] do
            if action == "clinch" or profile.inputs[action] ~= nil then
                table.insert(actions, action)
            end
        end
        plan[key] = actions
    end

    return plan
end

-- Freeze nested rules so players, AI and replays cannot mutate shared definitions.
local function Freeze(value)
    if table.isfrozen(value) then
        return value
    end

    for _, child in value do
        if type(child) == "table" then
            Freeze(child)
        end
    end

    return table.freeze(value)
end

function MoveDefinitions.Get(fighter_id: string, move_id: string)
    local profile = MoveDefinitions[fighter_id] or MoveDefinitions.Boxing

    return profile.moves[move_id]
end

function MoveDefinitions.GetFeedback(fighter_id: string, move_id: string, context)
    local move = MoveDefinitions.Get(fighter_id, move_id)
    local data = if move and move.feedback then move.feedback else FEEDBACK.Punch
    local result = table.clone(HIT_FEEDBACK)
    for key, value in data.Hit or {} do
        result[key] = value
    end
    for _, outcome in {"Opening", "Counter", "Momentum", "WallSplat", "Blocked", "Perfect", "Caught"} do
        if context and context[outcome] then
            for key, value in FEEDBACK_OUTCOMES[outcome] do
                result[key] = value
            end
            if outcome == "Counter" and not context.Blocked and not context.Perfect then
                result.volume = math.min(result.volume * COUNTER_FEEDBACK.volume_multiplier, COUNTER_FEEDBACK.max_volume)
                result.pitch *= COUNTER_FEEDBACK.pitch_multiplier
                result.shake_dealt = math.min(result.shake_dealt * COUNTER_FEEDBACK.shake_multiplier, COUNTER_FEEDBACK.max_shake)
                result.shake_taken = math.min(result.shake_taken * COUNTER_FEEDBACK.shake_multiplier, COUNTER_FEEDBACK.max_shake)
                result.shake_time = math.min(result.shake_time + COUNTER_FEEDBACK.shake_extension, COUNTER_FEEDBACK.max_shake_time)
                result.recoil *= COUNTER_FEEDBACK.recoil_multiplier
                result.flash_alpha = math.min(result.flash_alpha, COUNTER_FEEDBACK.flash_alpha)
                result.flash_time = math.max(result.flash_time, COUNTER_FEEDBACK.flash_time)
            end
            for key, value in data[outcome] or {} do
                result[key] = value
            end
        end
    end
    return result
end

function MoveDefinitions.Phase(age: number, startup: number, active: number, move)
    if not move then
        return if age < startup then "AttackStartup" elseif age < startup + active then "AttackActive" else "AttackRecovery"
    end

    local hits = move.timeline.hits
    local stage_offset = 0

    for index, hit in hits do
        local release = startup + hit.offset
        local windup = release - stage_offset

        if age < release then
            return "AttackStartup", index, stage_offset, windup
        end
        if age < release + hit.active then
            return "AttackActive", index, stage_offset, windup
        end
        if index == #hits then
            return "AttackRecovery", index, stage_offset, windup
        end

        stage_offset = release + hit.active
    end
end

local GUARD_RESPONSE = {tags = {Kick = true}, window_frames = 8, stamina = 16, cooldown_frames = 120, recovery_frames = 12, capture_move = "ClinchGrab"}

local CLINCH_GRAB = {
    advance = {distance = 0.9, frames = 10},
    feedback = FEEDBACK.Punch,
    animation = "ClinchGrab", animation_mode = "Natural", pairing = {on_hit = "Capture", guard = "Bypass"}, perfect_dodge = false,
    timeline = {startup = {14}, active = 3, recovery = {Hit = 12, Whiff = 28, Blocked = 28, Dodged = 28}},
    hitbox = {range = 6.5, half_width = 3.2, height = 2.5},
    damage = 0, stamina = 14, block_cost = 40, momentum_gain = 0,
    cooldown_key = "clinch_ready", cooldown_frames = 120,
}

local CLINCH_SHOVE = {
    feedback = FEEDBACK.Punch,
    animation = "ClinchShove", animation_mode = "Natural", pairing = {requires_control = true, on_hit = "Release", guard = "Bypass", shove_frames = 18}, perfect_dodge = false, wall_splat = {push = 3.4},
    timeline = {startup = {12}, active = 2, recovery = {Hit = 12, Whiff = 24, Blocked = 24, Dodged = 24}},
    hitbox = {range = 4.2, half_width = 2.4, height = 2.5},
    damage = 0, stamina = 10, block_cost = 0, momentum_gain = 0,
}

local CLINCH_KNEE = {
    feedback = FEEDBACK.ClinchKnee,
    animation = "ClinchKnee", animation_mode = "Natural", animation_fallback = "Knee", uses_legs = true, pairing = {requires_control = true, on_hit = "Continue", guard = "Block"}, perfect_dodge = false,
    timeline = {startup = {14}, active = 2, recovery = {Hit = 16, Whiff = 20, Blocked = 20, Dodged = 20}},
    hitbox = {range = 4.2, half_width = 2.4, height = 2.5},
    damage = 8, stamina = 10, block_cost = 35, momentum_gain = 0,
}

-- Reject malformed authored rules before the shared runtime uses them.
function MoveDefinitions.Validate(catalog, unnormalized)
    local issues = {}

    local function Issue(path, message)
        table.insert(issues, {path = path, message = message, severity = "Error"})
    end

    local function Number(value, minimum, integer, maximum)
        return type(value) == "number" and value == value and value < math.huge and value >= minimum and (not integer or value % 1 == 0) and (maximum == nil or type(maximum) == "number" and value <= maximum)
    end

    local function Sequence(value, allow_empty)
        if type(value) ~= "table" or not allow_empty and #value == 0 then
            return false
        end
        local count = 0
        for key in value do
            if not Number(key, 1, true, #value) then
                return false
            end
            count += 1
        end
        return count == #value
    end

    local function Hitbox(value, path)
        if type(value) ~= "table" or not Number(value.range, MIN_HITBOX_SIZE, false) or not Number(value.half_width, MIN_HITBOX_SIZE, false) or value.height ~= nil and not Number(value.height, MIN_HITBOX_SIZE, false) then
            Issue(path, "Hitbox needs finite positive dimensions")
        end
    end

    local function Control(rules, path)
        local valid = true
        for key, default in CONTROL_DEFAULTS do
            local value = rules[key]
            local integer = key ~= "distance" and key ~= "holder_drain" and key ~= "held_drain"
            if type(default) == "boolean" then
                if type(value) ~= "boolean" then
                    Issue(path .. "." .. key, "Expected a boolean")
                    valid = false
                end
            elseif not Number(value, 0, integer) then
                Issue(path .. "." .. key, "Expected a finite nonnegative value")
                valid = false
            end
        end
        if not valid then
            return
        end
        if rules.distance <= 0 or rules.escape_max <= 0 or rules.escape_tap_interval <= 0 then
            Issue(path, "Spacing and escape bounds must be positive")
            return
        end
        if rules.escape_cost >= MAX_RESOURCE then
            Issue(path .. ".escape_cost", "Escape cost must leave stamina after payment")
        end
        local net_gain = rules.escape_gain - rules.escape_decay * rules.escape_tap_interval
        if net_gain <= 0 then
            Issue(path, "Escape progress cannot reach completion")
            return
        end
        local presses = math.max(1, 1 + math.ceil((rules.escape_max - rules.escape_gain) / net_gain))
        local earliest = rules.escape_delay + (presses - 1) * rules.escape_tap_interval + rules.escape_startup
        if rules.duration <= earliest then
            Issue(path, "Hold expires before escape can finish")
        end
    end

    if type(catalog) ~= "table" then
        Issue("catalog", "Expected style definitions")
        return issues
    end

    for style_id, profile in catalog do
        if type(profile) ~= "table" or profile.moves == nil then
            continue
        end
        local prefix = tostring(style_id)
        if type(profile.moves) ~= "table" or type(profile.inputs) ~= "table" then
            Issue(prefix, "Expected moves and input bindings")
            continue
        end
        if type(profile.inputs.jab) ~= "string" or type(profile.moves[profile.inputs.jab]) ~= "table" then
            Issue(prefix .. ".inputs.jab", "A primary attack binding is required")
        end
        for input, name in profile.inputs do
            if not INPUT_ACTIONS[input] then
                Issue(prefix .. ".inputs." .. tostring(input), "Unknown input action")
            end
            if type(name) ~= "string" or type(profile.moves[name]) ~= "table" then
                Issue(prefix .. ".inputs." .. tostring(input), "Unknown move")
            end
        end
        if profile.speed_multiplier ~= nil and not Number(profile.speed_multiplier, MIN_HITBOX_SIZE, false) then
            Issue(prefix .. ".speed_multiplier", "Movement speed must be finite and positive")
        end
        if profile.counter_momentum ~= nil and not Number(profile.counter_momentum, 0, true, MAX_MOMENTUM) then
            Issue(prefix .. ".counter_momentum", "Invalid momentum gain")
        end

        local plan = PrepareAI(profile)
        if not plan then
            Issue(prefix .. ".ai", "Expected an AI plan")
        else
            for _, key in {"distance", "clinch_recovery", "special_reserve"} do
                local minimum = if key == "distance" then MIN_HITBOX_SIZE elseif key == "clinch_recovery" then 1 else 0
                if not Number(plan[key], minimum, key == "clinch_recovery", if key == "special_reserve" then MAX_RESOURCE else nil) then
                    Issue(prefix .. ".ai." .. key, "Invalid AI timing or resource value")
                end
            end
            for _, key in {"pattern", "counters"} do
                if not Sequence(plan[key], key == "counters") then
                    Issue(prefix .. ".ai." .. key, "Expected a dense action list")
                else
                    for _, action in plan[key] do
                        if type(action) ~= "string" or action ~= "clinch" and (not INPUT_ACTIONS[action] or type(profile.inputs[action]) ~= "string" or type(profile.moves[profile.inputs[action]]) ~= "table") then
                            Issue(prefix .. ".ai." .. key, "Unknown or unavailable AI action")
                        end
                    end
                end
            end
            if not Sequence(plan.clinch_delays, false) then
                Issue(prefix .. ".ai.clinch_delays", "Expected at least one clinch delay")
            else
                for _, delay in plan.clinch_delays do
                    if not Number(delay, 0, true) then
                        Issue(prefix .. ".ai.clinch_delays", "Clinch delays must use finite nonnegative frames")
                    end
                end
            end
            if plan.guard_pressure ~= nil and (type(plan.guard_pressure) ~= "string" or not INPUT_ACTIONS[plan.guard_pressure] or not profile.inputs[plan.guard_pressure]) then
                Issue(prefix .. ".ai.guard_pressure", "Unknown guard-pressure action")
            end
        end

        local response = profile.guard_response
        if response ~= nil and response ~= false then
            local path = prefix .. ".guard_response"
            if type(response) ~= "table" then
                Issue(path, "Expected guard response rules or false")
            else
                if not Number(response.window_frames, 1, true, 30) then Issue(path .. ".window_frames", "Expected a bounded positive frame window") end
                if not Number(response.recovery_frames, 1, true, 120) then Issue(path .. ".recovery_frames", "Expected a bounded positive recovery") end
                if not Number(response.cooldown_frames, 1, true) or Number(response.window_frames, 1, true) and Number(response.recovery_frames, 1, true) and response.cooldown_frames < response.window_frames + response.recovery_frames then
                    Issue(path .. ".cooldown_frames", "Cooldown must cover the response window and recovery")
                end
                if not Number(response.stamina, 0, false, MAX_RESOURCE - 1) then Issue(path .. ".stamina", "Guard response cost must be payable") end
                local capture = type(response.capture_move) == "string" and profile.moves[response.capture_move]
                local pairing = type(capture) == "table" and capture.pairing
                if not (unnormalized and response.capture_move == "ClinchGrab" and not capture) and (type(pairing) ~= "table" or pairing.on_hit ~= "Capture") then
                    Issue(path .. ".capture_move", "Guard response must reference a capture move")
                end
                if type(response.tags) ~= "table" or not next(response.tags) then
                    Issue(path .. ".tags", "Expected accepted attack tags")
                else
                    for tag, allowed in response.tags do
                        if type(tag) ~= "string" or tag == "" or allowed ~= true then Issue(path .. ".tags", "Attack tags must map nonempty names to true") end
                    end
                end
            end
        end

        local held_action = profile.clinch_attack or "ClinchShove"
        if not profile.moves[held_action] and not (unnormalized and (held_action == "ClinchShove" or held_action == "ClinchKnee")) then
            Issue(prefix .. ".clinch_attack", "Unknown held action")
        end
        local control = table.clone(CONTROL_DEFAULTS)
        control.duration = profile.clinch_duration or control.duration
        control.holder_drain = profile.clinch_drain or control.holder_drain
        if profile.control ~= nil and type(profile.control) ~= "table" then
            Issue(prefix .. ".control", "Expected control rules")
        else
            for key, value in profile.control or {} do
                control[key] = value
            end
        end
        Control(control, prefix .. ".control")
        local escape = if profile.escape == nil then {outcome = "Release"} else profile.escape
        if type(escape) ~= "table" then
            Issue(prefix .. ".escape", "Expected an escape policy")
        else
            if escape.outcome ~= "Release" and escape.outcome ~= "Reverse" then
                Issue(prefix .. ".escape", "Unknown escape outcome")
            end
            if escape.outcome == "Reverse" then
                if not Number(escape.reverse_duration or 90, 1, true) or not Number(escape.max_reversals or 1, 1, true) then
                    Issue(prefix .. ".escape", "Reversals need a bounded duration and count")
                end
                if Number(escape.reverse_duration or 90, 1, true) then
                    local reverse_control = table.clone(control)
                    local capture = profile.moves.ClinchGrab
                    local overrides = type(capture) == "table" and type(capture.pairing) == "table" and capture.pairing.control
                    if type(overrides) == "table" then
                        for key, value in overrides do
                            reverse_control[key] = value
                        end
                    end
                    reverse_control.duration = escape.reverse_duration or 90
                    Control(reverse_control, prefix .. ".escape")
                end
            end
        end

        for move_id, move in profile.moves do
            local path = prefix .. "." .. tostring(move_id)
            if type(move) ~= "table" then
                Issue(path, "Expected a move definition")
                continue
            end
            if move.guard_tag ~= nil and (type(move.guard_tag) ~= "string" or move.guard_tag == "") then
                Issue(path .. ".guard_tag", "Expected a nonempty attack tag")
            end
            local timeline = move.timeline
            if type(timeline) ~= "table" or not Sequence(timeline.startup, false) or type(timeline.recovery) ~= "table" then
                Issue(path .. ".timeline", "Missing startup or recovery phases")
                continue
            end
            local minimum_startup = math.huge
            for _, frames in timeline.startup do
                if not Number(frames, 1, true) then Issue(path .. ".timeline.startup", "Startup must use positive integer frames") else minimum_startup = math.min(minimum_startup, frames) end
            end
            for _, outcome in {"Hit", "Whiff", "Blocked", "Dodged"} do
                if not Number(timeline.recovery[outcome], 0, true) then
                    Issue(path .. ".timeline.recovery." .. outcome, "Missing or invalid recovery")
                end
            end
            local hits = if timeline.hits == nil then {{offset = 0, active = timeline.active}} else timeline.hits
            if not Sequence(hits, false) then
                Issue(path .. ".timeline.hits", "Expected at least one strike")
            else
                local previous_end = 0
                for index, hit in hits do
                    local hit_path = path .. ".timeline.hits." .. tostring(index)
                    if type(hit) == "table" then
                        for _, key in {"damage", "block_cost", "target_stun", "perfect_frames"} do
                            if hit[key] ~= nil and not Number(hit[key], 0, key == "target_stun" or key == "perfect_frames") then
                                Issue(hit_path .. "." .. key, "Invalid strike override")
                            end
                        end
                        if hit.hitbox ~= nil then
                            Hitbox(hit.hitbox, hit_path .. ".hitbox")
                        end
                    end
                    if type(hit) ~= "table" or not Number(hit.offset, previous_end, true) or not Number(hit.active, 1, true) or index == 1 and hit.offset ~= 0 then
                        Issue(path .. ".timeline.hits", "Strike windows overlap or use invalid frames")
                    else
                        previous_end = hit.offset + hit.active
                    end
                end
            end
            if not Number(move.stamina, 0, false) or move.stamina >= MAX_RESOURCE then
                Issue(path .. ".stamina", "Cost cannot be paid from a full stamina meter")
            end
            if not Number(move.damage, 0, false) then
                Issue(path .. ".damage", "Invalid damage")
            end
            Hitbox(move.hitbox, path .. ".hitbox")
            if not Number(move.block_cost, 0, false) then
                Issue(path .. ".block_cost", "Invalid block cost")
            end
            for _, key in {"block_cost", "target_stun", "perfect_frames", "chain_window", "opening_multiplier"} do
                if move[key] ~= nil and not Number(move[key], 0, key == "target_stun" or key == "perfect_frames" or key == "chain_window") then
                    Issue(path .. "." .. key, "Expected a finite nonnegative value")
                end
            end
            for _, key in {"momentum", "momentum_gain"} do
                if move[key] ~= nil and not Number(move[key], 0, true, MAX_MOMENTUM) then
                    Issue(path .. "." .. key, "Momentum exceeds the available meter")
                end
            end
            if move.chain_start ~= nil and not Number(move.chain_start, 0, true, #timeline.startup) then
                Issue(path .. ".chain_start", "Invalid chain entry")
            end
            if move.chain_stamina ~= nil then
                if not Sequence(move.chain_stamina, false) then
                    Issue(path .. ".chain_stamina", "Expected at least one chain cost")
                else
                    for _, cost in move.chain_stamina do
                        if not Number(cost, 0, false) or cost >= MAX_RESOURCE then
                            Issue(path .. ".chain_stamina", "Chain costs must be payable without exhaustion")
                        end
                    end
                end
            end
            if move.cooldown_key ~= nil then
                local key = move.cooldown_key
                if type(key) ~= "string" or not (COOLDOWN_KEYS[key] or key:match("^cooldown_[a-z][a-z0-9_]*$")) then
                    Issue(path .. ".cooldown_key", "Cooldown must use a supported timer or the cooldown_ namespace")
                end
                if not Number(move.cooldown_frames, 1, true) then
                    Issue(path .. ".cooldown_frames", "Cooldown must use positive integer frames")
                end
            elseif move.cooldown_frames ~= nil then
                Issue(path .. ".cooldown_key", "Cooldown duration needs a timer key")
            end
            if type(move.animation) ~= "string" or move.animation == "" then
                Issue(path .. ".animation", "Expected an animation name")
            end
            if not ANIMATION_MODES[move.animation_mode] then
                Issue(path .. ".animation_mode", "Unknown animation mode")
            end
            if move.fallback_animation_mode ~= nil and not ANIMATION_MODES[move.fallback_animation_mode] then
                Issue(path .. ".fallback_animation_mode", "Unknown fallback animation mode")
            end
            if move.cancels ~= nil and type(move.cancels) ~= "table" then
                Issue(path .. ".cancels", "Expected outcome branches")
            else
                for outcome, cancels in move.cancels or {} do
                    local branch_path = path .. ".cancels." .. tostring(outcome)
                    if type(cancels) ~= "table" or cancels.followups ~= nil and type(cancels.followups) ~= "table" then
                        Issue(branch_path, "Expected follow-up branches")
                        continue
                    end
                    for _, action in {"attack", "guard", "dodge"} do
                        if cancels[action] ~= nil and not Number(cancels[action], 0, true, timeline.recovery[outcome]) then
                            Issue(branch_path .. "." .. action, "Invalid cancel frame")
                        end
                    end
                    for name, branch in cancels.followups or {} do
                        if not profile.moves[name] then
                            Issue(branch_path .. "." .. tostring(name), "Unknown follow-up")
                        end
                        if type(branch) ~= "table" or not Number(branch.after, 0, true) or not Number(branch.window, 1, true) or not Number(branch.startup, 1, true) then
                            Issue(branch_path, "Invalid follow-up window")
                        elseif branch.counter_startup ~= nil and not Number(branch.counter_startup, 1, true) then
                            Issue(branch_path, "Invalid counter follow-up startup")
                        elseif not Number(timeline.recovery[outcome], 0, true) or branch.after + branch.window > timeline.recovery[outcome] then
                            Issue(branch_path, "Follow-up is outside recovery")
                        end
                    end
                end
            end
            if move.permissions ~= nil and type(move.permissions) ~= "table" then
                Issue(path .. ".permissions", "Expected phase permissions")
            else
                for phase, permissions in move.permissions or {} do
                    if type(permissions) ~= "table" then
                        Issue(path .. ".permissions", "Expected phase permissions")
                        continue
                    end
                    if phase ~= "startup" and phase ~= "active" and phase ~= "recovery" then
                        Issue(path .. ".permissions", "Unknown phase")
                    end
                    for action, allowed in permissions do
                        if (action ~= "movement" and action ~= "guard" and action ~= "dodge") or type(allowed) ~= "boolean" then
                            Issue(path .. ".permissions." .. tostring(phase), "Invalid input permission")
                        end
                    end
                end
            end
            if move.advance ~= nil then
                if type(move.advance) ~= "table" or not Number(move.advance.distance, MIN_HITBOX_SIZE, false, MAX_ADVANCE_DISTANCE) or not Number(move.advance.frames, 1, true, MAX_ADVANCE_FRAMES) then
                    Issue(path .. ".advance", "Attack advance needs a bounded distance and frame duration")
                elseif type(move.pairing) == "table" and (move.pairing.requires_control or move.pairing.entry_motion) then
                    Issue(path .. ".advance", "Attack advance cannot overlap held control or an entry motion")
                end
            end

            local pair = move.pairing
            if pair == nil then
                continue
            end
            if type(pair) ~= "table" then
                Issue(path .. ".pairing", "Expected paired interaction rules")
                continue
            end
            if pair.on_hit ~= "Capture" and pair.on_hit ~= "Continue" and pair.on_hit ~= "Release" then
                Issue(path .. ".pairing.on_hit", "Unknown contact outcome")
            end
            if pair.guard ~= "Bypass" and pair.guard ~= "Block" then
                Issue(path .. ".pairing.guard", "Unknown guard rule")
            end
            if pair.reaction ~= nil and pair.reaction ~= "Takedown" then
                Issue(path .. ".pairing.reaction", "Unknown paired reaction")
            end
            if pair.shove_frames ~= nil and not Number(pair.shove_frames, 0, true) then
                Issue(path .. ".pairing.shove_frames", "Invalid shove duration")
            end
            if type(pair.victim) == "table" and pair.victim.lock_facing ~= nil and type(pair.victim.lock_facing) ~= "boolean" then
                Issue(path .. ".pairing.victim.lock_facing", "Expected a boolean")
            end
            if pair.requires_control ~= nil and type(pair.requires_control) ~= "boolean" then
                Issue(path .. ".pairing.requires_control", "Expected a boolean")
            end
            if pair.requires_control and pair.on_hit == "Capture" then
                Issue(path .. ".pairing", "A held target cannot be captured again")
            end
            if pair.victim ~= nil and (type(pair.victim) ~= "table" or not pair.requires_control or type(pair.victim.animation) ~= "string" or pair.victim.animation == "") then
                Issue(path .. ".pairing.victim", "Paired victim playback requires control and an animation")
            end
            for _, key in {"entry_motion", "exit_motion"} do
                local motion = pair[key]
                if motion == nil then
                    continue
                end
                if type(motion) ~= "table" or type(motion.distance) ~= "number" or motion.distance ~= motion.distance or math.abs(motion.distance) == math.huge or not Number(motion.frames, 1, true) then
                    Issue(path .. ".pairing." .. key, "Invalid motion timeline")
                elseif key == "entry_motion" and motion.frames > minimum_startup then
                    Issue(path .. ".pairing.entry_motion", "Entry motion extends beyond startup")
                elseif key == "exit_motion" and (not Number(move.target_stun or 0, 0, true) or (move.target_stun or 0) < motion.frames) then
                    Issue(path .. ".pairing.exit_motion", "Target can act before the throw finishes")
                end
            end
            local rules = table.clone(control)
            if pair.control ~= nil and type(pair.control) ~= "table" then
                Issue(path .. ".pairing.control", "Expected control rules")
            else
                for key, value in pair.control or {} do
                    rules[key] = value
                end
                Control(rules, path .. ".pairing.control")
            end
        end
    end

    return issues
end

function MoveDefinitions.ValidateAssets(root, style_ids)
    local issues = {}
    if typeof(root) ~= "Instance" then
        return {{severity = "Error", path = "Animations", message = "Missing animation catalog"}}
    end
    for _, style_id in style_ids do
        local profile = MoveDefinitions[style_id]
        if not profile then
            continue
        end
        for move_id, move in profile.moves do
            local victim = move.pairing and move.pairing.victim
            if victim then
                local universal = root:FindFirstChild("Universal")
                local animation = universal and universal:FindFirstChild(victim.animation .. "Animation")
                if not animation or not animation:IsA("Animation") or animation.AnimationId == "" then
                    table.insert(issues, {severity = "Error", path = style_id .. "." .. move_id .. ".pairing.victim", message = "Missing victim animation: " .. victim.animation})
                end
            end
        end
    end
    return issues
end

local raw_issues = MoveDefinitions.Validate(MoveDefinitions, true)
if #raw_issues > 0 then
    local messages = {}
    for _, issue in raw_issues do
        table.insert(messages, issue.path .. ": " .. issue.message)
    end
    error(table.concat(messages, "\n"))
end

-- Normalize legacy fields once so runtime code reads one rule shape.
for _, profile in MoveDefinitions do
    if type(profile) == "table" and profile.moves then
        profile.moves.ClinchGrab = profile.moves.ClinchGrab or table.clone(CLINCH_GRAB)
        local clinch_attack = profile.clinch_attack or "ClinchShove"
        profile.clinch_attack = clinch_attack
        if not profile.moves[clinch_attack] then
            assert(clinch_attack == "ClinchKnee" or clinch_attack == "ClinchShove", "Missing clinch move definition")
            profile.moves[clinch_attack] = table.clone(if clinch_attack == "ClinchKnee" then CLINCH_KNEE else CLINCH_SHOVE)
        end
        if profile.guard_response == nil then profile.guard_response = {tags = table.clone(GUARD_RESPONSE.tags), window_frames = GUARD_RESPONSE.window_frames, stamina = GUARD_RESPONSE.stamina, cooldown_frames = GUARD_RESPONSE.cooldown_frames, recovery_frames = GUARD_RESPONSE.recovery_frames, capture_move = GUARD_RESPONSE.capture_move} end
        profile.ai = assert(PrepareAI(profile), "Invalid AI plan")
        profile.speed_multiplier = profile.speed_multiplier or 1
        local control = table.clone(CONTROL_DEFAULTS)
        control.duration = profile.clinch_duration or control.duration
        control.holder_drain = profile.clinch_drain or control.holder_drain
        for key, value in profile.control or {} do
            control[key] = value
        end
        profile.control = control
        profile.escape = profile.escape or {outcome = "Release"}
        profile.escape.reverse_duration = profile.escape.reverse_duration or 90
        profile.escape.max_reversals = profile.escape.max_reversals or 1
        for _, move in profile.moves do
            local feedback = table.clone(FEEDBACK.Punch)
            for key, value in move.feedback or {} do
                feedback[key] = value
            end
            move.feedback = feedback
            if not move.pairing and (move.grab or move.clinch_only or move.takedown or move.shove or move.lunge) then
                move.pairing = {
                    requires_control = move.clinch_only == true,
                    on_hit = if move.grab then "Capture" elseif move.takedown or move.shove then "Release" else "Continue",
                    guard = if move.grab or move.takedown or move.shove then "Bypass" else "Block",
                    reaction = if move.takedown then "Takedown" else nil,
                    shove_frames = if move.shove then 18 else 0,
                    entry_motion = move.lunge,
                    exit_motion = if move.throw_frames then {distance = move.throw_distance, frames = move.throw_frames} else nil,
                    victim = if move.victim_animation then {animation = move.victim_animation, lock_facing = true} else nil
                }
            end
            local permissions = move.permissions or {}
            for _, phase in {"startup", "active", "recovery"} do
                local rules = table.clone(LOCKED_PHASE)
                for action, allowed in permissions[phase] or {} do
                    rules[action] = allowed
                end
                permissions[phase] = rules
            end
            move.permissions = permissions
            if move.pairing then
                local control = table.clone(profile.control)
                for key, value in move.pairing.control or {} do
                    control[key] = value
                end
                move.pairing.control = control
                move.grab = move.pairing.on_hit == "Capture"
                move.clinch_only = move.pairing.requires_control == true
                move.shove = (move.pairing.shove_frames or 0) > 0
                move.takedown = move.pairing.reaction == "Takedown"
                move.lunge = move.pairing.entry_motion
                move.victim_animation = move.pairing.victim and move.pairing.victim.animation
                move.throw_distance = move.pairing.exit_motion and move.pairing.exit_motion.distance
                move.throw_frames = move.pairing.exit_motion and move.pairing.exit_motion.frames
            end

            local timeline = move.timeline
            if not timeline.hits then
                timeline.hits = {{offset = 0, active = timeline.active}}
            end
            assert(#timeline.hits > 0 and timeline.hits[1].offset == 0, "Move must start with a strike at offset zero")
            local last = 0
            for _, hit in timeline.hits do
                assert(hit.offset % 1 == 0 and hit.offset >= last and hit.active % 1 == 0 and hit.active > 0, "Invalid or overlapping strike windows")
                last = hit.offset + hit.active
            end
            timeline.active = last
        end
    end
end

local definition_issues = MoveDefinitions.Validate(MoveDefinitions)
if #definition_issues > 0 then
    local messages = {}
    for _, issue in definition_issues do
        table.insert(messages, issue.path .. ": " .. issue.message)
    end
    error(table.concat(messages, "\n"))
end

Freeze(HIT_FEEDBACK)
Freeze(FEEDBACK_OUTCOMES)
return Freeze(MoveDefinitions)
