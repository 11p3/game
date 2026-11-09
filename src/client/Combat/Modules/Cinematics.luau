local Cinematics = {TimeScale = 1, PERFECT_HOLD = 1}
local Audio = require(script.Parent.Audio)
local perfect_event_id
local perfect_sound
local perfect_started_at = -math.huge
local perfect_color
local PERFECT_HOLD = Cinematics.PERFECT_HOLD
local PERFECT_FADE = 0.25
local PERFECT_SPEED = 0.2 -- Slow visual playback to one-fifth speed without changing combat timers.
local FADE_SECONDS = 0.3
local BLACK_HOLD = 0.12 -- Keep a short fully black beat before revealing the next screen.
local RESULT_TIMEOUT = 3 -- Avoid trapping the player on black if a result packet never arrives.
local fade_frame
local fade_player
local fade_folder
local transition
local revealed_epoch = -1
local bout_epoch = -1

function Cinematics.BeginEnd(epoch)
    if type(epoch) ~= "number" or epoch < bout_epoch or epoch <= revealed_epoch or (transition and epoch < transition.epoch) then
        return false
    end
    if transition and transition.epoch == epoch then
        return true
    end
    transition = {epoch = epoch, stage = "Out", elapsed = 0, lobby = false, expects_result = false, result_ready = false, black_callbacks = {}}
    fade_frame.BackgroundTransparency = 1
    fade_frame.Visible = true
    fade_folder:SetAttribute("FightTransition", "Out")
    return true
end

function Cinematics.AtBlack(epoch, callback)
    if type(epoch) ~= "number" or epoch < bout_epoch then
        return false
    end
    if not Cinematics.BeginEnd(epoch) or transition.stage ~= "Out" then
        callback()
    else
        table.insert(transition.black_callbacks, callback)
    end
    return true
end

function Cinematics.CloseBout(epoch, expects_result, callback)
    if not Cinematics.BeginEnd(epoch) then
        if callback and epoch >= bout_epoch then
            callback()
        end
        return
    end
    transition.lobby = true
    transition.expects_result = expects_result == true
    if callback then
        Cinematics.AtBlack(epoch, callback)
    end
end

function Cinematics.ShowScorecard(epoch, callback)
    if type(epoch) ~= "number" or epoch < bout_epoch then
        return
    end
    if not Cinematics.BeginEnd(epoch) or transition.stage == "In" then
        -- A late result can appear once the black-screen handoff has finished.
        callback()
        return
    end
    transition.callback = callback
end

function Cinematics.BeginBout(epoch)
    bout_epoch = math.max(bout_epoch, epoch)
    if transition and epoch > transition.epoch then
        revealed_epoch = math.max(revealed_epoch, transition.epoch)
        transition = nil
        fade_folder:SetAttribute("FightTransition", nil)
        fade_frame.Visible = false
        fade_frame.BackgroundTransparency = 1
    end
end

local function UpdateFade(delta_time)
    local current = transition
    if not current then
        return
    end
    current.elapsed += math.clamp(delta_time, 0, 0.1)

    if current.stage == "Out" then
        local progress = math.clamp(current.elapsed / FADE_SECONDS, 0, 1)
        fade_frame.BackgroundTransparency = 1 - progress * progress * (3 - 2 * progress)
        if progress >= 1 then
            current.stage = "Hold"
            current.elapsed = 0
            fade_folder:SetAttribute("FightTransition", "Black")
        end
    elseif current.stage == "In" then
        local progress = math.clamp(current.elapsed / FADE_SECONDS, 0, 1)
        fade_frame.BackgroundTransparency = progress * progress * (3 - 2 * progress)
        if progress >= 1 then
            fade_frame.Visible = false
            revealed_epoch = math.max(revealed_epoch, current.epoch)
            transition = nil
            fade_folder:SetAttribute("FightTransition", nil)
        end
        return
    end

    if current.stage == "Hold" then
        local callbacks = current.black_callbacks
        current.black_callbacks = {}
        for _, callback in callbacks do
            callback()
            if transition ~= current then
                return
            end
        end

        if current.callback then
            local callback = current.callback
            current.callback = nil
            current.result_ready = true
            callback()
            if transition ~= current then
                return
            end
        end
        if current.lobby and current.elapsed >= BLACK_HOLD and fade_player:GetAttribute("MatchStatus") ~= "Fighting" and (not current.expects_result or current.result_ready or current.elapsed >= RESULT_TIMEOUT) then
            current.stage = "In"
            current.elapsed = 0
            fade_folder:SetAttribute("FightTransition", "In")
        end
    end
end

function Cinematics.PlayPerfect(event_id)
    perfect_event_id = event_id
    Cinematics.PerfectEventId = event_id
    perfect_started_at = os.clock()
    perfect_color.Enabled = true
    perfect_sound = Audio.Play("PerfectDodge", 0.65, 1, event_id) or perfect_sound
end

function Cinematics.Initialize()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local Lighting = game:GetService("Lighting")
    local player = Players.LocalPlayer
    fade_player = player
    fade_folder = script.Parent.Parent
    fade_folder:SetAttribute("FightTransition", nil)
    fade_frame = player:WaitForChild("PlayerGui"):WaitForChild("FightTransition"):WaitForChild("Fade")
    fade_frame.Visible = false
    fade_frame.BackgroundTransparency = 1
    local arena = workspace:WaitForChild("Combat"):WaitForChild("Arena")
    local rollback_effects = script.Parent.Parent:WaitForChild("RollbackEffects")
    perfect_color = Instance.new("ColorCorrectionEffect")
    perfect_color.Name = "PerfectDodge"
    perfect_color.Enabled = false
    perfect_color.Parent = Lighting

    RunService.RenderStepped:Connect(function(delta_time)
        UpdateFade(delta_time)
        local elapsed = os.clock() - perfect_started_at
        local phase = arena:GetAttribute("MatchState")

        if phase ~= "Fighting" or elapsed >= PERFECT_HOLD + PERFECT_FADE then
            if perfect_color.Enabled or Cinematics.TimeScale ~= 1 then
                Cinematics.TimeScale = 1
                perfect_color.Saturation = 0
                perfect_color.Contrast = 0
                perfect_color.Brightness = 0
                perfect_color.Enabled = false
            end

            return
        end

        local fade = math.clamp((elapsed - PERFECT_HOLD) / PERFECT_FADE, 0, 1)
        local weight = 1 - fade * fade * (3 - 2 * fade)

        Cinematics.TimeScale = 1 - (1 - PERFECT_SPEED) * weight
        perfect_color.Saturation = -weight
        perfect_color.Contrast = 0.12 * weight
        perfect_color.Brightness = -0.03 * weight
    end)

    player.CharacterAdded:Connect(function()
        perfect_started_at = -math.huge
    end)

    rollback_effects.Event:Connect(function(valid)
        if perfect_event_id and not valid[perfect_event_id] then
            perfect_started_at = -math.huge
            Cinematics.TimeScale = 1
            perfect_color.Enabled = false
            if perfect_sound and perfect_sound.Parent then
                perfect_sound:Stop(); perfect_sound:Destroy()
            end
            perfect_sound = nil
        end
    end)
end

return Cinematics
