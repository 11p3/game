local Crowd = {}

function Crowd.Initialize()
    local Players = game:GetService("Players")

    local stadium = workspace:WaitForChild("Combat"):WaitForChild("Stadium")
    local crowd = stadium:WaitForChild("Crowd")
    local MAX_SPECTATORS = 48
    local FRIENDS_PER_PLAYER = 24
    local LOAD_WORKERS = 4
    local random = Random.new()
    local occupied_seats = {}
    local used_friends = {}
    local loading_players = {}
    local waiting_players = {}
    local seats = {}

    for _, seat in stadium.Seating:GetDescendants() do
        if seat.Name == "Seat" and seat:IsA("BasePart") then
            table.insert(seats, seat)
        end
    end

    table.sort(seats, function(a, b)
        return (a:GetAttribute("SeatRank") or 0) < (b:GetAttribute("SeatRank") or 0)
    end)

    local function LoadFriends(player: Player)
        if loading_players[player] then
            return
        end

        loading_players[player] = true
        waiting_players[player] = nil

        local success, pages = pcall(function()
            return Players:GetFriendsAsync(player.UserId)
        end)

        if not success then
            warn("Could not load crowd friends for " .. player.Name .. ": " .. tostring(pages))
        end

        local friends = {}

        if success then
        repeat

            for _, friend in pages:GetCurrentPage() do
                table.insert(friends, friend)
            end

            if pages.IsFinished or #friends >= FRIENDS_PER_PLAYER then
                break
            end

            local advanced = pcall(function()
                pages:AdvanceToNextPageAsync()
            end)

            if not advanced then
                break
            end
        until not player.Parent
        end

        if #friends == 0 then
            for index = 1, FRIENDS_PER_PLAYER do
                table.insert(friends, {Id = "Fan:" .. player.UserId .. ":" .. index, Username = "Fan", Fallback = true})
            end
        end

        for index = #friends, 2, -1 do
            local swap = random:NextInteger(1, index)

            friends[index], friends[swap] = friends[swap], friends[index]
        end

        local next_friend = 0
        local reserved = 0
        for _, owner in occupied_seats do
            if owner == player then reserved += 1 end
        end
        local active_workers = LOAD_WORKERS

        for worker = 1, LOAD_WORKERS do
            task.spawn(function()
                while player.Parent and reserved < FRIENDS_PER_PLAYER do
                    next_friend += 1

                    local friend = friends[next_friend]

                    if not friend then
                        break
                    end

                    local occupied_count = 0
                    local available_seat

                    for _, seat in seats do
                        if occupied_seats[seat] then
                            occupied_count += 1
                        elseif not available_seat then
                            available_seat = seat
                        end
                    end

                    if occupied_count >= MAX_SPECTATORS or not available_seat then
                        waiting_players[player] = true
                        break
                    end

                    if used_friends[friend.Id] then
                        continue
                    end

                    occupied_seats[available_seat] = player
                    used_friends[friend.Id] = player
                    reserved += 1

                    local description
                    local created, model = pcall(function()
                        if friend.Fallback then
                            description = Instance.new("HumanoidDescription")

                            local skin_colors = {Color3.fromRGB(245, 205, 155), Color3.fromRGB(204, 156, 114), Color3.fromRGB(141, 88, 62), Color3.fromRGB(95, 65, 49)}
                            local shirt_colors = {
                                Color3.fromRGB(55, 70, 91),
                                Color3.fromRGB(120, 48, 45),
                                Color3.fromRGB(54, 86, 65),
                                Color3.fromRGB(175, 166, 146),
                                Color3.fromRGB(70, 65, 79)
                            }
                            local skin = skin_colors[random:NextInteger(1, #skin_colors)]
                            local shirt = shirt_colors[random:NextInteger(1, #shirt_colors)]

                            description.HeadColor = skin
                            description.LeftArmColor = skin
                            description.RightArmColor = skin
                            description.TorsoColor = shirt
                            description.LeftLegColor = Color3.fromRGB(44, 47, 55)
                            description.RightLegColor = description.LeftLegColor
                        else
                            description = Players:GetHumanoidDescriptionFromUserIdAsync(friend.Id)
                        end

                        local avatar = Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R6)

                        return avatar
                    end)

                    if description then
                        description:Destroy()
                    end

                    if not created or not player.Parent or occupied_seats[available_seat] ~= player then
                        if occupied_seats[available_seat] == player then
                            occupied_seats[available_seat] = nil
                        end

                        if used_friends[friend.Id] == player then
                            used_friends[friend.Id] = nil
                        end
                        reserved -= 1

                        if created then
                            model:Destroy()
                        end
                        continue
                    end

                    local humanoid = model:FindFirstChildOfClass("Humanoid")
                    local root = model:FindFirstChild("HumanoidRootPart")

                    if not humanoid or not root then
                        model:Destroy()

                        if occupied_seats[available_seat] == player then
                            occupied_seats[available_seat] = nil
                        end

                        if used_friends[friend.Id] == player then
                            used_friends[friend.Id] = nil
                        end
                        reserved -= 1
                        continue
                    end

                    model.Name = friend.Username
                    model:SetAttribute("FriendUserId", if friend.Fallback then 0 else friend.Id)
                    model:SetAttribute("FanKey", friend.Id)
                    model:SetAttribute("RandomFan", friend.Fallback == true)
                    model:SetAttribute("SourcePlayerUserId", player.UserId)
                    model:SetAttribute("SeatPosition", available_seat.Position)

                    for _, object in model:GetDescendants() do
                        if object:IsA("BasePart") then
                            object.CanCollide = false
                            object.CanTouch = false
                            object.CanQuery = false
                            object.Massless = true
                        elseif object:IsA("BaseScript") then
                            object:Destroy()
                        end
                    end

                    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                    humanoid.AutoRotate = false
                    humanoid.WalkSpeed = 0
                    humanoid.BreakJointsOnDeath = false

                    if not humanoid:FindFirstChildOfClass("Animator") then
                        Instance.new("Animator", humanoid)
                    end

                    root.Anchored = true

                    local position = available_seat.Position + Vector3.new(0, 2.9, 0) + available_seat.CFrame.LookVector * 0.8

                    root.CFrame = CFrame.lookAt(position, Vector3.new(0, position.Y, 0))
                    model.Parent = crowd
                    task.wait()
                end

                active_workers -= 1
                if active_workers == 0 then
                    loading_players[player] = nil
                    if reserved >= FRIENDS_PER_PLAYER or not player.Parent then waiting_players[player] = nil end

                    local occupied_count = 0
                    for _ in occupied_seats do occupied_count += 1 end
                    if occupied_count < math.min(MAX_SPECTATORS, #seats) then
                        for waiting in waiting_players do
                            if waiting.Parent and not loading_players[waiting] then task.defer(LoadFriends, waiting) end
                        end
                    end
                end
            end)
        end
    end

    Players.PlayerAdded:Connect(function(player)
        task.spawn(LoadFriends, player)
    end)

    Players.PlayerRemoving:Connect(function(player)
        waiting_players[player] = nil

        for _, model in crowd:GetChildren() do
            if model:GetAttribute("SourcePlayerUserId") == player.UserId then
                used_friends[model:GetAttribute("FanKey") or model:GetAttribute("FriendUserId")] = nil
                model:Destroy()
            end
        end

        for seat, owner in occupied_seats do
            if owner == player then
                occupied_seats[seat] = nil
            end
        end

        for waiting in waiting_players do
            if waiting.Parent and not loading_players[waiting] then task.defer(LoadFriends, waiting) end
        end
    end)

    for _, player in Players:GetPlayers() do
        task.spawn(LoadFriends, player)
    end
end

return Crowd
