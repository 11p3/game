local Training = {}

function Training.Initialize()
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Styles = require(ReplicatedStorage:WaitForChild("Combat").Modules.Styles)
    local RunService = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    local ContextActionService = game:GetService("ContextActionService")
    local player = Players.LocalPlayer
    local folder = script.Parent.Parent
    local commands = folder:WaitForChild("TrainingCommand")
    local gui = player:WaitForChild("PlayerGui"):WaitForChild("Training")
    local panel = gui.Panel
    local open_button = gui.Open
    local active = false
    local was_recording = false
    local elapsed = 0
    local style_ids = {}
    for style_id in Styles do
        table.insert(style_ids, style_id)
    end
    table.sort(style_ids, function(first, second) return (Styles[first].Order or 100) < (Styles[second].Order or 100) end)
    local behaviors = {"Idle", "Guard", "Attack", "Counter"}
    local toggles = {InfiniteHealth = "health", InfiniteStamina = "stamina", InfiniteBlock = "block", InfiniteMomentum = "special charge"}

    for _, action in {"Idle", "Guard", "Attack", "Counter", "Record", "Stop", "Playback", "Reset", "InfiniteHealth", "InfiniteStamina", "InfiniteBlock", "InfiniteMomentum"} do
        panel[action].Activated:Connect(function()
            if not active then
                return
            end
            if action == "Record" then
                panel.Visible = false
            end
            commands:Fire(action)
        end)
    end

    panel.DummyStyle.Activated:Connect(function()
        if active then
            local index = table.find(style_ids, folder:GetAttribute("TrainingDummyStyle")) or 0
            commands:Fire(style_ids[index % #style_ids + 1])
        end
    end)
    panel.Close.Activated:Connect(function() panel.Visible = false end)
    open_button.Activated:Connect(function() if active then panel.Visible = not panel.Visible end end)

    ContextActionService:BindActionAtPriority("TrainingMenu", function(_, input_state)
        if not active or UserInputService:GetFocusedTextBox() then
            return Enum.ContextActionResult.Pass
        end
        if input_state == Enum.UserInputState.Begin then
            panel.Visible = not panel.Visible
        end
        return Enum.ContextActionResult.Sink
    end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.T)

    RunService.Heartbeat:Connect(function(delta_time)
        elapsed += delta_time
        if elapsed < 0.1 then
            return
        end
        elapsed = 0

        local enabled = player:GetAttribute("MatchStatus") == "Fighting" and folder:GetAttribute("TrainingActive") == true
        local recording = enabled and folder:GetAttribute("TrainingRecording") == true

        if enabled and not active then
            panel.Visible = true
        end
        if not enabled then
            panel.Visible = false
        end
        if enabled and was_recording and not recording then
            panel.Visible = true
        end
        active, was_recording = enabled, recording
        open_button.Visible = enabled
        if not enabled then
            return
        end

        local frames = folder:GetAttribute("TrainingFrames") or 0
        local mode = folder:GetAttribute("TrainingMode") or "Idle"
        local playhead = folder:GetAttribute("TrainingPlayhead") or 0
        open_button.Text = if recording then string.format("REC %.1f / 5s  [T]", frames / 60) else "TRAINING  [T]"
        panel.Status.Text = if recording then string.format("Controlling the dummy: %.1f / 5 seconds", frames / 60) elseif mode == "Playback" then string.format("Looping %.1fs recording  |  %.1fs", frames / 60, math.min(playhead, frames) / 60) else "Dummy: " .. mode .. "  |  Saved: " .. string.format("%.1fs", frames / 60)
        local style = Styles[folder:GetAttribute("TrainingDummyStyle")] or Styles.Boxing
        panel.DummyStyle.Text = "Dummy style: " .. style.Name .. "  (change clears recording)"

        for _, behavior in behaviors do
            local selected = not recording and mode == behavior
            panel[behavior].Text = (if selected then "[x] " else "") .. (if behavior == "Guard" then "Always block" elseif behavior == "Attack" then "Repeated jabs" else behavior)
            panel[behavior]:SetAttribute("Selected", selected)
        end

        for action, label in toggles do
            panel[action].Text = "Unlimited " .. label .. ": " .. (if folder:GetAttribute("Training" .. action) then "ON" else "OFF")
        end

        panel.Playback.Text = if mode == "Playback" then "Looping recording" else "Loop recording"
        panel.Playback.Active = frames > 0
        panel.Playback.AutoButtonColor = frames > 0
        panel.Playback.TextTransparency = if frames > 0 then 0 else 0.55

        local camera = workspace.CurrentCamera
        if camera then
            panel.UIScale.Scale = math.min(1, camera.ViewportSize.X * 0.95 / 400, camera.ViewportSize.Y * 0.9 / 570)
        end
    end)
end

return Training
