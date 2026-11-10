local Players = game:GetService("Players")

Players.CharacterAutoLoads = false

local modules = script.Parent:WaitForChild("Modules")

-- Load persistence before matchmaking checks player readiness.
require(modules:WaitForChild("PlayerData")).Initialize()
require(modules:WaitForChild("Combat")).Initialize()
require(modules:WaitForChild("Crowd")).Initialize()
