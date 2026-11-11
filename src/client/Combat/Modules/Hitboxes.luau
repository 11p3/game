local Hitboxes = {}
local STUDIO = game:GetService("RunService"):IsStudio()
local MoveDefinitions = require(game:GetService("ReplicatedStorage").Combat.Modules.MoveDefinitions)
local TARGET_DIAMETER = 0.24 -- Mark the logical target point; this is not a physical hurtbox size.
local container
local boxes = {}
local targets = {}
local last_state
local last_frame = -1
local last_revision = -1

function Hitboxes.Clear()
    if container then container:Destroy() end
    container = nil
    table.clear(boxes)
    table.clear(targets)
    last_state = nil
    last_frame, last_revision = -1, -1
end

function Hitboxes.Apply(state, enabled, revision)
    if not STUDIO or not enabled or state.phase ~= "Fighting" then
        if container then Hitboxes.Clear() end
        return
    end
    if last_state == state and last_frame == state.frame and last_revision == revision then return end

    if not container then
        container = Instance.new("Folder")
        container.Name = "Hitboxes"
        container.Parent = workspace.Combat
        for index = 1, 2 do
            local box = Instance.new("Part")
            box.Name = "Attack" .. index
            box.Anchored = true
            box.CanCollide, box.CanTouch, box.CanQuery, box.CastShadow = false, false, false, false
            box.Material = Enum.Material.SmoothPlastic
            box.Transparency = 1
            box.Parent = container
            boxes[index] = box

            local target = box:Clone()
            target.Name = "Target" .. index
            target.Shape = Enum.PartType.Ball
            target.Size = Vector3.one * TARGET_DIAMETER
            target.Color = Color3.fromRGB(100, 220, 150)
            target.Parent = container
            targets[index] = target
        end
    end

    for index, fighter in state.fighters do
        local box, target = boxes[index], targets[index]
        local position = Vector3.new(fighter.x, fighter.y, fighter.z)
        target.CFrame = CFrame.new(position)
        target.Transparency = if fighter.health > 0 and not fighter.protected then 0.15 else 1
        local startup = fighter.state == "AttackStartup"
        local active = fighter.state == "AttackActive"
        local move = fighter.attack_started and MoveDefinitions.Get(fighter.fighter_id, fighter.attack_kind)
        if move and not move.feint and (startup or active) then
            local direction = Vector3.new(fighter.attack_forward_x, 0, fighter.attack_forward_z)
            local range = fighter.attack_range
            box.Size = Vector3.new(fighter.attack_width * 2, (fighter.attack_height or 2.5) * 2, range)
            box.CFrame = CFrame.lookAt(position, position + direction) * CFrame.new(0, 0, -range * 0.5)
            box.Color = if active then Color3.fromRGB(240, 80, 80) else Color3.fromRGB(235, 180, 65)
            box.Transparency = if active then 0.7 else 0.88
        else
            box.Transparency = 1
        end
    end

    last_state, last_frame, last_revision = state, state.frame, revision
end

return Hitboxes
