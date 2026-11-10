local FighterPresentation = require(game.ReplicatedStorage.Combat.Modules.FighterPresentation)
local Feedback = {}

function Feedback.Initialize()
    local Players = game:GetService("Players")
    local player = Players.LocalPlayer
    local arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    local folder = script.Parent.Parent
    local Animations = require(script.Parent.Animations)
    local Motion = require(script.Parent.Motion)
    local Effects = require(script.Parent.Effects)
    local HUD = require(script.Parent.HUD)
    local connections = {}
    local character_versions = setmetatable({}, {__mode = "k"})

    local function FindOpponent()
        return FighterPresentation.FindOpponent(Players, workspace.Combat, script.Parent.Parent)
    end


    local npc = FindOpponent()

    local function IsCurrentCharacter(character)
        return character.Parent ~= nil and (character == player.Character or character == FindOpponent())
    end

    local function WatchCharacter(character: Model)
        if not IsCurrentCharacter(character) then
            return
        end
        -- Discard older yielding binds if appearance or character setup starts again.
        local version = (character_versions[character] or 0) + 1
        character_versions[character] = version

        if connections[character] then
            connections[character]()
        end

        local humanoid = character:WaitForChild("Humanoid", 10)
        if not humanoid or not IsCurrentCharacter(character) or character_versions[character] ~= version then
            return
        end
        local animator = humanoid:WaitForChild("Animator", 10)
        if not animator or not IsCurrentCharacter(character) or character_versions[character] ~= version then
            return
        end
        local root = character:WaitForChild("HumanoidRootPart", 10)
        if not root or not IsCurrentCharacter(character) or character_versions[character] ~= version then
            return
        end

        local listeners = {}
        local cleanup_callbacks = {}
        local alive = true

        local function Cleanup()
            if not alive then
                return
            end
            alive = false
            for _, connection in listeners do
                connection:Disconnect()
            end
            for index = #cleanup_callbacks, 1, -1 do
                cleanup_callbacks[index]()
            end
            if connections[character] == Cleanup then
                connections[character] = nil
            end
            if character_versions[character] == version then
                character_versions[character] = nil
            end
        end

        connections[character] = Cleanup
        table.insert(listeners, character.Destroying:Connect(Cleanup))

        local animation_state, stop_animations = Animations.Bind(character, animator)
        table.insert(cleanup_callbacks, stop_animations)
        table.insert(cleanup_callbacks, HUD.Bind(character, root))
        table.insert(cleanup_callbacks, Motion.Bind(character, root, animation_state, FindOpponent))
        table.insert(cleanup_callbacks, Effects.Bind(character, root))

        table.insert(listeners, character.ChildAdded:Connect(function(child)
            if child.Name == "Animate" and child:IsA("LocalScript") then
                child.Disabled = true
            elseif child:IsA("Humanoid") then
                task.defer(WatchCharacter, character)
            end
        end))
        table.insert(listeners, character:GetAttributeChangedSignal("FighterId"):Connect(function() task.defer(WatchCharacter, character) end))
        table.insert(listeners, character:GetAttributeChangedSignal("AppearanceReady"):Connect(function()
            if character:GetAttribute("AppearanceReady") then
                task.defer(WatchCharacter, character)
            end
        end))
    end

    local function UpdateMatch()
        HUD.UpdateMatch(FindOpponent() ~= nil)
    end

    local function WatchOpponent()
        if npc and connections[npc] then
            connections[npc]()
        end
        npc = FindOpponent()
        if npc then
            task.spawn(WatchCharacter, npc)
        end
        UpdateMatch()
    end

    player.CharacterRemoving:Connect(function(character)
        if connections[character] then
            connections[character]()
        end
    end)

    local arenas = workspace.Combat:WaitForChild("Arenas")
    arenas.DescendantAdded:Connect(function(child)
        if child.Name == "NPC" and child.Parent and child.Parent.Name == folder:GetAttribute("ArenaId") then
            WatchOpponent()
        end
    end)
    arenas.DescendantRemoving:Connect(function(child)
        if child == npc then
            if connections[npc] then
                connections[npc]()
            end
            npc = nil
            HUD.UpdateMatch(false)
        end
    end)
    folder:GetAttributeChangedSignal("ArenaId"):Connect(WatchOpponent)
    folder:GetAttributeChangedSignal("OpponentUserId"):Connect(WatchOpponent)
    for _, attribute in {"MatchState", "Count", "Result", "DownedFighter"} do
        arena:GetAttributeChangedSignal(attribute):Connect(UpdateMatch)
    end
    WatchOpponent()
    player.CharacterAdded:Connect(WatchCharacter)
    if player.Character then
        task.spawn(WatchCharacter, player.Character)
    end
end

return Feedback
