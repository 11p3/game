local MoveGuide = {}
local Styles = require(game:GetService("ReplicatedStorage").Combat.Modules.Styles)
local Moves = require(game:GetService("ReplicatedStorage").Combat.Modules.MoveDefinitions)
local folder
local panel

function MoveGuide.Initialize(style_panel)
    folder = script.Parent.Parent
    panel = style_panel:WaitForChild("MoveGuide")
    panel.Close.Activated:Connect(function() MoveGuide.Close() end)
end

function MoveGuide.Open(style_id)
    local style = Styles[style_id]
    if not style then
        return
    end
    panel.Title.Text = string.upper(style.Name) .. " · MOVES"
    for _, row in panel.List:GetChildren() do if row:IsA("Frame") then row:Destroy() end end

    local side = folder:GetAttribute("CameraMode") == "Side"
    local keys = folder:GetAttribute("MovementKeys") or "Camera"
    local movement = if keys == "WS" or (keys == "Camera" and not side) then "W/S: approach / retreat. A/D: circle." elseif side then "A/D: screen left / right. W/S: screen up / down." else "D/A: approach / retreat. W/S: circle."
    local common = {
        {Key = "W A S D", Name = "Footwork", Description = movement, Use = "Keep moving to control range. Attacks and hit reactions briefly lock movement."},
        {
            Key = "F · hold",
            Name = "Guard",
            Description = "Block attacks coming from your front. Blocking spends your block meter; a broken guard stuns you.",
            Use = "Hold F before a strike connects. Release it and avoid pressure to recover your block meter."
        },
        {
            Key = "E · tap",
            Name = "Dodge / perfect dodge",
            Description = "Slip a strike. A fresh dodge during the bright red cue stuns the attacker.",
            Use = "Tap just before impact while in range. Early dodges can avoid damage but do not earn a perfect dodge."
        },
        {
            Key = "V",
            Name = "Clinch",
            Move = "ClinchGrab",
            Description = "Grab a nearby opponent, including through guard. Holding a clinch drains stamina.",
            Use = "Press V at close range. Once controlling, use your clinch attack or press E/V to release."
        },
        {
            Key = "M1 / E / V · mash",
            Name = "Escape a clinch",
            Description = "Repeated taps fill the escape bar; progress falls when you stop.",
            Use = "When held, wait through the initial half-second lock, then click or tap E/V repeatedly. Holding a button does not count as repeated taps."
        },
    }
    local entries = table.clone(style.MoveGuide)
    for _, entry in common do
        table.insert(entries, entry)
    end

    for index, entry in entries do
        local row = panel.RowTemplate:Clone()
        row.Name, row.LayoutOrder, row.Visible = "Move_" .. index, index, true
        row.Key.Text = entry.Key
        row.NameLabel.Text = entry.Name
        row.Description.Text = entry.Description
        row.HowTo.Text = entry.Use
        -- Read displayed costs from combat rules so the guide cannot drift from balance data.
        local move = entry.Move and Moves.Get(style.FighterId, entry.Move)
        local stamina = if move and move.chain_stamina then tostring(move.chain_stamina[1]) .. "–" .. tostring(move.chain_stamina[#move.chain_stamina]) elseif move then tostring(move.stamina) else ""
        row.Cost.Text = if move then stamina .. " STA" .. (if move.momentum then " · " .. move.momentum .. " MOM" else "") else ""
        row.Parent = panel.List
    end
    panel.List.CanvasPosition = Vector2.zero
    panel.Visible = true
end

function MoveGuide.Close()
    if panel then
        panel.Visible = false
    end
end

return MoveGuide
