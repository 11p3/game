local PlayerData = {}
local INITIAL_RETRY_SECONDS = 0.5
local MAX_RETRY_SECONDS = 4 -- Cap retry backoff so recovery stays responsive without tight request loops.
local SAVE_DEADLINE_SECONDS = 25 -- Leave shutdown headroom instead of waiting indefinitely for storage.
local LEASE_SAFETY_SECONDS = 5 -- Stop readiness shortly before the persistence lease expires.
local RESULT_JOB_RETENTION_SECONDS = 120
local JOURNAL_SCAN_SECONDS = 5
local SETTINGS_REQUEST_SECONDS = 0.1
local ProfileStore = require(script.Parent.ProfileStore)
local ResultJournal = require(script.Parent.ResultJournal)
local journal
local result_jobs = {}
local records = {}
local closing = false
local shutdown
local Players
local Styles
local studio = false
local AUTOSAVE_SECONDS = 30

local function Publish(player, profile)
    for key, value in profile.data.preferences do
        player:SetAttribute(key, if key == "ShowHitboxes" and not studio then "Off" else value)
    end
    local leaderboard = player:FindFirstChild("leaderstats")

    if not leaderboard then
        leaderboard = Instance.new("Folder")
        leaderboard.Name = "leaderstats"
        leaderboard.Parent = player
    end

    for key, value in profile.data.record do
        local name = string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
        local stat = leaderboard:FindFirstChild(name)

        if not stat then
            stat = Instance.new("IntValue")
            stat.Name = name
            stat.Parent = leaderboard
        end

        stat.Value = value
        player:SetAttribute("PvP" .. name, value)
    end
    for style_id, stats in profile.data.styles do
        for key, value in stats do
            player:SetAttribute(style_id .. "PvP" .. string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2), value)
        end
    end

    local character = player.Character
    if character and player:GetAttribute("MatchStatus") ~= "Fighting" then
        character:SetAttribute("FighterId", Styles[profile.data.preferences.StyleId].FighterId)
    end
end

local function Work(record)
    if record.working then
        return
    end
    record.working = true

    task.spawn(function()
        local player = record.player
        local profile = record.profile
        local delay_seconds = INITIAL_RETRY_SECONDS

        while not profile.data and not record.failed and not record.release do
            local loaded, reason = profile:Load()

            if loaded then
                if player.Parent == Players and not record.release then
                    Publish(player, profile)
                    player:SetAttribute("DataStatus", if studio then "Studio" else "Ready")
                    player:SetAttribute("DataSaveState", "Saved")
                end
                -- Spread autosaves across eleven offsets to avoid a join-time request spike.
                record.next_save = os.clock() + AUTOSAVE_SECONDS + player.UserId % 11
                break
            end

            if reason == "Unsupported data" or reason == "Invalid session" or os.clock() >= record.deadline then
                record.failed = true
                record.deadline = os.clock() + 5
                player:SetAttribute("DataStatus", "Unavailable")
                player:SetAttribute("DataSaveState", "Not saved")
                warn("Player data unavailable for " .. player.UserId .. ": " .. reason)
                break
            end

            task.wait(math.min(delay_seconds, math.max(0, record.deadline - os.clock())))
            delay_seconds = math.min(delay_seconds * 2, MAX_RETRY_SECONDS)
        end

        delay_seconds = INITIAL_RETRY_SECONDS

        while true do
            if profile.closed then
                break
            end
            local release = record.release or record.failed
            if not release and os.clock() < record.next_save then
                break
            end
            if release and os.clock() >= record.deadline then
                break
            end

            if player.Parent == Players and not release then
                player:SetAttribute("DataSaveState", "Saving")
            end
            local saved, reason = profile:Save(release)

            if saved then
                record.next_save = os.clock() + (if profile.revision > profile.saved_revision then 5 else AUTOSAVE_SECONDS + player.UserId % 11)
                if player.Parent == Players and not release then Publish(player, profile); player:SetAttribute("DataSaveState", if profile.revision > profile.saved_revision then "Pending" else "Saved") end
                if release then
                    break
                end
                if record.release then
                    continue
                end
                break
            end

            if reason == "Session lost" or profile.lost then
                record.failed = true
                player:SetAttribute("DataStatus", "Unavailable")
                player:SetAttribute("DataSaveState", "Not saved")
                break
            end

            if player.Parent == Players and not release then
                player:SetAttribute("DataSaveState", "Retrying")
            end
            if not release and delay_seconds >= MAX_RETRY_SECONDS then
                record.next_save = os.clock() + 5; break
            end
            task.wait(math.min(delay_seconds, if release then math.max(0, record.deadline - os.clock()) else delay_seconds))
            delay_seconds = math.min(delay_seconds * 2, MAX_RETRY_SECONDS)
        end

        record.working = false

        if record.release and (profile.closed or os.clock() >= record.deadline) then
            if not profile.closed then
                warn("Player data save deadline reached for " .. player.UserId)
            end
            if records[player] == record then
                records[player] = nil
            end
        elseif record.release then
            Work(record)
        end
    end)
