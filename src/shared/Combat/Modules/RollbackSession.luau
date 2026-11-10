local TrainingSimulation = require(script.Parent.TrainingSimulation)

local RollbackSession = {}
local HASH_SEED = 5381 -- DJB2 seed.
local HASH_MULTIPLIER = 33 -- DJB2 multiplies by 33 before adding each byte.
local HASH_MODULUS = 4294967296 -- 2^32 wraps the rolling hash to an unsigned 32-bit value.
local HASH_BLOCK_BYTES = 4 -- Four-byte products stay below the exact-integer limit of 2^53.
local HASH_BLOCK_MULTIPLIER = HASH_MULTIPLIER ^ HASH_BLOCK_BYTES
local HASH_THIRD_WEIGHT = HASH_MULTIPLIER ^ 3
local HASH_SECOND_WEIGHT = HASH_MULTIPLIER ^ 2
local DEFAULT_HISTORY_FRAMES = 120 -- Two seconds covers snapshot gaps while keeping memory per bout bounded.
local DEFAULT_ROLLBACK_FRAMES = 12 -- 200 ms trades late-input recovery against undoing hits already seen.
local DEFAULT_FUTURE_FRAMES = 18 -- Room for 14 frames of lead, 2 of input delay and 2 of scheduling slack.
local INPUT_FIELDS = {"axis", "strafe", "guard", "jab", "dodge", "special", "kick", "technique", "clinch", "training"}
RollbackSession.InputFields = table.freeze(INPUT_FIELDS)

RollbackSession.__index = RollbackSession

function RollbackSession.Copy(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}

    for key, item in value do
        result[key] = RollbackSession.Copy(item)
    end

    return result
end

-- Keep held controls, but never repeat a missing attack or dodge.
function RollbackSession.Predict(input)
    return {
        axis = if input then input.axis or 0 else 0,
        guard = input ~= nil and input.guard == true,
        jab = false,
        dodge = false,
        strafe = if input then input.strafe or 0 else 0,
        axis_one = if input then input.axis_one or 0 else 0,
        guard_one = input ~= nil and input.guard_one == true,
        jab_one = false,
        dodge_one = false,
        strafe_one = if input then input.strafe_one or 0 else 0,
        special = false,
        special_one = false,
        kick = false,
        kick_one = false,
        technique = false,
        technique_one = false,
        clinch = false,
        clinch_one = false,
        training = "",
        training_one = ""
    }
end

function RollbackSession.SameInput(a, b)
    return a ~= nil and b ~= nil and a.axis == b.axis and a.guard == b.guard and a.jab == b.jab and a.dodge == b.dodge and (a.strafe or 0) == (b.strafe or 0) and (a.training or "") == (b.training or "") and (a.training_one or "") == (b.training_one or "") and (a.clinch == true) == (b.clinch == true) and (a.clinch_one == true) == (b.clinch_one == true) and (a.technique == true) == (b.technique == true) and (a.technique_one == true) == (b.technique_one == true) and (a.kick == true) == (b.kick == true) and (a.kick_one == true) == (b.kick_one == true) and (a.special == true) == (b.special == true) and (a.special_one == true) == (b.special_one == true) and (a.axis_one or 0) == (b.axis_one or 0) and (a.guard_one == true) == (b.guard_one == true) and (a.jab_one == true) == (b.jab_one == true) and (a.dodge_one == true) == (b.dodge_one == true) and (a.strafe_one or 0) == (b.strafe_one or 0)
end

function RollbackSession.Equals(a, b)
    if type(a) ~= type(b) then
        return false
    end

    if type(a) ~= "table" then
        return a == b
    end

    for key, value in a do
        if not RollbackSession.Equals(value, b[key]) then
            return false
        end
    end

    for key in b do
        if a[key] == nil then
            return false
        end
    end

    return true
end

