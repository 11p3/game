local ProfileStore = {}
local LEGACY_DATA_VERSION = 1
local JOURNAL_SHARD_COUNT = 16
local MAX_SAFE_INTEGER = 9007199254740991 -- 2^53 - 1 is the largest exactly represented integer.
local MAX_MATCH_ID_LENGTH = 100
ProfileStore.__index = ProfileStore

local DATA_VERSION = 2
local LEASE_SECONDS = 120 -- Two-minute lease gives autosaves room to renew before ownership expires.
local RECENT_RESULTS = 64 -- Bound the short cache; durable journal watermarks handle older retries.
local MAX_COUNT = 1000000000
local PREFERENCES = {CameraMode = {Behind = true, Side = true}, MovementKeys = {Camera = true, WS = true, AD = true}, ShowHitboxes = {On = true, Off = true}}

local function Count(value)
    return if type(value) == "number" and value == value and value >= 0 and value < math.huge then math.min(MAX_COUNT, math.floor(value)) else 0
end

local function Record(value)
    value = if type(value) == "table" then value else {}
    local wins = Count(value.wins)
    return {wins = wins, losses = Count(value.losses), draws = Count(value.draws), knockouts = math.min(wins, Count(value.knockouts))}
end

local function Normalize(value, styles)
    if value ~= nil and (type(value) ~= "table" or value.version ~= LEGACY_DATA_VERSION and value.version ~= DATA_VERSION) then
        return nil
    end

    value = value or {}
    local preferences = if type(value.preferences) == "table" then value.preferences else {}
    local data = {
        version = DATA_VERSION,
        preferences = {CameraMode = "Behind", MovementKeys = "Camera", StyleId = "Boxing", ShowHitboxes = "Off"},
        record = Record(value.record),
        styles = {},
        recent = {},
        journal_watermarks = {}
    }

    for key, options in PREFERENCES do
        if type(preferences[key]) == "string" and options[preferences[key]] then
            data.preferences[key] = preferences[key]
        end
    end

    if type(preferences.StyleId) == "string" and styles[preferences.StyleId] then
        data.preferences.StyleId = preferences.StyleId
    end

    for style_id in styles do
        data.styles[style_id] = Record(if type(value.styles) == "table" then value.styles[style_id] else nil)
    end

    if type(value.recent) == "table" then
        for _, match_id in value.recent do
            if type(match_id) == "string" and #match_id <= MAX_MATCH_ID_LENGTH and #data.recent < RECENT_RESULTS and not table.find(data.recent, match_id) then
                table.insert(data.recent, match_id)
            end
        end
    end

    if type(value.journal_watermarks) == "table" then
        for index = 1, JOURNAL_SHARD_COUNT do
            local key = tostring(index)
            local sequence = value.journal_watermarks[key]
            if type(sequence) == "number" and sequence % 1 == 0 and sequence >= 0 and sequence <= MAX_SAFE_INTEGER then
                data.journal_watermarks[key] = sequence
            end
        end
    end
    return data
end

local function AddRecord(data, match_id, style_id, outcome, knockout)
    if table.find(data.recent, match_id) then
        return false
    end
    data.record[outcome] = math.min(MAX_COUNT, data.record[outcome] + 1)
    if knockout then
        data.record.knockouts = math.min(MAX_COUNT, data.record.knockouts + 1)
    end
    local style = data.styles[style_id]
    if style then
        style[outcome] = math.min(MAX_COUNT, style[outcome] + 1)
        if knockout then
            style.knockouts = math.min(MAX_COUNT, style.knockouts + 1)
        end
    end
    table.insert(data.recent, 1, match_id)
    if #data.recent > RECENT_RESULTS then
        table.remove(data.recent)
    end
    return true
end

local function HasLease(value)
    local lease = type(value) == "table" and value.session
    return type(lease) == "table" and type(lease.id) == "string" and type(lease.expires_at) == "number" and lease.expires_at == lease.expires_at and lease.expires_at < math.huge
end

function ProfileStore.New(store, user_id, token, clock, styles)
    return setmetatable({store = store, user_id = user_id, user_ids = if user_id > 0 then {user_id} else {}, key = "Player_" .. user_id, token = token, clock = clock, styles = styles, data = nil, revision = 0, saved_revision = 0, lease_until = 0, busy = false, closed = false, lost = false, pending_results = {}}, ProfileStore)
end

function ProfileStore:IsReady()
    return self.data ~= nil and not self.closed and not self.lost and self.clock() < self.lease_until
end

function ProfileStore:Load()
    if self.busy or self.closed or self.data then
        return false, "Unavailable"
    end

    self.busy = true
    local reason = "Locked"
    local ok, result = pcall(function()
        return self.store:UpdateAsync(self.key, function(value, info)
            reason = "Locked"
            local data = Normalize(value, self.styles)

            if not data then
                reason = "Unsupported data"; return nil
            end
            if value and value.session ~= nil and not HasLease(value) then
                reason = "Invalid session"; return nil
            end
            if HasLease(value) and value.session.id ~= self.token and value.session.expires_at > self.clock() then
                return nil
            end

            data.session = {id = self.token, expires_at = self.clock() + LEASE_SECONDS}
            return data, self.user_ids, if info then info:GetMetadata() else {}
        end)
    end)
    self.busy = false

    if not ok then
        return false, "Request failed"
    end
    if not HasLease(result) or result.session.id ~= self.token then
        return false, reason
    end

    self.data = Normalize(result, self.styles)
    self.lease_until = result.session.expires_at
    return true