end

function PlayerData.IsReady(player)
    local record = records[player]
    return not closing and record ~= nil and not record.release and not record.failed and record.profile:IsReady() and os.time() + LEASE_SAFETY_SECONDS < record.profile.lease_until
end

function PlayerData.IsLoading(player)
    local record = records[player]
    return record ~= nil and not record.failed and record.profile.data == nil
end

function PlayerData.IsClosing()
    return closing
end

function PlayerData.SetStyle(player, style_id)
    local record = records[player]
    if not Styles[style_id] then
        return
    end
    if record and record.profile:SetPreference("StyleId", style_id) then
        record.next_save = math.min(record.next_save, os.clock() + 5)
        player:SetAttribute("DataSaveState", "Pending")
    end
    player:SetAttribute("StyleId", style_id)
end

function PlayerData.RecordResult(match_id, participants, style_ids, loser, finish_reason)
    if closing or participants[1] == participants[2] or (loser ~= 0 and loser ~= 1 and loser ~= 2) then
        return false
    end

    local duplicate = 0
    for slot = 1, 2 do
        local player = participants[slot]
        if not PlayerData.IsReady(player) or not Styles[style_ids[slot]] then
            return false
        end
        if table.find(records[player].profile.data.recent, match_id) then
            duplicate += 1
        end
    end
    if duplicate > 0 then
        return duplicate == 2
    end

    local job = result_jobs[match_id]
    if job then
        return job.committed
    end
    local entries = {}
    for slot = 1, 2 do
        local outcome = if loser == 0 then "draws" elseif loser == slot then "losses" else "wins"
        entries[slot] = {
            user_id = participants[slot].UserId,
            style_id = style_ids[slot],
            outcome = outcome,
            knockout = outcome == "wins" and (finish_reason == "KO" or finish_reason == "TKO")
        }
        local player = participants[slot]
        records[player].pending_result_ids[match_id] = true
        player:SetAttribute("ResultSaveState", "Pending")
        player:SetAttribute("DataSaveState", "Pending")
    end
    job = {committed = false, participants = participants, entries = entries, started = os.clock()}
    result_jobs[match_id] = job
    task.spawn(function()
        local delay_seconds = INITIAL_RETRY_SECONDS
        while not job.committed and (not closing or os.clock() < (job.deadline or math.huge)) do
            local entry = journal:Commit(match_id, entries)
            if entry then
                job.committed = true
                journal:Drain(entry.shard)
                for _, player in participants do
                    local record = records[player]
                    if record and not record.release then
                        record.next_save = 0; Work(record)
                    end
                end
            else
                for _, player in participants do
                    if player.Parent == Players then player:SetAttribute("ResultSaveState", "Retrying") end
                end
                task.wait(delay_seconds)
                delay_seconds = math.min(5, delay_seconds * 2)
            end
        end
    end)
    return false
end

function PlayerData.Release(player)
    local record = records[player]
    if not record or record.release then
        return
    end
    record.release = true
    record.deadline = os.clock() + SAVE_DEADLINE_SECONDS
    Work(record)
end

function PlayerData.OnShutdown(callback)
    shutdown = callback
end

