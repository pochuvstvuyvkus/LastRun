-- Заезд и режимы сервера: лобби / заезд, старт в депо, поездка, босс, победа или поражение,
-- награды профиля, возврат в лобби (телепорт с зарезервированного сервера или локально)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Net = require(Shared.Net)
local Items = require(Shared.Items)
local WeaponDefs = require(Shared.Weapons)
local Classes = require(Shared.Classes)
local Difficulty = require(Shared.Difficulty)

local Run = {
	State = "Loading",
	Kills = 0,
	StartTime = os.clock(),
	Mode = "lobby", -- "lobby" | "run"
	Difficulty = "normal",
	BusType = "school", -- совместимость: типов автобусов больше нет
	Settings = {},
	IsReserved = false, -- зарезервированный сервер (сюда телепортируется группа)
}

local S
local acc = 0
local behindWarned = {}
local granted = {} -- игроки, получившие предметы из наград в этом заезде
local runToken = 0 -- меняется при каждой смене режима, чтобы отложенные действия не срабатывали невпопад
local building = false
local returning = false
local spawnIndex = 0
local classApplied = {} -- игроки, которым применён класс из TeleportData в этом заезде

local YELLOW = Color3.fromRGB(255, 220, 120)
local RED = Color3.fromRGB(255, 110, 90)
local GREEN = Color3.fromRGB(120, 230, 120)

local function difficultyIndex(id)
	for i, d in ipairs(Difficulty.Order) do
		if d == id then
			return i
		end
	end
	return nil
end

-- Проверка настроек заезда: неизвестные значения заменяются стандартными
local function sanitizeSettings(settings)
	settings = type(settings) == "table" and settings or {}
	local diff = settings.difficulty
	if type(diff) ~= "string" or not Difficulty.Modes[diff] then
		diff = "normal"
	end
	local members = {}
	if type(settings.members) == "table" then
		for _, uid in ipairs(settings.members) do
			if type(uid) == "number" and #members < 50 then
				table.insert(members, uid)
			end
		end
	end
	local leader = type(settings.leader) == "number" and settings.leader or nil
	-- классы участников, выбранные в лобби: { ["userId"] = classId }
	local classes = {}
	if type(settings.classes) == "table" then
		local n = 0
		for uid, classId in pairs(settings.classes) do
			local key = tonumber(uid)
			if key and type(classId) == "string" and Classes.List[classId] and n < 50 then
				classes[tostring(math.floor(key))] = classId
				n = n + 1
			end
		end
	end
	return { difficulty = diff, members = members, leader = leader, classes = classes }
end

local function setModeAttributes()
	local st = Net.State()
	st:SetAttribute("Mode", Run.Mode)
	st:SetAttribute("Difficulty", Run.Difficulty)
	st:SetAttribute("DifficultyName", Difficulty.Get(Run.Difficulty).name)
	st:SetAttribute("BusType", Run.BusType)
end

-- Инструменты по режиму: в лобби WeaponService убирает оружие (S.Run.Mode == "lobby")
local function refreshAllTools()
	for _, player in ipairs(Players:GetPlayers()) do
		if S.PlayerData.Get(player) then
			local ok, err = pcall(S.Weapons.RefreshTools, player)
			if not ok then
				warn("[Run] RefreshTools: " .. tostring(err))
			end
		end
	end
end

-- Класс из лобби (TeleportData) — только в депо, пока стартовый набор не тронут
local function applyLobbyClass(player)
	if classApplied[player] then
		return
	end
	local d = S.PlayerData.Get(player)
	if not d then
		return
	end
	classApplied[player] = true
	local classes = type(Run.Settings) == "table" and Run.Settings.classes or nil
	local classId = type(classes) == "table" and classes[tostring(player.UserId)] or nil
	if type(classId) == "string" and Classes.List[classId] and d.ClassId ~= classId then
		local ok, err = pcall(S.PlayerData.ApplyClass, player, classId)
		if not ok then
			warn("[Run] ApplyClass: " .. tostring(err))
		end
	end
