local MoveDefinitions = require(script.Parent.MoveDefinitions)
local CombatSimulation = require(script.Parent.CombatSimulation)
local MatchSimulation = require(script.Parent.MatchSimulation)
local AISimulation = require(script.Parent.AISimulation)
local TrainingSimulation = require(script.Parent.TrainingSimulation)
local RollbackSession = require(script.Parent.RollbackSession)
local SnapshotCodec = require(script.Parent.SnapshotCodec)
local HttpService = game:GetService("HttpService")

local MatchReplay = {}
-- Refresh these fingerprints when simulation source changes.
local SOURCE_HASHES = table.freeze({CombatSimulation = 521640928, MatchSimulation = 104575513, AISimulation = 1870682120, TrainingSimulation = 4224684585, PairedActions = 2191544561, RollbackSession = 3930436490})
MatchReplay.SourceHashes = SOURCE_HASHES
local HEADER_PREFIX_BYTES = 8
local HEADER_LENGTH_OFFSET = 4
local MIN_ARCHIVE_BYTES = 10
local MAX_HEADER_BYTES = 524288 -- 512 KiB to bound archive parsing and checkpoint metadata.
local MAX_ADVANCE_FRAMES = 600 -- At most ten seconds of replay work per advance call.
-- DJB2 constants for the same bounded checksum scheme as rollback.
local HASH_SEED = 5381 -- Standard DJB2 starting seed, not a gameplay tuning value.
local HASH_MULTIPLIER = 33 -- 32 + 1 is DJB2's mixing step, paired with the 5381 seed.
local HASH_MODULUS = 4294967296 -- 2^32 wraps the rolling hash to an unsigned 32-bit value.
local INPUT_SLOT_BYTES = 3 -- Two bytes for controls and one for a training command per player.
local INPUT_FLAG_SHIFT = 3
local INPUT_MASK_LIMIT = 2048
local FORMAT_VERSION = 1
local LEGACY_MOVE_VERSION = 5
local LEGACY_RULES_HASH = 4178806607
local LEGACY_SIMULATION_HASH = 1835614991
local MAX_FRAMES = 18000 -- Five minutes at 60 Hz to bound each in-memory recording.
local CHECKPOINT_FRAMES = 300 -- Five-second checkpoints to limit how much seeking must replay.
local FRAME_BYTES = 6
local MAGIC = 1296912722 -- Fixed archive marker to reject unrelated binary data.
local FLAGS = {"guard", "jab", "dodge", "special", "kick", "technique", "clinch"}
local ACTIONS = {""}
for action in TrainingSimulation.Actions do
    table.insert(ACTIONS, action)
end
table.sort(ACTIONS)
local ACTION_IDS = {}
for index, action in ACTIONS do
    ACTION_IDS[action] = index - 1
end
local VERSIONS = {
    format = FORMAT_VERSION,
    moves = MoveDefinitions.SIMULATION_VERSION,
    combat = CombatSimulation.VERSION,
    match = MatchSimulation.VERSION,
    ai = AISimulation.VERSION,
    training = TrainingSimulation.VERSION
}
local COSMETIC_FIELDS = {feedback = true, animation = true, animation_mode = true, animation_fallback = true, fallback_animation_mode = true, uses_legs = true}

local function SimulationRules(value, victim)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in value do
        if not COSMETIC_FIELDS[key] or victim and key == "animation" then
            result[key] = SimulationRules(child, key == "victim")
        end
    end
    return result
end

local profiles = {}
for name, profile in MoveDefinitions do if type(profile) == "table" and profile.moves then profiles[name] = SimulationRules(profile) end end
local RULES_HASH = RollbackSession.Checksum({versions = VERSIONS, source_hashes = SOURCE_HASHES, profiles = profiles, difficulties = AISimulation.Difficulties, actions = ACTIONS})

local function HashFrame(hash, commands, offset)
    for index = offset, offset + FRAME_BYTES - 1 do
        hash = (hash * HASH_MULTIPLIER + buffer.readu8(commands, index)) % HASH_MODULUS
    end
    return hash
end