function PlayerData.Initialize()
    Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local DataStoreService = game:GetService("DataStoreService")
    local HttpService = game:GetService("HttpService")
    local shared = ReplicatedStorage:WaitForChild("Combat")
    Styles = require(shared.Modules.Styles)
    studio = RunService:IsStudio()
    local store_name = if studio then "MMAPlayerData_Studio_v1" else "MMAPlayerData_v1"
    local data_store = DataStoreService:GetDataStore(store_name)
    local store = {}

    function store:UpdateAsync(key, transform, result_scope)
        if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRead) < 1 or DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardWrite) < 1 then
            error("Data store budget exhausted")
        end
        local target = if result_scope then DataStoreService:GetDataStore(store_name .. "_ResultIds", result_scope) else data_store
        return target:UpdateAsync(key, transform)
    end

    journal = ResultJournal.New(store, Styles, HttpService:GenerateGUID(false), os.time, function(user_id, saved, result_id)
        for player, record in records do
            if player.UserId == user_id and record.profile.data then
                record.pending_result_ids[result_id] = true
                if player.Parent == Players and not record.release then player:SetAttribute("ResultSaveState", "Pending") end
                record.profile:RefreshResults(saved)
                if player.Parent == Players and not record.release then
                    Publish(player, record.profile)
                end
            end
        end
    end, function(entry)
        for player, record in records do
            for _, participant in entry.participants do
                if player.UserId == participant.user_id then
                    record.pending_result_ids[entry.id] = nil
                    if player.Parent == Players and not record.release then
                        player:SetAttribute("ResultSaveState", if next(record.pending_result_ids) then "Pending" else "Saved")
                    end
                end
            end
        end
    end)
    task.spawn(function()
        local shard = 1
        while not closing do
            journal:Drain(shard)
            shard = shard % ResultJournal.SHARDS + 1
            for id, job in result_jobs do if job.committed and os.clock() - job.started > RESULT_JOB_RETENTION_SECONDS then result_jobs[id] = nil end end
            task.wait(JOURNAL_SCAN_SECONDS)
        end
    end)

    local function Register(player)
        if records[player] or closing then
            return
        end
        local profile = ProfileStore.New(store, player.UserId, HttpService:GenerateGUID(false), os.time, Styles)
        records[player] = {
            player = player,
            profile = profile,
            working = false,
            release = false,
            failed = false,
            deadline = os.clock() + SAVE_DEADLINE_SECONDS,
            next_save = math.huge,
            next_request = 0,
            pending_result_ids = {}
        }
        player:SetAttribute("DataStatus", "Loading")
        player:SetAttribute("DataSaveState", "Loading")
        player:SetAttribute("ResultSaveState", "Saved")
        player:SetAttribute("CameraMode", "Behind")
        player:SetAttribute("MovementKeys", "Camera")
        player:SetAttribute("ShowHitboxes", "Off")
        player:SetAttribute("StyleId", "Boxing")
        Work(records[player])
    end

    shared.Remotes.Settings.OnServerEvent:Connect(function(player, key, value)
        if key == "ShowHitboxes" and not studio then return end
        local record = records[player]
        local status = player:GetAttribute("MatchStatus")
        if not record or not PlayerData.IsReady(player) or status == "Fighting" or status == "Searching" or type(key) ~= "string" or (key ~= "CameraMode" and key ~= "MovementKeys" and key ~= "ShowHitboxes") or os.clock() < record.next_request then
            return
        end
        record.next_request = os.clock() + SETTINGS_REQUEST_SECONDS

        if record.profile:SetPreference(key, value) then
            player:SetAttribute(key, value)
            player:SetAttribute("DataSaveState", "Pending")
            record.next_save = math.min(record.next_save, os.clock() + 0.25)
        end
    end)

    Players.PlayerAdded:Connect(Register)
    for _, player in Players:GetPlayers() do
        Register(player)
    end

    task.spawn(function()
        while not closing do
            task.wait(1)
            for _, record in records do
                if not record.working and not record.failed and os.clock() >= record.next_save then
                    Work(record)
                end
            end
        end
    end)

    game:BindToClose(function()
        closing = true
        for _, job in result_jobs do
            job.deadline = os.clock() + SAVE_DEADLINE_SECONDS
        end
        if shutdown then
            shutdown()
        end
        for player in records do
            PlayerData.Release(player)
        end
        local deadline = os.clock() + SAVE_DEADLINE_SECONDS
        while (next(records) or next(result_jobs)) and os.clock() < deadline do
            for id, job in result_jobs do
                if job.committed then result_jobs[id] = nil end
            end
            task.wait(0.1)
        end
    end)
end

return PlayerData
