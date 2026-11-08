local Players = game:GetService("Players")

Players.CharacterAutoLoads = false

local modules = script.Parent:WaitForChild("Modules")

require(modules:WaitForChild("PlayerData")).Initialize()
require(modules:WaitForChild("Combat")).Initialize()
require(modules:WaitForChild("Crowd")).Initialize()
