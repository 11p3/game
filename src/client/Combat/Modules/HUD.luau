local HUD = {}
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Styles = require(game:GetService("ReplicatedStorage").Combat.Modules.Styles)
local MoveDefinitions = require(game:GetService("ReplicatedStorage").Combat.Modules.MoveDefinitions)
local COOLDOWN_ACTIONS = {Dodge = {key = "E", name = "Dodge", frames = 60}, Kick = {key = "C", input = "kick"}, Technique = {key = "Q", input = "technique"}, Clinch = {key = "V", name = "Clinch", move = "ClinchGrab"}, GuardResponse = {key = "F", name = "Catch", response = true}}
local cooldown_panel
local opponent_character
local UpdateCooldowns
local player
local arena
local gui
local block_template
local count_label
local timer_label
local match_active = false
local timer_seconds
local UpdateTimer
local escape_meter
local escape_fill
local escape_value = 0
local escape_shakes = {}
local health_bars = {}

function HUD.Initialize()
    player = Players.LocalPlayer
    arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    gui = player:WaitForChild("PlayerGui"):WaitForChild("CombatHUD")
    cooldown_panel = gui:WaitForChild("Cooldowns")
    block_template = gui:WaitForChild("BlockIndicatorTemplate")
    count_label = gui:WaitForChild("KnockdownCount")
    timer_label = gui:WaitForChild("MatchTimer")
    escape_meter = gui:WaitForChild("ClinchEscape")
    escape_fill = escape_meter.Track.Fill
    escape_meter.Visible = false
    escape_meter.Position = UDim2.fromScale(0.5, 0.76)
    escape_meter.Rotation = 0
    escape_fill.Size = UDim2.fromScale(0, 1)
    local folder = script.Parent.Parent
    local camera_shake = folder:WaitForChild("CameraShake")

    UpdateTimer = function()
        local frames = arena:GetAttribute("TimeRemainingFrames") or 0
        local seconds = math.max(0, math.ceil(frames / 60))
        if seconds ~= timer_seconds then
            timer_seconds = seconds
            timer_label.Text = string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
        end
        timer_label.Visible = match_active and not folder:GetAttribute("TrainingActive") and (arena:GetAttribute("TimeLimitFrames") or 0) > 0
    end

    for _, attribute in {"TimeRemainingFrames", "TimeLimitFrames"} do
        arena:GetAttributeChangedSignal(attribute):Connect(UpdateTimer)
    end
    folder:GetAttributeChangedSignal("TrainingActive"):Connect(UpdateTimer)
    UpdateTimer()

    folder:WaitForChild("CombatEffects").Event:Connect(function(event)
        if event.kind ~= "ClinchStruggle" or event.fighter ~= (folder:GetAttribute("FighterSlot") or 2) or not event.key then
            return
        end
        local character = player.Character
        if not character or character:GetAttribute("ClinchRole") ~= "Held" then
            return
        end

        escape_shakes[event.key] = 0
        camera_shake:Fire(0.09, 0.16)
    end)

    folder:WaitForChild("RollbackEffects").Event:Connect(function(valid_keys)
        for key in escape_shakes do
            if not valid_keys[key] then
                escape_shakes[key] = nil
            end
        end
    end)

    RunService:BindToRenderStep("CombatClinchEscape", Enum.RenderPriority.Last.Value, function(delta_time)
        local character = player.Character
        local active = player:GetAttribute("MatchStatus") == "Fighting" and arena:GetAttribute("MatchState") == "Fighting" and character and character:GetAttribute("ClinchRole") == "Held" and character:GetAttribute("ClinchEscapeStarted") == true
        if escape_meter.Visible ~= (active == true) then escape_meter.Visible = active == true end

        if not active then
            if escape_value ~= 0 or next(escape_shakes) then
                escape_value = 0
                table.clear(escape_shakes)
                escape_meter.Position = UDim2.fromScale(0.5, 0.76)
                escape_meter.Rotation = 0
                escape_fill.Size = UDim2.fromScale(0, 1)
            end
            return
        end

        local target = math.clamp(character:GetAttribute("ClinchEscapeProgress") or 0, 0, 1)
        escape_value += (target - escape_value) * (1 - math.exp(-18 * delta_time))
        if math.abs(target - escape_value) < 0.0001 then escape_value = target end
        local fill_size = UDim2.fromScale(escape_value, 1)
        if escape_fill.Size ~= fill_size then escape_fill.Size = fill_size end

        local strength = 0
        for key, age in escape_shakes do
            age += delta_time
            if age >= 0.22 then escape_shakes[key] = nil else escape_shakes[key] = age; strength += math.exp(-22 * age) end
        end

        strength = math.min(strength, 1.5)
        local time = os.clock()
        local position = UDim2.new(0.5, math.sin(time * 112) * 5 * strength, 0.76, math.cos(time * 93) * 3 * strength)
        local rotation = math.sin(time * 105) * 2.5 * strength
        if escape_meter.Position ~= position then escape_meter.Position = position end
        if escape_meter.Rotation ~= rotation then escape_meter.Rotation = rotation end
    end)

    for index, name in {"PlayerHealth", "NPCHealth"} do
        local container = gui:WaitForChild(name)

        health_bars[index] = {
            container = container,
            text = container:FindFirstChildOfClass("TextLabel"),
            fill = container.Track.Fill,
            title = if index == 1 then "YOU" else "NPC",
            meters = {Stamina = {fill = container.StaminaTrack.Fill, label = container.StaminaLabel}, Block = {fill = container.BlockTrack.Fill, label = container.BlockLabel}}
        }
    end