end

local function clearEffects()
	local effects = workspace:FindFirstChild("Effects")
	if effects then
		for _, child in ipairs(effects:GetChildren()) do
			child:Destroy()
		end
	end
end

-- Общая очистка мира заезда (перед новым заездом и при возврате в лобби)
local function cleanupRunWorld()
	S.Sleep.Clear()
	S.Zombies.ClearAll()
	S.Projectiles.Clear()
	S.Loot.Clear()
	S.Workbench.Clear()
	S.Events.Clear()
	S.Objectives.Clear()
	S.Bus.Destroy()
	S.Obstacles.Clear()
	clearEffects()
end

-- Удержать персонажей на месте, пока под ними убирают мир: иначе, ожидая своей очереди на
-- LoadCharacter, они падают в пустоту и могут погибнуть
local function holdCharacters()
	local held = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and not root.Anchored then
			root.Anchored = true
			held[player] = root
		end
	end
	return held
end

local function releaseCharacter(root)
	if root and root.Parent then
		root.Anchored = false
	end
end

-- Сброс всем сразу, затем респавн параллельно: LoadCharacter уступает, никто не ждёт очереди
local function respawnAll(held, onSpawn)
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if S.PlayerData.Get(player) then
			local ok, err = pcall(S.PlayerData.ResetForRun, player)
			if not ok then
				warn("[Run] ResetForRun: " .. tostring(err))
			end
			table.insert(list, player)
		else
			releaseCharacter(held[player])
		end
	end
	for _, player in ipairs(list) do
		task.spawn(function()
			S.PlayerData.SpawnCharacter(player)
			-- если LoadCharacter не удался, старый персонаж остался — отпустить его
			releaseCharacter(held[player])
		end)
		if onSpawn then
			onSpawn(player)
		end
	end
end

function Run.Init(services)
	S = services
	Players.PlayerRemoving:Connect(function(player)
		behindWarned[player] = nil
		granted[player] = nil
		classApplied[player] = nil
	end)
	-- неудачный телепорт при возврате в лобби: повторим общий цикл возврата
	TeleportService.TeleportInitFailed:Connect(function(player, result, message)
		if not returning or not player.Parent then
			return
		end
		if result == Enum.TeleportResult.IsTeleporting then
			return
		end
		warn("[Run] телепорт в лобби не удался для " .. player.Name .. ": " .. tostring(message))
		S.PlayerData.Notify(player, "Не удалось вернуться в лобби, пробуем ещё раз...", RED)
	end)
end

function Run.SetState(state)
	Run.State = state
	Net.State():SetAttribute("RunState", state)
end

function Run.AddKill()
	Run.Kills = Run.Kills + 1
	Net.State():SetAttribute("TeamKills", Run.Kills)
end

-- Предметы из ежедневных наград выдаются, когда автобус покинул депо:
-- до этого выбор класса в депо (PlayerData.ApplyClass) обнулил бы инвентарь
local function grantPendingItems(player)
	if granted[player] or not S.PlayerData.Get(player) then
		return
	end
	granted[player] = true
	local ok, items = pcall(S.Profile.TakePendingItems, player)
	if not ok or type(items) ~= "table" then
		return
	end
	local names = {}
	for id, count in pairs(items) do
		count = tonumber(count) or 0
		if type(id) == "string" and count > 0 then
			if Items.List[id] then
				if S.PlayerData.AddItem(player, id, count) then
					table.insert(names, (Items.List[id].name or id) .. " ×" .. math.floor(count))
				end
			elseif WeaponDefs.List[id] then
				if S.PlayerData.GiveWeapon(player, id) then
					table.insert(names, WeaponDefs.List[id].name or id)
				else
					-- Слоты заняты: оружие не пропадает, а ложится у ног игрока
					local char = player.Character
					local root = char and char:FindFirstChild("HumanoidRootPart")
					if root and S.Loot.SpawnWeapon then
						local cf = root.CFrame * CFrame.new(0, -2, -3)
						local okDrop = pcall(S.Loot.SpawnWeapon, id, cf, workspace:FindFirstChild("Loot") or workspace, { dropped = true })
						if okDrop then
							table.insert(names, (WeaponDefs.List[id].name or id) .. " (на земле)")
						end
					end
				end
			end
		end
	end
	if #names > 0 then
		S.PlayerData.Notify(player, "Награды доставлены в рюкзак: " .. table.concat(names, ", "), GREEN)
	end
