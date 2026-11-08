local CombatInput = {}
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local player
local folder
local training_gui
local enabled = false
local training = false
local window_focused = true
local guard = false
local studio_guard = false
local pending = {jab = false, dodge = false, special = false, kick = false, technique = false, clinch = false}
local training_commands = {}

function CombatInput.Initialize()
    player = Players.LocalPlayer
    folder = script.Parent.Parent
    training_gui = player:WaitForChild("PlayerGui"):WaitForChild("Training")

    folder:WaitForChild("TrainingCommand").Event:Connect(function(action)
        if enabled and training and #training_commands < 8 then
            table.insert(training_commands, action)
            pending = {jab = false, dodge = false, special = false, kick = false, technique = false, clinch = false}
        end
    end)

    ContextActionService:BindActionAtPriority("CombatMovement", function() return Enum.ContextActionResult.Sink end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.W, Enum.KeyCode.S, Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.Space, Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward, Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight, Enum.PlayerActions.CharacterJump)
    for action, key in {
        Jab = Enum.UserInputType.MouseButton1,
        Dodge = Enum.KeyCode.E,
        Guard = Enum.KeyCode.F,
        Special = Enum.KeyCode.R,
        Kick = Enum.KeyCode.C,
        Technique = Enum.KeyCode.Q,
        Clinch = Enum.KeyCode.V
    } do
        ContextActionService:BindActionAtPriority("Combat" .. action, function(_, input_state, input_object)
            local began = input_state == Enum.UserInputState.Begin

            if action == "Guard" and not began then
                guard = false
            end

            local over_training_ui = enabled and training and training_gui.Panel.Visible
            if enabled and training and action == "Jab" and began and input_object then
                for _, object in player.PlayerGui:GetGuiObjectsAtPosition(input_object.Position.X, input_object.Position.Y) do
                    if object:IsDescendantOf(training_gui) then
                        over_training_ui = true; break
                    end
                end
            end
            if over_training_ui and action == "Jab" then
                return Enum.ContextActionResult.Pass
            end

            if not over_training_ui and enabled and window_focused and player:GetAttribute("MatchStatus") == "Fighting" and not UserInputService:GetFocusedTextBox() and not UserInputService.ModalEnabled then
                if action == "Guard" then guard = began else if began then pending[string.lower(action)] = true end end
            end

            return Enum.ContextActionResult.Sink
        end, false, Enum.ContextActionPriority.High.Value, key)
    end

    if RunService:IsStudio() then
        ContextActionService:BindActionAtPriority("CombatTestGuard", function(_, input_state)
            if input_state == Enum.UserInputState.Begin and enabled and window_focused and player:GetAttribute("MatchStatus") == "Fighting" and not UserInputService:GetFocusedTextBox() and not UserInputService.ModalEnabled then
                studio_guard = not studio_guard
            end

            return Enum.ContextActionResult.Sink
        end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.G)
    end

    player:GetAttributeChangedSignal("MatchStatus"):Connect(function()
        if player:GetAttribute("MatchStatus") ~= "Fighting" then
            studio_guard = false
        end
    end)

    UserInputService.WindowFocusReleased:Connect(function()
        window_focused = false
        guard = false
        pending = {jab = false, dodge = false, special = false, kick = false, technique = false, clinch = false}
    end)

    UserInputService.WindowFocused:Connect(function() window_focused = true end)
    UserInputService.TextBoxFocused:Connect(function()
        guard = false
        pending = {jab = false, dodge = false, special = false, kick = false, technique = false, clinch = false}
    end)

end

function CombatInput.SetSession(config)
    enabled = config ~= nil
    training = config ~= nil and config.training == true and not config.pvp
    guard = false
    studio_guard = false
    pending = {jab = false, dodge = false, special = false, kick = false, technique = false, clinch = false}
    table.clear(training_commands)
end

function CombatInput.Capture(current_input: boolean)
    local allowed = enabled and not folder:GetAttribute("FightTransition") and window_focused and player:GetAttribute("MatchStatus") == "Fighting" and not UserInputService:GetFocusedTextBox() and not UserInputService.ModalEnabled and not (training and training_gui.Panel.Visible)
    local axis = if allowed then (if UserInputService:IsKeyDown(Enum.KeyCode.W) then 1 else 0) - (if UserInputService:IsKeyDown(Enum.KeyCode.S) then 1 else 0) else 0
    local strafe = if allowed then (if UserInputService:IsKeyDown(Enum.KeyCode.D) then 1 else 0) - (if UserInputService:IsKeyDown(Enum.KeyCode.A) then 1 else 0) else 0

    local movement_keys = folder:GetAttribute("MovementKeys") or "Camera"

    if movement_keys == "AD" or (movement_keys == "Camera" and folder:GetAttribute("CameraMode") == "Side") then
        local forward = allowed and UserInputService:IsKeyDown(Enum.KeyCode.D)
        local backward = allowed and UserInputService:IsKeyDown(Enum.KeyCode.A)
        local circle_left = allowed and UserInputService:IsKeyDown(Enum.KeyCode.W)
        local circle_right = allowed and UserInputService:IsKeyDown(Enum.KeyCode.S)

        local screen_sign = if folder:GetAttribute("CameraMode") == "Side" and folder:GetAttribute("SideControlSign") == -1 then -1 else 1
        axis = ((if forward then 1 else 0) - (if backward then 1 else 0)) * screen_sign
        strafe = ((if circle_right then 1 else 0) - (if circle_left then 1 else 0)) * screen_sign
    end

    return {
        axis = axis,
        strafe = strafe,
        guard = (allowed and guard) or (RunService:IsStudio() and studio_guard and not folder:GetAttribute("FightTransition") and player:GetAttribute("MatchStatus") == "Fighting"),
        jab = allowed and current_input and pending.jab,
        dodge = allowed and current_input and pending.dodge,
        special = allowed and current_input and pending.special,
        kick = allowed and current_input and pending.kick,
        technique = allowed and current_input and pending.technique,
        clinch = allowed and current_input and pending.clinch,
        training = if current_input and window_focused then training_commands[1] or "" else ""
    }
end

function CombatInput.Commit(input)
    pending = {jab = false, dodge = false, special = false, kick = false, technique = false, clinch = false}
    if input.training ~= "" then
        table.remove(training_commands, 1)
    end
end

return CombatInput
