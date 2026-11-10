local FighterPresentation = require(game.ReplicatedStorage.Combat.Modules.FighterPresentation)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatSimulation = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("Modules"):WaitForChild("CombatSimulation"))

local MoveDefinitions = require(ReplicatedStorage.Combat.Modules.MoveDefinitions)

local Hitboxes = require(script.Parent.Hitboxes)
local Presentation = {}
local SIMULATION_HZ = 60
local COOLDOWN_TICK_FRAMES = 6 -- Refresh tenths-of-a-second labels at 10 Hz instead of every render.
local COOLDOWN_FIELDS = {DodgeCooldown = "dodge", KickCooldown = "kick", TechniqueCooldown = "technique", ClinchCooldown = "clinch", GuardResponseCooldown = "guard_response"}
local MAX_CORRECTION_DISTANCE = 8 -- Snap large corrections instead of visibly sliding across the ring.
local MOVEMENT_THRESHOLD = 0.1
local BACKPEDAL_DOT_RATIO = 0.15
local MAX_EFFECT_AGE_FRAMES = 30 -- Skip stale half-second-old effects when catching up.
local EVENT_HISTORY_FRAMES = 120
local player
local arena
local folder
local combat_effects
local rollback_effects
local active_epoch
local reset_frame = -1
local seen = {}
local jab_counts = {0, 0}
local hit_counts = {0, 0}
local getup_counts = {0, 0}
local last_rollback_count = 0
local last_received_frame = -1
local played_events = 0
local start_pending = false
local rendered = {}
local concealed = {}
local render_frame = -1
local render_rollbacks = 0
local start_key
local training_reset = 0
local visibility_dirty = true
local visibility_players = {}
local visibility_listeners = {}
local visibility_one
local visibility_two
local cached_events = {}
local cached_event_keys = {}
local events_frame = -1
local events_rollbacks = -1
local events_received_frame = -1
local events_received
local events_state

local function EventKey(epoch, event)
    local key = tostring(epoch) .. ":" .. event.id

    if event.kind == "Attack" then
        key ..= ":" .. tostring(event.attack_kind or "Jab") .. ":" .. tostring(event.variant or 0)
    elseif event.kind == "Capture" then
        key ..= ":" .. tostring(event.attack_kind or "") .. ":" .. tostring(event.target or 0) .. ":" .. tostring(event.fighter_id or "")
    elseif event.kind == "Contact" then
        local contact = event.contact

        key ..= ":" .. tostring(contact.fighter_id or "") .. ":" .. tostring(contact.attacker or event.attacker) .. ":" .. tostring(contact.target or event.target) .. ":" .. tostring(contact.kind or "Jab") .. ":" .. tostring(contact.special == true) .. ":" .. tostring(contact.counter == true) .. ":" .. tostring(contact.opening == true)
        key ..= ":" .. tostring(contact.blocked == true) .. ":" .. tostring(contact.dodged == true) .. ":" .. tostring(contact.perfect == true) .. ":" .. tostring(contact.momentum == true) .. ":" .. tostring(contact.wall_splat == true) .. ":" .. tostring(contact.caught == true)
    end

    return key
end

local function RestoreCharacter(character)
    local record = concealed[character]
    if not record then
        return
    end

    record.connection:Disconnect()
    if record.destroy_connection then record.destroy_connection:Disconnect() end

    if record.humanoid and record.humanoid.Parent then
        record.humanoid.DisplayDistanceType = record.display_type
    end

    for part, transparency in record.parts do
        if part.Parent then
            part.LocalTransparencyModifier = transparency
        end
    end

    concealed[character] = nil
end

function Presentation.Initialize()
    player = Players.LocalPlayer
    arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    folder = script.Parent.Parent
    combat_effects = folder:WaitForChild("CombatEffects")
    rollback_effects = folder:WaitForChild("RollbackEffects")
    folder:GetAttributeChangedSignal("ShowHitboxes"):Connect(function()
        if not folder:GetAttribute("ShowHitboxes") then Hitboxes.Clear() end
    end)

    local function WatchPlayer(viewer)
        visibility_players[viewer] = true
        visibility_dirty = true
        visibility_listeners[viewer] = {
            viewer.CharacterAdded:Connect(function() visibility_dirty = true end),
            viewer.CharacterRemoving:Connect(function(character)
                RestoreCharacter(character)
                visibility_dirty = true
            end)
        }
    end
    Players.PlayerAdded:Connect(WatchPlayer)
    Players.PlayerRemoving:Connect(function(viewer)
        if viewer.Character then RestoreCharacter(viewer.Character) end
        for _, connection in visibility_listeners[viewer] or {} do connection:Disconnect() end
        visibility_listeners[viewer] = nil
        visibility_players[viewer] = nil
        visibility_dirty = true
    end)
    for _, viewer in Players:GetPlayers() do WatchPlayer(viewer) end
