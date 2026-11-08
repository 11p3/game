local Matchmaking = {}

function Matchmaking.Initialize()
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local player = Players.LocalPlayer
    local folder = script.Parent.Parent
    local shared = ReplicatedStorage:WaitForChild("Combat")
    local Styles = require(shared.Modules.Styles)
    local Maps = require(shared.Modules.Maps)
    local AISimulation = require(shared.Modules.AISimulation)
    local Invites = require(script.Parent.Invites)
    local MapVoting = require(script.Parent.MapVoting)
    local MoveGuide = require(script.Parent.MoveGuide)
    local Cinematics = require(script.Parent.Cinematics)

    local menu = player:WaitForChild("PlayerGui"):WaitForChild("Matchmaking")
    local panel = menu.Panel
    local settings_panel = menu.SettingsPanel
    local settings_open = false
    local leave_pending = false
    local invite_page
    local invite_id
    local styles_panel = menu.StylePanel
    local styles_open = false
    local styles_loading = false
    local style_generation = 0
    local pending_mode
    local pending_result_epoch
    local selected_map = "Arena"
    local selected_opponent = "Boxing"
    local selected_difficulty = "Normal"
    local opponent_styles = {}
    for style_id in Styles do
        table.insert(opponent_styles, style_id)
    end
    table.sort(opponent_styles, function(first, second) return Styles[first].Order < Styles[second].Order end)
    local scorecard
    local result_pending = false
    local latest_result_epoch = 0
    local result_panel = menu:WaitForChild("Scorecard")
    local selected_style = "Boxing"
    local previews = {}
    local preview_characters = {}

    for _, card in styles_panel.StyleList:GetChildren() do
        local style_id = card:GetAttribute("StyleId")

        if card:IsA("TextButton") and Styles[style_id] then
            previews[style_id] = {card.Preview, styles_panel.FighterPreview[style_id], styles_panel.OpponentPreview[style_id]}

            for _, preview in previews[style_id] do
                local camera = preview:FindFirstChild("Camera") or Instance.new("Camera")
                camera.Name = "Camera"
                camera.FieldOfView = 35
                camera.Parent = preview
                preview.CurrentCamera = camera
            end
        end
    end

    local matchmaking = shared.Remotes.Matchmaking

    panel.Cancel.Activated:Connect(function()
        if Invites.GetSession() then Invites.Cancel() else matchmaking:FireServer("Cancel") end
    end)
    menu.Leave.Activated:Connect(function()
        local epoch = folder:GetAttribute("RollbackEpoch")
        if leave_pending or player:GetAttribute("MatchStatus") ~= "Fighting" or type(epoch) ~= "number" or not folder:GetAttribute("RollbackReady") then
            return
        end
        leave_pending = true
        Cinematics.AtBlack(epoch, function()
            if player:GetAttribute("MatchStatus") == "Fighting" and folder:GetAttribute("RollbackEpoch") == epoch then
                matchmaking:FireServer("Leave")
            end
        end)
    end)
    local function UpdateMenu()
        if scorecard then
            local pending = player:GetAttribute("ResultSaveState")
            result_panel.Record.Text = string.format("PvP record  %dW / %dL / %dD", player:GetAttribute("PvPWins") or scorecard.record.wins, player:GetAttribute("PvPLosses") or scorecard.record.losses, player:GetAttribute("PvPDraws") or scorecard.record.draws) .. (if pending == "Pending" or pending == "Retrying" then "  · saving" else "")
        end
        local status = player:GetAttribute("MatchStatus") or "Loading avatar"

        if folder:GetAttribute("FightTransition") == "Out" then
            panel.Visible = false
            result_panel.Visible = false
            settings_panel.Visible = false
            styles_panel.Visible = false
            menu.FriendsPanel.Visible = false
            menu.InboxPanel.Visible = false
            menu.MapPanel.Visible = false
            return
        end

        if status ~= "Fighting" then
            leave_pending = false
        end

        if status == "Fighting" or status == "Searching" then
            settings_open, styles_open, pending_mode, invite_page = false, false, nil, nil
            MapVoting.Close()
            MoveGuide.Close()
        end
        local voting = MapVoting.IsOpen()
        menu.MapPanel.Visible = voting
        if scorecard and (folder:GetAttribute("RollbackEpoch") or 0) > scorecard.epoch then
            scorecard = nil; result_pending = false
        end
        local showing_result = scorecard ~= nil and not result_pending and status ~= "Fighting" and not settings_open and not styles_open and invite_page == nil and not voting
        result_panel.Visible = showing_result
        panel.Visible = status ~= "Fighting" and not settings_open and not styles_open and not showing_result and invite_page == nil and not voting
        menu.FriendsPanel.Visible = status ~= "Fighting" and not voting and invite_page == "Friends"
        menu.InboxPanel.Visible = status ~= "Fighting" and not voting and invite_page == "Inbox"
        settings_panel.Visible = status ~= "Fighting" and not voting and settings_open
        styles_panel.Visible = status ~= "Fighting" and not voting and styles_open
        local waiting = status == "Searching" or status == "Selecting" or status == "Voting"
        panel.Settings.Visible = not waiting
        panel.VsFriend.Visible = not waiting
        panel.Inbox.Visible = not waiting
        menu.Leave.Visible = status == "Fighting"
        local data_status = player:GetAttribute("DataStatus")
        local save_state = player:GetAttribute("DataSaveState")
        local caption = if status == "Searching" then "Searching..." elseif status == "Selecting" then "Choosing styles..." elseif status == "Voting" then "Voting for a map..." else ""
        if data_status == "Loading" then
            caption = "Loading saved data..."
        elseif data_status == "Unavailable" then
            caption = "Data unavailable — Vs AI / training only"
        elseif save_state == "Retrying" then
            caption = "Saving..."
        end
        panel.Status.Text = caption
        panel.Status.Visible = caption ~= ""
        panel.Cancel.Visible = waiting
        panel.FindMatch.Visible = not waiting
        panel.VsAI.Visible = not waiting
        panel.Training.Visible = not waiting
        Invites.Refresh()
    end

    local function RefreshStylePreview()
        if not styles_open then
            return
        end

        local selection = Invites.GetSession()
        local left_player = selection and Players:GetPlayerByUserId(selection.fighters[1].user_id) or player
        local right_player = selection and Players:GetPlayerByUserId(selection.fighters[2].user_id)

        for style_id, style_previews in previews do
            for index, preview in style_previews do
                local owner = if index == 1 then player elseif index == 2 then left_player else right_player
                local character = owner and owner.Character

                if preview_characters[preview] == character then
                    continue
                end
                preview_characters[preview] = nil
                for _, child in preview.WorldModel:GetChildren() do
                    child:Destroy()
                end

                if not character or not character:GetAttribute("AppearanceReady") then
                    continue
                end

                local archivable = character.Archivable
                character.Archivable = true
                local model = character:Clone()
                character.Archivable = archivable

                if not model then
                    continue
                end

                for _, item in model:GetDescendants() do
                    if item:IsA("BaseScript") or item:IsA("ForceField") or item:IsA("Highlight") then
                        item:Destroy()
                    end
                    if item:IsA("BasePart") then
                        item.Anchored = item.Name == "HumanoidRootPart"
                        item.CanCollide = false
                    end
                end

                model.Parent = preview.WorldModel
                model:PivotTo(CFrame.Angles(0, if index == 2 then -0.2 elseif index == 3 then 0.2 else 0, 0))
                preview_characters[preview] = character

                local humanoid = model:FindFirstChildOfClass("Humanoid")
                local profile = shared.Animations:FindFirstChild(Styles[style_id].FighterId)
                local idle = profile and profile:FindFirstChild("IdleAnimation")

                if not idle or idle.AnimationId == "" then
                    idle = shared.Animations.Boxing.IdleAnimation
                end

                if humanoid and idle and idle.AnimationId ~= "" then
                    humanoid.AutoRotate = false
                    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

                    local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
                    local loaded, track = pcall(function() return animator:LoadAnimation(idle) end)

                    if loaded then
                        track.Priority = Enum.AnimationPriority.Idle
                        track.Looped = true
                        track:Play(0)
                    end
                end

                local bounds, size = model:GetBoundingBox()
                local center = bounds.Position
                local aspect = math.max(0.1, preview.AbsoluteSize.X / math.max(preview.AbsoluteSize.Y, 1))
                local tangent = math.tan(math.rad(preview.CurrentCamera.FieldOfView * 0.5))
                local distance = math.max(size.Y, size.X / aspect) * 0.58 / tangent

                if preview.Parent:IsA("TextButton") then
                    local root = model:FindFirstChild("HumanoidRootPart")
                    if root then
                        center = root.Position + Vector3.new(0, 0.8, 0)
                    end
                    distance = 5.6
                end

                preview.CurrentCamera.CFrame = CFrame.lookAt(center + Vector3.new(0, size.Y * 0.04, -distance), center)
            end
        end
    end

    local function RefreshSelection()
        local selection = Invites.GetSession()
        styles_panel.Title.Text = "CHOOSE YOUR STYLE"
        styles_panel.Subtitle.Text = string.upper((Maps[selected_map] or Maps.Arena).Name)
        local paired = selection ~= nil and pending_mode == "Selection"
        local own_ready = paired and selection.ready

        styles_panel.AIOptions.Visible = pending_mode == "AI" or (pending_mode == "Rematch" and scorecard ~= nil and not scorecard.pvp)
        styles_panel.AIOptions.Opponent.Text = "Opponent: " .. Styles[selected_opponent].Name
        styles_panel.AIOptions.Difficulty.Text = "Difficulty: " .. selected_difficulty
        styles_panel.AIOptions.Opponent.Active = not styles_loading
        styles_panel.AIOptions.Difficulty.Active = not styles_loading
        styles_panel.Details.Visible = not paired
        styles_panel.PlayerOne.Visible = paired
        styles_panel.PlayerTwo.Visible = paired
        styles_panel.Versus.Visible = paired
        styles_panel.OpponentPreview.Visible = paired

        for side, viewports in {styles_panel.FighterPreview, styles_panel.OpponentPreview} do
            local fighter = paired and selection.fighters[side]
            local style_id = if fighter then (if side == selection.slot then selected_style else fighter.style_id) else selected_style

            for _, preview in viewports:GetChildren() do
                if preview:IsA("ViewportFrame") then
                    preview.Visible = preview.Name == style_id
                end
            end

            if fighter then
                local labels = if side == 1 then styles_panel.PlayerOne else styles_panel.PlayerTwo
                labels.NameLabel.Text = side .. " · " .. fighter.name .. (if side == selection.slot then "  (You)" else "")
                labels.StyleLabel.Text = string.upper(Styles[style_id].Name)
                labels.ReadyLabel.Text = if fighter.ready then "READY" else ""
            end
        end

        for _, card in styles_panel.StyleList:GetChildren() do
            if not card:IsA("TextButton") then
                continue
            end

            local style_id = card:GetAttribute("StyleId")
            local highlighted = style_id == selected_style
            card.SelectionOutline.Visible = highlighted

            for side, marker in {card.PlayerOne, card.PlayerTwo} do
                local fighter = paired and selection.fighters[side]
                marker.Visible = paired and (if side == selection.slot then selected_style else fighter.style_id) == style_id
            end
        end

        local style = Styles[selected_style]
        styles_panel.Details.NameLabel.Text = string.upper(style.Name)
        styles_panel.Details.Description.Text = style.Description
        styles_panel.Details.Record.Value.Text = string.format("PvP: %dW / %dL / %dD", player:GetAttribute(selected_style .. "PvPWins") or 0, player:GetAttribute(selected_style .. "PvPLosses") or 0, player:GetAttribute(selected_style .. "PvPDraws") or 0)
        styles_panel.Confirm.Text = if styles_loading then "LOADING..." elseif own_ready then "READY" else "CONFIRM"
        styles_panel.Confirm.Active = not own_ready and not styles_loading
        styles_panel.Confirm.AutoButtonColor = styles_panel.Confirm.Active
    end

    local function ShowStyle(style_id)
        local selection = Invites.GetSession()
        if not Styles[style_id] or styles_loading or (selection and selection.ready) then
            return
        end

        selected_style = style_id
        if pending_mode == "Selection" then
            Invites.Select(style_id)
        end
        RefreshSelection()
    end

    local function OpenStyle(mode)
        local status = player:GetAttribute("MatchStatus")
        if status == "Fighting" or status == "Searching" or (status == "Selecting" and mode ~= "Selection") then
            return
        end

        if mode ~= "Selection" and player:GetAttribute("DataStatus") == "Loading" then
            return
        end

        if mode == "Rematch" and (not scorecard or not scorecard.available) then
            return
        end
        style_generation += 1
        styles_loading = false
        pending_result_epoch = if mode == "Rematch" then scorecard.epoch else nil
        MapVoting.Close()
        MoveGuide.Close()
        pending_mode = mode
        invite_page = nil
        settings_open = false
        styles_open = true
        styles_panel.Subtitle.Text = ""
        local selection = Invites.GetSession()
        selected_style = if mode == "Selection" and selection then selection.fighters[selection.slot].style_id else player:GetAttribute("StyleId") or "Boxing"
        RefreshSelection()
        UpdateMenu()
        RefreshStylePreview()
    end

    panel.FindMatch.Activated:Connect(function()
        local status = player:GetAttribute("MatchStatus")
        local data_status = player:GetAttribute("DataStatus")
        if status == "Fighting" or status == "Searching" or status == "Selecting" or (data_status ~= "Ready" and data_status ~= "Studio") then
            return
        end
        matchmaking:FireServer("Queue")
    end)
    panel.VsAI.Activated:Connect(function() MapVoting.OpenSolo("AI") end)
    panel.Training.Activated:Connect(function() MapVoting.OpenSolo("Training") end)

    for _, card in styles_panel.StyleList:GetChildren() do
        local style_id = card:GetAttribute("StyleId")

        if card:IsA("TextButton") and Styles[style_id] then
            card.Activated:Connect(function() ShowStyle(style_id) end)
        end
    end

    styles_panel.AIOptions.Opponent.Activated:Connect(function()
        if styles_loading or not styles_panel.AIOptions.Visible then
            return
        end
        selected_opponent = opponent_styles[(table.find(opponent_styles, selected_opponent) or 0) % #opponent_styles + 1]
        RefreshSelection()
    end)
    styles_panel.AIOptions.Difficulty.Activated:Connect(function()
        if styles_loading or not styles_panel.AIOptions.Visible then
            return
        end
        selected_difficulty = AISimulation.DifficultyOrder[(table.find(AISimulation.DifficultyOrder, selected_difficulty) or 0) % #AISimulation.DifficultyOrder + 1]
        RefreshSelection()
    end)

    styles_panel.Back.Activated:Connect(function()
        style_generation += 1
        styles_loading = false
        if pending_mode == "Selection" then
            Invites.Cancel()
        end
        pending_mode = nil
        styles_open = false
        UpdateMenu()
    end)

    styles_panel.Confirm.Activated:Connect(function()
        local status = player:GetAttribute("MatchStatus")
        if status == "Fighting" or status == "Searching" then
            return
        end

        if not pending_mode then
            return
        end

        if styles_loading then
            return
        end

        local generation = style_generation
        local mode = pending_mode
        local style_id = selected_style
        local result_epoch = pending_result_epoch
        local chosen_invite = invite_id
        local ai_options = if mode == "AI" or mode == "Rematch" then {style_id = selected_opponent, difficulty = selected_difficulty} else nil
        local profile = shared.Animations:FindFirstChild(Styles[style_id].FighterId)
        local idle = profile and profile:FindFirstChild("IdleAnimation")

        if not idle or idle.AnimationId == "" then
            idle = shared.Animations.Boxing.IdleAnimation
        end

        styles_loading = true
        styles_panel.Confirm.Text = "LOADING..."

        if idle and idle.AnimationId ~= "" then
            local loaded, message = pcall(function()
                game:GetService("ContentProvider"):PreloadAsync({idle})
            end)

            if not loaded then
                warn("Could not preload idle: " .. tostring(message))
            end
        end

        if generation ~= style_generation or not styles_open or pending_mode ~= mode then
            return
        end

        styles_loading = false
        ShowStyle(selected_style)

        if not styles_open or pending_mode ~= mode or selected_style ~= style_id or player:GetAttribute("MatchStatus") == "Fighting" or player:GetAttribute("MatchStatus") == "Searching" then
            return
        end

        if mode == "Rematch" and (not scorecard or scorecard.epoch ~= result_epoch or not scorecard.available) then
            return
        end
        if mode == "Selection" then
            if not Invites.GetSession() or Invites.GetSession().id ~= chosen_invite then
                return
            end
            Invites.Ready(chosen_invite, style_id)
            RefreshSelection()
            return
        else
            matchmaking:FireServer(mode, style_id, result_epoch, selected_map, ai_options)
        end
        pending_mode = nil
        styles_open = false
        UpdateMenu()
    end)

    MoveGuide.Initialize(styles_panel)
    styles_panel.Moves.Activated:Connect(function() MoveGuide.Open(selected_style) end)
    MapVoting.Initialize({Menu = menu, UpdateMenu = UpdateMenu, Vote = Invites.Vote, Cancel = Invites.Cancel, Continue = function(mode, map_id)
        selected_map = map_id
        OpenStyle(mode)
    end})

    Invites.Initialize({Menu = menu, UpdateMenu = UpdateMenu, OpenPage = function(page)
        local status = player:GetAttribute("MatchStatus")
        if status == "Fighting" or status == "Searching" or status == "Selecting" then
            return
        end
        invite_page = page
        settings_open = false
        styles_open = false
        pending_mode = nil
        scorecard = nil
        MapVoting.Close()
        UpdateMenu()
    end, ChooseMap = function(selection)
        invite_id = selection.id
        invite_page, pending_mode = nil, nil
        styles_open, settings_open = false, false
        scorecard = nil
        MapVoting.OpenSession(selection)
        UpdateMenu()
    end, ChooseStyle = function(id)
        invite_id = id
        invite_page = nil
        scorecard = nil
        OpenStyle("Selection")
    end, SelectionChanged = function(selection)
        if selection.id ~= invite_id or selection.phase == "Voting" then
            return
        end
        selected_map = selection.map_id or "Arena"
        if selection.ready then
            selected_style = selection.fighters[selection.slot].style_id
        end
        RefreshSelection()
        RefreshStylePreview()
    end, IsChoosing = function() return styles_open and pending_mode == "Selection" end, EndChoice = function()
        if pending_mode == "Selection" then
            styles_open = false; pending_mode = nil
        end
        invite_id = nil
        MapVoting.Close()
        UpdateMenu()
    end})

    local function UpdateRematch()
        if not scorecard then
            return
        end
        result_panel.Rematch.Active = scorecard.available == true
        result_panel.Rematch.AutoButtonColor = scorecard.available == true
        result_panel.Rematch.Text = if scorecard.waiting then "Waiting..." elseif not scorecard.available then "Unavailable" elseif scorecard.pvp then "Rematch" else "Fight again"
        result_panel.Rematch.TextTransparency = if scorecard.available or scorecard.waiting then 0 else 0.5
    end

    shared.Remotes:WaitForChild("Results").OnClientEvent:Connect(function(kind, packet)
        if type(packet) ~= "table" or type(packet.epoch) ~= "number" or packet.epoch < latest_result_epoch or packet.epoch < (folder:GetAttribute("RollbackEpoch") or 0) then
            return
        end

        if kind == "Scorecard" then
            latest_result_epoch = packet.epoch
            scorecard = packet
            result_pending = true
            styles_open = false
            settings_open = false
            pending_mode = nil
            result_panel.Title.Text = packet.outcome .. (if packet.outcome == "Draw" then "" else " · " .. packet.reason)
            result_panel.Opponent.Text = "vs " .. packet.opponent .. "  ·  " .. (Styles[packet.style_id] or Styles.Boxing).Name
            result_panel.Strikes.Value.Text = string.format("%d / %d", packet.landed, packet.thrown)
            result_panel.Accuracy.Value.Text = string.format("%d%%", if packet.thrown > 0 then math.floor(packet.landed / packet.thrown * 100 + 0.5) else 0)
            result_panel.Damage.Value.Text = string.format("%g", packet.damage)
            result_panel.PerfectDodges.Value.Text = tostring(packet.perfect_dodges)
            result_panel.Knockdowns.Value.Text = tostring(packet.knockdowns)
            result_panel.Record.Text = string.format("PvP record  %dW / %dL / %dD", packet.record.wins, packet.record.losses, packet.record.draws)
            result_panel.Series.Text = string.format("You %d — %d %s", packet.series.you, packet.series.opponent, packet.opponent)
            -- Reveal results only after this bout has reached a fully black transition.
            Cinematics.ShowScorecard(packet.epoch, function()
                if scorecard and scorecard.epoch == packet.epoch then
                    result_pending = false
                    UpdateRematch()
                    UpdateMenu()
                end
            end)
        elseif kind == "Rematch" and scorecard and scorecard.epoch == packet.epoch then
            scorecard.available = packet.available
            scorecard.waiting = packet.waiting
            if not packet.available and not packet.waiting and pending_mode == "Rematch" then
                styles_open = false; pending_mode = nil
            end
        else
            return
        end

        UpdateRematch()
        UpdateMenu()
    end)

    result_panel.Rematch.Activated:Connect(function()
        if not scorecard or not scorecard.available then
            return
        end
        if scorecard.pvp then matchmaking:FireServer("Rematch", nil, scorecard.epoch) else MapVoting.OpenSolo("Rematch") end
    end)

    result_panel.Menu.Activated:Connect(function()
        if scorecard then
            matchmaking:FireServer("DismissResult", nil, scorecard.epoch)
        end
        scorecard = nil
        pending_mode = nil
        styles_open = false
        UpdateMenu()
    end)

    folder:GetAttributeChangedSignal("RollbackEpoch"):Connect(function()
        leave_pending = false
        UpdateMenu()
    end)
    folder:GetAttributeChangedSignal("FightTransition"):Connect(UpdateMenu)

    local function ResizeStylePanel()
        local camera = workspace.CurrentCamera
        if not camera then
            return
        end

        local viewport = camera.ViewportSize
        menu.MapPanel.UIScale.Scale = math.min(1, viewport.X * 0.94 / 800, viewport.Y * 0.9 / 420)
        styles_panel.UIScale.Scale = math.min(1, viewport.X * 0.94 / 920, viewport.Y * 0.9 / 620)
        result_panel.UIScale.Scale = math.min(1, viewport.X * 0.9 / 320, viewport.Y * 0.9 / 346)
        panel.UIScale.Scale = math.min(1, viewport.X * 0.9 / 300, viewport.Y * 0.9 / 380)
        menu.FriendsPanel.UIScale.Scale = math.min(1, viewport.X * 0.9 / 340, viewport.Y * 0.9 / 360)
        menu.InboxPanel.UIScale.Scale = menu.FriendsPanel.UIScale.Scale
    end

    local viewport_connection
    local function WatchCamera()
        if viewport_connection then
            viewport_connection:Disconnect()
            viewport_connection = nil
        end

        local camera = workspace.CurrentCamera
        if camera then
            viewport_connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(ResizeStylePanel)
        end
        ResizeStylePanel()
    end

    local camera_connection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(WatchCamera)
    script.Destroying:Once(function()
        camera_connection:Disconnect()
        if viewport_connection then
            viewport_connection:Disconnect()
        end
    end)
    WatchCamera()
    player:GetAttributeChangedSignal("StyleId"):Connect(UpdateMenu)
    player:GetAttributeChangedSignal("MatchStatus"):Connect(function()
        if styles_open then
            RefreshStylePreview()
        end
    end)

    panel.Settings.Activated:Connect(function()
        if player:GetAttribute("MatchStatus") == "Fighting" then
            return
        end
        settings_open = true
        styles_open = false
        UpdateMenu()
    end)

    settings_panel.Back.Activated:Connect(function()
        settings_open = false
        UpdateMenu()
    end)

    player:GetAttributeChangedSignal("MatchStatus"):Connect(UpdateMenu)
    UpdateMenu()

    local settings = shared.Remotes:WaitForChild("Settings")
    local camera_button = settings_panel.CameraMode
    local movement_button = settings_panel.MovementKeys
    local hitbox_button = settings_panel.ShowHitboxes

    local function RefreshSettings()
        local camera_mode = player:GetAttribute("CameraMode") or "Behind"
        local movement_keys = player:GetAttribute("MovementKeys") or "Camera"

        folder:SetAttribute("CameraMode", camera_mode)
        folder:SetAttribute("MovementKeys", movement_keys)
        folder:SetAttribute("ShowHitboxes", player:GetAttribute("ShowHitboxes") == "On")
        local data_status = player:GetAttribute("DataStatus")
        local ready = data_status == "Ready" or data_status == "Studio"
        hitbox_button.Active = ready
        hitbox_button.AutoButtonColor = ready
        hitbox_button.Text = if data_status == "Loading" then "Hitboxes: Loading..." elseif not ready then "Hitboxes: Unavailable" else "Hitboxes: " .. (player:GetAttribute("ShowHitboxes") or "Off")
        camera_button.Active = ready
        camera_button.AutoButtonColor = ready
        movement_button.Active = ready
        movement_button.AutoButtonColor = ready
        camera_button.Text = if data_status == "Loading" then "Camera: Loading..." elseif not ready then "Camera: Unavailable" else "Camera: " .. camera_mode
        movement_button.Text = if data_status == "Loading" then "Movement: Loading..." elseif not ready then "Movement: Unavailable" else "Movement: " .. (if movement_keys == "Camera" then "Follow camera" elseif movement_keys == "WS" then "W / S" else "A / D")
    end

    camera_button.Activated:Connect(function()
        if player:GetAttribute("MatchStatus") == "Fighting" then
            return
        end
        settings:FireServer("CameraMode", if player:GetAttribute("CameraMode") == "Behind" then "Side" else "Behind")
    end)

    movement_button.Activated:Connect(function()
        if player:GetAttribute("MatchStatus") == "Fighting" then
            return
        end
        local current = player:GetAttribute("MovementKeys")
        settings:FireServer("MovementKeys", if current == "Camera" then "WS" elseif current == "WS" then "AD" else "Camera")
    end)

    hitbox_button.Activated:Connect(function()
        if player:GetAttribute("MatchStatus") == "Fighting" then return end
        settings:FireServer("ShowHitboxes", if player:GetAttribute("ShowHitboxes") == "On" then "Off" else "On")
    end)

    for _, attribute in {"CameraMode", "MovementKeys", "ShowHitboxes", "DataStatus"} do
        player:GetAttributeChangedSignal(attribute):Connect(RefreshSettings)
    end
    for _, attribute in {"DataStatus", "DataSaveState", "ResultSaveState", "PvPWins", "PvPLosses", "PvPDraws"} do
        player:GetAttributeChangedSignal(attribute):Connect(UpdateMenu)
    end
    RefreshSettings()
end

return Matchmaking
