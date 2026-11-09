local StylePreviews = {}
local Players = game:GetService("Players")
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Combat")
local Styles = require(shared.Modules.Styles)

function StylePreviews.New(styles_panel)
    local player = Players.LocalPlayer
    local previews = {}

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

    local binding = {views = previews, characters = {}}
    function binding:Refresh(selection)
        local left_player = selection and Players:GetPlayerByUserId(selection.fighters[1].user_id) or player
        local right_player = selection and Players:GetPlayerByUserId(selection.fighters[2].user_id)

        for style_id, style_previews in self.views do
            for index, preview in style_previews do
                local owner = if index == 1 then player elseif index == 2 then left_player else right_player
                local character = owner and owner.Character

                if self.characters[preview] == character then
                    continue
                end
                self.characters[preview] = nil
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
                self.characters[preview] = character

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

    return binding
end

return StylePreviews