end

function ProfileStore:SetPreference(key, value)
    if not self:IsReady() or type(value) ~= "string" then
        return false
    end
    if key == "StyleId" then
        if not self.styles[value] then
            return false
        end
    elseif not PREFERENCES[key] or not PREFERENCES[key][value] then
        return false
    end

    if self.data.preferences[key] ~= value then
        self.data.preferences[key] = value
        self.revision += 1
    end

    return true
end

function ProfileStore:AddResult(match_id, style_id, outcome, knockout)
    if not self:IsReady() or type(match_id) ~= "string" or #match_id == 0 or #match_id > MAX_MATCH_ID_LENGTH or not self.styles[style_id] or (outcome ~= "wins" and outcome ~= "losses" and outcome ~= "draws") then
        return false
    end
    if knockout ~= nil and type(knockout) ~= "boolean" then
        return false
    end
    if knockout and outcome ~= "wins" then
        return false
    end
    if table.find(self.data.recent, match_id) then
        return false
    end

    AddRecord(self.data, match_id, style_id, outcome, knockout)
    table.insert(self.pending_results, {id = match_id, style_id = style_id, outcome = outcome, knockout = knockout == true})
    self.revision += 1
    return true
end

-- Apply each shard sequence once so retried results cannot count twice.
function ProfileStore.ApplyJournal(value, styles, entry, participant)
    local data = assert(Normalize(value, styles), "Unsupported profile data")
    local key = tostring(entry.shard)
    if entry.sequence > (data.journal_watermarks[key] or 0) then
        AddRecord(data, entry.id, participant.style_id, participant.outcome, participant.knockout)
        data.journal_watermarks[key] = entry.sequence
    end
    data.session = if type(value) == "table" then value.session else nil
    return data
end

function ProfileStore:RefreshResults(value)
    local saved = Normalize(value, self.styles)
    if not saved or not self.data then
        return
    end
    for key, count in saved.record do
        self.data.record[key] = math.max(self.data.record[key], count)
    end
    for style_id, record in saved.styles do
        for key, count in record do
            self.data.styles[style_id][key] = math.max(self.data.styles[style_id][key], count)
        end
    end
    for key, sequence in saved.journal_watermarks do
        self.data.journal_watermarks[key] = math.max(self.data.journal_watermarks[key] or 0, sequence)
    end
    for index = #saved.recent, 1, -1 do
        local id = saved.recent[index]
        if not table.find(self.data.recent, id) then
            table.insert(self.data.recent, 1, id)
        end
    end
    while #self.data.recent > RECENT_RESULTS do table.remove(self.data.recent) end
end

function ProfileStore:Save(release)
    if self.busy or self.closed then
        return false, "Unavailable"
    end
    if not release and not self:IsReady() then
        self.lost = true; return false, "Session lost"
    end

    local payload = if self.data then Normalize(self.data, self.styles) else nil
    -- Capture the revision so edits during a yielding save remain pending.
    local revision = self.revision
    local pending = table.clone(self.pending_results)
    local reason = "Session lost"
    self.busy = true

    local ok, result = pcall(function()
        return self.store:UpdateAsync(self.key, function(value, info)
            reason = "Session lost"

            if not HasLease(value) or value.session.id ~= self.token then
                if release then
                    reason = "Released"
                end
                return nil
            end
            if value.version ~= LEGACY_DATA_VERSION and value.version ~= DATA_VERSION then
                return nil
            end

            local data

            if payload and value.session.expires_at > self.clock() and not self.lost then
                data = Normalize(payload, self.styles)
                local stored = assert(Normalize(value, self.styles))
                data.record, data.styles, data.recent, data.journal_watermarks = stored.record, stored.styles, stored.recent, stored.journal_watermarks
                for _, result in pending do
                    AddRecord(data, result.id, result.style_id, result.outcome, result.knockout)
                end
            elseif release then
                data = table.clone(value)
            else
                return nil
            end

            data.session = if release then nil else {id = self.token, expires_at = self.clock() + LEASE_SECONDS}
            return data, self.user_ids, if info then info:GetMetadata() else {}
        end)
    end)
    self.busy = false

    if not ok then
        return false, "Request failed"
    end

    if release and (result ~= nil or reason == "Released") then
        self.closed = true
        return true
    end

    if not HasLease(result) or result.session.id ~= self.token then
        self.lost = true; return false, reason
    end

    for _ = 1, #pending do
        table.remove(self.pending_results, 1)
    end
    self:RefreshResults(result)
    self.lease_until = result.session.expires_at
    self.saved_revision = revision
    return true
end

return ProfileStore
