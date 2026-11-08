local BoutResults = {}
BoutResults.__index = BoutResults
local REMATCH_SECONDS = 45

function BoutResults.New(context)
    return setmetatable({context = context, offers = {}}, BoutResults)
end

function BoutResults:Clear(player, message)
    local offer = self.offers[player]
    if not offer then
        return
    end

    for _, participant in offer.players do
        if self.offers[participant] == offer then
            self.offers[participant] = nil
        end
        if participant.Parent == self.context.Players then
            self.context.Remote:FireClient(participant, "Rematch", {epoch = offer.epoch, available = false, waiting = false, message = message or "Unavailable"})
        end
    end

    if offer.slot then
        self.context.ReleaseSlot(offer.slot)
        offer.slot = nil
    end
end

function BoutResults:Show(match, loser, reason, allow_rematch)
    local context = self.context
    local state = match.session.state
    local participants = if match.opponent then {match.opponent, match.player} else {match.player}
    local series = table.clone(match.series)
    if loser > 0 then series[if loser == 1 then 2 else 1] += 1 end
    local available = allow_rematch

    for _, player in participants do
        self:Clear(player)
        available = available and context.IsReady(player) and (not match.opponent or context.PlayerData.IsReady(player))
    end

    local offer
    if available then
        offer = {
            epoch = match.epoch,
            player = match.player,
            opponent = match.opponent,
            players = participants,
            ready = {},
            series = series,
            slot = match.slot,
            expires_at = context.Clock() + REMATCH_SECONDS
        }
        for _, player in participants do
            self.offers[player] = offer
        end
    end

    for _, player in participants do
        if player.Parent ~= context.Players then
            continue
        end
        local slot = if player == match.opponent then 1 else 2
        local other_slot = if slot == 1 then 2 else 1
        local fighter, other = state.fighters[slot], state.fighters[other_slot]
        local stats = fighter.stats
        local opponent = if player == match.opponent then match.player else match.opponent
        local payload = {
            epoch = match.epoch,
            outcome = if loser == 0 then "Draw" elseif loser == slot then "Loss" else "Win",
            reason = reason,
            opponent = if opponent then opponent.DisplayName or opponent.Name else "NPC",
            pvp = match.opponent ~= nil,
            style_id = match.style_ids[slot],
            thrown = stats.thrown,
            landed = stats.landed,
            damage = stats.damage_tenths / 10,
            perfect_dodges = stats.perfect_dodges,
            knockdowns = other.knockdowns,
            record = {wins = player:GetAttribute("PvPWins") or 0, losses = player:GetAttribute("PvPLosses") or 0, draws = player:GetAttribute("PvPDraws") or 0},
            series = {you = series[slot], opponent = series[other_slot]},
            available = available,
            waiting = false
        }
        context.Remote:FireClient(player, "Scorecard", payload)
    end

    return offer ~= nil
end

function BoutResults:Accept(player, result_epoch, style_id, map_id, ai_options)
    local context = self.context
    local offer = self.offers[player]
    if not offer or result_epoch ~= offer.epoch or (style_id ~= nil and (type(style_id) ~= "string" or not context.Styles[style_id])) or (not offer.opponent and not context.Styles[style_id]) or offer.ready[player] then
        return false
    end
    if map_id ~= nil and (type(map_id) ~= "string" or not context.Maps[map_id]) then
        return false
    end
    if context.Clock() >= offer.expires_at then
        self:Clear(player, "Expired"); return false
    end

    for _, participant in offer.players do
        if not context.IsReady(participant) or (offer.opponent and not context.PlayerData.IsReady(participant)) then
            self:Clear(player); return false
        end
    end

    offer.ready[player] = if offer.opponent then true else style_id
    for _, participant in offer.players do
        context.Remote:FireClient(participant, "Rematch", {epoch = offer.epoch, available = offer.ready[participant] == nil, waiting = offer.ready[participant] ~= nil})
    end

    for _, participant in offer.players do
        if not offer.ready[participant] then
            return true
        end
    end

    if offer.opponent then
        if not context.BeginSelection(offer.player, offer.opponent, offer) then
            self:Clear(player); return false
        end
        for _, participant in offer.players do
            self.offers[participant] = nil
        end
        return true
    end

    for _, participant in offer.players do
        local selected_style = offer.ready[participant]
        context.PlayerData.SetStyle(participant, selected_style)
        participant.Character:SetAttribute("FighterId", context.Styles[selected_style].FighterId)
    end

    if not context.StartBout(offer.player, offer.opponent, false, offer, map_id or "Arena", ai_options) then
        self:Clear(player); return false
    end
    for _, participant in offer.players do
        self.offers[participant] = nil
    end
    offer.slot = nil
    return true
end

function BoutResults:Update()
    local context = self.context
    for player, offer in self.offers do
        if context.PlayerData.IsClosing() or context.Clock() >= offer.expires_at or not context.IsReady(player) or (offer.opponent and not context.PlayerData.IsReady(player)) then
            self:Clear(player, "Unavailable")
        end
    end
end

return BoutResults