end

function HUD.Bind(character, root)
    local is_player = character == player.Character
    local character_connections = {}
    local alive = true
    local block_indicator = block_template:Clone()

    block_indicator.Name = "BlockIndicator_" .. character.Name

    local block_anchor = character:FindFirstChild("Head") or root

    block_indicator.Parent = gui

    local block_binding = "CombatBlockIcon_" .. character.Name

    RunService:BindToRenderStep(block_binding, Enum.RenderPriority.Camera.Value + 2, function()
        local state = character:GetAttribute("CombatState")
        local blocking = arena:GetAttribute("MatchState") == "Fighting" and (state == "Guard" or state == "Blockstun")
        local camera = workspace.CurrentCamera

        if not blocking or not camera or not block_anchor.Parent then
            if block_indicator.Visible then block_indicator.Visible = false end

            return
        end

        local position, visible

        if gui.IgnoreGuiInset then
            position, visible = camera:WorldToViewportPoint(block_anchor.Position + Vector3.new(0, 2, 0))
        else
            position, visible = camera:WorldToScreenPoint(block_anchor.Position + Vector3.new(0, 2, 0))
        end

        block_indicator.Position = UDim2.fromOffset(position.X, position.Y)
        block_indicator.Visible = visible
    end)

    local bar = health_bars[if is_player then 1 else 2]

    bar.title = if is_player then "YOU" elseif character.Name == "NPC" then "NPC" else character.Name

    local function UpdateMeters()
        local health = character:GetAttribute("CombatHealth") or 100
        local maximum = character:GetAttribute("CombatMaxHealth") or 100

        bar.fill.Size = UDim2.fromScale(math.clamp(health / math.max(maximum, 1), 0, 1), 1)
        local style = Styles[character:GetAttribute("FighterId")] or Styles.Boxing
        bar.text.Text = bar.title .. "  " .. tostring(math.ceil(health)) .. "    KD " .. tostring(character:GetAttribute("Knockdowns") or 0) .. "/3  MOM " .. tostring(character:GetAttribute("CombatMomentum") or 0) .. "/3" .. (if (character:GetAttribute("ClinchRole") or "") ~= "" then "  CLINCH" elseif (character:GetAttribute("CombatMomentum") or 0) >= 3 then "  R: " .. style.SpecialName else "")

        local stamina = character:GetAttribute("CombatStamina") or 100
        local block = character:GetAttribute("CombatBlock") or 100

        bar.meters.Stamina.fill.Size = UDim2.fromScale(math.clamp(stamina / 100, 0, 1), 1)
        bar.meters.Block.fill.Size = UDim2.fromScale(math.clamp(block / 100, 0, 1), 1)
        bar.meters.Stamina.label.Text = "STA " .. tostring(math.ceil(stamina))
        bar.meters.Block.label.Text = "BLOCK " .. tostring(math.ceil(block))
    end

    table.insert(character_connections, character:GetAttributeChangedSignal("CombatHealth"):Connect(UpdateMeters))
    table.insert(character_connections, character:GetAttributeChangedSignal("CombatMaxHealth"):Connect(UpdateMeters))
    table.insert(character_connections, character:GetAttributeChangedSignal("Knockdowns"):Connect(UpdateMeters))
    table.insert(character_connections, character:GetAttributeChangedSignal("CombatStamina"):Connect(UpdateMeters))
    table.insert(character_connections, character:GetAttributeChangedSignal("CombatMomentum"):Connect(UpdateMeters))
    table.insert(character_connections, character:GetAttributeChangedSignal("CombatBlock"):Connect(UpdateMeters))
    table.insert(character_connections, character:GetAttributeChangedSignal("ClinchRole"):Connect(UpdateMeters))
    UpdateMeters()

    if is_player then
        UpdateCooldowns = function()
            local style = Styles[character:GetAttribute("FighterId")] or Styles.Boxing
            local profile = MoveDefinitions[style.FighterId] or MoveDefinitions.Boxing
            local opponent_profile = opponent_character and MoveDefinitions[opponent_character:GetAttribute("FighterId")]
            -- Hide Catch unless the opponent has a move with an eligible guard tag.
            local can_catch = false
            if profile.guard_response and opponent_profile then
                for _, move in opponent_profile.moves do
                    if profile.guard_response.tags[move.guard_tag] then
                        can_catch = true
                        break
                    end
                end
            end

            for name, action in COOLDOWN_ACTIONS do
                local row = cooldown_panel[name]
                local kind = action.move or (action.input and profile.inputs[action.input])
                local move = kind and profile.moves[kind]
                local frames = action.frames or (action.response and profile.guard_response and profile.guard_response.cooldown_frames) or (move and move.cooldown_frames)
                local remaining = character:GetAttribute(name .. "Cooldown") or 0
                row.Visible = frames ~= nil and remaining > 0 and (not action.response or can_catch)
                if not frames then continue end

                local caption = action.name
                if not caption then
                    for _, entry in style.MoveGuide do
                        if entry.Move == kind then caption = entry.Name; break end
                    end
                end
                local label = action.key .. "  " .. (caption or kind)
                local timer = if remaining > 0 then string.format("%.1f", remaining) else ""
                local fill = UDim2.fromScale(1 - math.clamp(remaining * 60 / frames, 0, 1), 1)
                if row.Label.Text ~= label then row.Label.Text = label end
                if row.Timer.Text ~= timer then row.Timer.Text = timer end
                if row.Track.Fill.Size ~= fill then row.Track.Fill.Size = fill end
            end
        end

        for _, field in {"FighterId", "DodgeCooldown", "KickCooldown", "TechniqueCooldown", "ClinchCooldown", "GuardResponseCooldown"} do
            table.insert(character_connections, character:GetAttributeChangedSignal(field):Connect(UpdateCooldowns))
        end
        UpdateCooldowns()
    else
        opponent_character = character
        table.insert(character_connections, character:GetAttributeChangedSignal("FighterId"):Connect(function()
            if UpdateCooldowns then UpdateCooldowns() end
        end))
        if UpdateCooldowns then UpdateCooldowns() end
    end

    return function()
        if not alive then
            return
        end
        alive = false
        if opponent_character == character then
            opponent_character = nil
            if UpdateCooldowns then UpdateCooldowns() end
        end
        RunService:UnbindFromRenderStep(block_binding)
        block_indicator:Destroy()
        for _, connection in character_connections do
            connection:Disconnect()
        end
    end
end

function HUD.UpdateMatch(active: boolean)
    match_active = active
    cooldown_panel.Visible = active
    if UpdateTimer then
        UpdateTimer()
    end
    local phase = arena:GetAttribute("MatchState")
    for _, bar in health_bars do
        bar.container.Visible = active
    end
    count_label.Visible = phase == "Knockdown"
    if phase == "Knockdown" then
        local count = arena:GetAttribute("Count") or 0
        count_label.Text = if count > 0 then tostring(count) else "DOWN"
    end
end

return HUD
