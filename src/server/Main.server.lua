-- Точка входа сервера: коллизии, папки, сервисы, главный цикл
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

Players.CharacterAutoLoads = false
-- Shift занят бегом, поэтому отключаем стандартный Shift Lock
game:GetService("StarterPlayer").EnableMouseLockOption = false

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
Net.Setup()

-- Группы столкновений: автобус не сталкивается с миром (им управляет своя логика препятствий)
local function registerGroup(name)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end
registerGroup("Bus")
registerGroup("World")
registerGroup("Zombies")
registerGroup("Debris")
PhysicsService:CollisionGroupSetCollidable("Bus", "World", false)
PhysicsService:CollisionGroupSetCollidable("Bus", "Debris", false)
PhysicsService:CollisionGroupSetCollidable("Zombies", "Zombies", false)
PhysicsService:CollisionGroupSetCollidable("Debris", "Default", false)
PhysicsService:CollisionGroupSetCollidable("Debris", "Zombies", false)
PhysicsService:CollisionGroupSetCollidable("Debris", "Debris", false)

local function folder(name)
	local f = workspace:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = workspace
	end
	return f
end
folder("World")
folder("Zombies")
folder("Loot")
folder("Effects")

local baseplate = workspace:FindFirstChild("Baseplate")
if baseplate then
	baseplate:Destroy()
end

-- Список игроков отключает клиент (SetCoreGuiEnabled работает только в LocalScript)

-- { ключ в реестре S, имя модуля }
local order = {
	{ "Obstacles", "Obstacles" },
	{ "Profile", "ProfileService" },
	{ "PlayerData", "PlayerData" },
	{ "Combat", "CombatService" },
	{ "Projectiles", "ProjectileService" },
	{ "Weapons", "WeaponService" },
	{ "Loot", "LootService" },
	{ "Grab", "GrabService" },
	{ "Workbench", "WorkbenchService" },
	{ "Zombies", "ZombieService" },
	{ "Sleep", "SleepService" },
	{ "DayNight", "DayNight" },
	{ "Bus", "BusService" },
	{ "Props", "Props" },
	{ "World", "WorldGen" },
	{ "Stations", "StationService" },
	{ "Objectives", "ObjectiveService" },
	{ "Events", "EventService" },
	{ "Shop", "ShopService" },
	{ "Lobby", "LobbyService" },
	{ "Run", "RunManager" },
}

local S = {}
for _, entry in ipairs(order) do
	S[entry[1]] = require(script.Parent:WaitForChild(entry[2]))
end
for _, entry in ipairs(order) do
	local service = S[entry[1]]
	if service.Init then
		service.Init(S)
	end
end

-- Главный цикл. Ошибка в одном сервисе не останавливает остальные.
local lastErrorAt = {}
local updateOrder = { "Run", "Lobby", "Bus", "Grab", "World", "Zombies", "Projectiles", "PlayerData", "Sleep", "DayNight", "Stations", "Objectives", "Events", "Workbench", "Profile" }
RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, 0.1)
	for _, name in ipairs(updateOrder) do
		local service = S[name]
		if service and service.Update then
			local ok, err = pcall(service.Update, dt)
			if not ok then
				local now = os.clock()
				if not lastErrorAt[name] or now - lastErrorAt[name] > 5 then
					lastErrorAt[name] = now
					warn("[" .. name .. "] " .. tostring(err))
				end
			end
		end
	end
end)

-- Решает, лобби это или заезд, и запускает нужный режим
S.Run.Boot()

Players.PlayerAdded:Connect(function(player)
	S.PlayerData.OnPlayerAdded(player)
end)
Players.PlayerRemoving:Connect(function(player)
	S.PlayerData.OnPlayerRemoving(player)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(S.PlayerData.OnPlayerAdded, player)
end

game:BindToClose(function()
	if S.Profile.SaveAll then
		S.Profile.SaveAll()
	end
end)

print("[Последний рейс] сервер запущен")
