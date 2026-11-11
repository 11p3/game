local MenuSettings = {}

function MenuSettings.Initialize(settings_panel, folder)
    local studio = game:GetService("RunService"):IsStudio()
    local player = game:GetService("Players").LocalPlayer
    local shared = game:GetService("ReplicatedStorage"):WaitForChild("Combat")
    local settings = shared.Remotes:WaitForChild("Settings")
    local camera_button = settings_panel.CameraMode
    local movement_button = settings_panel.MovementKeys
    local hitbox_button = settings_panel.ShowHitboxes
    hitbox_button.Visible = studio

    local function RefreshSettings()
        local camera_mode = player:GetAttribute("CameraMode") or "Behind"
        local movement_keys = player:GetAttribute("MovementKeys") or "Camera"

        folder:SetAttribute("CameraMode", camera_mode)
        folder:SetAttribute("MovementKeys", movement_keys)
        folder:SetAttribute("ShowHitboxes", studio and player:GetAttribute("ShowHitboxes") == "On")
        local data_status = player:GetAttribute("DataStatus")
        local ready = data_status == "Ready" or data_status == "Studio"
        hitbox_button.Active = studio and ready
        hitbox_button.AutoButtonColor = studio and ready
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
        settings:FireServer("CameraMode", if (player:GetAttribute("CameraMode") or "Behind") == "Behind" then "Side" else "Behind")
    end)

    movement_button.Activated:Connect(function()
        if player:GetAttribute("MatchStatus") == "Fighting" then
            return
        end
        local current = player:GetAttribute("MovementKeys") or "Camera"
        settings:FireServer("MovementKeys", if current == "Camera" then "WS" elseif current == "WS" then "AD" else "Camera")
    end)

    hitbox_button.Activated:Connect(function()
        if not studio or player:GetAttribute("MatchStatus") == "Fighting" then return end
        settings:FireServer("ShowHitboxes", if player:GetAttribute("ShowHitboxes") == "On" then "Off" else "On")
    end)

    for _, attribute in {"CameraMode", "MovementKeys", "ShowHitboxes", "DataStatus"} do
        player:GetAttributeChangedSignal(attribute):Connect(RefreshSettings)
    end
    RefreshSettings()
end

return MenuSettings
