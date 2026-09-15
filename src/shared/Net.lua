-- Сетевые события (RemoteEvent) и папка общего состояния игры
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Net = {}

Net.Events = {
	-- клиент -> сервер
	"DriveInput",
	"Attack", -- оружие: удар/выстрел
	"Release", -- отпускание (лук)
	"Reload",
	"AimPitch",
	"UseItem",
	"DropItem",
	"ShopBuy",
	"ShopSell",
	"SellAll",
	"SelectClass",
	"WakeUp",
	"Sprint",
	"SelfRevive",
	"InventoryAction", -- (action: "equip"|"move"|"drop"|"use"|"split"|"unequip", data: {from, to, count, slot})
	"Craft", -- (recipeId)
	"UpgradeWeapon", -- (weaponId)
	"DropWeapon", -- (weaponId)
	"GiveItem", -- (targetPlayer, itemId, count)
	"GiveWeapon", -- (targetPlayer, weaponId)
	"ClaimDaily", -- ()
	"PartyAction", -- (action: string, data: table)
	-- сервер -> клиент
	"OpenWorkbench", -- (info: {kind, name})
	"ProfileSync", -- (profile snapshot table)
	"DailyReward", -- (info: {day, streak, reward, claimable})
	"LevelUp", -- (newLevel)
	"PartyState", -- (state table)
	"ObjectivesSync", -- (state table)
	"EventBanner", -- (info: {id, title, text, color, duration, pos})
	"HitFx", -- (info: {pos, kind: "flesh"|"wood"|"metal"|"stone"|"air", weaponId, attacker, hits, heavy, dir, gun, projectile})
	"Notify",
	"Toast",
	"DamageNumber",
	"HitConfirm",
	"PlayAnim",
	"Tracer",
	"Projectile",
	"ProjectileEnd",
	"Explosion",
	"Inventory",
	"PickupFx", -- сервер → подобравшему: (id, count, kind "item"|"weapon", position)
	"GrabAction", -- клиент → сервер: (action "grab"|"release"|"attach", model) — перенос крупных объектов (колёса и т. п.)
	"SleepEvent",
	"OpenShop",
	"OpenClassSelect",
	"Shake",
	"EndScreen",
}

local remotesFolder = nil
local stateFolder = nil

function Net.Setup()
	assert(RunService:IsServer(), "Net.Setup только на сервере")
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	for _, name in ipairs(Net.Events) do
		local r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotesFolder
	end
	remotesFolder.Parent = ReplicatedStorage

	stateFolder = Instance.new("Folder")
	stateFolder.Name = "GameState"
	stateFolder.Parent = ReplicatedStorage
end

local function folder()
	if not remotesFolder then
		if RunService:IsServer() then
			remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
		else
			remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
		end
	end
	return remotesFolder
end

function Net.Get(name)
	local f = folder()
	local r = f:FindFirstChild(name) or f:WaitForChild(name, 10)
	if not r then
		error("Нет события " .. tostring(name))
	end
	return r
end

function Net.State()
	if not stateFolder then
		if RunService:IsServer() then
			stateFolder = ReplicatedStorage:FindFirstChild("GameState")
		else
			stateFolder = ReplicatedStorage:WaitForChild("GameState")
		end
	end
	return stateFolder
end

-- Сервер: отправить всем игрокам в радиусе от точки
function Net.FireNear(name, position, radius, ...)
	local remote = Net.Get(name)
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - position).Magnitude <= radius then
			remote:FireClient(plr, ...)
		end
	end
end

return Net