end

-- Лидер группы должен иметь открытую сложность (если его профиль доступен)
local function validateAgainstLeader(settings)
	if not settings.leader then
		return
	end
	local leader = Players:GetPlayerByUserId(settings.leader)
	local profile = leader and S.Profile.Get(leader)
	if not profile then
		return
	end
	local unlocked = difficultyIndex(profile.unlockedDifficulty or "normal") or 1
	local want = difficultyIndex(settings.difficulty) or 1
	if want > unlocked then
		settings.difficulty = "normal"
	end
end

function Run.NewRun(settings)
	if building then
		return
	end
	building = true
	settings = sanitizeSettings(settings)
	runToken = runToken + 1
	returning = false

	Run.SetState("Loading")
	Run.Mode = "run"
	Run.Settings = settings
	Run.Difficulty = settings.difficulty
	Run.BusType = "school"
	setModeAttributes()

	local held = holdCharacters()
	local okClean, errClean = pcall(function()
		cleanupRunWorld()
		S.Lobby.Stop()
	end)
	if not okClean then
		warn("[Run] ошибка очистки перед заездом: " .. tostring(errClean))
	end

	local seed = Config.Seed
	if not seed or seed == 0 then
		seed = Random.new():NextInteger(1, 999999)
	end
	local ok, err = pcall(function()
		S.Stations.NewRun()
		S.World.NewRun(seed)
		S.Objectives.NewRun(seed)
		S.Events.NewRun(seed)
		S.DayNight.Reset()
		S.Bus.Build(70)
		S.World.GenerateAround(70, 700, 400)
	end)
	if not ok then
		warn("[Run] ошибка подготовки заезда: " .. tostring(err))
	end

	Run.Kills = 0
	Run.StartTime = os.clock()
	behindWarned = {}
	granted = {}
	classApplied = {}
	spawnIndex = 0
	-- классы из лобби применяем до ResetForRun (он выдаёт набор класса d.ClassId)
	for _, player in ipairs(Players:GetPlayers()) do
		applyLobbyClass(player)
	end
	local st = Net.State()
	st:SetAttribute("TeamKills", 0)
	st:SetAttribute("TotalKm", Config.RouteKm)
	st:SetAttribute("Seed", seed)
	st:SetAttribute("Weather", "")
	st:SetAttribute("RunTime", 0)
	Run.SetState("Depot")
	building = false

	local diffName = Difficulty.Get(settings.difficulty).name
	local token = runToken
	respawnAll(held, function(player)
		-- класс выбирают в лобби; окно в депо — только в тестовом режиме без лобби
		if Config.StartMode == "run" then
			task.delay(2, function()
				if player.Parent and Run.State == "Depot" and token == runToken then
					Net.Get("OpenClassSelect"):FireClient(player)
				end
			end)
		end
	end)
	task.delay(1, function()
		if token == runToken and Run.Mode == "run" then
			refreshAllTools()
		end
	end)
	Net.Get("Toast"):FireAllClients("ДЕПО", "Соберите автобус и отправляйтесь • сложность: " .. diffName, YELLOW)
end