end

function Presentation.Reset(epoch, state, silent)
    Hitboxes.Clear()
    for character in concealed do
        RestoreCharacter(character)
    end

    visibility_dirty = true
    cached_events = {}
    events_frame = -1
    events_state = nil
    active_epoch = epoch
    reset_frame = (if state then state.frame else 0) - 1
    seen = {}
    jab_counts = {0, 0}
    hit_counts = {0, 0}
    getup_counts = {0, 0}
    last_rollback_count = 0
    last_received_frame = -1
    played_events = 0
    start_pending = not silent
    training_reset = if state and state.training then state.training.reset_serial else 0
    start_key = nil
    rendered = {}
    render_frame = -1
    render_rollbacks = 0
    folder:SetAttribute("PresentationEvents", 0)
    rollback_effects:Fire({})
end

function Presentation.Apply(session, epoch, delta_time)
    local state = session.state

    if active_epoch ~= epoch then
        Presentation.Reset(epoch, state)
    elseif state.training and state.training.reset_serial ~= training_reset then
        Presentation.Reset(epoch, state, true)
    end

    debug.profilebegin("Combat.Presentation")

    local correction_changed = session.rollback_count ~= render_rollbacks
    local corrected = session.history[render_frame]
    -- Remove about 95% of a visual correction in 0.17 seconds, regardless of FPS.
    local decay = math.exp(-18 * math.clamp(delta_time or 1 / SIMULATION_HZ, 0, 0.1))
    local turn_alpha = 1 - math.exp(-(session.config.turn_response or 14) * math.clamp(delta_time or 1 / SIMULATION_HZ, 0, 0.1))
    local now = workspace:GetServerTimeNow()
    local first = if session.config.player_one and session.config.player_one ~= 0 then Players:GetPlayerByUserId(session.config.player_one) else nil
    local second = Players:GetPlayerByUserId(session.config.player_two or player.UserId)
    local arenas = workspace.Combat:FindFirstChild("Arenas")
    local active = arenas and arenas:FindFirstChild(folder:GetAttribute("ArenaId") or "")
    local characters = {if first then first.Character else active and active:FindFirstChild("NPC"), second and second.Character}
    local paired_keys = {}

    if visibility_dirty or visibility_one ~= session.config.player_one or visibility_two ~= session.config.player_two then
        visibility_dirty = false
        visibility_one, visibility_two = session.config.player_one, session.config.player_two
        for viewer in visibility_players do
            local character = viewer.Character
            local participant = viewer.UserId == session.config.player_one or viewer.UserId == session.config.player_two

            if character and not participant and not concealed[character] then
                local humanoid = character:FindFirstChildOfClass("Humanoid")
                local record = {parts = {}, humanoid = humanoid, display_type = humanoid and humanoid.DisplayDistanceType}

                if humanoid then
                    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                end

                local function HidePart(part)
                    if part:IsA("Humanoid") and part ~= record.humanoid then
                        record.humanoid = part
                        record.display_type = part.DisplayDistanceType
                        part.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                    elseif part:IsA("BasePart") then
                        record.parts[part] = part.LocalTransparencyModifier
                        part.LocalTransparencyModifier = 1
                    end
                end

                record.connection = character.DescendantAdded:Connect(HidePart)
                record.destroy_connection = character.Destroying:Connect(function() RestoreCharacter(character) end)
                concealed[character] = record

                for _, part in character:GetDescendants() do
                    HidePart(part)
                end
            elseif character and participant and concealed[character] then
                RestoreCharacter(character)
            end
        end

        for character in concealed do
            if not character.Parent then
                RestoreCharacter(character)
            end
        end


    end

    for index = 1, 2 do
        local character = characters[index]
        local fighter = state.fighters[index]

        if not character then
            rendered[index] = nil
        end

        if character then
            local root = character:FindFirstChild("HumanoidRootPart")

            if root then
                local position = Vector3.new(fighter.x, fighter.y, fighter.z)
                local previous = rendered[index]

                if not previous or previous.root ~= root then
                    previous = {root = root, position = position, display_yaw = fighter.yaw, offset = Vector3.zero}
                    rendered[index] = previous
                elseif correction_changed and corrected then
                    local prior = corrected.fighters[index]

                    previous.offset += previous.position - Vector3.new(prior.x, prior.y, prior.z)
                end

                if previous.offset.Magnitude > MAX_CORRECTION_DISTANCE then
                    previous.offset = Vector3.zero
                end
                previous.offset *= decay
                previous.display_position = position + previous.offset
                previous.position = position
            else
                rendered[index] = nil
            end

            local attack_age = if fighter.attack_started then fighter.frame - fighter.attack_started - (fighter.attack_stage_offset or 0) else -1
            local started_at = if attack_age >= 0 then now - attack_age / SIMULATION_HZ else 0
            local chained = fighter.attack_result == "Hit" and fighter.frame <= fighter.chain_until
            local profile = MoveDefinitions[fighter.fighter_id] or MoveDefinitions.Boxing
            local jab_startups = profile.moves[profile.inputs.jab].timeline.startup
            local prior_state = session.history[state.frame - 1]
            local prior_fighter = prior_state and prior_state.fighters[index]
            local velocity = if prior_fighter then Vector3.new(fighter.x - prior_fighter.x, 0, fighter.z - prior_fighter.z) * SIMULATION_HZ else Vector3.zero
            local forward = Vector3.new(-math.sin(fighter.yaw), 0, -math.cos(fighter.yaw))

            if rendered[index] then
                rendered[index].moving = velocity.Magnitude > MOVEMENT_THRESHOLD
            end

            local paired = fighter.paired_action
            local paired_role = if paired then "Victim" else ""

            if not paired then
                local other = state.fighters[fighter.target]
                if other.paired_action and other.paired_action.attacker == index then
                    paired = other.paired_action; paired_role = "Attacker"
                end
            end

            local paired_active = paired and (state.frame < paired.until_frame or (paired.confirmed and state.phase ~= "Fighting"))
            local paired_key = if paired_active then tostring(epoch) .. ":Paired:" .. paired.started .. ":" .. paired.attacker .. ":" .. paired.kind else ""

            if paired_key ~= "" then
                paired_keys[paired_key] = true
            end

            FighterPresentation.Set(character, "PairedAnimationAgeFrames", if paired_active then state.frame - paired.started else -1)
            FighterPresentation.Set(character, "PairedAnimationConfirmed", paired_active and paired.confirmed == true)
            FighterPresentation.Set(character, "PairedRole", if paired_active then paired_role else "")
            FighterPresentation.Set(character, "PairedAnimation", if paired_active and paired_role == "Victim" then paired.animation else "")
            FighterPresentation.Set(character, "PairedRootOffset", if paired_active and paired_role == "Victim" then Vector3.new(paired.origin_x - fighter.x, 0, paired.origin_z - fighter.z) else Vector3.zero)
            FighterPresentation.Set(character, "PairedAnimationEventId", paired_key)

            FighterPresentation.Set(character, "CombatMoveSpeed", velocity.Magnitude)
            FighterPresentation.Set(character, "CombatMoveVelocity", velocity)
            FighterPresentation.Set(character, "CombatMoveDirection", if velocity:Dot(forward) < -velocity.Magnitude * BACKPEDAL_DOT_RATIO then -1 else 1)
            FighterPresentation.Set(character, "FighterId", fighter.fighter_id)
            FighterPresentation.Set(character, "CombatHealth", fighter.health)
            FighterPresentation.Set(character, "CombatMaxHealth", 100)
            for field, action in COOLDOWN_FIELDS do
                local kind = if action == "clinch" then "ClinchGrab" else profile.inputs[action]
                local move = kind and profile.moves[kind]
                local ready = if action == "dodge" then fighter.dodge_ready elseif action == "guard_response" then fighter.guard_response_ready else move and move.cooldown_key and fighter[move.cooldown_key] or 0
                FighterPresentation.Set(character, field, math.ceil(math.max(0, ready - fighter.frame) / COOLDOWN_TICK_FRAMES) * COOLDOWN_TICK_FRAMES / SIMULATION_HZ)
            end
            FighterPresentation.Set(character, "CombatStamina", math.floor(fighter.stamina + 0.5))
            FighterPresentation.Set(character, "CombatBlock", math.floor(fighter.block_meter + 0.5))
            FighterPresentation.Set(character, "CombatMomentum", fighter.momentum)
            FighterPresentation.Set(character, "GetUpAgeFrames", if state.frame < (fighter.getup_until or 0) then state.frame - fighter.getup_started else -1)
            FighterPresentation.Set(character, "GetUpDurationFrames", CombatSimulation.GetUpFrames)
            FighterPresentation.Set(character, "StunReason", fighter.stun_reason)
            FighterPresentation.Set(character, "StunEventId", if fighter.state == "Stunned" then tostring(epoch) .. ":" .. tostring(state.frame + fighter.stun_until - fighter.frame) .. ":Stun:" .. tostring(index) else "")
            FighterPresentation.Set(character, "StunRemainingFrames", math.max(0, fighter.stun_until - fighter.frame))
            local clinch_holder = state.fighters[fighter.clinch_holder or 0]
            FighterPresentation.Set(character, "ClinchFighterId", if clinch_holder then clinch_holder.fighter_id else "")
            FighterPresentation.Set(character, "ClinchRole", if (fighter.clinch_holder or 0) == 0 then "" elseif fighter.clinch_holder == index then "Control" else "Held")
            FighterPresentation.Set(character, "ClinchEscapeUntil", fighter.clinch_escape_until or 0)
            FighterPresentation.Set(character, "ClinchEscapeProgress", CombatSimulation.Pairing.EscapeProgress(state.fighters, index))
            FighterPresentation.Set(character, "ClinchEscapeStarted", fighter.clinch_escape_started == true)
            FighterPresentation.Set(character, "ClinchEscapeLocked", fighter.frame < (fighter.clinch_escape_ready or 0))
            local down_age = if state.phase == "Knockdown" and (state.downed == index or state.double_down) then state.frame - state.knockdown_started elseif state.phase == "Finished" and fighter.health <= 0 then state.frame - state.finished_frame else -1
            FighterPresentation.Set(character, "KnockdownAgeFrames", down_age)
            FighterPresentation.Set(character, "CombatState", fighter.state)
            FighterPresentation.Set(character, "JabResult", fighter.attack_result)
            FighterPresentation.Set(character, "AttackSpecial", fighter.attack_special == true)
            FighterPresentation.Set(character, "AttackKind", fighter.attack_kind)
            FighterPresentation.Set(character, "AttackActiveFrames", fighter.attack_hit_active or fighter.attack_active)
            FighterPresentation.Set(character, "JabStartupFrames", fighter.attack_stage_startup or fighter.attack_startup)
            FighterPresentation.Set(character, "JabNextStartupFrames", jab_startups[if chained then math.min(fighter.chain_count + 1, #jab_startups) else 1])
            FighterPresentation.Set(character, "AttackAgeFrames", attack_age)
            FighterPresentation.Set(character, "AttackRecoveryFrames", fighter.attack_recovery)
            FighterPresentation.Set(character, "DodgeAgeFrames", if fighter.dodge_started then fighter.frame - fighter.dodge_started else -1)
            FighterPresentation.Set(character, "JabVariant", fighter.jab_sequence)
            FighterPresentation.Set(character, "AttackStartedAt", started_at)
            FighterPresentation.Set(character, "PerfectWindowAt", if attack_age >= 0 then started_at + ((fighter.attack_stage_startup or fighter.attack_startup) - fighter.attack_perfect_frames) / SIMULATION_HZ else 0)
            FighterPresentation.Set(character, "PunchActiveAt", if attack_age >= 0 then started_at + (fighter.attack_stage_startup or fighter.attack_startup) / SIMULATION_HZ else 0)
            FighterPresentation.Set(character, "AttackReadyAt", if attack_age >= 0 then started_at + (fighter.attack_startup + fighter.attack_active + fighter.attack_recovery) / SIMULATION_HZ else 0)
            FighterPresentation.Set(character, "AttackChainReadyAt", if attack_age >= 0 then started_at + (fighter.attack_startup + CombatSimulation.JabActiveFrames + CombatSimulation.HitChainRecovery) / SIMULATION_HZ else 0)
            FighterPresentation.Set(character, "GuardOnlyUntil", if fighter.reaction_until > fighter.frame then now + (fighter.reaction_until - fighter.frame) / SIMULATION_HZ else 0)
            FighterPresentation.Set(character, "Knockdowns", fighter.knockdowns)
        end
    end

    for index, fighter in state.fighters do
        local visual = rendered[index]
        local other = rendered[fighter.target]

        if visual and visual.root.Parent then
            local moving = visual.moving or (other and other.moving)
            local target_yaw = visual.facing_target or fighter.yaw

            if fighter.state == "Knockdown" or fighter.state == "BoutOver" or (state.frame < (fighter.throw_facing_until or 0) or state.frame < (fighter.getup_until or 0)) then
                target_yaw = fighter.yaw
            elseif other and (moving or visual.was_moving or not visual.facing_target) then
                local opponent = state.fighters[fighter.target]
                local separation = if moving then visual.display_position - other.display_position else Vector3.new(fighter.x - opponent.x, 0, fighter.z - opponent.z)

                if separation.X * separation.X + separation.Z * separation.Z > 0.01 then
                    target_yaw = math.atan2(separation.X, separation.Z)
                end
            end

            visual.facing_target = target_yaw
            visual.was_moving = moving == true

            local difference = (target_yaw - visual.display_yaw + math.pi) % (math.pi * 2) - math.pi

            if math.abs(difference) > math.rad(0.3) then
                visual.display_yaw = (visual.display_yaw + difference * turn_alpha + math.pi) % (math.pi * 2) - math.pi
            end

            visual.root.CFrame = CFrame.new(visual.display_position) * CFrame.Angles(0, visual.display_yaw, 0)
        end
    end

    render_frame = state.frame
    render_rollbacks = session.rollback_count

    local result = state.result

    if folder:GetAttribute("FighterSlot") == 1 then
        if state.phase == "Finished" and result ~= "Draw" and result ~= "" then
            result = (if state.downed == 1 then "You lose — " else "You win — ") .. (if state.finish_reason and state.finish_reason ~= "" then state.finish_reason else "TKO")
        end
    end

    folder:SetAttribute("TrainingActive", state.training ~= nil)
    if state.training then
        folder:SetAttribute("TrainingMode", state.training.mode)
        folder:SetAttribute("TrainingRecording", state.training.recording)
        folder:SetAttribute("TrainingFrames", #state.training.sequence)
        folder:SetAttribute("TrainingPlayhead", state.training.playhead)
        folder:SetAttribute("TrainingDummyStyle", state.training.dummy_style)
        folder:SetAttribute("TrainingInfiniteHealth", state.training.infinite_health)
        folder:SetAttribute("TrainingInfiniteStamina", state.training.infinite_stamina)
        folder:SetAttribute("TrainingInfiniteBlock", state.training.infinite_block)
        folder:SetAttribute("TrainingInfiniteMomentum", state.training.infinite_momentum)
    end

    arena:SetAttribute("TimeRemainingFrames", math.max(0, (state.duration_frames or 0) - (state.fight_frames or 0)))
    arena:SetAttribute("TimeLimitFrames", state.duration_frames or 0)
    arena:SetAttribute("Result", result)

    local downed_character = characters[state.downed]

    arena:SetAttribute("DownedFighter", if state.double_down then "Both fighters" elseif state.downed == 0 then "" elseif state.downed == (folder:GetAttribute("FighterSlot") or 2) then "You" elseif downed_character then downed_character.Name else "Opponent")
    arena:SetAttribute("GetUpCount", if state.knockdown_duration > 0 then state.knockdown_duration / SIMULATION_HZ else 3)
    arena:SetAttribute("Count", state.count)
    arena:SetAttribute("MatchState", state.phase)
    folder:SetAttribute("ActiveRollbackFrame", state.frame)

    -- Commit all fighter fields before action observers react to changed serials.
    for _, character in characters do if character then FighterPresentation.Commit(character) end end

    local valid_keys = table.clone(paired_keys)

    if start_pending then
        start_pending = false

        if state.phase == "Fighting" then
            start_key = tostring(epoch) .. ":Start:" .. tostring(state.frame)
            played_events += 1
            combat_effects:Fire({id = "Start:" .. tostring(state.frame), key = start_key, epoch = epoch, frame = state.frame, kind = "Start", fighter = 0})
        end
    end

    if start_key then
        valid_keys[start_key] = true
    end

    local oldest = math.max(0, state.frame - EVENT_HISTORY_FRAMES)
    local received_frame = if type(session.received_frame) == "number" and type(session.received_events) == "table" then session.received_frame else -1
    if events_frame ~= state.frame or events_rollbacks ~= session.rollback_count or events_received_frame ~= received_frame or events_received ~= session.received_events or events_state ~= state then
        local events = {}

        if received_frame >= 0 then
            for _, event in session.received_events do
                if event.frame >= oldest and event.frame <= received_frame and event.frame <= state.frame then
                    table.insert(events, event)
                end
            end
        end

        for frame = math.max(oldest, received_frame + 1), state.frame do
            local saved = session.history[frame]

            if saved then
                for _, event in saved.events do
                    table.insert(events, event)
                end
            end
        end

        table.sort(events, function(a, b)
            if a.frame == b.frame then
                return a.id < b.id
            end

            return a.frame < b.frame
        end)

        cached_event_keys = {}
        for index, event in events do cached_event_keys[index] = EventKey(epoch, event) end
        cached_events = events
        events_frame, events_rollbacks, events_received_frame = state.frame, session.rollback_count, received_frame
        events_received, events_state = session.received_events, state
    end
    local events = cached_events

    for event_index, event in events do
        local key = cached_event_keys[event_index]

        valid_keys[key] = true

        if not seen[key] and event.frame > reset_frame and state.frame - event.frame <= MAX_EFFECT_AGE_FRAMES then
            local index = if event.kind == "Contact" then event.target else event.fighter
            local character = characters[index]
            local requires_character = event.kind == "Attack" or event.kind == "Contact" or event.kind == "GetUp"

            if not requires_character or character then
                seen[key] = event.frame
                played_events += 1

                if event.kind == "Attack" then
                    local fighter = state.fighters[index]

                    if fighter.attack_id == event.frame and fighter.attack_started then
                        jab_counts[index] = math.max(jab_counts[index], character:GetAttribute("JabSequence") or 0) + 1
                        FighterPresentation.Set(character, "PresentationEventId", key)
                        FighterPresentation.Set(character, "AttackEventId", key)
                        FighterPresentation.Set(character, "JabSequence", jab_counts[index])
                        FighterPresentation.Commit(character)
                    end
                elseif event.kind == "Contact" then
                    local contact = event.contact

                    FighterPresentation.Set(character, "LastHitFighterId", contact.fighter_id or (state.fighters[contact.attacker or event.attacker] and state.fighters[contact.attacker or event.attacker].fighter_id) or "Boxing")
                    FighterPresentation.Set(character, "LastHitCounter", contact.counter == true)
                    FighterPresentation.Set(character, "LastHitSpecial", contact.special == true)
                    FighterPresentation.Set(character, "LastHitTakedown", contact.takedown == true and not contact.wall_splat)
                    FighterPresentation.Set(character, "LastHitWallSplat", contact.wall_splat == true)
                FighterPresentation.Set(character, "LastHitKind", contact.kind or "Jab")
                    FighterPresentation.Set(character, "LastHitMomentum", contact.momentum == true)
                    FighterPresentation.Set(character, "LastHitOpening", contact.opening == true)
                    FighterPresentation.Set(character, "LastHitCaught", contact.caught == true)
                    FighterPresentation.Set(character, "LastHitPerfect", contact.perfect == true)
                    FighterPresentation.Set(character, "LastHitBlocked", contact.blocked == true)
                    FighterPresentation.Set(character, "LastHitDodged", contact.dodged == true)
                    FighterPresentation.Set(character, "PresentationEventId", key)
                    FighterPresentation.Set(character, "LastHitPresentationEventId", key)
                    hit_counts[index] = math.max(hit_counts[index], character:GetAttribute("HitSerial") or 0) + 1
                    FighterPresentation.Set(character, "HitSerial", hit_counts[index])
                    FighterPresentation.Commit(character)
                elseif event.kind == "GetUp" then
                    FighterPresentation.Set(character, "PresentationEventId", key)
                    getup_counts[index] = math.max(getup_counts[index], character:GetAttribute("GetUpSerial") or 0) + 1
                    FighterPresentation.Set(character, "GetUpSerial", getup_counts[index])
                    FighterPresentation.Commit(character)

                    local payload = table.clone(event)

                    payload.key = key
                    payload.epoch = epoch
                    combat_effects:Fire(payload)
                else
                    local payload = table.clone(event)

                    payload.key = key
                    payload.epoch = epoch
                    combat_effects:Fire(payload)
                end
            end
        end
    end

    for key, frame in seen do
        if frame < oldest or ((session.rollback_count ~= last_rollback_count or received_frame ~= last_received_frame) and not valid_keys[key]) then
            seen[key] = nil
        end
    end

    folder:SetAttribute("PresentationEvents", played_events)

    if session.rollback_count ~= last_rollback_count or received_frame ~= last_received_frame then
        last_rollback_count = session.rollback_count
        last_received_frame = received_frame
        rollback_effects:Fire(valid_keys)
    end

    Hitboxes.Apply(state, folder:GetAttribute("ShowHitboxes") == true, session.rollback_count)
    debug.profileend()
end

return Presentation
