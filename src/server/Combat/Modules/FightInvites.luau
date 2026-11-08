local FightInvites = {}
FightInvites.__index = FightInvites
local INVITE_SECONDS = 30
local STYLE_SECONDS = 60
local VOTE_SECONDS = 10
local MAX_INBOX = 6 -- Bound pending invites so one player cannot fill another's inbox indefinitely.
local MAX_ID = 9007199254740991 -- Keep IDs within the exact integer range of Lua numbers.

function FightInvites.New(context)
    return setmetatable({context = context, pending = {}, outgoing = {}, sessions = {}, budgets = {}, send_ready = {}, list_ready = {}, next_id = 0}, FightInvites)
end

function FightInvites:Available(player)
    return player ~= nil and self.sessions[player] == nil and player:GetAttribute("MatchStatus") ~= "Searching" and self.context.CanFight(player)
end

function FightInvites:Sync(player, message)
    local context = self.context
    if not player or player.Parent ~= context.Players then
        return
    end
    local inbox = {}
    for _, invite in self.pending do
        if invite.recipient == player then
            table.insert(inbox, {id = invite.id, user_id = invite.sender.UserId, name = invite.sender.Name, display_name = invite.sender.DisplayName or invite.sender.Name})
        end
    end
    table.sort(inbox, function(first, second) return first.id > second.id end)
    local outgoing = self.outgoing[player]
    local session = self.sessions[player]
    local opponent = session and (if session.sender == player then session.recipient else session.sender)
    local selection

    if session then
        local fighters = {}

        for _, participant in {session.sender, session.recipient} do
            table.insert(fighters, {user_id = participant.UserId, name = participant.DisplayName or participant.Name, style_id = session.styles[participant], ready = session.ready[participant] ~= nil, vote = session.votes[participant]})
        end

        selection = {
            phase = session.phase,
            map_id = session.map_id,
            seconds = math.max(0, session.expires_at - context.Clock()),
            id = session.id,
            slot = if player == session.sender then 1 else 2,
            fighters = fighters,
            opponent = opponent.DisplayName or opponent.Name,
            ready = session.ready[player] ~= nil
        }
    end

    context.Remote:FireClient(player, {inbox = inbox, outgoing = if outgoing then {id = outgoing.id, user_id = outgoing.recipient.UserId} else nil, session = selection, message = message or ""})
end

function FightInvites:Remove(invite, message)
    if self.pending[invite.id] ~= invite then
        return
    end
    self.pending[invite.id] = nil
    if self.outgoing[invite.sender] == invite then
        self.outgoing[invite.sender] = nil
    end
    self:Sync(invite.sender, message)
    self:Sync(invite.recipient, message)
end

function FightInvites:CancelSession(session, message)
    for _, player in {session.sender, session.recipient} do
        if self.sessions[player] ~= session then
            continue
        end
        self.sessions[player] = nil
        player:SetAttribute("InviteId", nil)
        if player:GetAttribute("MatchStatus") == "Selecting" or player:GetAttribute("MatchStatus") == "Voting" then
            player:SetAttribute("MatchStatus", "Menu")
        end
    end
    if session.rematch and session.rematch.slot then
        self.context.ReleaseSlot(session.rematch.slot)
        session.rematch.slot = nil
    end

    self:Sync(session.sender, message)
    self:Sync(session.recipient, message)
end

function FightInvites:Clear(player, message)
    local session = self.sessions[player]
    if session then
        self:CancelSession(session, message or "Fight cancelled")
    end
    for _, invite in self.pending do
        if invite.sender == player or invite.recipient == player then
            self:Remove(invite, message or "Invite cancelled")
        end
    end
end

function FightInvites:Send(player, user_id)
    local context = self.context
    if type(user_id) ~= "number" or user_id % 1 ~= 0 or user_id == player.UserId then
        return
    end
    if not self:Available(player) then
        self:Sync(player, "You are unavailable"); return
    end
    local recipient = context.Players:GetPlayerByUserId(user_id)
    if not self:Available(recipient) then
        self:Sync(player, "Player is unavailable"); return
    end
    if self.outgoing[player] then
        self:Sync(player, "Cancel your current invite first"); return
    end
    local count = 0
    for _, invite in self.pending do if invite.recipient == recipient then count += 1 end end
    if count >= MAX_INBOX then
        self:Sync(player, "Their inbox is full"); return
    end
    if context.Clock() < (self.send_ready[player] or 0) then
        return
    end
    self.send_ready[player] = context.Clock() + 3
    self.next_id += 1
    local invite = {id = self.next_id, sender = player, recipient = recipient, expires_at = context.Clock() + INVITE_SECONDS}
    self.pending[invite.id] = invite
    self.outgoing[player] = invite
    self:Sync(player, "Invite sent")
    self:Sync(recipient)