local function Checkpoint(record, state, held)
    local entry = {
        frame = state.frame,
        state = RollbackSession.Copy(state),
        held = RollbackSession.Predict(held),
        checksum = RollbackSession.Checksum(state),
        input_checksum = record.input_checksum
    }
    local last = record.checkpoints[#record.checkpoints]
    if last and last.frame == entry.frame then record.checkpoints[#record.checkpoints] = entry else table.insert(record.checkpoints, entry) end
end

local function Validate(record)
    if type(record) == "table" and type(record.versions) == "table" and record.versions.moves == LEGACY_MOVE_VERSION and record.rules_hash == LEGACY_RULES_HASH and RULES_HASH == LEGACY_SIMULATION_HASH then
        local migrated = table.clone(record.versions)
        migrated.moves = VERSIONS.moves
        if RollbackSession.Equals(migrated, VERSIONS) then
            record.versions, record.rules_hash = migrated, RULES_HASH
        end
    end
    assert(type(record) == "table" and record.format_version == FORMAT_VERSION, "format_version")
    assert(RollbackSession.Equals(record.versions, VERSIONS), "simulation_version")
    assert(record.rules_hash == RULES_HASH, "rules_mismatch")
    assert(type(record.frames) == "number" and record.frames % 1 == 0 and record.frames >= 0 and record.frames <= MAX_FRAMES, "frame_limit")
    assert(typeof(record.commands) == "buffer" and buffer.len(record.commands) >= record.frames * FRAME_BYTES, "command_length")
    assert(type(record.config) == "table" and type(record.checkpoints) == "table" and #record.checkpoints > 0, "invalid_header")
    assert(#record.checkpoints <= math.ceil(MAX_FRAMES / CHECKPOINT_FRAMES) + 3, "checkpoint_limit")
    assert(record.status == "Recording" or record.status == "Complete" or record.status == "Truncated" or record.status == "Invalid", "record_status")
    if record.status ~= "Recording" then
        assert(record.checkpoints[#record.checkpoints].frame == record.frames, "final_checkpoint")
        assert(type(record.final_checksum) == "number" and type(record.input_checksum) == "number", "final_checksum")
    end
    local previous = -1
    for _, entry in record.checkpoints do
        assert(type(entry.frame) == "number" and entry.frame % 1 == 0 and entry.frame > previous and entry.frame <= record.frames, "checkpoint_order")
        assert(type(entry.state) == "table" and entry.state.frame == entry.frame and type(entry.held) == "table", "checkpoint_state")
        assert(type(entry.checksum) == "number" and type(entry.input_checksum) == "number", "checkpoint_checksum")
        previous = entry.frame
    end
    assert(record.checkpoints[1].frame == 0, "initial_checkpoint")
end

function MatchReplay.New(session, metadata)
    assert(session.state.frame == 0, "Whole-bout recording starts at frame zero")
    local record = {
        format_version = FORMAT_VERSION,
        versions = RollbackSession.Copy(VERSIONS),
        rules_hash = RULES_HASH,
        metadata = RollbackSession.Copy(metadata or {}),
        config = RollbackSession.Copy(session.config),
        frames = 0,
        commands = buffer.create(MAX_FRAMES * FRAME_BYTES),
        checkpoints = {},
        input_checksum = HASH_SEED,
        status = "Recording",
        checkpoint_offset = (metadata and metadata.epoch or 0) % CHECKPOINT_FRAMES,
        last_state = session:Snapshot(),
        last_held = RollbackSession.Predict(session.last_input)
    }
    Checkpoint(record, session.state, session.last_input)
    return record
end

function MatchReplay.Capture(record, session, final)
    if record.status ~= "Recording" then
        return false
    end
    -- Record confirmed frames so later rollback cannot rewrite archived commands.
    local through = if final then session.state.frame else math.max(0, session.state.frame - session.rollback_window)
    for frame = record.frames + 1, math.min(through, MAX_FRAMES) do
        local state, input = session.history[frame], session.used_inputs[frame]
        if not state or not input then
            record.status, record.error = "Invalid", "history_missing"; return false
        end
        local offset = (frame - 1) * FRAME_BYTES
        for slot = 1, 2 do
            local suffix = if slot == 1 then "_one" else ""
            local packed = (input["axis" .. suffix] or 0) + 1 + ((input["strafe" .. suffix] or 0) + 1) * 4
            for index, key in FLAGS do if input[key .. suffix] then packed = bit32.bor(packed, bit32.lshift(1, index + INPUT_FLAG_SHIFT)) end end
            buffer.writeu16(record.commands, offset + (slot - 1) * INPUT_SLOT_BYTES, packed)
            local action = ACTION_IDS[input["training" .. suffix] or ""]
            if action == nil then
                record.status, record.error = "Invalid", "training_action"; return false
            end
            buffer.writeu8(record.commands, offset + (slot - 1) * INPUT_SLOT_BYTES + 2, action)
        end
        record.frames = frame
        record.input_checksum = HashFrame(record.input_checksum, record.commands, offset)
        record.last_state, record.last_held = state, session.held_inputs[frame]
        if frame % CHECKPOINT_FRAMES == record.checkpoint_offset then
            Checkpoint(record, state, record.last_held)
        end
    end
    if through > MAX_FRAMES then
        record.status, record.error = "Truncated", "frame_limit"; return false
    end
    return true
end

function MatchReplay.Finish(record, session, reason)
    if record.status == "Recording" then
        MatchReplay.Capture(record, session, true)
        if record.status == "Recording" then
            record.status = "Complete"
        end
    end
    record.end_reason = reason or ""
    local state = if record.frames == session.state.frame then session.state else record.last_state
    Checkpoint(record, state, record.last_held)
    record.final_checksum = RollbackSession.Checksum(state)
    return record
end

function MatchReplay.Encode(record)
    Validate(record)
    assert(record.status ~= "Recording", "Recording has not finished")
    local header = {
        format_version = record.format_version,
        versions = record.versions,
        rules_hash = record.rules_hash,
        metadata = record.metadata,
        config = record.config,
        frames = record.frames,
        checkpoints = record.checkpoints,
        input_checksum = record.input_checksum,
        final_checksum = record.final_checksum,
        status = record.status,
        error = record.error,
        end_reason = record.end_reason
    }
    local encoded = SnapshotCodec.Encode(header)
    local data = buffer.create(HEADER_PREFIX_BYTES + buffer.len(encoded) + record.frames * FRAME_BYTES)
    buffer.writeu32(data, 0, MAGIC)
    buffer.writeu32(data, HEADER_LENGTH_OFFSET, buffer.len(encoded))
    buffer.copy(data, HEADER_PREFIX_BYTES, encoded)
    buffer.copy(data, HEADER_PREFIX_BYTES + buffer.len(encoded), record.commands, 0, record.frames * FRAME_BYTES)
    return data
end

function MatchReplay.Decode(data)
    local ok, result = pcall(function()
        if type(data) == "string" then
            data = HttpService:JSONDecode(data).record
        end
        assert(typeof(data) == "buffer" and buffer.len(data) >= MIN_ARCHIVE_BYTES and buffer.len(data) <= HEADER_PREFIX_BYTES + MAX_HEADER_BYTES + MAX_FRAMES * FRAME_BYTES, "archive_size")
        assert(buffer.readu32(data, 0) == MAGIC, "archive_magic")
        local length = buffer.readu32(data, HEADER_LENGTH_OFFSET)
        assert(length <= MAX_HEADER_BYTES and length + HEADER_PREFIX_BYTES <= buffer.len(data), "header_length")
        local header = buffer.create(length)
        buffer.copy(header, 0, data, HEADER_PREFIX_BYTES, length)
        local record, reason = SnapshotCodec.Decode(header)
        assert(record, reason)
        assert(type(record.frames) == "number" and record.frames % 1 == 0 and record.frames >= 0 and record.frames <= MAX_FRAMES, "frame_limit")
        assert(buffer.len(data) == HEADER_PREFIX_BYTES + length + record.frames * FRAME_BYTES, "command_length")
        record.commands = buffer.create(record.frames * FRAME_BYTES)
        buffer.copy(record.commands, 0, data, HEADER_PREFIX_BYTES + length)
        Validate(record)
        return record
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

function MatchReplay.Open(record)
    local ok, result = pcall(function()
        Validate(record)
        assert(record.status == "Complete" or record.status == "Truncated", "recording_incomplete")
        local initial = record.checkpoints[1]
        assert(RollbackSession.Checksum(initial.state) == initial.checksum, "initial_checksum")
        local session = RollbackSession.New(initial.state, MatchSimulation.Step, record.config)
        session.last_input = RollbackSession.Predict(initial.held)
        session.held_inputs[0] = RollbackSession.Copy(session.last_input)
        return {record = record, session = session, input_checksum = HASH_SEED, next_checkpoint = 2, verified_frame = 0}
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

function MatchReplay.Advance(cursor, frames)
    frames = frames or 1
    if type(frames) ~= "number" or frames % 1 ~= 0 or frames < 0 or frames > MAX_ADVANCE_FRAMES then
        return nil, "step_limit"
    end
    local ok, result = pcall(function()
        for _ = 1, math.min(frames, cursor.record.frames - cursor.session.state.frame) do
            local frame = cursor.session.state.frame + 1
            local offset = (frame - 1) * FRAME_BYTES
            local input = {}
            for slot = 1, 2 do
                local suffix = if slot == 1 then "_one" else ""
                local packed = buffer.readu16(cursor.record.commands, offset + (slot - 1) * INPUT_SLOT_BYTES)
                local axis, strafe = bit32.band(packed, 3) - 1, bit32.band(bit32.rshift(packed, 2), 3) - 1
                assert(packed < INPUT_MASK_LIMIT and axis <= 1 and strafe <= 1, "command_bits")
                input["axis" .. suffix], input["strafe" .. suffix] = axis, strafe
                for index, key in FLAGS do
                    input[key .. suffix] = bit32.band(packed, bit32.lshift(1, index + INPUT_FLAG_SHIFT)) ~= 0
                end
                local action = ACTIONS[buffer.readu8(cursor.record.commands, offset + (slot - 1) * INPUT_SLOT_BYTES + 2) + 1]
                assert(action ~= nil, "training_action")
                input["training" .. suffix] = action
            end
            cursor.input_checksum = HashFrame(cursor.input_checksum, cursor.record.commands, offset)
            assert(cursor.session:Advance(input), "replay_input")
            local checkpoint = cursor.record.checkpoints[cursor.next_checkpoint]
            if checkpoint and checkpoint.frame == frame then
                assert(RollbackSession.Checksum(checkpoint.state) == checkpoint.checksum, "checkpoint_checksum")
                assert(cursor.input_checksum == checkpoint.input_checksum, "input_checksum")
                assert(RollbackSession.Checksum(cursor.session.state) == checkpoint.checksum, "state_checksum")
                cursor.verified_frame = frame
                cursor.next_checkpoint += 1
            end
        end
        return cursor.session.state
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

function MatchReplay.Seek(cursor, frame)
    if type(frame) ~= "number" or frame % 1 ~= 0 or frame < 0 or frame > cursor.record.frames then
        return nil, "seek_frame"
    end
    local index = #cursor.record.checkpoints
    while cursor.record.checkpoints[index].frame > frame do index -= 1 end
    local checkpoint = cursor.record.checkpoints[index]
    if RollbackSession.Checksum(checkpoint.state) ~= checkpoint.checksum then
        return nil, "checkpoint_checksum"
    end
    cursor.session = RollbackSession.New(checkpoint.state, MatchSimulation.Step, cursor.record.config)
    cursor.session.last_input = RollbackSession.Predict(checkpoint.held)
    cursor.session.held_inputs[checkpoint.frame] = RollbackSession.Copy(cursor.session.last_input)
    cursor.input_checksum, cursor.next_checkpoint, cursor.verified_frame = checkpoint.input_checksum, index + 1, checkpoint.frame
    while cursor.session.state.frame < frame do
        local state, reason = MatchReplay.Advance(cursor, math.min(MAX_ADVANCE_FRAMES, frame - cursor.session.state.frame))
        if not state then
            return nil, reason
        end
    end
    return cursor.session.state
end

function MatchReplay.Verify(record)
    local cursor, reason = MatchReplay.Open(record)
    if not cursor then
        return {valid = false, frame = 0, reason = reason}
    end
    while cursor.session.state.frame < record.frames do
        local state
        state, reason = MatchReplay.Advance(cursor, math.min(MAX_ADVANCE_FRAMES, record.frames - cursor.session.state.frame))
        if not state then
            return {valid = false, frame = cursor.session.state.frame, reason = reason}
        end
    end
    if cursor.input_checksum ~= record.input_checksum then
        return {valid = false, frame = record.frames, reason = "input_checksum"}
    end
    if RollbackSession.Checksum(cursor.session.state) ~= record.final_checksum then
        return {valid = false, frame = record.frames, reason = "final_checksum"}
    end
    return {valid = true, frames = record.frames, checksum = record.final_checksum, complete = record.status == "Complete", state = cursor.session.state}
end

return MatchReplay
