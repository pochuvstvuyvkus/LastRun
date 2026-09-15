-- Точка входа клиента
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
Net.Get("Notify")

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
end)

local C = {
	State = { Inventory = {}, WeaponOrder = {}, WeaponLevels = {} },
	Player = Players.LocalPlayer,
}

local order = { "SoundFX", "UI", "Effects", "Footsteps", "CharAnimator", "ZombieAnim", "HUD", "Panels", "ProgressUI", "ObjectivesUI", "EventsUI", "WorkbenchUI", "LobbyUI", "WeaponClient", "GrabClient", "ViewModel", "BusClient", "SleepClient" }
for _, name in ipairs(order) do
	C[name] = require(script.Parent:WaitForChild(name))
end
for _, name in ipairs(order) do
	local module = C[name]
	if module.Init then
		local ok, err = pcall(module.Init, C)
		if not ok then
			warn("[Клиент " .. name .. "] " .. tostring(err))
		end
	end
end