function RollbackSession.Checksum(state)
    local hash = HASH_SEED

    local function Hash(value)
        local kind = type(value)

        if kind == "table" then
            local keys = {}
            local key_kind
            local uniform = true

            for key in value do
                local current_kind = type(key)
                if key_kind and key_kind ~= current_kind then uniform = false end
                key_kind = current_kind
                table.insert(keys, key)
            end

            -- Sort keys so table iteration order cannot change the checksum.
            if uniform and (key_kind == "string" or key_kind == "number") then
                table.sort(keys)
            else
                table.sort(keys, function(a, b)
                    if type(a) ~= type(b) then
                        return type(a) < type(b)
                    end

                    return if type(a) == "number" or type(a) == "string" then a < b else tostring(a) < tostring(b)
                end)
            end

            Hash("{")

            for _, key in keys do
                Hash(key)
                Hash(value[key])
            end

            Hash("}")
        else
            local encoded = kind .. ":" .. (if kind == "number" then string.format("%.17g", value) else tostring(value))

            encoded = tostring(#encoded) .. ":" .. encoded

            local block_end = #encoded - #encoded % HASH_BLOCK_BYTES
            for index = 1, block_end, HASH_BLOCK_BYTES do
                local first, second, third, fourth = string.byte(encoded, index, index + HASH_BLOCK_BYTES - 1)
                hash = (hash * HASH_BLOCK_MULTIPLIER + first * HASH_THIRD_WEIGHT + second * HASH_SECOND_WEIGHT + third * HASH_MULTIPLIER + fourth) % HASH_MODULUS
            end
            for index = block_end + 1, #encoded do
                hash = (hash * HASH_MULTIPLIER + string.byte(encoded, index)) % HASH_MODULUS
            end
        end
    end

    Hash(state)

    return hash
end

function RollbackSession.New(initial_state, step_function, config)
    local frame = initial_state.frame or 0
    local state = RollbackSession.Copy(initial_state)

    state.frame = frame

    local neutral = RollbackSession.Predict(nil)

    return setmetatable({state = state, frame = frame, trimmed_before = frame - (if config then config.history_size or DEFAULT_HISTORY_FRAMES else DEFAULT_HISTORY_FRAMES), inputs = {}, used_inputs = {}, history = {[frame] = RollbackSession.Copy(state)}, held_inputs = {[frame] = neutral}, last_input = neutral, step_function = step_function, config = config or {}, rollback_window = if config then config.rollback_window or DEFAULT_ROLLBACK_FRAMES else DEFAULT_ROLLBACK_FRAMES, history_size = if config then config.history_size or DEFAULT_HISTORY_FRAMES else DEFAULT_HISTORY_FRAMES, future_window = if config then config.future_window or DEFAULT_FUTURE_FRAMES else DEFAULT_FUTURE_FRAMES, rollback_count = 0, replayed_frames = 0, last_rollback_frame = nil, last_authoritative_frame = frame - 1}, RollbackSession)
end

function RollbackSession:Trim()
    local oldest = self.state.frame - self.history_size
    local previous = self.trimmed_before or oldest
    if oldest <= previous then
        return
    end
    local entries = {self.inputs, self.used_inputs, self.history, self.held_inputs}
    if self.player_inputs then
        table.insert(entries, self.player_inputs[1])
        table.insert(entries, self.player_inputs[2])
    end

    if oldest - previous > self.history_size + self.future_window then
        for _, records in entries do
            for frame in records do if frame < oldest then records[frame] = nil end end
        end
    else
        for frame = previous, oldest - 1 do
            for _, records in entries do
                records[frame] = nil
            end
        end
    end
    self.trimmed_before = oldest
end

function RollbackSession:StepFrame()
    local frame = self.state.frame + 1
    local input = self.inputs[frame] or RollbackSession.Predict(self.last_input)

    if self.player_inputs then
        input = RollbackSession.Predict(self.last_input)

        for slot = 1, 2 do
            local accepted = self.player_inputs[slot][frame]

            if accepted then
                local suffix = if slot == 1 then "_one" else ""

                for _, key in INPUT_FIELDS do
                    input[key .. suffix] = accepted[key]
                end
            end
        end
    end

    -- Commands contain only scalars; nested fight state still needs deep copies.
    local resolved = table.clone(input)

    self.used_inputs[frame] = resolved
    debug.profilebegin("Combat.SimulationStep")
    self.step_function(self.state, table.clone(resolved), self.config)
    debug.profileend()
    self.state.frame = frame
    self.frame = frame
    self.last_input = RollbackSession.Predict(resolved)
    self.history[frame] = RollbackSession.Copy(self.state)
    self.held_inputs[frame] = table.clone(self.last_input)
    self:Trim()
end

function RollbackSession:Submit(frame: number, input)
    if type(frame) ~= "number" or frame ~= frame or frame % 1 ~= 0 or frame < 1 then
        return false, "invalid_frame"
    end

    if type(input) ~= "table" or (input.axis ~= -1 and input.axis ~= 0 and input.axis ~= 1) then
        return false, "invalid_input"
    end

    for _, key in {"guard", "jab", "dodge", "special", "kick", "technique", "clinch"} do
        if type(input[key]) ~= "boolean" and not ((key == "special" or key == "kick" or key == "technique" or key == "clinch") and input[key] == nil) then
            return false, "invalid_input"
        end
    end

    if input.strafe ~= nil and input.strafe ~= -1 and input.strafe ~= 0 and input.strafe ~= 1 then
        return false, "invalid_input"
    end

    if input.training ~= nil and (type(input.training) ~= "string" or (input.training ~= "" and not TrainingSimulation.Actions[input.training])) then
        return false, "invalid_input"
    end

    local current = self.state.frame

    if frame <= current - self.rollback_window then
        return false, "stale"
    end

    if frame > current + self.future_window then
        return false, "future"
    end

    local accepted = self.inputs[frame]

    if accepted then
        local same = RollbackSession.SameInput(accepted, input)

        return same, if same then "duplicate" else "conflict"
    end

    if frame <= current and not self.history[frame - 1] then
        return false, "history_missing"
    end

    self.inputs[frame] = {
        axis = input.axis,
        guard = input.guard,
        jab = input.jab,
        dodge = input.dodge,
        strafe = input.strafe or 0,
        axis_one = input.axis_one or 0,
        guard_one = input.guard_one == true,
        jab_one = input.jab_one == true,
        dodge_one = input.dodge_one == true,
        strafe_one = input.strafe_one or 0,
        special = input.special == true,
        special_one = input.special_one == true,
        kick = input.kick == true,
        kick_one = input.kick_one == true,
        technique = input.technique == true,
        technique_one = input.technique_one == true,
        clinch = input.clinch == true,
        clinch_one = input.clinch_one == true,
        training = input.training or "",
        training_one = input.training_one or ""
    }

    if frame > current or RollbackSession.SameInput(self.used_inputs[frame], input) then
        return true, "accepted"
    end

    if self.defer_replay then
        self.replay_from = math.min(self.replay_from or frame, frame)
        return true, "deferred"
    end

    self:ReplayFrom(frame)
    return true, "rollback"
end

function RollbackSession:ReplayFrom(frame: number)
    local current = self.state.frame
    self.state = RollbackSession.Copy(self.history[frame - 1])
    self.frame = self.state.frame
    self.last_input = RollbackSession.Copy(self.held_inputs[frame - 1])
    self.rollback_count += 1
    self.last_rollback_frame = frame

    debug.profilebegin("Combat.LateInputReplay")

    for replay_frame = frame, current do
        self:StepFrame()
        self.replayed_frames += 1
    end

    debug.profileend()


end

function RollbackSession:SubmitBatch(batch, slot, defer)
    if type(batch) ~= "table" or (slot ~= 1 and slot ~= 2) then
        return 1
    end
    assert(not self.defer_replay, "Input batches cannot be nested")
    self.defer_replay = true
    self.replay_from = nil
    local rejected = 0
    for _, record in batch do
        if type(record) ~= "table" or not self:SubmitPlayer(record.frame, record.input, slot) then
            rejected += 1
        end
    end
    self.defer_replay = false
    local replay_from = self.replay_from
    self.replay_from = nil
    if replay_from then
        self.pending_replay_from = math.min(self.pending_replay_from or replay_from, replay_from)
        if not defer then
            self:FlushInputs()
        end
    end
    return rejected
end

function RollbackSession:FlushInputs()
    local frame = self.pending_replay_from
    if not frame then
        return false
    end
    self.pending_replay_from = nil
    self:ReplayFrom(frame)
    return true
end

function RollbackSession:Advance(input)
    self:FlushInputs()
    if input then
        local accepted, reason = self:Submit(self.state.frame + 1, input)

        if not accepted then
            return false, reason
        end
    end

    self:StepFrame()

    return self.state
end

function RollbackSession:Reconcile(authoritative_state, authoritative_input)
    if type(authoritative_state) ~= "table" then
        return false, "invalid_snapshot"
    end

    local frame = authoritative_state.frame

    if type(frame) ~= "number" or frame ~= frame or frame % 1 ~= 0 or frame < 0 then
        return false, "invalid_snapshot"
    end

    if frame <= self.last_authoritative_frame then
        return false, "stale_snapshot"
    end

    local current = self.state.frame

    if current - frame > self.history_size then
        return false, "snapshot_too_old"
    end

    self.last_authoritative_frame = frame

    local expected_held = if authoritative_input then RollbackSession.Predict(authoritative_input) else nil

    if self.history[frame] and RollbackSession.Equals(self.history[frame], authoritative_state) and (not expected_held or RollbackSession.SameInput(expected_held, self.held_inputs[frame])) then
        return true, "confirmed"
    end

    local held = expected_held or self.held_inputs[frame]

    if not held then
        local latest = -1

        for input_frame, input in self.inputs do
            if input_frame <= frame and input_frame > latest then
                latest = input_frame
                held = RollbackSession.Predict(input)
            end
        end
    end

    self.state = RollbackSession.Copy(authoritative_state)
    self.frame = frame
    self.last_input = RollbackSession.Copy(held or RollbackSession.Predict(nil))

    for saved_frame in self.history do
        if saved_frame >= frame then
            self.history[saved_frame] = nil
            self.held_inputs[saved_frame] = nil
            self.used_inputs[saved_frame] = nil
        end
    end

    self.history[frame] = RollbackSession.Copy(self.state)
    self.held_inputs[frame] = RollbackSession.Copy(self.last_input)

    if frame < current then
        self.rollback_count += 1
        self.last_rollback_frame = frame

        debug.profilebegin("Combat.SnapshotReplay")

        for replay_frame = frame + 1, current do
            self:StepFrame()
            self.replayed_frames += 1
        end
        debug.profileend()
    else
        self:Trim()
    end

    return true, if frame > current then "advanced" else "reconciled"
end

function RollbackSession:Snapshot()
    return RollbackSession.Copy(self.state)
end

function RollbackSession:SubmitPlayer(frame: number, input, slot: number)
    if slot ~= 1 and slot ~= 2 then
        return false, "slot"
    end

    if type(frame) ~= "number" or frame ~= frame or frame % 1 ~= 0 or frame <= self.state.frame - self.rollback_window or frame > self.state.frame + self.future_window or frame < 1 then
        return false, "frame"
    end

    if type(input) ~= "table" or (input.axis ~= -1 and input.axis ~= 0 and input.axis ~= 1) then
        return false, "input"
    end

    for _, key in {
        "guard",
        "jab",
        "dodge",
        "special",
        "kick",
        "technique",
        "clinch"
    } do if type(input[key]) ~= "boolean" and not ((key == "special" or key == "kick" or key == "technique" or key == "clinch") and input[key] == nil) then return false, "input" end end

    if input.strafe ~= nil and input.strafe ~= -1 and input.strafe ~= 0 and input.strafe ~= 1 then
        return false, "input"
    end
    if input.training ~= nil and (type(input.training) ~= "string" or (input.training ~= "" and not TrainingSimulation.Actions[input.training])) then
        return false, "input"
    end
    self.player_inputs = self.player_inputs or {{}, {}}

    local accepted = self.player_inputs[slot][frame]
    local normalized = {
        axis = input.axis,
        strafe = input.strafe or 0,
        guard = input.guard,
        jab = input.jab,
        dodge = input.dodge,
        special = input.special == true,
        kick = input.kick == true,
        technique = input.technique == true,
        clinch = input.clinch == true,
        training = input.training or ""
    }

    if accepted then
        local same = RollbackSession.SameInput(accepted, normalized)

        return same, if same then "duplicate" else "conflict"
    end

    local previous = self.inputs[frame]
    local combined = RollbackSession.Copy(previous or self.used_inputs[frame] or RollbackSession.Predict(self.last_input))

    for _, key in INPUT_FIELDS do combined[key .. (if slot == 1 then "_one" else "")] = normalized[key] end
    -- Rebuild the combined frame without replacing either player's accepted input.
    self.player_inputs[slot][frame] = normalized
    self.inputs[frame] = nil

    local ok, reason = self:Submit(frame, combined)

    if not ok then
        self.inputs[frame] = previous
        self.player_inputs[slot][frame] = nil
    end


    return ok, reason
end

return RollbackSession