end

function FightInvites:BeginSelection(first, second, rematch, invite_id)
    local context = self.context

    if not first or not second or first == second or self.sessions[first] or self.sessions[second] or not context.CanFight(first) or not context.CanFight(second) then
        return false
    end

    self:Clear(first)
    self:Clear(second)

    if not rematch then
        context.CloseRematch(first)
        context.CloseRematch(second)
    end

    if not invite_id then
        self.next_id += 1
        invite_id = self.next_id
    end

    local session = {
        id = invite_id,
        sender = first,
        recipient = second,
        phase = "Voting",
        votes = {},
        ready = {},
        styles = {},
        characters = {},
        rematch = rematch,
        expires_at = context.Clock() + VOTE_SECONDS
    }

    for _, participant in {first, second} do
        local style_id = participant:GetAttribute("StyleId")
        session.styles[participant] = if context.Styles[style_id] then style_id else "Boxing"
        session.characters[participant] = participant.Character
        self.sessions[participant] = session
        participant:SetAttribute("InviteId", session.id)
        participant:SetAttribute("MatchStatus", "Voting")
    end

    self:Sync(first)
    self:Sync(second)
    return true
end

function FightInvites:Accept(player, invite_id)
    local invite = self.pending[invite_id]
    if not invite or invite.recipient ~= player then
        return
    end

    local context = self.context
    if context.Clock() >= invite.expires_at or not self:Available(player) or not self:Available(invite.sender) then
        self:Remove(invite, "Invite unavailable"); return
    end

    self:BeginSelection(invite.sender, invite.recipient, nil, invite.id)
end

function FightInvites:ResolveVote(session)
    if session.phase ~= "Voting" then
        return
    end

    local counts = {}
    local highest = 0

    for _, map_id in session.votes do
        counts[map_id] = (counts[map_id] or 0) + 1
        highest = math.max(highest, counts[map_id])
    end

    local tied = {}
    for map_id in self.context.Maps do
        if highest > 0 and counts[map_id] == highest then
            table.insert(tied, map_id)
        end
    end
    -- Use stable map order before rotating tied votes by session ID.
    table.sort(tied, function(first, second) return self.context.Maps[first].Order < self.context.Maps[second].Order end)

    session.map_id = if #tied == 0 then "Arena" else tied[(session.id - 1) % #tied + 1]
    session.phase = "Selecting"
    session.expires_at = self.context.Clock() + STYLE_SECONDS

    for _, player in {session.sender, session.recipient} do
        player:SetAttribute("MatchStatus", "Selecting")
        self:Sync(player)
    end
end

function FightInvites:Vote(player, selection_id, map_id)
    local session = self.sessions[player]
    if not session or session.id ~= selection_id or session.phase ~= "Voting" or type(map_id) ~= "string" or not self.context.Maps[map_id] then
        return
    end
    if self.context.Clock() >= session.expires_at then
        self:ResolveVote(session); return
    end

    session.votes[player] = map_id
    if session.votes[session.sender] and session.votes[session.recipient] then
        self:ResolveVote(session)
    else
        self:Sync(session.sender)
        self:Sync(session.recipient)
    end
end

function FightInvites:Select(player, selection_id, style_id)
    local session = self.sessions[player]
    local context = self.context

    if not session or session.id ~= selection_id or session.phase ~= "Selecting" or session.ready[player] or type(style_id) ~= "string" or not context.Styles[style_id] or session.styles[player] == style_id then
        return
    end
    if context.Clock() >= session.expires_at then
        self:CancelSession(session, "Selection expired"); return
    end

    session.styles[player] = style_id
    self:Sync(session.sender)
    self:Sync(session.recipient)
end