-- Лобби на этом же сервере (Studio, публичный сервер, запасной вариант)
function Run.EnterLobby()
	runToken = runToken + 1
	returning = false
	building = false
	Run.Mode = "lobby"
	Run.Settings = {}
	Run.Difficulty = "normal"
	Run.BusType = "school"

	local held = holdCharacters()
	local okClean, errClean = pcall(function()
		cleanupRunWorld()
		S.World.Clear()
	end)
	if not okClean then
		warn("[Run] ошибка очистки перед лобби: " .. tostring(errClean))
	end
	-- в лобби дороги нет: остальные сервисы проверяют S.World.Road == nil
	if S.World.Road ~= nil then
		S.World.Road = nil
	end
	S.Bus.S = 0
	S.DayNight.Reset()

	Run.Kills = 0
	Run.StartTime = os.clock()
	behindWarned = {}
	granted = {}
	local st = Net.State()
	st:SetAttribute("TeamKills", 0)
	st:SetAttribute("TotalKm", Config.RouteKm)
	st:SetAttribute("Weather", "")
	st:SetAttribute("RunTime", 0)
	setModeAttributes()
	Run.SetState("Lobby")

	S.Lobby.Start()
	respawnAll(held)
	-- оружие в лобби не нужно: сразу и повторно, когда персонажи появятся
	refreshAllTools()
	local token = runToken
	task.delay(1.5, function()
		if token == runToken and Run.Mode == "lobby" then
			refreshAllTools()
		end
	end)
end

