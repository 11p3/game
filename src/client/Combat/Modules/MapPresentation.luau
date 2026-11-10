local MapPresentation = {}

function MapPresentation.Initialize()
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Lighting = game:GetService("Lighting")
    local folder = script.Parent.Parent
    local combat = workspace:WaitForChild("Combat")
    local arena = combat:WaitForChild("Arena")
    local stadium = combat:WaitForChild("Stadium")
    local Maps = require(ReplicatedStorage.Combat.Modules.Maps)
    local assets = ReplicatedStorage.Combat:WaitForChild("MapAssets")
    local current_map = "Arena"
    local active_model
    local hidden = {} -- Remember authored visibility so returning to Arena restores each object correctly.
    local lighting_defaults = {}
    local effect_defaults = {}
    local visibility_connections = {}

    for _, property in {"ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "FogColor", "FogStart", "FogEnd"} do
        lighting_defaults[property] = Lighting[property]
    end
    for _, effect in Lighting:GetChildren() do
        if effect:IsA("PostEffect") then
            effect_defaults[effect] = effect.Enabled
        end
    end

    local sky = Lighting:FindFirstChildOfClass("Sky")
    local celestial_defaults = sky and sky.CelestialBodiesShown
    local star_defaults = sky and sky.StarCount

    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
    local atmosphere_defaults = atmosphere and {Density = atmosphere.Density, Haze = atmosphere.Haze, Color = atmosphere.Color, Decay = atmosphere.Decay}

    local function SetArenaVisible(object, visible)
        if object:IsA("BasePart") or object:IsA("Decal") or object:IsA("Texture") then
            if hidden[object] == nil then
                hidden[object] = object.Transparency
            end
            object.Transparency = if visible then hidden[object] else 1
        elseif object:IsA("Light") or object:IsA("ParticleEmitter") or object:IsA("Trail") or object:IsA("Beam") or object:IsA("Sparkles") or object:IsA("Fire") or object:IsA("Smoke") or object:IsA("Highlight") or object:IsA("BillboardGui") or object:IsA("SurfaceGui") then
            if hidden[object] == nil then
                hidden[object] = object.Enabled
            end
            object.Enabled = visible and hidden[object] == true
            -- Remove already-emitted particles when hiding the arena.
            if not visible and object:IsA("ParticleEmitter") then
                object:Clear()
            end
            if not visible and object:IsA("Trail") then
                object:Clear()
            end
        end
    end

    for _, model in {arena, stadium} do
        local function WatchScenery(object)
            SetArenaVisible(object, current_map == "Arena")

            if hidden[object] ~= nil and not object:IsA("BasePart") and not object:IsA("Decal") and not object:IsA("Texture") then
                visibility_connections[object] = object:GetPropertyChangedSignal("Enabled"):Connect(function()
                    if current_map == "Arena" then
                        hidden[object] = object.Enabled
                    elseif object.Enabled then
                        SetArenaVisible(object, false)
                    end
                end)
            end
        end

        model.DescendantAdded:Connect(WatchScenery)
        model.DescendantRemoving:Connect(function(object)
            if visibility_connections[object] then
                visibility_connections[object]:Disconnect(); visibility_connections[object] = nil
            end
            if hidden[object] ~= nil then
                SetArenaVisible(object, true); hidden[object] = nil
            end
        end)
        for _, object in model:GetDescendants() do
            WatchScenery(object)
        end
    end

    local function HideStudioObject(object)
        if not object:IsA("BasePart") and not object:IsA("Decal") and not object:IsA("Humanoid") then
            return
        end

        local ancestor = object
        while ancestor and ancestor ~= workspace do
            if ancestor:GetAttribute("StudioOnly") then
                if object:IsA("Humanoid") then
                    object.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                else
                    object.Transparency = 1
                end
                return
            end
            ancestor = ancestor.Parent
        end
    end

    for _, object in workspace:GetChildren() do
        if object:GetAttribute("StudioOnly") then
            for _, descendant in object:GetDescendants() do
                HideStudioObject(descendant)
            end
        end
    end
    workspace.DescendantAdded:Connect(HideStudioObject)

    local function UpdateMap()
        local map_id = folder:GetAttribute("MapId") or "Arena"
        if not Maps[map_id] then
            map_id = "Arena"
        end
        if map_id == current_map then
            return
        end
        current_map = map_id

        if active_model then
            active_model:Destroy(); active_model = nil
        end
        for object in hidden do
            if not object.Parent then hidden[object] = nil else SetArenaVisible(object, map_id == "Arena") end
        end
        for property, original in lighting_defaults do
            local value = Maps[map_id].Lighting and Maps[map_id].Lighting[property]
            Lighting[property] = if value ~= nil then value else original
        end
        for effect, enabled in effect_defaults do if effect.Parent then effect.Enabled = map_id == "Arena" and enabled end end

        if sky then
            sky.StarCount = if map_id == "Arena" then star_defaults else 0
            sky.CelestialBodiesShown = map_id == "Arena" and celestial_defaults
        end

        if atmosphere then
            for property, original in atmosphere_defaults do
                atmosphere[property] = original
            end
            if map_id == "Desert" then
                atmosphere.Density, atmosphere.Haze = 0.31, 2
                atmosphere.Color, atmosphere.Decay = Color3.fromRGB(222, 198, 156), Color3.fromRGB(183, 146, 99)
            elseif map_id == "Rooftop" then
                atmosphere.Density, atmosphere.Haze = 0.29, 1.7
                atmosphere.Color, atmosphere.Decay = Color3.fromRGB(174, 177, 189), Color3.fromRGB(119, 130, 153)
            end
        end

        if map_id ~= "Arena" then
            local template = assets:FindFirstChild(map_id)
            if template then
                active_model = template:Clone()
                active_model.Name = "ActiveMap"
                active_model.Parent = combat
            end
        end
    end

    folder:GetAttributeChangedSignal("MapId"):Connect(UpdateMap)
    folder:SetAttribute("MapId", "Arena")
    UpdateMap()
end

return MapPresentation