function FightInvites:Ready(player, invite_id, style_id)
    local session = self.sessions[player]
    local context = self.context
    if not session or session.id ~= invite_id or session.phase ~= "Selecting" or type(style_id) ~= "string" or not context.Styles[style_id] or session.ready[player] then
        return
    end
    if context.Clock() >= session.expires_at or not context.CanFight(session.sender) or not context.CanFight(session.recipient) or session.sender.Character ~= session.characters[session.sender] or session.recipient.Character ~= session.characters[session.recipient] then
        self:CancelSession(session, "Fight unavailable"); return
    end
    session.styles[player] = style_id
    session.ready[player] = style_id
    self:Sync(player)
    local other = if session.sender == player then session.recipient else session.sender
    self:Sync(other)
    if not session.ready[other] then
        return
    end

    for _, participant in {session.sender, session.recipient} do
        local selected_style = session.ready[participant]
        context.PlayerData.SetStyle(participant, selected_style)
        participant.Character:SetAttribute("FighterId", context.Styles[selected_style].FighterId)
        self.sessions[participant] = nil
        participant:SetAttribute("InviteId", nil)
    end

    local started = context.StartBout(session.sender, session.recipient, false, session.rematch, session.map_id)
    if session.rematch and session.rematch.slot then
        if not started then
            context.ReleaseSlot(session.rematch.slot)
        end
        session.rematch.slot = nil
    end
    for _, participant in {session.sender, session.recipient} do
        if not started and participant:GetAttribute("MatchStatus") == "Selecting" then
            participant:SetAttribute("MatchStatus", "Menu")
        end
        self:Sync(participant, if started then "" else "Fight unavailable")
    end
end

function FightInvites:Handle(player, action, value, style_id)
    if player.Parent ~= self.context.Players then
        return
    end
    if action ~= "List" and (type(value) ~= "number" or value % 1 ~= 0 or math.abs(value) > MAX_ID) then
        return
    end
    if action == "Cancel" or action == "Decline" then
        local session = self.sessions[player]
        if action == "Cancel" and session and session.id == value then
            self:CancelSession(session, "Fight cancelled"); return
        end
        local invite = self.pending[value]
        if invite and ((action == "Cancel" and invite.sender == player) or (action == "Decline" and invite.recipient == player)) then self:Remove(invite, if action == "Decline" then "Invite declined" else "Invite cancelled") end
        return
    end
    if action ~= "List" and action ~= "Send" and action ~= "Accept" and action ~= "Ready" and action ~= "Select" and action ~= "Vote" then
        return
    end
    local now = self.context.Clock()
    local budget = self.budgets[player]
    if not budget or now - budget.started >= 1 then
        budget = {started = now, count = 0}; self.budgets[player] = budget
    end
    budget.count += 1
    if budget.count > 12 then
        return
    end

    if action == "List" then
        if now < (self.list_ready[player] or 0) then
            return
        end
        self.list_ready[player] = now + 1
        self:Sync(player)
    elseif action == "Send" then
        self:Send(player, value)
    elseif action == "Accept" then
        self:Accept(player, value)
    elseif action == "Select" then
        self:Select(player, value, style_id)
    elseif action == "Vote" then
        self:Vote(player, value, style_id)
    elseif action == "Ready" then
        self:Ready(player, value, style_id)
    end
end

function FightInvites:RemovePlayer(player)
    self:Clear(player, "Player left")
    self.budgets[player] = nil
    self.send_ready[player] = nil
    self.list_ready[player] = nil
end

function FightInvites:Update()
    local context = self.context
    local now = context.Clock()
    for _, invite in self.pending do
        if now >= invite.expires_at or not self:Available(invite.sender) or not self:Available(invite.recipient) then
            self:Remove(invite, "Invite expired")
        end
    end
    for player, session in self.sessions do
        if player ~= session.sender then
            continue
        end
        if not context.CanFight(session.sender) or not context.CanFight(session.recipient) or session.sender.Character ~= session.characters[session.sender] or session.recipient.Character ~= session.characters[session.recipient] then
            self:CancelSession(session, "Fight unavailable")
        elseif now >= session.expires_at then
            if session.phase == "Voting" then self:ResolveVote(session) else self:CancelSession(session, "Selection expired") end
        end
    end
end

return FightInvites
