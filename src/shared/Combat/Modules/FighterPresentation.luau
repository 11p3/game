export type AttributeValue = string | number | boolean | Vector3 | CFrame
export type Snapshot = {[string]: AttributeValue}
export type Connection = {Disconnect: (Connection) -> ()}

local FighterPresentation = {}
local records = setmetatable({}, {__mode = "k"})
local EMPTY = {}
local FIELDS = {
    PairedAnimationAgeFrames = true,
    PairedAnimationConfirmed = true,
    PairedRole = true,
    PairedAnimation = true,
    PairedRootOffset = true,
    PairedAnimationEventId = true,
    CombatMoveSpeed = true,
    CombatMoveVelocity = true,
    CombatMoveDirection = true,
    FighterId = true,
    CombatHealth = true,
    CombatMaxHealth = true,
    CombatStamina = true,
    CombatBlock = true,
    CombatMomentum = true,
    DodgeCooldown = true,
    KickCooldown = true,
    TechniqueCooldown = true,
    ClinchCooldown = true,
    GuardResponseCooldown = true,
    GetUpAgeFrames = true,
    GetUpDurationFrames = true,
    StunReason = true,
    StunEventId = true,
    StunRemainingFrames = true,
    ClinchFighterId = true,
    ClinchRole = true,
    ClinchEscapeUntil = true,
    ClinchEscapeProgress = true,
    ClinchEscapeStarted = true,
    ClinchEscapeLocked = true,
    KnockdownAgeFrames = true,
    CombatState = true,
    JabResult = true,
    AttackSpecial = true,
    AttackKind = true,
    AttackActiveFrames = true,
    JabStartupFrames = true,
    JabNextStartupFrames = true,
    AttackAgeFrames = true,
    AttackRecoveryFrames = true,
    DodgeAgeFrames = true,
    JabVariant = true,
    AttackStartedAt = true,
    PerfectWindowAt = true,
    PunchActiveAt = true,
    AttackReadyAt = true,
    AttackChainReadyAt = true,
    GuardOnlyUntil = true,
    Sidestepping = true,
    OpponentSide = true,
    Knockdowns = true,
    PresentationEventId = true,
    AttackEventId = true,
    JabSequence = true,
    LastHitFighterId = true,
    LastHitCounter = true,
    LastHitSpecial = true,
    LastHitTakedown = true,
    LastHitWallSplat = true,
    LastHitKind = true,
    LastHitMomentum = true,
    LastHitOpening = true,
    LastHitPerfect = true,
    LastHitCaught = true,
    LastHitBlocked = true,
    LastHitDodged = true,
    LastHitPresentationEventId = true,
    HitSerial = true,
    GetUpSerial = true,
    AppearanceReady = true
}
-- Write state before action serials so observers see one complete outcome.
local TRIGGERS = {FighterId = 1, CombatState = 1, JabSequence = 2, HitSerial = 2, GetUpSerial = 2}

local function Record(character)
    local record = records[character]
    if not record then
        local values = {}
        for name in FIELDS do
            values[name] = character:GetAttribute(name)
        end
        record = {values = values, pending = {}, watchers = {}}
        records[character] = record
    end
    return record
end

function FighterPresentation.Set(character, name: string, value: AttributeValue?)
    assert(FIELDS[name], "Unknown fighter presentation field: " .. name)
    Record(character).pending[name] = if value == nil then EMPTY else value
end

function FighterPresentation.Snapshot(character): Snapshot
    return table.freeze(table.clone(Record(character).values))
end

function FighterPresentation.Commit(character)
    local record = Record(character)
    local changed, writes = {}, {}
    for name, value in record.pending do
        local resolved = if value == EMPTY then nil else value
        if character:GetAttribute(name) ~= resolved then
            changed[name] = true
            table.insert(writes, name)
        end
        record.values[name] = resolved
    end
    local pending = record.pending
    record.pending = {}
    table.sort(writes, function(first, second)
        local first_order, second_order = TRIGGERS[first] or 0, TRIGGERS[second] or 0
        return if first_order == second_order then first < second else first_order < second_order
    end)
    for _, watcher in record.watchers do
        watcher.last_value = record.values[watcher.name]
    end
    for _, name in writes do character:SetAttribute(name, if pending[name] == EMPTY then nil else pending[name]) end
    if not next(changed) then
        return
    end
    local snapshot = FighterPresentation.Snapshot(character)
    local called = {}
    for _, watcher in table.clone(record.watchers) do
        if watcher.active and changed[watcher.name] and not called[watcher.callback] then
            called[watcher.callback] = true
            watcher.callback(snapshot)
        end
    end
end

function FighterPresentation.Observe(character, name: string, callback: (Snapshot) -> ()): Connection
    assert(FIELDS[name], "Unknown fighter presentation field: " .. name)
    local record = Record(character)
    local watcher = {name = name, callback = callback, active = true, last_value = character:GetAttribute(name)}
    table.insert(record.watchers, watcher)
    local connection = character:GetAttributeChangedSignal(name):Connect(function()
        local value = character:GetAttribute(name)
        if not watcher.active or value == watcher.last_value then
            return
        end
        watcher.last_value = value
        for field in FIELDS do
            record.values[field] = character:GetAttribute(field)
        end
        callback(FighterPresentation.Snapshot(character))
    end)
    return {Disconnect = function()
        if not watcher.active then
            return
        end
        watcher.active = false
        connection:Disconnect()
        local index = table.find(record.watchers, watcher)
        if index then
            table.remove(record.watchers, index)
        end
    end}
end

function FighterPresentation.Reaction(state: string, reason: string?, paired: boolean): string
    if state == "Knockdown" or state == "Knockout" then
        return "Knockdown"
    elseif state == "GettingUp" then
        return "GetUp"
    elseif state == "Stunned" then
        if reason == "Exhausted" then return "Stun" end
        if paired then return "Paired" end
        return if reason == "Takedown" then "Takedown" else "Stun"
    end

    return if paired then "Paired" else "None"
end

return FighterPresentation
