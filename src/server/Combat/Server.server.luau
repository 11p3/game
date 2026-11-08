local Players = game:GetService("Players")

-- Let combat prepare the avatar before a bout can use it.
Players.CharacterAutoLoads = false

local modules = script.Parent:WaitForChild("Modules")

-- Load persistence before matchmaking checks player readiness.
require(modules:WaitForChild("PlayerData")).Initialize()
require(modules:WaitForChild("Combat")).Initialize()
require(modules:WaitForChild("Crowd")).Initialize()
