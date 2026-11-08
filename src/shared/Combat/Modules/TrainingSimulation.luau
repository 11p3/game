local MoveDefinitions = require(script.Parent.MoveDefinitions)

local TrainingSimulation = {VERSION = 1}
local MAX_RECORDING_FRAMES = 300 -- Five-second recordings to keep training snapshots bounded.
local LOOP_REST_FRAMES = 60 -- One second between loops to leave room for a response.

local actions = {
    Idle = true,
    Guard = true,
    Attack = true,
    Counter = true,
    Record = true,
    Stop = true,
    Playback = true,
    Reset = true,
    InfiniteHealth = true,
    InfiniteStamina = true,
    InfiniteBlock = true,
    InfiniteMomentum = true
}
for fighter_id, profile in MoveDefinitions do
    if type(profile) == "table" and profile.moves then
        actions[fighter_id] = true
    end
end
TrainingSimulation.Actions = table.freeze(actions)

function TrainingSimulation.Create(dummy_style)
    return {
        mode = "Idle",
        recording = false,
        sequence = {},
        playhead = 0,
        ticks = 0,
        reset_serial = 0,
        dummy_style = dummy_style or "Boxing",
        infinite_health = true,
        infinite_stamina = false,
        infinite_block = false,
        infinite_momentum = false
    }
end

function TrainingSimulation.Pack(input)
    -- Use two bits per axis, then separate bits for action buttons.
    local value = (input.axis or 0) + 1 + ((input.strafe or 0) + 1) * 4
    for index, key in {"guard", "jab", "dodge", "special", "kick", "technique", "clinch"} do
        if input[key] == true then
            value += 2 ^ (index + 3)
        end
    end
    return value
end

function TrainingSimulation.Unpack(value)
    local input = {axis = value % 4 - 1, strafe = math.floor(value / 4) % 4 - 1}
    for index, key in {"guard", "jab", "dodge", "special", "kick", "technique", "clinch"} do
        input[key] = bit32.band(value, 2 ^ (index + 3)) ~= 0
    end
    return input
end

function TrainingSimulation.Step(training, input, phase, distance)
    local action = input.training
    local reset = false

    if action == "Idle" or action == "Guard" or action == "Attack" or action == "Counter" then
        training.mode, training.recording, training.ticks = action, false, 0
    elseif action == "Record" then
        training.sequence, training.recording, training.mode, training.playhead, training.ticks = {}, true, "Idle", 0, 0
        reset = true
    elseif action == "Stop" then
        training.recording, training.mode, training.playhead = false, "Idle", 0
    elseif action == "Playback" and #training.sequence > 0 then
        training.recording, training.mode, training.playhead = false, "Playback", 0
    elseif action == "Reset" then
        training.recording = false
        reset = true
    elseif type(action) == "string" and type(MoveDefinitions[action]) == "table" and MoveDefinitions[action].moves then
        training.dummy_style, training.mode, training.recording, training.sequence, training.playhead = action, "Idle", false, {}, 0
        reset = true
    elseif action == "InfiniteHealth" then
        training.infinite_health = not training.infinite_health
    elseif action == "InfiniteStamina" then
        training.infinite_stamina = not training.infinite_stamina
    elseif action == "InfiniteBlock" then
        training.infinite_block = not training.infinite_block
    elseif action == "InfiniteMomentum" then
        training.infinite_momentum = not training.infinite_momentum
    end

    if reset then
        training.reset_serial += 1
        training.playhead, training.ticks = 0, 0
    end

    if phase ~= "Fighting" and not reset then
        training.recording, training.playhead = false, 0
        return {}, {}, false
    end

    training.ticks += 1

    if training.recording then
        local packed = TrainingSimulation.Pack(input)
        table.insert(training.sequence, packed)
        if #training.sequence >= MAX_RECORDING_FRAMES then
            training.recording = false
        end
        return {}, TrainingSimulation.Unpack(packed), reset
    elseif training.mode == "Playback" and #training.sequence > 0 then
        training.playhead = training.playhead % (#training.sequence + LOOP_REST_FRAMES) + 1
        return input, if training.playhead <= #training.sequence then TrainingSimulation.Unpack(training.sequence[training.playhead]) else {}, reset
    elseif training.mode == "Guard" then
        return input, {guard = true}, reset
    elseif training.mode == "Attack" then
        return input, {axis = if distance > 3.8 then 1 else 0, jab = distance <= 4.5 and training.ticks % 60 == 1}, reset
    elseif training.mode == "Counter" then
        return input, nil, reset
    end

    return input, {}, reset
end

function TrainingSimulation.Restore(fighters, training)
    for _, fighter in fighters do
        if training.infinite_health then
            fighter.health = 100
            if fighter.state == "Knockout" then fighter.state = if fighter.frame < fighter.stun_until then "Stunned" else "HitReact" end
        end
        if training.infinite_stamina then
            fighter.stamina = 100
        end
        if training.infinite_block then
            fighter.block_meter = 100
        end
        if training.infinite_momentum then
            fighter.momentum = 3
        end
    end
end

return TrainingSimulation
