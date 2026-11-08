local ProfileStore = require(script.Parent.ProfileStore)
local ResultJournal = {}
local JOURNAL_VERSION = 1
local MAX_MATCH_ID_LENGTH = 100
local IDENTITY_VERSION = 1
local STORE_KEY_BYTES = 50 -- Split identity between scope and key to fit datastore name limits.
local SHORT_ID_SCOPE = "Short"
local MAX_DRAIN_RESULTS = 4 -- Bound datastore work before yielding the journal to another drain.
-- DJB2 distributes result IDs across shards; it is not a security hash.
local HASH_SEED = 5381 -- Standard DJB2 starting seed, not a gameplay tuning value.
local HASH_MULTIPLIER = 33 -- 32 + 1 is DJB2's mixing step, paired with the 5381 seed.
local HASH_MODULUS = 4294967296 -- 2^32 wraps the rolling hash to an unsigned 32-bit value.
ResultJournal.__index = ResultJournal
ResultJournal.SHARDS = 16
local MAX_PENDING = 64
local MAX_RECENT = 128
local LEASE_SECONDS = 30 -- Expire abandoned drain ownership so another server can retry.

local function Bucket(value)
    if value == nil then
        return {version = JOURNAL_VERSION, sequence = 0, pending = {}, recent = {}}
    end
    assert(type(value) == "table" and value.version == JOURNAL_VERSION and type(value.pending) == "table" and type(value.recent) == "table", "Unsupported result journal")
    return value
end

local function Same(first, second)
    for index = 1, 2 do
        local a, b = first[index], second[index]
        if not a or not b or a.user_id ~= b.user_id or a.style_id ~= b.style_id or a.outcome ~= b.outcome or a.knockout ~= b.knockout then
            return false
        end
    end
    return true
end

function ResultJournal.New(store, styles, token, clock, notify, confirm)
    return setmetatable({store = store, styles = styles, token = token, clock = clock, notify = notify, confirm = confirm, busy = {}}, ResultJournal)
end

function ResultJournal:Receipt(id, participants, entry, complete)
    local scope = if #id <= STORE_KEY_BYTES then SHORT_ID_SCOPE else string.sub(id, 1, STORE_KEY_BYTES)
    local key = if #id <= STORE_KEY_BYTES then id else string.sub(id, STORE_KEY_BYTES + 1)
    local receipt

    -- Keep a durable receipt after the bounded recent-results cache expires.
    self.store:UpdateAsync(key, function(value)
        if value then
            assert(type(value) == "table" and value.version == IDENTITY_VERSION and value.id == id and Same(value.participants, participants), "Conflicting result identity")
            receipt = value
            if value.entry and (not complete or value.entry.complete) then
                return nil
            end
        else
            receipt = {version = IDENTITY_VERSION, id = id, participants = participants}
        end

        if not entry then
            return if value then nil else receipt
        end

        local saved = table.clone(receipt)
        saved.entry = table.clone(saved.entry or entry)
        if complete then
            saved.entry.complete = true
        end
        receipt = saved
        return saved
    end, scope)

    return receipt.entry
end

function ResultJournal:Commit(id, participants)
    assert(type(id) == "string" and #id > 0 and #id <= MAX_MATCH_ID_LENGTH and not id:find("[^ -~]") and type(participants) == "table" and #participants == 2, "Invalid result identity")
    for _, participant in participants do
        assert(type(participant.user_id) == "number" and participant.user_id % 1 == 0 and type(participant.style_id) == "string", "Invalid result participant")
        assert(participant.outcome == "wins" or participant.outcome == "losses" or participant.outcome == "draws", "Invalid result outcome")
        assert(type(participant.knockout) == "boolean" and (not participant.knockout or participant.outcome == "wins"), "Invalid knockout")
    end
    assert(participants[1].user_id ~= participants[2].user_id, "Duplicate participant")
    local hash = HASH_SEED
    for index = 1, #id do
        hash = (hash * HASH_MULTIPLIER + string.byte(id, index)) % HASH_MODULUS
    end
    local shard = hash % ResultJournal.SHARDS + 1
    local entry
    local ok, reason = pcall(function()
        entry = self:Receipt(id, participants)
        if entry then
            return
        end

        self.store:UpdateAsync("Results_" .. shard, function(value)
            local bucket = Bucket(value)
            for _, collection in {bucket.pending, bucket.recent} do
                for _, saved in collection do
                    if saved.id == id then
                        assert(Same(saved.participants, participants), "Conflicting result")
                        entry = saved
                        return nil
                    end
                end
            end
            assert(#bucket.pending < MAX_PENDING, "Result journal is full")
            bucket.sequence += 1
            entry = {id = id, shard = shard, sequence = bucket.sequence, participants = participants}
            table.insert(bucket.pending, entry)
            return bucket
        end)

        entry = self:Receipt(id, participants, entry, entry.complete)
    end)
    if not ok then
        return nil, tostring(reason)
    end
    return entry
end

function ResultJournal:Drain(shard, limit)
    if self.busy[shard] then
        return false, "Busy"
    end
    self.busy[shard] = true
    local completed = {}
    local ok, reason = pcall(function()
        local owned = false
        local bucket = self.store:UpdateAsync("Results_" .. shard, function(value)
            owned = false
            local current = Bucket(value)
            if #current.pending == 0 then
                return nil
            end
            if current.owner and current.owner ~= self.token and current.lease_until > self.clock() then
                return nil
            end
            current.owner, current.lease_until = self.token, self.clock() + LEASE_SECONDS
            owned = true
            return current
        end)
        if not owned or not bucket then
            return
        end
        for _ = 1, math.clamp(limit or MAX_DRAIN_RESULTS, 1, MAX_DRAIN_RESULTS) do
            local entry = bucket.pending[1]
            if not entry then
                break
            end
            local stable_entry = self:Receipt(entry.id, entry.participants, entry)
            for _, participant in stable_entry.participants do
                local saved = self.store:UpdateAsync("Player_" .. participant.user_id, function(value, info)
                    local data = ProfileStore.ApplyJournal(value, self.styles, stable_entry, participant)
                    return data, if participant.user_id > 0 then {participant.user_id} else {}, if info then info:GetMetadata() else {}
                end)
                assert(saved and (saved.journal_watermarks[tostring(shard)] or 0) >= stable_entry.sequence, "Result write was not confirmed")
                if self.notify then
                    self.notify(participant.user_id, saved, stable_entry.id)
                end
            end
            self:Receipt(entry.id, entry.participants, stable_entry, true)
            -- Only report Saved after both player writes and the receipt are confirmed.
            if self.confirm then self.confirm(stable_entry) end

            local removed = false
            bucket = self.store:UpdateAsync("Results_" .. shard, function(value)
                local current = Bucket(value)
                if current.owner ~= self.token or not current.pending[1] or current.pending[1].sequence ~= entry.sequence then
                    return nil
                end
                table.remove(current.pending, 1)
                local receipt = table.clone(entry)
                receipt.complete = true
                table.insert(current.recent, 1, receipt)
                if #current.recent > MAX_RECENT then
                    table.remove(current.recent)
                end
                current.lease_until = self.clock() + LEASE_SECONDS
                removed = true
                return current
            end)
            if not removed or not bucket then
                break
            end
            table.insert(completed, entry.id)
        end
        self.store:UpdateAsync("Results_" .. shard, function(value)
            local current = Bucket(value)
            if current.owner ~= self.token then
                return nil
            end
            current.owner, current.lease_until = nil, nil
            return current
        end)
    end)
    self.busy[shard] = nil
    return ok, if ok then completed else tostring(reason)
end

return ResultJournal
