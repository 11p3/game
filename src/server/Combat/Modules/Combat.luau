local Combat = {}
local update_metrics = {updates = 0, over_budget = 0, last_ms = 0, maximum_ms = 0, active_matches = 0}

function Combat.GetMetrics()
    return table.clone(update_metrics)
end
local MATCH_REQUEST_SECONDS = 0.3
local SNAPSHOT_INTERVAL_FRAMES = 3
local MAX_FRAME_DEBT_SECONDS = 0.25
local RESULT_HOLD_FRAMES = 60
local ROLLBACK_WINDOW_FRAMES = 12
local HISTORY_FRAMES = 120
local FUTURE_INPUT_FRAMES = 18
local LOBBY_UPDATE_SECONDS = 0.2
local SIMULATION_HZ = 60
local PlayerData = require(script.Parent.PlayerData)
local BoutResults = require(script.Parent.BoutResults)
local FightInvites = require(script.Parent.FightInvites)
local CombatTransport = require(script.Parent.CombatTransport)

function Combat.Initialize()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local ServerStorage = game:GetService("ServerStorage")

    local shared = ReplicatedStorage:WaitForChild("Combat")
    local Styles = require(shared.Modules.Styles)
    local MoveDefinitions = require(shared.Modules.MoveDefinitions)
    local Maps = require(shared.Modules.Maps)
    local AISimulation = require(shared.Modules.AISimulation)
    local MatchSimulation = require(shared.Modules.MatchSimulation)
    local RollbackSession = require(shared.Modules.RollbackSession)
    local SnapshotCodec = require(shared.Modules.SnapshotCodec)
    local MatchReplay = require(shared.Modules.MatchReplay)
    local HttpService = game:GetService("HttpService")
    local result_namespace = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)

    local combat = workspace:WaitForChild("Combat")
    local arena = combat:WaitForChild("Arena")
    local arenas = combat:WaitForChild("Arenas")
    local npc_template = ServerStorage.Combat:WaitForChild("NPC")
    local replay_archive = ServerStorage.Combat:FindFirstChild("Replays") or Instance.new("Folder")
    replay_archive.Name = "Replays"
    replay_archive.Parent = ServerStorage.Combat
    local replay_order = {}
    local MAX_REPLAYS = 6
    local remote = shared.Remotes.Rollback
    local matches = {}
    local update_queue = {}
    local update_cursor = 0
    local player_matches = {}
    local transport = CombatTransport.New({matches = player_matches, remote = remote, codec = SnapshotCodec, clock = os.clock, server_time = function() return workspace:GetServerTimeNow() end})
    local queue = {}
    local requests = {}
    local descriptions = {}
    local free_slots = {}
    local next_slot = 0
    local epoch = 0
    local results
    local invites
    local lobby_elapsed = LOBBY_UPDATE_SECONDS
    local STEP = 1 / SIMULATION_HZ
    local ARENA_SPACING = 512
    local UPDATE_BUDGET_SECONDS = 0.008
    local MAX_CATCHUP_STEPS = 4

    local function IsReady(player)
        local character = player and player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")

        return player ~= nil and player.Parent == Players and character ~= nil and character.Parent ~= nil and character:GetAttribute("AppearanceReady") == true and humanoid ~= nil and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") ~= nil
    end

    local function RemoveFromQueue(player)
        for index = #queue, 1, -1 do
            if queue[index] == player then
                table.remove(queue, index)
            end
        end
    end

    local function StartBout(player, other, training, rematch, map_id, ai_options)
        if PlayerData.IsClosing() or PlayerData.IsLoading(player) or player_matches[player] or not IsReady(player) or other == player or (other and (player_matches[other] or not IsReady(other) or not PlayerData.IsReady(player) or not PlayerData.IsReady(other))) then
            return false
        end

        map_id = map_id or "Arena"
        if type(map_id) ~= "string" or not Maps[map_id] then
            return false
        end
        if ai_options ~= nil and (type(ai_options) ~= "table" or type(ai_options.style_id) ~= "string" or not Styles[ai_options.style_id] or type(ai_options.difficulty) ~= "string" or not AISimulation.Difficulties[ai_options.difficulty]) then
            return false
        end

        if invites then
            invites:Clear(player)
            if other then
                invites:Clear(other)
            end
        end

        if not rematch and results then
            results:Clear(player)
            if other then
                results:Clear(other)
            end
        end

        local opponent_style = if other then other.Character:GetAttribute("FighterId") else (if ai_options then Styles[ai_options.style_id].FighterId else "Boxing")
        local animation_issues = MoveDefinitions.ValidateAssets(shared.Animations, {player.Character:GetAttribute("FighterId"), opponent_style})
        if #animation_issues > 0 then
            for _, issue in animation_issues do warn(issue.path .. ": " .. issue.message) end
            player:SetAttribute("MatchStatus", "Animations unavailable")
            if other then other:SetAttribute("MatchStatus", "Animations unavailable") end
            return false
        end

        local slot = if rematch then rematch.slot else table.remove(free_slots)

        if not slot then
            next_slot += 1
            slot = next_slot
        end

        epoch += 1

        local origin = Vector3.new(slot % 8 * ARENA_SPACING, 0, math.floor(slot / 8) * ARENA_SPACING)
        local model = Instance.new("Model")
        model.Name = "Match_" .. epoch
        model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
        model:SetAttribute("Origin", origin)
        model:SetAttribute("RollbackEpoch", epoch)

        local npc

        if not other then
            npc = npc_template:Clone()
            npc.Name = "NPC"
            if not training then
                npc:SetAttribute("FighterId", Styles[if ai_options then ai_options.style_id else "Boxing"].FighterId)
            end
            npc.Parent = model
        end

        local characters = {if other then other.Character else npc, player.Character}
        local config = {
            ai_difficulty = if ai_options and not other and not training then ai_options.difficulty else "Normal",
            map_id = map_id,
            ring_shape = arena:GetAttribute("RingShape"),
            left_limit = arena:GetAttribute("LeftLimit"),
            right_limit = arena:GetAttribute("RightLimit"),
            lane_z = arena:GetAttribute("LaneZ"),
            back_limit = arena.Canvas.Position.Z - arena.Canvas.Size.Z * 0.5 + 3,
            front_limit = arena.Canvas.Position.Z + arena.Canvas.Size.Z * 0.5 - 3,
            spacing = arena:GetAttribute("FighterSpacing"),
            walk_speed = arena:GetAttribute("WalkSpeed"),
            npc_speed = arena:GetAttribute("NPCWalkSpeed"),
            turn_response = arena:GetAttribute("TurnResponse"),
            practice_mode = npc_template:GetAttribute("PracticeMode") or "Counter",
            player_fighter_id = characters[2]:GetAttribute("FighterId") or "Boxing",
            npc_fighter_id = characters[1]:GetAttribute("FighterId") or "Boxing",
            rollback_window = ROLLBACK_WINDOW_FRAMES,
            history_size = HISTORY_FRAMES,
            future_window = FUTURE_INPUT_FRAMES,
            pvp = other ~= nil,
            training = training == true and other == nil,
            player_one = if other then other.UserId else 0,
            player_two = player.UserId
        }
        local session = RollbackSession.New(MatchSimulation.Create(config), MatchSimulation.Step, config)
        local match = {
            epoch = epoch,
            slot = slot,
            origin = origin,
            model = model,
            player = player,
            opponent = other,
            viewers = {player, other},
            snapshot_pending = {},
            snapshot_turn = 0,
            characters = characters,
            streaming_modes = {},
            session = session,
            accumulator = 0,
            next_snapshot = SNAPSHOT_INTERVAL_FRAMES + epoch % SNAPSHOT_INTERVAL_FRAMES,
            rejected_inputs = 0,
            result_recorded = false,
            result_id = result_namespace .. ":" .. epoch,
            style_ids = {if other then other:GetAttribute("StyleId") or "Boxing" else characters[1]:GetAttribute("FighterId") or "Boxing", player:GetAttribute("StyleId") or "Boxing"},
            series = if rematch then table.clone(rematch.series) else {0, 0}
        }

        if not training then
            match.recording = MatchReplay.New(session, {epoch = epoch, player_one = config.player_one, player_two = config.player_two, map_id = map_id, styles = table.clone(match.style_ids)})
        end

        for index, character in characters do
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            local root = character:FindFirstChild("HumanoidRootPart")
            local fighter = session.state.fighters[index]

            match.streaming_modes[index] = character.ModelStreamingMode
            character.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
            humanoid.AutoRotate = false
            humanoid.WalkSpeed = 0
            humanoid.JumpPower = 0
            humanoid.JumpHeight = 0
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
            humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
            root.Anchored = true
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.new(origin + Vector3.new(fighter.x, fighter.y, fighter.z)) * CFrame.Angles(0, fighter.yaw, 0)

            local shield = character:FindFirstChildOfClass("ForceField")

            if shield then
                shield:Destroy()
            end
        end

        model.Parent = arenas
        matches[epoch] = match
        table.insert(update_queue, match)
        player_matches[player] = match
        player:SetAttribute("MatchStatus", "Fighting")

        if other then
            player_matches[other] = match
            other:SetAttribute("MatchStatus", "Fighting")
        end

        transport:SendSnapshot(player)

        if other then
            transport:SendSnapshot(other)
        end

        return true
    end

    local function GetOutcome(match, forfeiting_player)
        if match.outcome then
            return match.outcome
        end

        match.session:FlushInputs()
        local state = match.session.state

        if state.phase == "Finished" and state.frame - state.finished_frame > match.session.config.rollback_window then
            match.outcome = {loser = state.downed or 0, reason = if state.finish_reason and state.finish_reason ~= "" then state.finish_reason else "TKO"}
        elseif forfeiting_player and (forfeiting_player == match.player or forfeiting_player == match.opponent) then
            match.outcome = {loser = if forfeiting_player == match.opponent then 1 else 2, reason = "Forfeit"}
        end

        return match.outcome
    end

    local function RecordResult(match, outcome)
        if not outcome or match.result_recorded or not match.opponent or match.session.config.training or PlayerData.IsClosing() then
            return
        end

        match.result_recorded = PlayerData.RecordResult(match.result_id, {match.opponent, match.player}, match.style_ids, outcome.loser, outcome.reason)
    end

    local function EndBout(match, message, forfeiting_player)
        if not match or matches[match.epoch] ~= match then
            return
        end

        local outcome = GetOutcome(match, forfeiting_player)
        RecordResult(match, outcome)
        if match.recording then
            local record = MatchReplay.Finish(match.recording, match.session, message)
            local ok, encoded = pcall(function() return HttpService:JSONEncode({record = MatchReplay.Encode(record)}) end)
            if ok then
                local saved = Instance.new("StringValue")
                saved.Name = "Match_" .. match.epoch
                saved.Value = encoded
                saved:SetAttribute("Epoch", match.epoch)
                saved:SetAttribute("Frames", record.frames)
                saved:SetAttribute("Status", record.status)
                saved:SetAttribute("Reason", record.end_reason)
                saved:SetAttribute("RulesHash", record.rules_hash)
                saved:SetAttribute("FinalChecksum", record.final_checksum)
                saved:SetAttribute("PlayerOne", match.session.config.player_one)
                saved:SetAttribute("PlayerTwo", match.session.config.player_two)
                saved.Parent = replay_archive
                table.insert(replay_order, saved)
                if #replay_order > MAX_REPLAYS then
                    table.remove(replay_order, 1):Destroy()
                end
            else
                warn("Could not archive match " .. match.epoch .. ": " .. tostring(encoded))
            end
            match.recording = nil
        end
        local show_result = outcome ~= nil and not match.session.config.training and not PlayerData.IsClosing() and (message == "Match complete" or forfeiting_player ~= nil)
        matches[match.epoch] = nil
        local queued_index = table.find(update_queue, match)
        if queued_index then
            table.remove(update_queue, queued_index)
            if queued_index <= update_cursor then update_cursor -= 1 end
        end

        for _, participant in {match.player, match.opponent} do
            if participant and player_matches[participant] == match then
                player_matches[participant] = nil

                if participant.Parent == Players then
                    local status = message or "Menu"

                    if message == "Match complete" and outcome then
                        local participant_slot = if participant == match.opponent then 1 else 2
                        status = if outcome.loser == 0 then "Draw" else (if outcome.loser == participant_slot then "You lose — " else "You win — ") .. outcome.reason
                    end

                    participant:SetAttribute("MatchStatus", status)
                    remote:FireClient(participant, "Lobby", {epoch = match.epoch, results = show_result})

                    local root = participant.Character and participant.Character:FindFirstChild("HumanoidRootPart")

                    if root then
                        root.CFrame = CFrame.new(arena:GetAttribute("LobbyX"), 4, arena:GetAttribute("LobbyZ"))
                    end
                end
            end
        end

        for index, character in match.characters do
            if character.Parent then
                character.ModelStreamingMode = match.streaming_modes[index]
            end
        end

        match.model:Destroy()
        local reserved = false

        if show_result then
            reserved = results:Show(match, outcome.loser, outcome.reason, forfeiting_player == nil)
        end

        if not reserved then
            table.insert(free_slots, match.slot)
        end
    end

    results = BoutResults.New({Players = Players, PlayerData = PlayerData, Styles = Styles, Maps = Maps, Remote = shared.Remotes.Results, IsReady = IsReady, StartBout = StartBout, ReleaseSlot = function(slot) table.insert(free_slots, slot) end, BeginSelection = function(first, second, rematch) return invites:BeginSelection(first, second, rematch) end, Clock = os.clock})

    invites = FightInvites.New({Players = Players, PlayerData = PlayerData, Styles = Styles, Maps = Maps, Remote = shared.Remotes.Invites, CanFight = function(player) return player ~= nil and IsReady(player) and PlayerData.IsReady(player) and not player_matches[player] and not PlayerData.IsClosing() end, StartBout = StartBout, CloseRematch = function(player) results:Clear(player) end, ReleaseSlot = function(slot) table.insert(free_slots, slot) end, Clock = os.clock})

    shared.Remotes.Invites.OnServerEvent:Connect(function(player, action, value, style_id)
        invites:Handle(player, action, value, style_id)
    end)

    shared.Remotes.Matchmaking.OnServerEvent:Connect(function(player, action, style_id, result_epoch, map_id, ai_options)
        if action ~= "Queue" and action ~= "AI" and action ~= "Training" and action ~= "Cancel" and action ~= "Leave" and action ~= "Rematch" and action ~= "DismissResult" then
            return
        end

        if action == "DismissResult" then
            local offer = results.offers[player]
            if not player_matches[player] and offer and result_epoch == offer.epoch then
                results:Clear(player, "Declined")
            end
            return
        end

        local now = os.clock()

        if now < (requests[player] or 0) then
            return
        end

        requests[player] = now + MATCH_REQUEST_SECONDS

        local match = player_matches[player]

        if action == "Leave" then
            if match then
                EndBout(match, "Match ended", player)
            end
            return
        end

        if match then
            return
        end
        if invites.sessions[player] and action ~= "Cancel" then
            return
        end

        local offer = results.offers[player]
        if action == "AI" or (action == "Rematch" and offer and not offer.opponent) then
            if type(ai_options) ~= "table" or type(ai_options.style_id) ~= "string" or not Styles[ai_options.style_id] or type(ai_options.difficulty) ~= "string" or not AISimulation.Difficulties[ai_options.difficulty] then
                return
            end
            ai_options = {style_id = ai_options.style_id, difficulty = ai_options.difficulty}
        else
            ai_options = nil
        end

        if action == "Rematch" then
            results:Accept(player, result_epoch, style_id, map_id, ai_options)
            return

        end

        local style

        if action == "AI" or action == "Training" then
            if player:GetAttribute("MatchStatus") == "Searching" or type(style_id) ~= "string" then
                return
            end

            style = Styles[style_id]

            if not style or (map_id ~= nil and (type(map_id) ~= "string" or not Maps[map_id])) then
                return
            end
        end

        RemoveFromQueue(player)
        invites:Clear(player)
        results:Clear(player)

        if action == "Cancel" then
            player:SetAttribute("MatchStatus", "Menu")
        elseif PlayerData.IsLoading(player) then
            player:SetAttribute("MatchStatus", "Loading data")
        elseif action == "Queue" and not PlayerData.IsReady(player) then
            player:SetAttribute("MatchStatus", "Data unavailable — try Vs AI")
        elseif IsReady(player) then
            if action == "AI" or action == "Training" then
                PlayerData.SetStyle(player, style_id)
                player.Character:SetAttribute("FighterId", style.FighterId)
                StartBout(player, nil, action == "Training", nil, map_id, ai_options)
            else
                table.insert(queue, player)
                player:SetAttribute("MatchStatus", "Searching")
            end
        end
    end)

    local function PrepareCharacter(player, character)
        local style = Styles[player:GetAttribute("StyleId")] or Styles.Boxing
        character:SetAttribute("FighterId", style.FighterId)
        character:SetAttribute("AppearanceLoading", true)
        character:SetAttribute("AppearanceReady", false)

        local humanoid = character:WaitForChild("Humanoid")
        local root = character:WaitForChild("HumanoidRootPart")

        root.Anchored = true
        root.CFrame = CFrame.new(arena:GetAttribute("LobbyX"), 4, arena:GetAttribute("LobbyZ"))
        humanoid.BreakJointsOnDeath = false

        humanoid.Died:Once(function()
            EndBout(player_matches[player], "Character reset — match ended", player)
            RemoveFromQueue(player)
            results:Clear(player)
            invites:Clear(player)
            player:SetAttribute("MatchStatus", "Respawning")

            task.delay(1, function()
                if player.Parent == Players and player.Character == character then
                    local loaded, error_message = pcall(function() player:LoadCharacterAsync() end)

                    if not loaded then
                        warn("Could not respawn " .. player.Name .. ": " .. tostring(error_message))
                    end
                end
            end)
        end)

        local success, message = pcall(function()
            local description = descriptions[player]

            if not description then
                description = Players:GetHumanoidDescriptionFromUserIdAsync(player.UserId)

                if not player.Parent then
                    description:Destroy(); return
                end

                descriptions[player] = description
            end

            if player.Character == character and character.Parent then
                humanoid:ApplyDescriptionResetAsync(description)
            end
        end)

        if not success then
            warn("Could not load avatar for " .. player.Name .. ": " .. tostring(message))
        end

        if player.Character ~= character or not character.Parent or humanoid.Health <= 0 then
            return
        end

        character:SetAttribute("AppearanceLoading", false)
        character:SetAttribute("AppearanceReady", true)
        player:SetAttribute("MatchStatus", "Menu")
    end

    local function RegisterPlayer(player)
        if not Styles[player:GetAttribute("StyleId")] then
            player:SetAttribute("StyleId", "Boxing")
        end

        player.CharacterRemoving:Connect(function()
            EndBout(player_matches[player], "Character reset — match ended", player)
            RemoveFromQueue(player)
            results:Clear(player)
            invites:Clear(player)
        end)

        player.CharacterAdded:Connect(function(character) PrepareCharacter(player, character) end)

        if player.Character then
            task.spawn(PrepareCharacter, player, player.Character)
        else
            task.spawn(function() player:LoadCharacterAsync() end)
        end
    end

    remote.OnServerEvent:Connect(function(player, kind, packet_epoch, batch, snapshot_ack)
        transport:HandleInput(player, kind, packet_epoch, batch, snapshot_ack)
    end)

    Players.PlayerAdded:Connect(RegisterPlayer)

    Players.PlayerRemoving:Connect(function(player)
        requests[player] = nil
        transport:RemovePlayer(player)

        if descriptions[player] then
            descriptions[player]:Destroy(); descriptions[player] = nil
        end

        RemoveFromQueue(player)
        EndBout(player_matches[player], "Opponent left", if PlayerData.IsClosing() then nil else player)
        invites:RemovePlayer(player)
        results:Clear(player, "Opponent left")
        PlayerData.Release(player)
    end)

    for _, player in Players:GetPlayers() do
        RegisterPlayer(player)
    end

    PlayerData.OnShutdown(function()
        for _, match in matches do
            EndBout(match, "Server closing")
        end
        results:Update()
        invites:Update()
    end)

    local function UpdateLobby(delta_time)
        lobby_elapsed += delta_time
        if lobby_elapsed >= LOBBY_UPDATE_SECONDS then
            lobby_elapsed %= LOBBY_UPDATE_SECONDS
            results:Update()
            invites:Update()
            for index = #queue, 1, -1 do
                local queued = queue[index]

                if player_matches[queued] or invites.sessions[queued] or not IsReady(queued) or not PlayerData.IsReady(queued) then
                    table.remove(queue, index)

                    if queued.Parent == Players and not player_matches[queued] then
                        queued:SetAttribute("MatchStatus", "Loading avatar")
                    end
                end
            end

            while #queue >= 2 do
                local first, second = queue[1], queue[2]
                table.remove(queue, 1)
                table.remove(queue, 1)

                if not invites:BeginSelection(first, second) then
                    for _, player in {first, second} do
                        if IsReady(player) and PlayerData.IsReady(player) and not player_matches[player] then
                            table.insert(queue, player)
                            player:SetAttribute("MatchStatus", "Searching")
                        end
                    end

                    break
                end
            end

        end

    end

    local function UpdateMatch(match, update_deadline)
        if os.clock() >= update_deadline then return end
        match.session:FlushInputs()
        if os.clock() >= update_deadline then return end
        if match.opponent and (not PlayerData.IsReady(match.player) or not PlayerData.IsReady(match.opponent)) then
            EndBout(match, "Data unavailable — match ended")
            return
        end

        if not IsReady(match.player) or match.player.Character ~= match.characters[2] or (match.opponent and (not IsReady(match.opponent) or match.opponent.Character ~= match.characters[1])) then
            EndBout(match, "Fighter unavailable — match ended")
            return
        end

        local steps = 0
        while match.accumulator >= STEP and steps < MAX_CATCHUP_STEPS and os.clock() < update_deadline do
            steps += 1
            match.accumulator -= STEP
            match.session:Advance()
        end

        if os.clock() >= update_deadline then return end
        if match.recording then
            MatchReplay.Capture(match.recording, match.session)
        end
        local state = match.session.state
        if match.rendered_frame == state.frame and match.rendered_rollbacks == match.session.rollback_count then
            return
        end
        match.rendered_frame, match.rendered_rollbacks = state.frame, match.session.rollback_count

        local outcome = GetOutcome(match)

        if outcome and state.phase == "Finished" and not match.session.config.training then
            RecordResult(match, outcome)
            if not match.finish_notified then
                match.finish_notified = true
                remote:FireClient(match.player, "Finished", match.epoch)
                if match.opponent then
                    remote:FireClient(match.opponent, "Finished", match.epoch)
                end
            end
        end

        if outcome and state.phase == "Finished" and not match.session.config.training and state.frame - state.finished_frame >= RESULT_HOLD_FRAMES then
            EndBout(match, "Match complete")
            return
        end

        for index, fighter in state.fighters do
            if match.characters[index]:GetAttribute("FighterId") ~= fighter.fighter_id then
                match.characters[index]:SetAttribute("FighterId", fighter.fighter_id)
            end
            local root = match.characters[index]:FindFirstChild("HumanoidRootPart")

            if root then
                root.CFrame = CFrame.new(match.origin + Vector3.new(fighter.x, fighter.y, fighter.z)) * CFrame.Angles(0, fighter.yaw, 0)
            end
        end

        match.model:SetAttribute("ServerFrame", state.frame)
        match.model:SetAttribute("ServerRollbacks", match.session.rollback_count)
        match.model:SetAttribute("RejectedInputs", match.rejected_inputs)

        if state.frame >= match.next_snapshot then
            match.next_snapshot = state.frame + SNAPSHOT_INTERVAL_FRAMES
            for _, viewer in match.viewers do match.snapshot_pending[viewer] = true end
        end
        for _ = 1, #match.viewers do
            if os.clock() >= update_deadline then break end
            match.snapshot_turn = match.snapshot_turn % #match.viewers + 1
            local viewer = match.viewers[match.snapshot_turn]
            if match.snapshot_pending[viewer] or transport:NeedsSnapshot(viewer) then
                transport:SendSnapshot(viewer)
                match.snapshot_pending[viewer] = nil
            end
        end
    end

    RunService.Heartbeat:Connect(function(delta_time)
        debug.profilebegin("Combat.ServerUpdate")
        local update_started = os.clock()
        UpdateLobby(delta_time)

        for _, match in matches do
            match.accumulator = math.min(match.accumulator + delta_time, MAX_FRAME_DEBT_SECONDS)
        end
        local update_deadline = os.clock() + UPDATE_BUDGET_SECONDS
        local scheduled = #update_queue
        for _ = 1, scheduled do
            if os.clock() >= update_deadline then
                break
            end
            if #update_queue == 0 then break end
            update_cursor = update_cursor % #update_queue + 1
            local match = update_queue[update_cursor]
            if matches[match.epoch] ~= match then
                continue
            end
            UpdateMatch(match, update_deadline)
        end
        local elapsed = os.clock() - update_started
        update_metrics.updates += 1
        update_metrics.last_ms = elapsed * 1000
        update_metrics.maximum_ms = math.max(update_metrics.maximum_ms, update_metrics.last_ms)
        update_metrics.active_matches = #update_queue
        if elapsed > UPDATE_BUDGET_SECONDS then update_metrics.over_budget += 1 end
        debug.profileend()
    end)
end

return Combat
