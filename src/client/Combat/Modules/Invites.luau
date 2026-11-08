local Invites = {}
type Invite = {id: number, user_id: number, name: string, display_name: string}
type SelectionFighter = {user_id: number, name: string, style_id: string, ready: boolean, vote: string?}
type Selection = {id: number, phase: "Voting" | "Selecting", map_id: string?, seconds: number, slot: number, fighters: {SelectionFighter}, opponent: string, ready: boolean}
type InviteState = {inbox: {Invite}, outgoing: {id: number, user_id: number}?, session: Selection?, message: string?}

local state: InviteState = {inbox = {}}
local remote
local Refresh
local cancelling_id

function Invites.GetSession()
    return state.session
end

function Invites.Cancel()
    if state.session then
        -- Block late Ready clicks locally while server cancellation is in flight.
        cancelling_id = state.session.id
        remote:FireServer("Cancel", state.session.id)
    end
end

function Invites.Ready(invite_id, style_id)
    if state.session and state.session.id == invite_id and invite_id ~= cancelling_id and not state.session.ready then
        remote:FireServer("Ready", invite_id, style_id)
    end
end

function Invites.Select(style_id)
    local session = state.session
    if session and session.phase == "Selecting" and not session.ready and session.id ~= cancelling_id then
        remote:FireServer("Select", session.id, style_id)
    end
end

function Invites.Vote(selection_id, map_id)
    local session = state.session
    if session and session.phase == "Voting" and session.id == selection_id and session.id ~= cancelling_id then
        remote:FireServer("Vote", selection_id, map_id)
    end
end

function Invites.Refresh()
    if Refresh then
        Refresh()
    end
end

function Invites.Initialize(context)
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local player = Players.LocalPlayer
    local menu = context.Menu
    local friends = menu:WaitForChild("FriendsPanel")
    local inbox = menu:WaitForChild("InboxPanel")
    local player_rows = {}
    local inbox_rows = {}
    local watchers = {}
    remote = ReplicatedStorage:WaitForChild("Combat").Remotes:WaitForChild("Invites")

    local function RenderPlayers()
        if not friends.Visible then
            return
        end
        local players = Players:GetPlayers()
        table.sort(players, function(first, second)
            local first_name, second_name = string.lower(first.DisplayName), string.lower(second.DisplayName)
            return if first_name == second_name then first.UserId < second.UserId else first_name < second_name
        end)
        local present = {}
        local count = 0

        for _, other in players do
            if other == player then
                continue
            end
            count += 1
            present[other.UserId] = true
            local row = player_rows[other.UserId]
            if not row then
                row = friends.RowTemplate:Clone()
                row.Name = "Player_" .. other.UserId
                row.Visible = true
                row.Parent = friends.List
                row.Action.Activated:Connect(function()
                    if state.outgoing and state.outgoing.user_id == other.UserId then remote:FireServer("Cancel", state.outgoing.id) else remote:FireServer("Send", other.UserId) end
                end)
                player_rows[other.UserId] = row
            end

            local status = other:GetAttribute("MatchStatus")
            local data_status = other:GetAttribute("DataStatus")
            local available = status ~= "Fighting" and status ~= "Searching" and status ~= "Selecting" and status ~= "Voting" and (data_status == "Ready" or data_status == "Studio") and other.Character ~= nil and other.Character:GetAttribute("AppearanceReady") == true
            local sent = state.outgoing and state.outgoing.user_id == other.UserId
            row.LayoutOrder = count
            row.NameLabel.Text = if other.DisplayName == other.Name then other.Name else other.DisplayName .. "\n@" .. other.Name
            row.Action.Text = if sent then "Cancel" elseif available then "Invite" else "Busy"
            row.Action.Active = sent == true or (available and state.outgoing == nil)
            row.Action.AutoButtonColor = row.Action.Active
            row.Action.TextTransparency = if row.Action.Active then 0 else 0.5
        end

        for user_id, row in player_rows do
            if not present[user_id] then
                row:Destroy(); player_rows[user_id] = nil
            end
        end
        friends.List.Empty.Visible = count == 0
    end

    local function RenderInbox()
        local present = {}
        for _, invite in state.inbox do
            present[invite.id] = true
            local row = inbox_rows[invite.id]
            if not row then
                row = inbox.RowTemplate:Clone()
                row.Name = "Invite_" .. invite.id
                row.Visible = true
                row.Parent = inbox.List
                row.Accept.Activated:Connect(function() remote:FireServer("Accept", invite.id) end)
                row.Decline.Activated:Connect(function() remote:FireServer("Decline", invite.id) end)
                inbox_rows[invite.id] = row
            end
            row.LayoutOrder = -invite.id
            row.NameLabel.Text = if invite.display_name == invite.name then invite.name else invite.display_name .. "\n@" .. invite.name
        end
        for invite_id, row in inbox_rows do
            if not present[invite_id] then
                row:Destroy(); inbox_rows[invite_id] = nil
            end
        end
        inbox.List.Empty.Visible = #state.inbox == 0
        menu.Panel.Inbox.Text = "Inbox" .. (if #state.inbox > 0 then " (" .. #state.inbox .. ")" else "")
    end

    Refresh = function()
        RenderPlayers()
        RenderInbox()
    end

    local function ChooseStyle()
        if not state.session or state.session.id == cancelling_id then
            return
        end
        if state.session.phase == "Voting" then
            context.ChooseMap(state.session)
        elseif not state.session.ready and not context.IsChoosing() then
            context.ChooseStyle(state.session.id, state.session.opponent)
        end
    end

    remote.OnClientEvent:Connect(function(packet)
        if type(packet) ~= "table" or type(packet.inbox) ~= "table" then
            return
        end
        local previous = state.session
        state = packet
        if not state.session then
            cancelling_id = nil
        end
        friends.Message.Text = packet.message or ""
        inbox.Message.Text = packet.message or ""
        if state.session then
            ChooseStyle()
            context.SelectionChanged(state.session)
        elseif previous then
            context.EndChoice()
        end
        Refresh()
        context.UpdateMenu()
    end)

    menu.Panel.VsFriend.Activated:Connect(function()
        context.OpenPage("Friends")
        remote:FireServer("List")
        Refresh()
    end)
    menu.Panel.Inbox.Activated:Connect(function()
        context.OpenPage("Inbox")
        remote:FireServer("List")
        Refresh()
    end)
    friends.Back.Activated:Connect(function() context.OpenPage(nil) end)
    inbox.Back.Activated:Connect(function() context.OpenPage(nil) end)

    local function WatchPlayer(other)
        if watchers[other] then
            return
        end
        local connections = {}
        for _, attribute in {"MatchStatus", "DataStatus", "InviteId"} do
            table.insert(connections, other:GetAttributeChangedSignal(attribute):Connect(RenderPlayers))
        end
        table.insert(connections, other.CharacterAdded:Connect(RenderPlayers))
        table.insert(connections, other.CharacterRemoving:Connect(RenderPlayers))
        watchers[other] = connections
        RenderPlayers()
    end
    Players.PlayerAdded:Connect(WatchPlayer)
    Players.PlayerRemoving:Connect(function(other)
        for _, connection in watchers[other] or {} do
            connection:Disconnect()
        end
        watchers[other] = nil
        local row = player_rows[other.UserId]
        if row then
            row:Destroy(); player_rows[other.UserId] = nil
        end
        task.defer(RenderPlayers)
    end)
    player:GetAttributeChangedSignal("MatchStatus"):Connect(ChooseStyle)
    for _, other in Players:GetPlayers() do
        WatchPlayer(other)
    end
    Refresh()
    remote:FireServer("List")
end

return Invites
