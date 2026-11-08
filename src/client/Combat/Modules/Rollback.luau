local Rollback = {}

function Rollback.Initialize()
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local RunService = game:GetService("RunService")

    local player = Players.LocalPlayer
    local folder = script.Parent.Parent
    local shared = ReplicatedStorage:WaitForChild("Combat")
    local MatchSimulation = require(shared.Modules.MatchSimulation)
    local RollbackSession = require(shared.Modules.RollbackSession)
    local SnapshotCodec = require(shared.Modules.SnapshotCodec)
    local Presentation = require(script.Parent.Presentation)
    local CombatInput = require(script.Parent.CombatInput)
    local Cinematics = require(script.Parent.Cinematics)

    local remote = shared.Remotes:WaitForChild("Rollback")
    local arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    local session
    local epoch = 0
    local closed_epoch = -1
    local slot = 2
    local latest_frame = 0
    local latest_time = 0
    local lead = 2
    local snapshot_bases = {}
    local snapshot_id = 0
    local resync_at = 0
    local INPUT_DELAY = 2

    Presentation.Initialize()

    remote.OnClientEvent:Connect(function(kind, packet)
        if kind == "Finished" then
            if packet == epoch and packet > closed_epoch then
                Cinematics.BeginEnd(packet)
            end
            return
        end

        if kind == "Lobby" then
            local ending_epoch = if type(packet) == "table" then packet.epoch elseif type(packet) == "number" then packet else epoch
            closed_epoch = math.max(closed_epoch, ending_epoch)

            if closed_epoch < epoch then
                return
            end
            session = nil
            table.clear(snapshot_bases)
            snapshot_id = 0
            CombatInput.SetSession(nil)
            latest_frame = 0
            Cinematics.CloseBout(ending_epoch, type(packet) == "table" and packet.results == true, function()
                if epoch ~= ending_epoch then
                    return
                end
                Presentation.Reset(epoch, nil)
                folder:SetAttribute("FighterSlot", 0)
                folder:SetAttribute("RollbackReady", false)
                folder:SetAttribute("TrainingActive", false)
                folder:SetAttribute("OpponentUserId", 0)
                folder:SetAttribute("ArenaId", "")
                folder:SetAttribute("MapId", "Arena")
                arena:SetAttribute("MatchState", "Idle")

                local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                if root then
                    root.CFrame = CFrame.new(arena:GetAttribute("LobbyX"), 4, arena:GetAttribute("LobbyZ"))
                end
            end)

            return
        end

        if kind ~= "Snapshot" or type(packet) ~= "table" then
            return
        end

        for _, key in {"epoch", "id", "frame", "base_id"} do
            local value = packet[key]
            if type(value) ~= "number" or value % 1 ~= 0 or value < (if key == "frame" or key == "base_id" then 0 else 1) then return end
        end
        if packet.epoch <= closed_epoch or packet.epoch < epoch then
            return
        end

        if packet.epoch == epoch and (packet.frame < latest_frame or packet.id <= snapshot_id) then
            return
        end

        if packet.slot ~= 1 and packet.slot ~= 2 then
            return
        end
        local baseline = if packet.epoch == epoch then snapshot_bases[packet.base_id] else nil
        local body
        if packet.base_id == 0 or baseline then
            body = SnapshotCodec.Decode(packet.payload, baseline)
        end
        if type(body) ~= "table" or type(body.state) ~= "table" or body.state.frame ~= packet.frame or type(body.config) ~= "table" or type(body.held) ~= "table" or type(body.journal) ~= "table" then
            if os.clock() >= resync_at then
                resync_at = os.clock() + 0.5
                remote:FireServer("Ready", packet.epoch, true)
            end
            return
        end
        if packet.epoch ~= epoch then
            table.clear(snapshot_bases)
        end
        snapshot_bases[packet.id] = body
        snapshot_id = packet.id
        for id in snapshot_bases do if id <= snapshot_id - 16 then snapshot_bases[id] = nil end end
        packet.state, packet.config, packet.held = body.state, body.config, body.held
        packet.events = {}
        for frame = math.max(0, packet.frame - 119), packet.frame do
            for _, event in body.journal[frame] or {} do
                table.insert(packet.events, event)
            end
        end

        slot = packet.slot
        folder:SetAttribute("MapId", packet.config.map_id or "Arena")
        folder:SetAttribute("ArenaId", packet.arena_id)
        folder:SetAttribute("FighterSlot", slot)
        folder:SetAttribute("OpponentUserId", if slot == 1 then packet.config.player_two else packet.config.player_one)

        if packet.epoch ~= epoch or not session then
            Cinematics.BeginBout(packet.epoch)
            epoch = packet.epoch
            session = RollbackSession.New(packet.state, MatchSimulation.Step, packet.config)
            session.last_input = RollbackSession.Predict(packet.held)
            session.held_inputs[packet.state.frame] = RollbackSession.Copy(session.last_input)
            CombatInput.SetSession(packet.config)
            Presentation.Reset(epoch, packet.state)
        else
            local remote_suffix = if slot == 1 then "" else "_one"

            for frame, input in session.inputs do
                if frame > packet.state.frame then
                    for _, key in {"axis", "strafe", "guard"} do
                        input[key .. remote_suffix] = packet.held[key .. remote_suffix]
                    end

                    for _, key in {"jab", "dodge", "special", "kick", "technique", "clinch"} do
                        input[key .. remote_suffix] = false
                    end
                    input["training" .. remote_suffix] = ""
                end
            end

            local accepted, reason = session:Reconcile(packet.state, packet.held)

            folder:SetAttribute("LastReconcile", reason)

            if not accepted and reason ~= "stale_snapshot" then
                session = RollbackSession.New(packet.state, MatchSimulation.Step, packet.config)
                session.last_input = RollbackSession.Predict(packet.held)
                session.held_inputs[packet.state.frame] = RollbackSession.Copy(session.last_input)
            end
        end

        session.received_events = packet.events or {}
        session.received_frame = packet.state.frame

        if packet.state.frame >= latest_frame or packet.epoch ~= folder:GetAttribute("RollbackEpoch") then
            latest_frame = packet.state.frame
            latest_time = packet.sent_at
            lead = packet.lead
        end

        folder:SetAttribute("RollbackEpoch", epoch)
        folder:SetAttribute("AuthoritativeFrame", packet.state.frame)
        folder:SetAttribute("ServerRollbacks", packet.rollbacks)
        folder:SetAttribute("RejectedInputs", packet.rejected)
        folder:SetAttribute("RollbackReady", true)
    end)

    RunService.Heartbeat:Connect(function()
        if not session then
            return
        end

        local target = latest_frame + math.clamp(math.floor((workspace:GetServerTimeNow() - latest_time) * 60), 0, 120) + lead
        local controlling = slot == 1 or slot == 2
        local capture_frame = math.min(target, session.state.frame + 8) - 1
        local steps = 0

        while session.state.frame < target and steps < 8 do
            steps += 1

            if controlling then
                local current_input = session.state.frame == capture_frame
                local input = CombatInput.Capture(current_input)
                local combined = RollbackSession.Predict(session.last_input)

                for _, key in {
                    "axis",
                    "strafe",
                    "guard",
                    "jab",
                    "dodge",
                    "special",
                    "kick",
                    "technique",
                    "clinch",
                    "training"
                } do combined[key .. (if slot == 1 then "_one" else "")] = input[key] end

                local accepted = session:Submit(session.state.frame + INPUT_DELAY, combined)

                if current_input and accepted then
                    CombatInput.Commit(input)
                end
            end

            session:Advance()

            if controlling and session.state.frame % 2 == 0 then
                local batch = {}

                for frame = math.max(1, session.state.frame - 3), session.state.frame + INPUT_DELAY do
                    local input = session.inputs[frame]

                    if input then
                        local own = {}

                        for _, key in {
                            "axis",
                            "strafe",
                            "guard",
                            "jab",
                            "dodge",
                            "special",
                            "kick",
                            "technique",
                            "clinch",
                            "training"
                        } do own[key] = input[key .. (if slot == 1 then "_one" else "")] end
                        table.insert(batch, {frame = frame, input = own})
                    end
                end

                remote:FireServer("Input", epoch, batch, snapshot_id)
            end
        end

        folder:SetAttribute("PredictionFrame", session.state.frame)
        folder:SetAttribute("ClientRollbacks", session.rollback_count)
        folder:SetAttribute("ReplayedFrames", session.replayed_frames)
    end)

    RunService:BindToRenderStep("RollbackPresentation", Enum.RenderPriority.Camera.Value - 1, function(delta_time)
        if session then
            Presentation.Apply(session, epoch, delta_time)
        end
    end)

    task.spawn(function()
        while player.Parent do if session then remote:FireServer("Ready") end; task.wait(2) end
    end)
end

return Rollback
