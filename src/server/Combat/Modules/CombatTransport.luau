local CombatTransport = {}
CombatTransport.__index = CombatTransport

local SNAPSHOT_CACHE_SIZE = 16 -- About 0.8 seconds of baselines at the 20 Hz snapshot rate.
local INPUT_BATCH_LIMIT = 8 -- Bound the redundant frame records handled by one packet.
local INPUT_PACKET_LIMIT = 90 -- Allow normal 30 Hz batches with room for bursts, then drop excess.
local RESYNC_REQUEST_SECONDS = 0.5 -- Throttle full resync requests so clients cannot force constant serialization.
local SIMULATION_HZ = 60
local EVENT_HISTORY_FRAMES = 120
local INPUT_JITTER_FRAMES = 3 -- 50 ms of jitter allowance beyond measured one-way latency.

function CombatTransport.New(context)
    return setmetatable({matches = context.matches, remote = context.remote, codec = context.codec, clock = context.clock, server_time = context.server_time, ready_at = {}, packet_budgets = {}, resync = {}}, CombatTransport)
end

function CombatTransport:SendSnapshot(player, force_full)
    local match = self.matches[player]
    if not match or not player.Parent then
        return
    end
    debug.profilebegin("Combat.Snapshot")

    local session = match.session
    force_full = force_full or self.resync[player] == true
    self.resync[player] = nil
    match.snapshots = match.snapshots or {}
    match.snapshot_viewers = match.snapshot_viewers or {}
    local viewer = match.snapshot_viewers[player]
    if not viewer then
        viewer = {ack = 0, sent = {}}
        match.snapshot_viewers[player] = viewer
    end
    if force_full then
        viewer.ack = 0
    end

    local saved = match.latest_snapshot
    if not saved or saved.frame ~= session.state.frame or saved.rollbacks ~= session.rollback_count then
        local journal = {}
        for frame = math.max(0, session.state.frame - EVENT_HISTORY_FRAMES + 1), session.state.frame do
            local history = session.history[frame]
            if history and #history.events > 0 then
                journal[frame] = history.events
            end
        end
        match.snapshot_id = (match.snapshot_id or 0) + 1
        saved = {
            id = match.snapshot_id,
            frame = session.state.frame,
            rollbacks = session.rollback_count,
            body = {state = session:Snapshot(), journal = journal, config = session.config, held = session.last_input},
            encoded = {}
        }
        match.latest_snapshot = saved
        match.snapshots[saved.id] = saved
        for id in match.snapshots do if id <= saved.id - SNAPSHOT_CACHE_SIZE then match.snapshots[id] = nil end end
    end

    local baseline = match.snapshots[viewer.ack]
    local base_id = if baseline then baseline.id else 0
    local encoded = saved.encoded[base_id]
    if not encoded then
        encoded = self.codec.Encode(saved.body, baseline and baseline.body)
        saved.encoded[base_id] = encoded
    end
    viewer.sent[saved.id] = true
    for id in viewer.sent do if id <= saved.id - SNAPSHOT_CACHE_SIZE then viewer.sent[id] = nil end end

    self.remote:FireClient(player, "Snapshot", {epoch = match.epoch, arena_id = match.model.Name, id = saved.id, base_id = base_id, frame = saved.frame, payload = encoded, slot = if player == match.opponent then 1 else 2, sent_at = self.server_time(), lead = math.clamp(math.ceil(player:GetNetworkPing() * SIMULATION_HZ) + 2, 2, 14), rollbacks = session.rollback_count, rejected = match.rejected_inputs})
    debug.profileend()
end


function CombatTransport:HandleInput(player, kind, packet_epoch, batch, snapshot_ack)
    local now = self.clock()
    local match = self.matches[player]

    if kind == "Ready" then
        if match and now >= (self.ready_at[player] or 0) then
            self.ready_at[player] = now + RESYNC_REQUEST_SECONDS
            self.resync[player] = packet_epoch == match.epoch and batch == true
        end

        return
    end

    if kind ~= "Input" or not match or packet_epoch ~= match.epoch or type(batch) ~= "table" or #batch > INPUT_BATCH_LIMIT then
        return
    end

    local count = 0

    for key in batch do
        count += 1

        if count > INPUT_BATCH_LIMIT or type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > INPUT_BATCH_LIMIT then
            return
        end
    end

    local budget = self.packet_budgets[player]

    if not budget or now - budget.started >= 1 then
        budget = {started = now, packets = 0}
        self.packet_budgets[player] = budget
    end

    budget.packets += 1

    if budget.packets > INPUT_PACKET_LIMIT then
        return
    end

    local viewer = match.snapshot_viewers and match.snapshot_viewers[player]
    if viewer and type(snapshot_ack) == "number" and snapshot_ack % 1 == 0 and snapshot_ack > viewer.ack and viewer.sent[snapshot_ack] and match.snapshots[snapshot_ack] then
        viewer.ack = snapshot_ack
    end

    local latency_frames = math.ceil(player:GetNetworkPing() * SIMULATION_HZ) + INPUT_JITTER_FRAMES
    local late_frames = math.clamp(latency_frames, INPUT_JITTER_FRAMES, match.session.rollback_window)
    local accepted = {}
    -- Derive ownership from the server match, not a client-supplied slot.
    local slot = if player == match.opponent then 1 else 2
    for _, record in batch do
        local frame = type(record) == "table" and record.frame
        local existing = type(frame) == "number" and match.session.player_inputs and match.session.player_inputs[slot][frame]
        if type(frame) == "number" and frame % 1 == 0 and frame <= match.session.state.frame - late_frames and not existing then
            match.rejected_inputs += 1
        else
            table.insert(accepted, record)
        end
    end
    match.rejected_inputs += match.session:SubmitBatch(accepted, slot, true)
end

function CombatTransport:NeedsSnapshot(player)
    return self.resync[player] ~= nil
end

function CombatTransport:RemovePlayer(player)
    self.resync[player] = nil
    self.ready_at[player] = nil
    self.packet_budgets[player] = nil
end

return CombatTransport