-- TeleportData игрока, пришедшего с сервера лобби
local function readTeleportData(player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return nil
	end
	local td = joinData.TeleportData
	if type(td) ~= "table" or td.mode ~= "run" then
		return nil
	end
	return sanitizeSettings(td)
end

local function membersReady(settings)
	if #settings.members == 0 then
		for _, player in ipairs(Players:GetPlayers()) do
			if S.PlayerData.Get(player) then
				return true
			end
		end
		return false
	end
	for _, uid in ipairs(settings.members) do
		local player = Players:GetPlayerByUserId(uid)
		if not player or not S.PlayerData.Get(player) then
			return false
		end
	end
	return true
end

local function countPresent(settings)
	local n = 0
	for _, uid in ipairs(settings.members) do
		local player = Players:GetPlayerByUserId(uid)
		if player and S.PlayerData.Get(player) then
			n = n + 1
		end
	end
	return n
end

-- Зарезервированный сервер: ждём участников группы, затем стартуем заезд
local function bootReserved()
	Run.Mode = "run"
	Run.IsReserved = true
	setModeAttributes()
	Run.SetState("Loading")
	-- площадка ожидания, пока собирается группа (без досок и кнопок)
	S.Lobby.Start({ waiting = true })
	local token = runToken
	task.spawn(function()
		while #Players:GetPlayers() == 0 do
			task.wait(0.5)
		end
		local started = os.clock()
		local timeout = Config.PartyStartTimeout or 25
		local settings = nil
		local lastToast = 0
		while os.clock() - started < timeout do
			if token ~= runToken then
				return
			end
			if not settings then
				for _, player in ipairs(Players:GetPlayers()) do
					settings = readTeleportData(player)
					if settings then
						break
					end
				end
			end
			if settings and membersReady(settings) then
				break
			end
			if os.clock() - lastToast > 6 then
				lastToast = os.clock()
				local text = "Ждём участников группы"
				if settings and #settings.members > 0 then
					text = text .. ": " .. countPresent(settings) .. " из " .. #settings.members
				end
				Net.Get("Toast"):FireAllClients("ПОДГОТОВКА ЗАЕЗДА", text, YELLOW)
			end
			task.wait(0.5)
		end
		if token ~= runToken then
			return
		end
		-- дождаться хотя бы одного загруженного игрока
		while not membersReady({ members = {} }) do
			task.wait(0.5)
		end
		settings = settings or sanitizeSettings({})
		validateAgainstLeader(settings)
		Run.NewRun(settings)
	end)
end

function Run.Boot()
	local mode = Config.StartMode
	if mode == "run" then
		Run.NewRun({})
		return
	end
	if mode == "lobby" then
		Run.EnterLobby()
		return
	end
	-- "auto": зарезервированный сервер = заезд группы, иначе (публичный сервер, Studio) — лобби
	local reserved = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
	if reserved then
		bootReserved()
	else
		Run.EnterLobby()
	end
end

function Run.GetSpawnCFrame()
	if Run.Mode == "lobby" or not S.Bus.Root then
		if S.Lobby.IsActive() then
			local cf = S.Lobby.GetSpawnCFrame()
			if cf then
				return cf
			end
		end
		if Run.Mode == "lobby" then
			return CFrame.new(0, 10, -4000)
		end
	end
	spawnIndex = spawnIndex + 1
	local cf = S.Bus.GetSpawnCFrame(spawnIndex)
	if cf then
		return cf
	end
	return CFrame.new(0, 10, 0)
end

function Run.CanRespawn()
	if Run.Mode == "lobby" or Run.State == "Loading" then
		return true
	end
	return Run.State == "Depot" or Run.State == "Driving" or Run.State == "Boss"
end

function Run.CheckWipe()
	if Run.Mode ~= "run" then
		return
	end
	if Run.State ~= "Driving" and Run.State ~= "Boss" then
		return
	end
	local any = false
	for _, player in ipairs(Players:GetPlayers()) do
		local d = S.PlayerData.Get(player)
		if d then
			any = true
			if not d.Dead then
				return
			end
		end
	end
	if any then
		Run.Fail()
	end
end

local function countStations()
	local n = 0
	if type(S.Stations.List) == "table" then
		for _, station in ipairs(S.Stations.List) do
			if station.state == "clear" then
				n = n + 1
			end
		end
	end
	return n
end

local function nextModeAfterRun()
	if Config.StartMode == "run" then
		return "run"
	end
	return "lobby"
end

-- Итоги заезда + награды профиля каждому игроку
local function collectStats(victory, returnIn)
	local km = math.clamp(Util.Round((S.Bus.S or 0) / Config.StudsPerKm, 1), 0, Config.RouteKm)
	local objectives = 0
	local okObj, count = pcall(S.Objectives.CountDone)
	if okObj and type(count) == "number" then
		objectives = count
	end
	local stations = countStations()
	local players = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local d = S.PlayerData.Get(player)
		if d then
			local award = nil
			local ok, result = pcall(S.Profile.AwardRun, player, {
				km = km,
				victory = victory,
				difficulty = Run.Difficulty,
				kills = d.Kills,
				objectives = objectives,
				stations = stations,
			})
			if ok and type(result) == "table" then
				award = result
			elseif not ok then
				warn("[Run] AwardRun: " .. tostring(result))
			end
			S.Lobby.SubmitBestKm(player, km)
			table.insert(players, {
				name = player.DisplayName,
				userId = player.UserId,
				kills = d.Kills,
				earned = d.Earned,
				revives = d.Revives,
				tickets = award and tonumber(award.tickets) or 0,
				xp = award and tonumber(award.xp) or 0,
			})
		end
	end
	return {
		km = km,
		totalKm = Config.RouteKm,
		time = os.clock() - Run.StartTime,
		kills = Run.Kills,
		players = players,
		victory = victory,
		difficulty = Run.Difficulty,
		difficultyName = Difficulty.Get(Run.Difficulty).name,
		objectives = objectives,
		stations = stations,
		nextMode = nextModeAfterRun(),
		returnIn = returnIn,
	}
end

-- Возврат всех игроков с зарезервированного сервера на публичный (лобби)
local function teleportAllToLobby(token)
	returning = true
	Net.Get("Toast"):FireAllClients("ВОЗВРАЩЕНИЕ В ЛОББИ", "Переносим команду на сервер лобби...", YELLOW)
	task.spawn(function()
		for attempt = 1, 4 do
			if token ~= runToken then
				return
			end
			local list = Players:GetPlayers()
			if #list == 0 then
				return
			end
			local ok, err = pcall(function()
				TeleportService:TeleportAsync(game.PlaceId, list)
			end)
			if not ok then
				warn("[Run] TeleportAsync (попытка " .. attempt .. "): " .. tostring(err))
				task.wait(3)
			else
				local t0 = os.clock()
				while os.clock() - t0 < 20 and #Players:GetPlayers() > 0 do
					task.wait(1)
				end
				if #Players:GetPlayers() == 0 then
					return
				end
			end
		end
		if token ~= runToken then
			return
		end
		-- не получилось: лобби прямо на этом сервере
		Net.Get("Toast"):FireAllClients("ЛОББИ", "Не удалось перенести на сервер лобби — лобби открыто здесь", RED)
		Run.EnterLobby()
	end)
end

local function afterRun(token)
	if token ~= runToken then
		return
	end
	if Config.StartMode == "run" then
		Run.NewRun(Run.Settings)
	elseif Run.IsReserved then
		teleportAllToLobby(token)
	else
		Run.EnterLobby()
	end
end

local function finishRun(kind)
	local victory = kind == "victory"
	local delaySec = victory and 30 or 14
	local stats = collectStats(victory, delaySec)
	Net.Get("EndScreen"):FireAllClients(kind, stats)
	local token = runToken
	task.delay(delaySec, function()
		afterRun(token)
	end)
end

function Run.Victory()
	if Run.Mode ~= "run" or Run.State == "Victory" or Run.State == "Failed" then
		return
	end
	Run.SetState("Victory")
	for _, z in ipairs(S.Zombies.List()) do
		if z.humanoid then
			z.humanoid.Health = 0
		end
	end
	finishRun("victory")
end

function Run.Fail()
	if Run.Mode ~= "run" or Run.State == "Victory" or Run.State == "Failed" then
		return
	end
	Run.SetState("Failed")
	finishRun("fail")
end

function Run.Update(dt)
	acc = acc + dt
	if acc < 1 then
		return
	end
	acc = 0
	if Run.Mode ~= "run" or Run.State == "Loading" then
		return
	end
	local st = Net.State()
	if Run.State ~= "Victory" and Run.State ~= "Failed" then
		st:SetAttribute("RunTime", math.floor(os.clock() - Run.StartTime))
	end

	-- опоздавшие участники группы: класс из лобби, пока автобус в депо
	if Run.State == "Depot" then
		for _, player in ipairs(Players:GetPlayers()) do
			if not classApplied[player] and S.PlayerData.Get(player) then
				applyLobbyClass(player)
			end
		end
	end

	if Run.State == "Depot" and S.Bus.Root and (S.Bus.S or 0) > Config.DepotLength then
		Run.SetState("Driving")
		Net.Get("Toast"):FireAllClients("В ПУТЬ!", "До конечной " .. Config.RouteKm .. " км. Следите за топливом и сном", YELLOW)
	end

	-- предметы из наград: всем после отправления из депо, опоздавшим — сразу при входе
	if Run.State == "Driving" or Run.State == "Boss" then
		for _, player in ipairs(Players:GetPlayers()) do
			if not granted[player] and S.PlayerData.Get(player) then
				grantPendingItems(player)
			end
		end
	end

	-- Отставших от автобуса возвращаем
	if Run.State == "Driving" and S.Bus.Root then
		local busPos = S.Bus.Root.Position
		for _, player in ipairs(Players:GetPlayers()) do
			local d = S.PlayerData.Get(player)
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if d and root and not d.Dead and not S.Sleep.IsSleeping(player) then
				local dist = Util.FlatDist(root.Position, busPos)
				if dist > Config.Player.FallBehindDistance then
					if not behindWarned[player] then
						behindWarned[player] = os.clock()
						S.PlayerData.Notify(player, "Вы слишком отстали от автобуса! Через 8 секунд вас вернёт", Color3.fromRGB(255, 170, 80))
					elseif os.clock() - behindWarned[player] > 8 then
						behindWarned[player] = nil
						if d.Downed then
							S.PlayerData.Kill(player)
						else
							player.Character:PivotTo(Run.GetSpawnCFrame())
							S.PlayerData.Notify(player, "Вас подобрал автобус", Color3.fromRGB(200, 200, 200))
						end
					end
				else
					behindWarned[player] = nil
				end
			end
		end
	end
end

return Run
