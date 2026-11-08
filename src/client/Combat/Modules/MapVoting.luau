local MapVoting = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Maps = require(ReplicatedStorage.Combat.Modules.Maps)
local panel
local context
local open = false
local mode
local session
local chosen = "Arena"
local deadline = 0
local countdown_generation = 0

local function RefreshCountdown()
    countdown_generation += 1
    local generation = countdown_generation
    local function Tick()
        if generation ~= countdown_generation or not open or not panel then return end
        local remaining = deadline - os.clock()
        local seconds = math.max(0, math.ceil(remaining))
        local text = if session then tostring(seconds) else ""
        if panel.Countdown.Text ~= text then panel.Countdown.Text = text end
        if session and seconds > 0 then task.delay(math.max(0.05, remaining - seconds + 1), Tick) end
    end
    Tick()
end

local function Refresh()
    if not panel then
        return
    end

    local counts = {}
    if session then
        for _, fighter in session.fighters do if fighter.vote then counts[fighter.vote] = (counts[fighter.vote] or 0) + 1 end end
    end
    for map_id in Maps do
        local card = panel.Options[map_id]
        card.SelectionOutline.Visible = chosen == map_id
        card.Votes.Text = if session then tostring(counts[map_id] or 0) .. " / 2 votes" else ""
    end
    panel.Title.Text = if session then "VOTE FOR A MAP" else "CHOOSE A MAP"
    panel.Confirm.Text = if session then "VOTE" else "CONTINUE"
end

function MapVoting.Initialize(options)
    context = options
    panel = options.Menu:WaitForChild("MapPanel")

    for map_id, map in Maps do
        local card = panel.Options[map_id]
        card.NameLabel.Text = string.upper(map.Name)
        card.Description.Text = map.Description
        card.Activated:Connect(function() chosen = map_id; Refresh() end)

        local preview = card.Preview
        local camera = preview:FindFirstChild("Camera") or Instance.new("Camera")
        camera.Name, camera.Parent = "Camera", preview
        preview.CurrentCamera = camera
        local source = if map_id == "Arena" then workspace.Combat.Arena else ReplicatedStorage.Combat.MapAssets:WaitForChild(map_id)
        local model = source:Clone()
        for _, object in model:GetDescendants() do if object:IsA("BaseScript") then object:Destroy() end end
        model.Parent = preview.WorldModel
        camera.FieldOfView = 48
        camera.CFrame = if map_id == "Arena" then CFrame.lookAt(Vector3.new(40, 31, 43), Vector3.new(0, 1, 0)) else CFrame.lookAt(Vector3.new(52, 43, 57), Vector3.new(0, 1, 0))
    end

    panel.Confirm.Activated:Connect(function()
        if not open then
            return
        end
        if session then
            context.Vote(session.id, chosen)
        else
            local selected_mode, map_id = mode, chosen
            MapVoting.Close()
            context.Continue(selected_mode, map_id)
        end
    end)
    panel.Back.Activated:Connect(function()
        if session then
            context.Cancel()
        end
        MapVoting.Close()
        context.UpdateMenu()
    end)

end

function MapVoting.OpenSolo(selected_mode)
    mode, session, chosen, open = selected_mode, nil, "Arena", true
    Refresh()
    RefreshCountdown()
    context.UpdateMenu()
end

function MapVoting.OpenSession(selection)
    local changed = not session or session.id ~= selection.id
    mode, session, open = nil, selection, true
    chosen = selection.fighters[selection.slot].vote or (if changed then "Arena" else chosen)
    deadline = os.clock() + selection.seconds
    Refresh()
    RefreshCountdown()
end

function MapVoting.Close()
    countdown_generation += 1
    open, mode, session = false, nil, nil
    if panel then
        panel.Visible = false
    end
end

function MapVoting.IsOpen()
    return open
end

return MapVoting
